#!/usr/bin/env bash
# test-container-upgrader.sh
#
# Unit tests for write_run_state_log() (see
# docs/requirements/implemented/run-summary-log.md), the login status
# banner - status_main/register_banner_main/unregister_banner_main (see
# docs/requirements/implemented/login-status-banner.md) - and the settings
# file parser/loader (docs/requirements/implemented/settings-file.md).
# Settings precedence and image prune (docs/requirements/implemented/
# image-prune.md) are additionally tested black-box at the end, running a
# copy of the script against a stub docker. Otherwise deliberately narrower
# than platforms/bash/interface-configurator's fully black-box convention:
# a true black-box run of container-upgrader.sh would require stubbing
# docker/podman across the container inspect/pull/restart lifecycle just to
# reach the report phase, wildly disproportionate for testing one pure,
# self-contained function whose only real dependency is jq. Instead, the
# function's exact source is extracted from the real script (between its
# own definition and the matching closing brace) and evaluated here, so
# these tests can never silently drift from the shipped implementation -
# the same "extract and test in isolation" approach already used for the
# self-upgrade functions (see docs/implementation.md), just committed as a
# real test file this time instead of one-off manual verification.
#
# Usage: platforms/bash/container-upgrader/tests/test-container-upgrader.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../container-upgrader.sh"

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: all tests (jq not found on PATH)"
  exit 0
fi

# Extract write_run_state_log()'s exact source from the real script.
func_src=$(sed -n '/^write_run_state_log() {$/,/^}$/p' "$SCRIPT")
if [[ -z "$func_src" ]]; then
  fail "could not extract write_run_state_log() from $SCRIPT - test can't run"
  exit 1
fi
eval "$func_src"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# --- Test 1: a single run writes one correctly-shaped JSON entry ----------
STATE_LOG_FILE="$WORKDIR/one.log"
STATE_LOG_MAX_ENTRIES=50
SCRIPT_VERSION="1.1.8-dev1"
MODE="safe"
PRUNE="dangling"
write_run_state_log 2 3 1 5 4

if [[ $(wc -l < "$STATE_LOG_FILE" | tr -d ' ') -eq 1 ]]; then
  pass "writes exactly one line for one run"
else
  fail "expected exactly one line after one run, got $(wc -l < "$STATE_LOG_FILE")"
fi

line=$(cat "$STATE_LOG_FILE")
expected_fields=(
  ".version == \"1.1.8-dev1\""
  ".mode == \"safe\""
  ".prune == \"dangling\""
  ".containers_not_uptodate == 2"
  ".images_updated_successfully == 3"
  ".images_update_failed == 1"
  ".containers_updated_successfully == 5"
  ".containers_update_failed == 4"
)
all_ok=true
for expr in "${expected_fields[@]}"; do
  if ! echo "$line" | jq -e "$expr" >/dev/null 2>&1; then
    fail "field check failed: $expr (entry: $line)"
    all_ok=false
  fi
done
$all_ok && pass "all fields present with correct values"

if echo "$line" | jq -e '.date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null 2>&1; then
  pass "date field is ISO-8601 UTC (Z-suffixed)"
else
  fail "date field is not ISO-8601 UTC: $(echo "$line" | jq -r '.date')"
fi

# --- Test 2: successive runs append, most recent last ---------------------
STATE_LOG_FILE="$WORKDIR/append.log"
STATE_LOG_MAX_ENTRIES=50
write_run_state_log 0 0 0 1 0
write_run_state_log 0 0 0 2 0
write_run_state_log 0 0 0 3 0

count=$(wc -l < "$STATE_LOG_FILE" | tr -d ' ')
if [[ "$count" -eq 3 ]]; then
  pass "three runs append three lines"
else
  fail "expected 3 lines after 3 runs, got $count"
fi

last_val=$(tail -n1 "$STATE_LOG_FILE" | jq '.containers_updated_successfully')
if [[ "$last_val" == "3" ]]; then
  pass "most recent run is the last line"
else
  fail "expected last line's containers_updated_successfully == 3, got $last_val"
fi

# --- Test 3: trimmed to STATE_LOG_MAX_ENTRIES ------------------------------
STATE_LOG_FILE="$WORKDIR/trim.log"
STATE_LOG_MAX_ENTRIES=5
for i in $(seq 1 8); do
  write_run_state_log 0 0 0 "$i" 0
done

count=$(wc -l < "$STATE_LOG_FILE" | tr -d ' ')
if [[ "$count" -eq 5 ]]; then
  pass "trims to STATE_LOG_MAX_ENTRIES (5) after 8 runs"
else
  fail "expected 5 lines after trimming, got $count"
fi

