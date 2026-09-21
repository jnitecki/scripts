#!/usr/bin/env bash
# test-interface-configurator.sh
# Version: 2.0.0
#
# Black-box tests for interface-configurator.sh, following the same style
# as tools/git-hooks/test-post-commit.sh: invokes the real script as a
# subprocess against a scratch filesystem, and asserts on side effects
# (files written, stdout/stderr, exit codes) - no sourcing of internal
# functions, consistent with this repo's "self-contained single file
# scripts" convention.
#
# All of the script's real-system touchpoints (/etc/systemd/system,
# /etc/udev/rules.d, /etc/interface-configurator/rules.d, /sys/class/net,
# systemctl, udevadm, ip, timeout, id) are overridden per-test via
# environment variables and a stub PATH, so this suite runs safely without
# root and without a real systemd/udev system.
#
# The script itself requires bash 4.3+ at runtime (namerefs in
# write_rule_config/cmd_install/apply_now_for_pattern; coproc, 4.0+, in
# watch_iface) - this is fine given it's Linux-only by design (see
# docs/requirements/generic/cross-platform-shell-compatibility.md section
# 0), but it means this suite can only exercise those codepaths where the
# `bash` resolved via `#!/usr/bin/env bash` is actually 4.3+. Where it
# isn't (e.g. macOS's system bash, still 3.2), the affected tests are
# clearly SKIPPED rather than run against the wrong interpreter and
# reported as a false pass or fail - see HAVE_BASH43 below.
#
# Usage: platforms/bash/interface-configurator/tests/test-interface-configurator.sh

set -uo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../interface-configurator.sh"

FAILURES=0
SKIPPED=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }
skip() { echo "SKIP: $1 (needs bash 4.3+, found ${RESOLVED_BASH_VERSION})"; SKIPPED=$((SKIPPED + 1)); }

RESOLVED_BASH_VERSION=$(bash -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')
BASH_MAJOR=$(bash -c 'echo "${BASH_VERSINFO[0]}"')
BASH_MINOR=$(bash -c 'echo "${BASH_VERSINFO[1]}"')
if [ "$BASH_MAJOR" -gt 4 ] || { [ "$BASH_MAJOR" -eq 4 ] && [ "$BASH_MINOR" -ge 3 ]; }; then
  HAVE_BASH43=true
else
  HAVE_BASH43=false
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

STUBBIN="${WORKDIR}/stubbin"
mkdir -p "${STUBBIN}"
mkdir -p "${WORKDIR}/active-units"
CALLS_LOG="${WORKDIR}/calls.log"

# --- stub commands, shared by every "as root, real platform" test ----------
cat > "${STUBBIN}/id" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then echo 0; else echo root; fi
EOF

# systemctl stub: logs every call. `is-active --quiet <unit>` succeeds
# only if a marker file exists under active-units/<unit> - tests toggle
# this to simulate "a watcher is already running for this interface" vs.
# not, since apply_now_for_pattern's behavior branches on it.
cat > "${STUBBIN}/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "${CALLS_LOG}"
if [ "\$1" = "is-active" ]; then
  unit="\${*: -1}"
  [ -f "${WORKDIR}/active-units/\${unit}" ] && exit 0
  exit 3
fi
exit 0
EOF

cat > "${STUBBIN}/udevadm" <<EOF
#!/usr/bin/env bash
echo "udevadm \$*" >> "${CALLS_LOG}"
exit 0
EOF

# Fake `ip`: handles the three invocation shapes the script makes.
# - `monitor link dev <iface>` (wait_for_ready) and
#   `monitor link addr dev <iface>` (watch_iface): emit a line every
#   0.05s indefinitely: the fake `timeout` below (for wait_for_ready) or
#   the coprocess's own consumer (for watch_iface) is what actually
#   bounds how long anyone waits on it.
# - `-o addr show dev <iface>`: prints the fixture file
#   addrs/<iface>.txt if present (empty otherwise) - get_addresses'
#   snapshot source, settable per-test to simulate an address change.
cat > "${STUBBIN}/ip" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "monitor" ]; then
  while true; do echo "line"; sleep 0.05; done
