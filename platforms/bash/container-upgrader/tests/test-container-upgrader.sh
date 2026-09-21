#!/usr/bin/env bash
# test-container-upgrader.sh
#
# Unit tests for write_run_state_log() (see
# docs/requirements/implemented/run-summary-log.md) and the login status
# banner - status_main/register_banner_main/unregister_banner_main (see
# docs/requirements/implemented/login-status-banner.md). Deliberately narrower
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

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