first_kept=$(head -n1 "$STATE_LOG_FILE" | jq '.containers_updated_successfully')
last_kept=$(tail -n1 "$STATE_LOG_FILE" | jq '.containers_updated_successfully')
if [[ "$first_kept" == "4" && "$last_kept" == "8" ]]; then
  pass "trimming keeps the most recent entries (4..8), drops the oldest"
else
  fail "expected kept range 4..8, got first=$first_kept last=$last_kept"
fi

# --- Test 4: best-effort - unwritable directory doesn't error out ---------
STATE_LOG_FILE="/nonexistent-root-only-path/definitely/not/writable/x.log"
STATE_LOG_MAX_ENTRIES=50
if write_run_state_log 0 0 0 0 0; then
  pass "returns success even when the target directory can't be created (best-effort)"
else
  fail "write_run_state_log should never itself fail the caller (best-effort)"
fi

# ===========================================================================
# Login status banner (docs/requirements/implemented/login-status-banner.md)
# ===========================================================================
# Same extraction approach as write_run_state_log above. log()/err() are
# pulled in too since register_banner_main/unregister_banner_main call
# them; COLOR_RED/COLOR_BOLD/COLOR_RESET/HAD_ERRORS are the globals err()
# needs, set directly here rather than extracted (trivial, not worth a
# sed pattern of their own).
extract_fn() {
  local name="$1" src
  src=$(sed -n "/^${name}() {\$/,/^}\$/p" "$SCRIPT")
  [[ -z "$src" ]] && { fail "could not extract ${name}() from $SCRIPT"; return 1; }
  eval "$src"
}
# log() is a one-liner (opening/closing brace on the same line), so the
# multi-line extract_fn pattern above doesn't match it - grep the single
# line directly instead.
log_src=$(grep -m1 '^log() {' "$SCRIPT")
[[ -z "$log_src" ]] && { fail "could not extract log() from $SCRIPT"; exit 1; }
eval "$log_src"
extract_fn err || exit 1
extract_fn parse_to_epoch || exit 1
extract_fn resolve_script_path || exit 1
extract_fn status_main || exit 1
extract_fn register_banner_main || exit 1
extract_fn unregister_banner_main || exit 1
COLOR_RED=""; COLOR_BOLD=""; COLOR_RESET=""; HAD_ERRORS=false
STATUS_STALE_DAYS_EXPLICIT=false

# --- status_main: no log yet -> nothing, exit 0 ----------------------------
STATE_LOG_FILE="$WORKDIR/status-none.log"
STATUS_STALE_DAYS=3
out=$(status_main); code=$?
if [[ -z "$out" && "$code" -eq 0 ]]; then
  pass "status_main: no log file -> nothing, exit 0"
else
  fail "status_main: expected empty output and exit 0 with no log, got [$out] exit=$code"
fi

# --- status_main: containers not up to date -> awaiting-upgrade line ------
STATE_LOG_FILE="$WORKDIR/status-awaiting.log"
echo '{"date":"2026-09-20T00:00:00Z","version":"1.1.8-dev2","mode":"safe","containers_not_uptodate":2,"images_updated_successfully":1,"images_update_failed":0,"containers_updated_successfully":3,"containers_update_failed":1}' > "$STATE_LOG_FILE"
out=$(status_main); code=$?
if [[ "$out" == "3 container(s) are awaiting upgrade." && "$code" -eq 0 ]]; then
  pass "status_main: sums containers_not_uptodate + containers_update_failed (2+1=3)"
else
  fail "status_main: expected '3 container(s) are awaiting upgrade.', got [$out] exit=$code"
fi

# --- status_main: clean run, stale (>= threshold) --------------------------
STATE_LOG_FILE="$WORKDIR/status-stale.log"
five_days_ago=$(date -u -v-5d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '5 days ago' '+%Y-%m-%dT%H:%M:%SZ')
echo "{\"date\":\"$five_days_ago\",\"version\":\"1.1.8-dev2\",\"mode\":\"safe\",\"containers_not_uptodate\":0,\"images_updated_successfully\":0,\"images_update_failed\":0,\"containers_updated_successfully\":2,\"containers_update_failed\":0}" > "$STATE_LOG_FILE"
out=$(status_main); code=$?
if [[ "$out" == "Containers were last upgraded 5 day(s) ago." && "$code" -eq 0 ]]; then
  pass "status_main: clean run 5 days ago (>= 3-day default threshold) -> stale line"
else
  fail "status_main: expected 'Containers were last upgraded 5 day(s) ago.', got [$out] exit=$code"
fi