elif [ "\$1" = "-o" ] && [ "\$2" = "addr" ] && [ "\$3" = "show" ] && [ "\$4" = "dev" ]; then
  cat "${WORKDIR}/addrs/\$5.txt" 2>/dev/null
fi
EOF

# Fake `timeout`: real semantics (run "\$@", kill it after \$1 seconds),
# implemented with plain bash so the suite doesn't depend on GNU
# coreutils' `timeout` being on PATH (absent by default on macOS).
cat > "${STUBBIN}/timeout" <<'EOF'
#!/usr/bin/env bash
dur="$1"; shift
"$@" &
pid=$!
( sleep "$dur"; kill "$pid" 2>/dev/null ) &
watchdog=$!
wait "$pid" 2>/dev/null
kill "$watchdog" 2>/dev/null
exit 0
EOF

chmod +x "${STUBBIN}"/*

# A second stub dir without `id` (real `id` is used instead), for the
# root-requirement test below - every other stub (systemctl/udevadm/ip/
# timeout) is still faked so require_platform passes before require_root
# is reached and rejects the (real, non-root) invocation.
STUBBIN_NOID="${WORKDIR}/stubbin-noid"
mkdir -p "${STUBBIN_NOID}"
for tool in systemctl udevadm ip timeout; do
  cp "${STUBBIN}/${tool}" "${STUBBIN_NOID}/${tool}"
done
chmod +x "${STUBBIN_NOID}"/*

# args: $1=fixture root -> sets IC_* env vars pointing at fresh scratch
# locations under it, and PATH so the stubs above are found first. Used as
# a prefix before every "happy path" invocation of the script below.
fixture_env() {
  local root="$1"
  mkdir -p "${root}/systemd" "${root}/udev-rules" "${root}/rules.d" "${root}/sys-class-net"
  cat <<EOF
IC_SYSTEMD_DIR=${root}/systemd
IC_UDEV_RULES_DIR=${root}/udev-rules
IC_RULES_DIR=${root}/rules.d
IC_SYS_CLASS_NET=${root}/sys-class-net
IC_READY_TIMEOUT_SECONDS=1
PATH=${STUBBIN}:${PATH}
EOF
}

# args: $1=fixture root $2=interface name $3=ready(true|false) -> creates a
# fake /sys/class/net/<iface>/{flags,carrier} pair.
fixture_iface() {
  local root="$1" iface="$2" ready="$3" dir
  dir="${root}/sys-class-net/${iface}"
  mkdir -p "$dir"
  if [ "$ready" = "true" ]; then
    printf '0x1043' > "${dir}/flags"
    printf '1' > "${dir}/carrier"
  else
    printf '0x1002' > "${dir}/flags"
    printf '0' > "${dir}/carrier"
  fi
}

# args: $1=interface name $2=address text -> sets that interface's fake
# `ip -o addr show` output (get_addresses' data source).
fixture_addrs() {
  mkdir -p "${WORKDIR}/addrs"
  printf '%s\n' "$2" > "${WORKDIR}/addrs/$1.txt"
}

# args: $1=unit name -> marks it "active" for the systemctl stub's
# is-active check.
mark_unit_active() {
  touch "${WORKDIR}/active-units/$1"
}

run_script() {
  local root="$1"; shift
  env $(fixture_env "$root") "$SCRIPT" "$@"
}

# =============================================================================
# --help
# =============================================================================

out=$("$SCRIPT" --help 2>/dev/null); code=$?
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q -- '--install <interface_pattern>' \
   && ! printf '%s' "$out" | grep -q -- '--upgrade-type'; then
  pass "bare --help shows core options only, exits 1"
else
  fail "bare --help output/exit code unexpected (exit=$code)"
fi

out=$("$SCRIPT" --help full 2>/dev/null)
if printf '%s' "$out" | grep -q -- '--install <interface_pattern>' \
   && printf '%s' "$out" | grep -q -- '--upgrade-type'; then
  pass "--help full shows both core and upgrade options"
else
  fail "--help full missing expected content"
fi

out=$("$SCRIPT" --help upgrade 2>/dev/null)
if printf '%s' "$out" | grep -q -- '--upgrade-type' \
   && ! printf '%s' "$out" | grep -q -- '--install <interface_pattern>'; then
  pass "--help upgrade shows only upgrade options"
else
  fail "--help upgrade output unexpected"
fi

# =============================================================================
# Argument validation (no bash 4.3 needed - these all fail before reaching
# any nameref/coproc codepath)
# =============================================================================

"$SCRIPT" >/dev/null 2>&1; [ $? -eq 1 ] && pass "no mode given -> exit 1" || fail "no mode given should exit 1"
"$SCRIPT" --bogus >/dev/null 2>&1; [ $? -eq 1 ] && pass "unrecognized option -> exit 1" || fail "unrecognized option should exit 1"
"$SCRIPT" --install 'eth*' >/dev/null 2>&1
[ $? -eq 1 ] && pass "--install with no --add -> exit 1" || fail "--install with no --add should exit 1"
"$SCRIPT" --install 'eth*' --add >/dev/null 2>&1
[ $? -eq 1 ] && pass "--add missing its command -> exit 1" || fail "--add missing its command should exit 1"
"$SCRIPT" --install 'eth*' --add 'true' --remove >/dev/null 2>&1
[ $? -eq 1 ] && pass "--remove missing its command -> exit 1" || fail "--remove missing its command should exit 1"
"$SCRIPT" --run >/dev/null 2>&1; [ $? -eq 1 ] && pass "--run missing interface -> exit 1" || fail "--run missing interface should exit 1"
"$SCRIPT" --install 'eth*' --add 'true' --uninstall >/dev/null 2>&1
[ $? -eq 1 ] && pass "mutually exclusive modes rejected" || fail "mutually exclusive modes should be rejected"
"$SCRIPT" --upgrade-check --upgrade-only >/dev/null 2>&1
[ $? -eq 1 ] && pass "--upgrade-check + --upgrade-only rejected" || fail "--upgrade-check + --upgrade-only should be rejected"
"$SCRIPT" --upgrade-type replacement --no-autoupdate >/dev/null 2>&1
[ $? -eq 1 ] && pass "--upgrade-type + --no-autoupdate rejected" || fail "--upgrade-type + --no-autoupdate should be rejected"

# =============================================================================
# Root requirement (real `id`, not stubbed - asserts the actual check fires
# for a non-root invocation; this suite itself must not be run as root).
# No bash 4.3 needed - fails at require_root, before any nameref/coproc.
# =============================================================================

if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP: root-requirement test (this suite is running as root)" >&2
else
  root="${WORKDIR}/root-check"
  out=$(env $(fixture_env "$root" | grep -v '^PATH=') PATH="${STUBBIN_NOID}:${PATH}" \
        "$SCRIPT" --install 'eth*' --add 'true' 2>&1); code=$?
  if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -qi "require root"; then
    pass "--install without root is rejected"
  else
    fail "--install without root should be rejected (exit=$code)"
  fi
fi

# =============================================================================
# Platform gate: systemctl/udevadm/ip missing -> clear error, exit 1.
# No bash 4.3 needed - fails at require_platform, before any nameref/coproc.
# =============================================================================

MINPATH="${WORKDIR}/minpath"
mkdir -p "$MINPATH"
for tool in bash sed grep readlink cat mkdir date id basename dirname rm mv chmod stat head cut mktemp awk tr sort; do
  real=$(command -v "$tool" 2>/dev/null) || continue
  ln -sf "$real" "${MINPATH}/${tool}"
done
root="${WORKDIR}/platform"
mkdir -p "${root}/systemd" "${root}/udev-rules" "${root}/rules.d" "${root}/sys-class-net"
out=$(env IC_SYSTEMD_DIR="${root}/systemd" IC_UDEV_RULES_DIR="${root}/udev-rules" \
      IC_RULES_DIR="${root}/rules.d" IC_SYS_CLASS_NET="${root}/sys-class-net" \
      PATH="$MINPATH" "$SCRIPT" --install 'eth*' --add 'true' 2>&1); code=$?
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -qi "not supported on this platform"; then
  pass "missing systemctl/udevadm/ip -> clear fail-fast error, exit 1"
else
  fail "missing platform tools should fail fast with a clear error (exit=$code): $out"
fi

# =============================================================================
# --run: no matching pattern. No bash 4.3 needed - exits before wait/watch.
# =============================================================================

root="${WORKDIR}/run-nomatch"
out=$(run_script "$root" --run 'wlan9' 2>&1); code=$?
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -qi "no rule matches"; then
  pass "--run with no matching pattern logs a no-op and exits 0"
else
  fail "--run with no matching pattern should log a no-op and exit 0 (exit=$code)"
fi

# =============================================================================
# --run: matches, but interface never becomes ready. No bash 4.3 needed -
# wait_for_ready's own timeout exits before watch_iface/coproc is reached.
# =============================================================================

root="${WORKDIR}/run-notready"
fixture_iface "$root" "eth7" false
marker="${root}/marker.log"
run_script "$root" --install 'eth*' --add "echo ran >> ${marker}" >/dev/null 2>&1
rm -f "$marker"
out=$(run_script "$root" --run 'eth7' 2>&1); code=$?
if [ "$code" -eq 1 ] && [ ! -f "$marker" ] && printf '%s' "$out" | grep -qi "did not become ready"; then
  pass "--run exits 1 and never runs the command when the interface never becomes ready"
else
  fail "--run should exit 1 without running the command when never ready (exit=$code): $out"
fi

if ! $HAVE_BASH43; then
  skip "--install: rule config content"
  skip "--install: shared systemd template unit content (Type=simple, BindsTo=)"
  skip "--install: udev rule content"
  skip "--install: calls daemon-reload and reload-rules"
  skip "--install: upsert semantics"
  skip "--install: content-drift check replaces a corrupted shared unit"
  skip "--install: apply-now, watcher already active -> applies add commands directly"
  skip "--install: apply-now, no watcher active -> starts the watcher instead"
  skip "--uninstall <pattern>: removes only that pattern, leaves a still-matched watcher running"
  skip "--uninstall <pattern>: stops the watcher once no pattern matches it any more, without running remove commands"
  skip "--uninstall of an unregistered pattern is a no-op"
  skip "--uninstall with no pattern removes everything and stops every watcher"
  skip "--run: applies add commands, then enters the watch loop"
  skip "--run watch loop: interface goes down -> runs remove commands"
  skip "--run watch loop: interface comes back up -> runs add commands again"
  skip "--run watch loop: address change while ready -> remove then add"
  skip "--run watch loop: interface removed -> runs remove commands and exits 0"
  skip "--run watch loop: SIGTERM with config already gone -> exits 0 without running remove commands"
  echo ""
  echo "${SKIPPED} test(s) skipped (bash ${RESOLVED_BASH_VERSION} < 4.3 - namerefs/coproc unavailable)."
  if [ "$FAILURES" -eq 0 ]; then
    echo "All runnable tests passed."
    exit 0
  else
    echo "${FAILURES} test(s) failed."
    exit 1
  fi
fi

# =============================================================================
# --install: rule config, shared unit, udev rule content (needs bash 4.3+:
# write_rule_config/cmd_install use `local -n`)
# =============================================================================

root="${WORKDIR}/install1"
run_script "$root" --install 'eth*' --add 'echo installed' >/dev/null 2>&1
code=$?

conf=$(ls "${root}/rules.d"/*.conf 2>/dev/null | head -n1)
if [ "$code" -eq 0 ] && [ -n "$conf" ]; then
  pass "--install exits 0 and creates a rule config file"
else
  fail "--install should exit 0 and create a rule config file (exit=$code)"
fi

if [ -n "$conf" ] && grep -q "^PATTERN=" "$conf" 2>/dev/null \
   && [ "$(grep -c '^ADD=' "$conf" 2>/dev/null)" -eq 1 ] \
   && [ "$(grep -c '^REMOVE=' "$conf" 2>/dev/null)" -eq 0 ]; then
  pass "rule config stores the pattern and one add command, zero remove commands"
else
  fail "rule config content unexpected: $(cat "$conf" 2>/dev/null)"
fi

unit="${root}/systemd/interface-configurator@.service"
if [ -f "$unit" ] && grep -q '^Type=simple$' "$unit" && grep -q '^Restart=on-failure$' "$unit" \
   && grep -q '^BindsTo=sys-subsystem-net-devices-%i.device$' "$unit" \
   && grep -q -- '--no-autoupdate --run %i$' "$unit"; then
  pass "shared systemd template unit has expected content (Type=simple, BindsTo=)"
else
  fail "shared unit missing/incorrect content: $(cat "$unit" 2>/dev/null)"
fi

rule=$(ls "${root}/udev-rules"/99-interface-configurator-*.rules 2>/dev/null | head -n1)
if [ -n "$rule" ] && grep -q 'ACTION=="add"' "$rule" && grep -q 'KERNEL=="eth\*"' "$rule" \
   && grep -q 'ENV{SYSTEMD_WANTS}+="interface-configurator@%k.service"' "$rule"; then
  pass "udev rule has expected content (ACTION==add only)"
else
  fail "udev rule missing/incorrect content: $(cat "$rule" 2>/dev/null)"
fi

if grep -q '^systemctl daemon-reload$' "${CALLS_LOG}" 2>/dev/null \
   && grep -q '^udevadm control --reload-rules$' "${CALLS_LOG}" 2>/dev/null; then
  pass "--install calls systemctl daemon-reload and udevadm control --reload-rules"
else
  fail "--install should call daemon-reload and reload-rules: $(cat "${CALLS_LOG}" 2>/dev/null)"
fi

# =============================================================================
# --install: upsert semantics
# =============================================================================

root="${WORKDIR}/upsert"
run_script "$root" --install 'wlan*' --add 'echo first' >/dev/null 2>&1
run_script "$root" --install 'wlan*' --add 'echo second' --add 'echo third' --remove 'echo cleanup' >/dev/null 2>&1
confs=("${root}/rules.d"/*.conf)
if [ ${#confs[@]} -eq 1 ] && [ "$(grep -c '^ADD=' "${confs[0]}")" -eq 2 ] && [ "$(grep -c '^REMOVE=' "${confs[0]}")" -eq 1 ] \
   && ! grep -q 'first' "${confs[0]}"; then
  pass "installing the same pattern twice upserts (one file, latest add/remove lists)"
else
  fail "upsert should leave exactly one config file with the latest add/remove lists (found ${#confs[@]})"
fi

# =============================================================================
# --install: content-drift check replaces a corrupted shared unit
# =============================================================================

root="${WORKDIR}/drift"
run_script "$root" --install 'eth*' --add 'echo a' >/dev/null 2>&1
unit="${root}/systemd/interface-configurator@.service"
printf 'garbage\n' > "$unit"
marker_line=$(wc -l < "${CALLS_LOG}" 2>/dev/null || echo 0)
run_script "$root" --install 'wlan*' --add 'echo b' >/dev/null 2>&1
if grep -q '^Type=simple$' "$unit" && ! grep -q 'garbage' "$unit" \
   && tail -n "+$((marker_line + 1))" "${CALLS_LOG}" | grep -q '^systemctl daemon-reload$'; then
  pass "corrupted shared unit is detected and replaced, with a reload"
else
  fail "corrupted shared unit should be replaced on next --install"
fi

# =============================================================================
# --install: apply-now behavior depends on whether a watcher is already
# active for the matching interface (avoids double-running add commands)
# =============================================================================

root="${WORKDIR}/applynow-active"
fixture_iface "$root" "eth0" true
mark_unit_active "interface-configurator@eth0.service"
marker="${root}/marker.log"
run_script "$root" --install 'eth*' --add "echo ran:\$IFACE:\$1 >> ${marker}" >/dev/null 2>&1
if [ -f "$marker" ] && grep -q '^ran:eth0:eth0$' "$marker"; then
  pass "--install applies add commands directly when a watcher is already active"
else
  fail "--install should have applied add commands directly for an already-watched interface"
fi

root="${WORKDIR}/applynow-inactive"
fixture_iface "$root" "eth0" true
marker="${root}/marker.log"
: > "${CALLS_LOG}"
run_script "$root" --install 'eth*' --add "echo ran >> ${marker}" >/dev/null 2>&1
if [ ! -f "$marker" ] && grep -q '^systemctl start interface-configurator@eth0.service$' "${CALLS_LOG}"; then
  pass "--install starts the watcher (instead of applying directly) when none is active yet"
else
  fail "--install should start the watcher, not double-apply, when none is active: $(cat "${CALLS_LOG}")"
fi

# =============================================================================
# --uninstall
# =============================================================================

root="${WORKDIR}/uninstall-still-matched"
fixture_iface "$root" "eth0" true
mark_unit_active "interface-configurator@eth0.service"
run_script "$root" --install 'eth*' --add 'echo a' >/dev/null 2>&1
run_script "$root" --install 'eth0' --add 'echo b' >/dev/null 2>&1
: > "${CALLS_LOG}"
run_script "$root" --uninstall 'eth0' >/dev/null 2>&1
if ! grep -q '^systemctl stop interface-configurator@eth0.service$' "${CALLS_LOG}"; then
  pass "--uninstall <pattern> leaves a watcher running when another pattern still matches its interface"
else
  fail "--uninstall <pattern> should not stop a watcher another pattern still matches"
fi

root="${WORKDIR}/uninstall-unmatched"
fixture_iface "$root" "eth0" true
mark_unit_active "interface-configurator@eth0.service"
run_script "$root" --install 'eth*' --add 'echo a' --remove 'echo cleanup' >/dev/null 2>&1
marker="${root}/marker.log"
: > "${CALLS_LOG}"
run_script "$root" --uninstall 'eth*' >/dev/null 2>&1
if grep -q '^systemctl stop interface-configurator@eth0.service$' "${CALLS_LOG}" && [ ! -f "$marker" ]; then
  pass "--uninstall stops the watcher once no pattern matches its interface, without running remove commands"
else
  fail "--uninstall should stop the now-unmatched watcher and never run its remove commands"
fi

root="${WORKDIR}/uninstall-noop"
run_script "$root" --install 'eth*' --add 'echo a' >/dev/null 2>&1
out=$(run_script "$root" --uninstall 'nonexistent*' 2>&1); code=$?
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -qi "nothing to remove"; then
  pass "--uninstall of an unregistered pattern is a no-op, exit 0"
else
  fail "--uninstall of an unregistered pattern should be a no-op (exit=$code)"
fi

root="${WORKDIR}/uninstall-all"
fixture_iface "$root" "eth0" true
fixture_iface "$root" "wlan0" true
mark_unit_active "interface-configurator@eth0.service"
mark_unit_active "interface-configurator@wlan0.service"
run_script "$root" --install 'eth*' --add 'echo a' >/dev/null 2>&1
run_script "$root" --install 'wlan*' --add 'echo b' >/dev/null 2>&1
: > "${CALLS_LOG}"
run_script "$root" --uninstall >/dev/null 2>&1
remaining=("${root}/rules.d"/*.conf)
if [ ${#remaining[@]} -eq 0 ] && [ ! -f "${root}/systemd/interface-configurator@.service" ] \
   && grep -q '^systemctl stop interface-configurator@eth0.service$' "${CALLS_LOG}" \
   && grep -q '^systemctl stop interface-configurator@wlan0.service$' "${CALLS_LOG}"; then
  pass "--uninstall with no pattern removes everything and stops every watcher"
else
  fail "--uninstall with no pattern should remove every pattern, stop every watcher, and remove the shared unit"
fi

# =============================================================================
# --run: applies add commands, then enters the watch loop (coproc, 4.0+)
# =============================================================================

root="${WORKDIR}/run-watch"
fixture_iface "$root" "eth7" true
fixture_addrs "eth7" "inet 192.168.1.5/24"
marker="${root}/marker.log"
run_script "$root" --install 'eth*' --add "echo add:\$IFACE >> ${marker}" --remove "echo remove:\$IFACE >> ${marker}" >/dev/null 2>&1
rm -f "$marker"

# --run never returns on its own now - it keeps watching until the
# interface disappears or it's signaled. Run it in the background, give
# the watch loop time to actually start (its coproc + first 1s poll
# tick), then drive it through each transition via the fixtures.
(
  eval "$(fixture_env "$root")"
  export IC_SYSTEMD_DIR IC_UDEV_RULES_DIR IC_RULES_DIR IC_SYS_CLASS_NET IC_READY_TIMEOUT_SECONDS PATH
  "$SCRIPT" --run eth7
) &
RUN_PID=$!
sleep 1.5

if [ -f "$marker" ] && grep -q '^add:eth7$' "$marker"; then
  pass "--run applies add commands before entering the watch loop"
else
  fail "--run should have applied add commands before watching"
fi

# down -> remove
: > "$marker"
fixture_iface "$root" "eth7" false
sleep 1.5
if grep -q '^remove:eth7$' "$marker" && ! grep -q '^add:eth7$' "$marker"; then
  pass "watch loop: interface going down runs remove commands"
else
  fail "watch loop should have run remove commands when the interface went down: $(cat "$marker" 2>/dev/null)"
fi

# up again -> add
: > "$marker"
fixture_iface "$root" "eth7" true
sleep 1.5
if grep -q '^add:eth7$' "$marker" && ! grep -q '^remove:eth7$' "$marker"; then
  pass "watch loop: interface coming back up runs add commands again"
else
  fail "watch loop should have run add commands when the interface came back up: $(cat "$marker" 2>/dev/null)"
fi

# address change while ready -> remove then add
: > "$marker"
fixture_addrs "eth7" "inet 192.168.1.9/24"
sleep 1.5
if [ "$(cat "$marker" 2>/dev/null)" = "$(printf 'remove:eth7\nadd:eth7')" ]; then
  pass "watch loop: address change while ready runs remove then add"
else
  fail "watch loop should have run remove then add on address change: $(cat "$marker" 2>/dev/null)"
fi

# removal -> remove commands, then the watcher exits on its own
: > "$marker"
rm -rf "${root}/sys-class-net/eth7"
sleep 2
if ! kill -0 "$RUN_PID" 2>/dev/null && grep -q '^remove:eth7$' "$marker"; then
  pass "watch loop: interface removal runs remove commands and the watcher exits"
else
  fail "watch loop should have run remove commands and exited on removal"
  kill "$RUN_PID" 2>/dev/null
fi
wait "$RUN_PID" 2>/dev/null

# =============================================================================
# --run watch loop: SIGTERM after the pattern's config was already deleted
# (the --uninstall ordering) runs no remove commands.
# =============================================================================

root="${WORKDIR}/run-sigterm-unconfigured"
fixture_iface "$root" "eth9" true
marker="${root}/marker.log"
run_script "$root" --install 'eth*' --add "echo add:\$IFACE >> ${marker}" --remove "echo remove:\$IFACE >> ${marker}" >/dev/null 2>&1
rm -f "$marker"

(
  eval "$(fixture_env "$root")"
  export IC_SYSTEMD_DIR IC_UDEV_RULES_DIR IC_RULES_DIR IC_SYS_CLASS_NET IC_READY_TIMEOUT_SECONDS PATH
  "$SCRIPT" --run eth9
) &
RUN_PID=$!
sleep 1.5
: > "$marker"

# Simulate what --uninstall does: delete the config before stopping.
rm -f "${root}/rules.d"/*.conf
kill -TERM "$RUN_PID" 2>/dev/null
sleep 1.5

if ! kill -0 "$RUN_PID" 2>/dev/null && [ ! -s "$marker" ]; then
  pass "watch loop: SIGTERM with config already deleted exits without running remove commands"
else
  fail "watch loop should not run remove commands when its config was already deleted before stopping"
  kill "$RUN_PID" 2>/dev/null
fi
wait "$RUN_PID" 2>/dev/null

# =============================================================================

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