# --- status_main: clean run, today -> nothing ------------------------------
STATE_LOG_FILE="$WORKDIR/status-fresh.log"
today=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "{\"date\":\"$today\",\"version\":\"1.1.8-dev2\",\"mode\":\"safe\",\"containers_not_uptodate\":0,\"images_updated_successfully\":0,\"images_update_failed\":0,\"containers_updated_successfully\":2,\"containers_update_failed\":0}" > "$STATE_LOG_FILE"
out=$(status_main); code=$?
if [[ -z "$out" && "$code" -eq 0 ]]; then
  pass "status_main: clean run today -> nothing"
else
  fail "status_main: expected nothing for a fresh clean run, got [$out] exit=$code"
fi

# --- status_main: custom --status-stale-days below the elapsed days -------
STATE_LOG_FILE="$WORKDIR/status-custom-threshold.log"
echo "{\"date\":\"$five_days_ago\",\"version\":\"1.1.8-dev2\",\"mode\":\"safe\",\"containers_not_uptodate\":0,\"images_updated_successfully\":0,\"images_update_failed\":0,\"containers_updated_successfully\":2,\"containers_update_failed\":0}" > "$STATE_LOG_FILE"
STATUS_STALE_DAYS=10
out=$(status_main); code=$?
STATUS_STALE_DAYS=3
if [[ -z "$out" && "$code" -eq 0 ]]; then
  pass "status_main: --status-stale-days 10 with 5 elapsed days -> nothing"
else
  fail "status_main: expected nothing below a raised threshold, got [$out] exit=$code"
fi

# --- register_banner_main: refuses when not root ---------------------------
MOTD_DIR="$WORKDIR/motd-norootcheck.d"
MOTD_SCRIPT_NAME="92-container-upgrader"
MOTD_MARKER="# Auto-generated by container-upgrader.sh --register-banner"
mkdir -p "$MOTD_DIR"
out=$(register_banner_main 2>&1); code=$?
if [[ "$code" -ne 0 && ! -f "$MOTD_DIR/$MOTD_SCRIPT_NAME" ]]; then
  pass "register_banner_main: refuses when EUID != 0, writes nothing"
else
  fail "register_banner_main: expected non-zero exit and no file written when not root, got exit=$code"
fi

# --- register/unregister as "root" (EUID check patched for this test only,
# since we can't become real root here - same technique used in this
# feature's own live verification, see docs/implementation.md) -----------
root_register_src=$(sed -n '/^register_banner_main() {$/,/^}$/p' "$SCRIPT" | sed 's/"\$EUID" -ne 0/"0" -ne 0/')
root_unregister_src=$(sed -n '/^unregister_banner_main() {$/,/^}$/p' "$SCRIPT" | sed 's/"\$EUID" -ne 0/"0" -ne 0/')
eval "$root_register_src"
eval "$root_unregister_src"

MOTD_DIR="$WORKDIR/motd.d"
mkdir -p "$MOTD_DIR"
SCRIPT_PATH="$SCRIPT"
SUDO_USER="testuser"
out=$(register_banner_main 2>&1); code=$?
motd_file="$MOTD_DIR/$MOTD_SCRIPT_NAME"
if [[ "$code" -eq 0 && -f "$motd_file" ]]; then
  pass "register_banner_main (as root): writes the MOTD script"
else
  fail "register_banner_main (as root): expected exit 0 and a written file, got exit=$code output=[$out]"
fi

if grep -qF "$MOTD_MARKER" "$motd_file" 2>/dev/null && grep -qF 'su - testuser -c' "$motd_file" 2>/dev/null; then
  pass "register_banner_main: generated script carries the marker and the correct target user"
else
  fail "register_banner_main: generated script missing marker or target user: $(cat "$motd_file" 2>/dev/null)"
fi

perm=$(stat -f '%Lp' "$motd_file" 2>/dev/null || stat -c '%a' "$motd_file" 2>/dev/null)
if [[ "$perm" == "755" ]]; then
  pass "register_banner_main: sets mode 755"
else
  fail "register_banner_main: expected mode 755, got $perm"
fi

# argv-splitting sanity check: the generated su line must hand `-c` the
# path+flag as ONE argument (su -c expects a single command string), not
# two separate words - verified against a real bash argv dump.
su_line=$(grep '^su - ' "$motd_file")
argv_check_script="$WORKDIR/argv_check.sh"
{ echo '#!/usr/bin/env bash'; echo 'echo "ARGC=$#"'; } > "$argv_check_script"
chmod +x "$argv_check_script"
# shellcheck disable=SC2086 - intentional: reproducing the generated line's own word-splitting
argc_out=$(eval "${argv_check_script} ${su_line#su - }")
if [[ "$argc_out" == "ARGC=3" ]]; then
  pass "generated su line: -c receives the path+--status as one argument (su - user -c <one-arg> = 3 args)"
else
  fail "generated su line: expected 3 args after 'su -', got: $argc_out"
fi

if ! grep -q -- '--status-stale-days' "$motd_file"; then
  pass "register_banner_main: no --status-stale-days in the generated line when not given"
else
  fail "register_banner_main: unexpected --status-stale-days in generated line: $(cat "$motd_file")"
fi

STATUS_STALE_DAYS_EXPLICIT=true
STATUS_STALE_DAYS=7
out=$(register_banner_main 2>&1); code=$?
if [[ "$code" -eq 0 ]] && grep -qF -- '--status\ --status-stale-days\ 7' "$motd_file"; then
  pass "register_banner_main: passes an explicit --status-stale-days through to the generated --status line"
else
  fail "register_banner_main: expected '--status --status-stale-days 7' (printf %q-escaped) in generated line, got: $(cat "$motd_file")"
fi
STATUS_STALE_DAYS_EXPLICIT=false
STATUS_STALE_DAYS=3

out=$(unregister_banner_main 2>&1); code=$?
if [[ "$code" -eq 0 && ! -f "$motd_file" ]]; then
  pass "unregister_banner_main (as root): removes the registered file"
else
  fail "unregister_banner_main (as root): expected exit 0 and file removed, got exit=$code output=[$out]"
fi

out=$(unregister_banner_main 2>&1); code=$?
if [[ "$code" -eq 0 ]]; then
  pass "unregister_banner_main: no-ops cleanly when nothing is registered"
else
  fail "unregister_banner_main: expected exit 0 when already absent, got exit=$code"
fi

echo "#!/bin/sh" > "$motd_file"
echo "echo not ours" >> "$motd_file"
out=$(unregister_banner_main 2>&1); code=$?
if [[ "$code" -ne 0 && -f "$motd_file" ]]; then
  pass "unregister_banner_main: refuses to remove a file without the marker comment"
else
  fail "unregister_banner_main: expected refusal (non-zero exit, file left alone) for a foreign file, got exit=$code, exists=$([[ -f "$motd_file" ]] && echo yes || echo no)"
fi

# ===========================================================================
# Settings file (docs/requirements/pending/settings-file.md) - unit tests
# ===========================================================================
extract_fn setting_check || exit 1
extract_fn setting_assign || exit 1
extract_fn settings_parse_file || exit 1
extract_fn settings_load_all || exit 1
extract_fn settings_banner_line || exit 1
extract_fn prune_until_filter || exit 1

# --- setting_check -----------------------------------------------------------
check_ok() {
  if setting_check "$1" "$2" >/dev/null; then pass "setting_check accepts $1=$2"
  else fail "setting_check should accept $1=$2"; fi
}
check_bad() {
  if setting_check "$1" "$2" >/dev/null; then fail "setting_check should reject $1=$2"
  else pass "setting_check rejects $1=$2"; fi
}
check_ok mode safe
check_bad mode fast
check_ok timeout 0
check_bad timeout abc
check_bad timeout ""
check_ok engine auto
check_ok prune dangling
check_bad prune some
check_ok prune-until 7d
check_ok prune-until 30m
check_ok prune-until none
check_bad prune-until 0d
check_bad prune-until 7w
check_ok upgrade-level auto
check_ok skip-crashing false
check_bad skip-crashing yes
setting_check restart-all true >/dev/null; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "setting_check: non-setting key -> return 2"
else fail "setting_check: expected return 2 for a non-setting key, got $rc"; fi

# --- prune_until_filter: Go durations have no day unit ----------------------
for pair in "7d:168h" "1d:24h" "12h:12h" "30m:30m"; do
  got=$(prune_until_filter "${pair%%:*}")
  if [[ "$got" == "${pair##*:}" ]]; then pass "prune_until_filter ${pair%%:*} -> ${pair##*:}"
  else fail "prune_until_filter ${pair%%:*}: expected ${pair##*:}, got $got"; fi
done

# --- settings_parse_file: valid content --------------------------------------
cfg="$WORKDIR/valid.conf"
printf '%s\n' \
  '# full-line comment' \
  '   ; indented semicolon comment' \
  $'\t# tab-indented comment' \
  '' \
  '  prune   =   dangling  ' \
  'mode="simple"' \
  "prune-until = '7d'" \
  $'timeout = 45\r' > "$cfg"
if settings_parse_file "$cfg"; then
  joined=""
  for ((i = 0; i < ${#SETTINGS_FILE_KEYS[@]}; i++)); do
    joined="${joined}${SETTINGS_FILE_KEYS[$i]}=${SETTINGS_FILE_VALUES[$i]};"
  done
  if [[ "$joined" == "prune=dangling;mode=simple;prune-until=7d;timeout=45;" ]]; then
    pass "settings_parse_file: comments, whitespace, quotes and CRLF handled"
  else
    fail "settings_parse_file: unexpected parse result [$joined]"
  fi
else
  fail "settings_parse_file: valid file rejected: $SETTINGS_ERROR"
fi

# --- settings_parse_file: content errors name file:line ----------------------
parse_err() {
  local desc="$1" expect="$2" content="$3"
  printf '%s\n' "$content" > "$WORKDIR/bad.conf"
  if settings_parse_file "$WORKDIR/bad.conf"; then
    fail "settings_parse_file should reject: $desc"
  elif [[ "$SETTINGS_ERROR" == *"$WORKDIR/bad.conf:"*"$expect"* ]]; then
    pass "settings_parse_file rejects $desc ($SETTINGS_ERROR)"
  else
    fail "settings_parse_file: $desc - unexpected message [$SETTINGS_ERROR]"
  fi
}
parse_err "section header" "2: section" $'prune = all\n[main]'
parse_err "line without =" "1: malformed" 'prune all'
parse_err "empty key" "1: malformed" ' = all'
parse_err "duplicate key" "3: duplicate" $'prune = all\nmode = safe\nprune = none'
parse_err "unknown key" "1: unknown setting" 'colour = red'
parse_err "command-line-only key" "1: dry-run is only valid on the command line" 'dry-run = true'
parse_err "alias key" "1: no-autoupdate is only valid on the command line" 'no-autoupdate = true'
parse_err "negation key" "1: no-skip-crashing is only valid on the command line" 'no-skip-crashing = true'
parse_err "invalid value" "1: invalid value for mode" 'mode = fast'
parse_err "trailing comment is part of the value" "1: invalid value for prune" 'prune = all # comment'

# --- settings_load_all: precedence, per key, CLI wins ------------------------
reset_settings_state() {
  MODE="safe"; TIMEOUT=30; PRUNE="none"; PRUNE_UNTIL=""; ENGINE=""; ENGINE_EXPLICIT=false
  SKIP_CRASHING=false; UPGRADE_TYPE=""; UPGRADE_LEVEL=""; STATUS_STALE_DAYS=3
  CLI_SET_KEYS=" "; SETTINGS_SILENT=false
}
SETTINGS_SYSTEM_FILE="$WORKDIR/sys.conf"
SETTINGS_SCRIPT_FILE="$WORKDIR/scriptdir.conf"
SETTINGS_USER_FILE="$WORKDIR/user.conf"
printf '%s\n' 'prune = all' 'mode = simple' 'timeout = 10' 'engine = podman' > "$SETTINGS_SYSTEM_FILE"
printf '%s\n' 'prune = dangling' 'timeout = 20' > "$SETTINGS_SCRIPT_FILE"
printf '%s\n' 'timeout = 30' 'upgrade-level = beta' > "$SETTINGS_USER_FILE"
reset_settings_state
CLI_SET_KEYS=" mode "; MODE="safe"
settings_load_all
if [[ "$PRUNE" == "dangling" && "$TIMEOUT" == "30" && "$MODE" == "safe" && "$ENGINE" == "podman" \
      && "$ENGINE_EXPLICIT" == "true" && "$UPGRADE_LEVEL" == "beta" ]]; then
  pass "settings_load_all: per-key precedence user > script-dir > system, CLI-set key untouched"
else
  fail "settings_load_all: got PRUNE=$PRUNE TIMEOUT=$TIMEOUT MODE=$MODE ENGINE=$ENGINE/$ENGINE_EXPLICIT UPGRADE_LEVEL=$UPGRADE_LEVEL"
fi
expected_line="Using settings from: $SETTINGS_USER_FILE, $SETTINGS_SCRIPT_FILE, $SETTINGS_SYSTEM_FILE"
if [[ "$(settings_banner_line)" == "$expected_line" ]]; then
  pass "settings_banner_line lists loaded files, highest precedence first"
else
  fail "settings_banner_line: expected [$expected_line], got [$(settings_banner_line)]"
fi

rm -f "$SETTINGS_SCRIPT_FILE" "$SETTINGS_SYSTEM_FILE"
printf '%s\n' 'engine = auto' 'upgrade-level = auto' 'prune-until = none' > "$SETTINGS_USER_FILE"
reset_settings_state
ENGINE="docker"; ENGINE_EXPLICIT=true; UPGRADE_LEVEL="rc"; PRUNE_UNTIL="7d"
settings_load_all
if [[ -z "$ENGINE" && "$ENGINE_EXPLICIT" == "false" && -z "$UPGRADE_LEVEL" && -z "$PRUNE_UNTIL" ]]; then
  pass "settings_load_all: auto/none values restore the built-in defaults"
else
  fail "settings_load_all: auto/none not applied (ENGINE=$ENGINE/$ENGINE_EXPLICIT UPGRADE_LEVEL=$UPGRADE_LEVEL PRUNE_UNTIL=$PRUNE_UNTIL)"
fi

reset_settings_state
rm -f "$SETTINGS_USER_FILE"
settings_load_all
if [[ -z "$(settings_banner_line)" ]]; then
  pass "settings_banner_line: nothing printed when no file was loaded"
else
  fail "settings_banner_line: expected nothing, got [$(settings_banner_line)]"
fi

# Silent mode (--status): a broken file is ignored whole, without output.
printf '%s\n' 'prune = all' > "$SETTINGS_SYSTEM_FILE"
printf '%s\n' 'status-stale-days = 9' 'bogus = 1' > "$SETTINGS_USER_FILE"
reset_settings_state
SETTINGS_SILENT=true
out=$(settings_load_all 2>&1; echo "PRUNE=$PRUNE STALE=$STATUS_STALE_DAYS")
if [[ "$out" == "PRUNE=all STALE=3" ]]; then
  pass "settings_load_all (silent): broken file ignored as a whole, others still applied, no output"
else
  fail "settings_load_all (silent): unexpected [$out]"
fi

reset_settings_state
out=$( (settings_load_all) 2>&1 ); code=$?
if [[ "$code" -eq 1 && "$out" == *"$SETTINGS_USER_FILE:2: unknown setting"* ]]; then
  pass "settings_load_all: content error is fatal (exit 1) and names file:line"
else
  fail "settings_load_all: expected exit 1 with file:line, got exit=$code [$out]"
fi
rm -f "$SETTINGS_SYSTEM_FILE" "$SETTINGS_USER_FILE"

# ===========================================================================
# Settings file + image prune - black-box runs against a stub engine
# ===========================================================================
# A copy of the real script runs against a stub `docker` that records every
# invocation: one running container whose image is already current, so a
# run goes all the way through prune, pull and the report without
# restarting anything. The copy lives in its own directory so its
# script-location settings file never touches the repo.
BB="$WORKDIR/bb"
mkdir -p "$BB/bin" "$BB/app" "$BB/home"
cp "$SCRIPT" "$BB/app/container-upgrader.sh"
chmod +x "$BB/app/container-upgrader.sh"
cat > "$BB/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$*" in
  "ps --format {{.Names}}") echo c1 ;;
  "inspect --format {{.Config.Image}} c1") echo img:latest ;;
  "inspect --format {{.Image}} c1") echo sha256:aaa ;;
  "pull img:latest") echo pulled ;;
  "image inspect --format {{.Id}} img:latest") echo sha256:aaa ;;
  "image prune"*) echo "Total reclaimed space: 0B"; exit "${STUB_PRUNE_EXIT:-0}" ;;
  "image ls -f dangling=true") printf 'REPOSITORY TAG IMAGE ID\n<none> <none> deadbeef\n' ;;
esac
exit 0
STUB
chmod +x "$BB/bin/docker"
USER_CONF="$BB/home/.config/scripts-config/bash_container-upgrader.conf"
APP_CONF="$BB/app/container-upgrader.conf"
STATE_LOG="$BB/home/.local/state/scripts-state/bash_container-upgrader.log"
SYSTEM_CONF="/etc/scripts-config/bash_container-upgrader.conf"
if [[ -e "$SYSTEM_CONF" ]]; then
  echo "NOTE: $SYSTEM_CONF exists on this machine - black-box results may be affected by it"
fi

# Runs the copied script; output in $BB_OUT, exit code in $BB_CODE, engine
# calls in $BB/stub.log.
bb_run() {
  : > "$BB/stub.log"
  BB_OUT=$(env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
    HOME="$BB/home" PATH="$BB/bin:$PATH" STUB_LOG="$BB/stub.log" \
    bash "$BB/app/container-upgrader.sh" "$@" 2>&1)
  BB_CODE=$?
}
bb_reset() { rm -rf "$BB/home"; mkdir -p "$BB/home/.config/scripts-config"; rm -f "$APP_CONF"; }
line_of() { grep -n -F -- "$1" "$BB/stub.log" | head -n1 | cut -d: -f1; }

# --- no settings, no --prune: default is dangling ----------------------------
bb_reset
bb_run --no-autoupdate --engine docker
if [[ "$BB_CODE" -eq 0 ]] && grep -qx 'image prune -f' "$BB/stub.log" && [[ "$BB_OUT" != *"Using settings from"* ]]; then
  pass "black-box: no settings and no --prune -> dangling prune by default, no settings line"
else
  fail "black-box: default run - exit=$BB_CODE, stub log: $(tr '\n' '|' < "$BB/stub.log") output: $BB_OUT"
fi
if [[ "$(tail -n1 "$STATE_LOG" 2>/dev/null | jq -r '.prune')" == "dangling" ]]; then
  pass "black-box: run summary log records the default prune=dangling"
else
  fail "black-box: run summary log missing prune=dangling: $(tail -n1 "$STATE_LOG" 2>/dev/null)"
fi

# --- --prune none disables pruning ----------------------------------------------
bb_run --no-autoupdate --engine docker --prune none
if [[ "$BB_CODE" -eq 0 ]] && ! grep -q 'image prune' "$BB/stub.log" \
    && [[ "$(tail -n1 "$STATE_LOG" 2>/dev/null | jq -r '.prune')" == "none" ]]; then
  pass "black-box: --prune none -> no prune, logged as prune=none"
else
  fail "black-box: --prune none - exit=$BB_CODE, stub log: $(tr '\n' '|' < "$BB/stub.log")"
fi

# --- user file: prune dangling + prune-until, before the pull ----------------
bb_reset
printf '%s\n' 'prune = dangling' 'prune-until = 7d' > "$USER_CONF"
bb_run --no-autoupdate --engine docker
prune_line=$(line_of 'image prune -f --filter until=168h')
pull_line=$(line_of 'pull img:latest')
if [[ "$BB_CODE" -eq 0 && -n "$prune_line" && -n "$pull_line" && "$prune_line" -lt "$pull_line" ]]; then
  pass "black-box: prune (dangling, until=168h) runs before the image pull"
else
  fail "black-box: expected prune before pull - exit=$BB_CODE, stub log: $(tr '\n' '|' < "$BB/stub.log")"
fi
if [[ "$BB_OUT" == *"Using settings from: $USER_CONF"* ]]; then
  pass "black-box: 'Using settings from' line names the user file"
else
  fail "black-box: missing 'Using settings from' line: $BB_OUT"
fi
if [[ "$(tail -n1 "$STATE_LOG" 2>/dev/null | jq -r '.prune')" == "dangling" ]]; then
  pass "black-box: run summary log records prune=dangling"
else
  fail "black-box: run summary log prune field wrong: $(tail -n1 "$STATE_LOG" 2>/dev/null)"
fi

# --- CLI overrides the file ----------------------------------------------------
bb_run --no-autoupdate --engine docker --prune all --prune-until none
if grep -qx 'image prune -a -f' "$BB/stub.log"; then
  pass "black-box: --prune all / --prune-until none on the command line override the file"
else
  fail "black-box: expected 'image prune -a -f', stub log: $(tr '\n' '|' < "$BB/stub.log")"
fi

# --- prune failure is a warning only ------------------------------------------
STUB_PRUNE_EXIT=1 bb_run --no-autoupdate --engine docker
if [[ "$BB_CODE" -eq 0 && "$BB_OUT" == *"WARNING: image prune failed"* && "$BB_OUT" != *"ERRORS OCCURRED"* ]] \
    && grep -q 'pull img:latest' "$BB/stub.log"; then
  pass "black-box: failed prune -> warning, run continues, exit 0"
else
  fail "black-box: failed prune handling - exit=$BB_CODE output: $BB_OUT"
fi

# --- dry-run: no prune, dangling candidates listed -----------------------------
bb_run --no-autoupdate --engine docker --dry-run --prune dangling --prune-until none
if ! grep -q 'image prune' "$BB/stub.log" && grep -q 'image ls -f dangling=true' "$BB/stub.log" \
    && [[ "$BB_OUT" == *"Dry run: would prune dangling images"* && "$BB_OUT" == *"deadbeef"* ]]; then
  pass "black-box: --dry-run lists dangling candidates without pruning"
else
  fail "black-box: dry-run prune - stub log: $(tr '\n' '|' < "$BB/stub.log") output: $BB_OUT"
fi
bb_run --no-autoupdate --engine docker --dry-run --prune all
if ! grep -q 'image prune\|image ls' "$BB/stub.log" && [[ "$BB_OUT" == *"Dry run: would prune all images"* && "$BB_OUT" == *"no preview"* ]]; then
  pass "black-box: --dry-run with prune all reports without a preview list"
else
  fail "black-box: dry-run prune all - stub log: $(tr '\n' '|' < "$BB/stub.log") output: $BB_OUT"
fi

# --- per-key precedence across script-location and user files ------------------
bb_reset
printf '%s\n' 'prune = all' 'mode = simple' 'skip-crashing = true' > "$APP_CONF"
printf '%s\n' 'prune = dangling' > "$USER_CONF"
bb_run --no-autoupdate --engine docker --no-skip-crashing
if grep -qx 'image prune -f' "$BB/stub.log" && [[ "$BB_OUT" == *"Mode: simple"* && "$BB_OUT" == *"Skip-crashing: false"* \
    && "$BB_OUT" == *"Using settings from: $USER_CONF, $APP_CONF"* ]]; then
  pass "black-box: user file wins per key over script-location file; --no-skip-crashing overrides the file"
else
  fail "black-box: precedence - stub log: $(tr '\n' '|' < "$BB/stub.log") output: $BB_OUT"
fi

# --- --engine auto overrides a file engine -------------------------------------
bb_reset
printf '%s\n' 'engine = podman' > "$USER_CONF"
bb_run --no-autoupdate --engine auto
if [[ "$BB_CODE" -eq 0 && "$BB_OUT" == *"Engine: docker"* ]]; then
  pass "black-box: --engine auto restores auto-detection over a file's engine"
else
  fail "black-box: --engine auto - exit=$BB_CODE output: $BB_OUT"
fi

# --- settings errors -----------------------------------------------------------
bb_reset
printf '%s\n' 'restart-all = true' > "$USER_CONF"
bb_run --no-autoupdate --engine docker
if [[ "$BB_CODE" -eq 1 && "$BB_OUT" == *"$USER_CONF:1: restart-all is only valid on the command line"* ]] \
    && [[ ! -s "$BB/stub.log" ]]; then
  pass "black-box: command-line-only key in a file is fatal before any engine work"
else
  fail "black-box: CLI-only key - exit=$BB_CODE output: $BB_OUT"
fi
bb_run --no-autoupdate --engine docker --timeout abc
if [[ "$BB_CODE" -eq 1 && "$BB_OUT" == *"Invalid --timeout: abc"* ]]; then
  pass "black-box: invalid numeric command-line value rejected"
else
  fail "black-box: --timeout abc - exit=$BB_CODE output: $BB_OUT"
fi

# --- --status: silent on settings errors, reads status-stale-days --------------
bb_reset
mkdir -p "$(dirname "$STATE_LOG")"
echo "{\"date\":\"$five_days_ago\",\"version\":\"x\",\"mode\":\"safe\",\"prune\":\"none\",\"containers_not_uptodate\":0,\"images_updated_successfully\":0,\"images_update_failed\":0,\"containers_updated_successfully\":1,\"containers_update_failed\":0}" > "$STATE_LOG"
printf '%s\n' 'status-stale-days = 10' > "$USER_CONF"
bb_run --status
if [[ "$BB_CODE" -eq 0 && -z "$BB_OUT" ]]; then
  pass "black-box: --status uses status-stale-days from the settings file, prints no settings line"
else
  fail "black-box: --status with file threshold - exit=$BB_CODE output: [$BB_OUT]"
fi
printf '%s\n' 'status-stale-days = 10' 'bogus' > "$USER_CONF"
bb_run --status
if [[ "$BB_CODE" -eq 0 && "$BB_OUT" == "Containers were last upgraded 5 day(s) ago." ]]; then
  pass "black-box: --status ignores a broken settings file silently"
else
  fail "black-box: --status with broken file - exit=$BB_CODE output: [$BB_OUT]"
fi

# --- file upgrade values don't bypass the self-upgrade cooldown ----------------
bb_reset
printf '%s\n' 'upgrade-level = stable' > "$USER_CONF"
mkdir -p "$BB/home/.cache/scripts-upgrade"
date +%s > "$BB/home/.cache/scripts-upgrade/bash_container-upgrader.state"
bb_run --engine docker
if [[ "$BB_OUT" == *"upgrade not checked: cooldown active"* ]]; then
  pass "black-box: upgrade-level from a file keeps the invocation implicit (cooldown honored)"
else
  fail "black-box: cooldown with file upgrade-level - output: $BB_OUT"
fi

# --- trial run: script-location file comes from the original directory ---------
bb_reset
mkdir -p "$BB/orig"
printf '%s\n' 'prune = dangling' > "$BB/orig/container-upgrader.conf"
CONTAINER_UPGRADE_APPLIED_FROM=1.0.0 CONTAINER_UPGRADE_APPLIED_MODE=link CONTAINER_UPGRADE_ORIGINAL_DIR="$BB/orig" \
  bb_run --engine docker
if [[ "$BB_OUT" == *"Using settings from: $BB/orig/container-upgrader.conf"* ]] && grep -qx 'image prune -f' "$BB/stub.log"; then
  pass "black-box: trial run reads the script-location file from CONTAINER_UPGRADE_ORIGINAL_DIR"
else
  fail "black-box: trial-run script dir - stub log: $(tr '\n' '|' < "$BB/stub.log") output: $BB_OUT"
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
