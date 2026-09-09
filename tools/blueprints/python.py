# Reference blueprint — Python — for the autoupdate mechanism defined in
# docs/requirements/generic/script-autoupdate-convention.md.
#
# Sketch only: no Python script exists in this repo yet (see platforms/),
# so this has not been exercised against a real script. Treat it as a
# starting point to refine once the first platforms/python/ script adopts
# autoupdate, not as a finished, tested implementation.
#
# Like the bash blueprint, this is NOT imported by a deployed script at
# runtime — scripts are self-contained single files; copy/adapt the
# relevant functions directly into the adopting script. Stdlib only
# (urllib), so adopting this doesn't add a dependency.

import json
import os
import re
import sys
import time
import urllib.request

# --- Identity, read from the adopting script's own header (section 1) ------
# SCRIPT_PATH = os.path.abspath(__file__)
# SCRIPT_LANG = "python"
# SCRIPT_NAME = "example-script"          # matches platforms/<lang>/<name>/
# LOCAL_VERSION = "1.0.0"                 # parsed from own "# Version:" line
# UPDATE_OWNER = "jnitecki"
# UPDATE_REPO = "scripts"
# UPDATE_TIMEOUT = 10                     # seconds


# --- section 2: should a check even happen this run? ------------------------
def should_check(no_autoupdate, force, cache_file, cooldown_seconds=24 * 3600):
    if no_autoupdate:
        return False
    if force:
        return True
    try:
        with open(cache_file) as f:
            last_checked = int(f.readline().strip())
    except (OSError, ValueError):
        return True
    return (time.time() - last_checked) >= cooldown_seconds


# --- section 3-4: discover highest matching tag, compare versions -----------
def _version_tuple(v):
    return tuple(int(p) for p in v.split("."))


def discover_latest(owner, repo, lang, name, timeout=10):
    prefix = f"{lang}/{name}/v"
    url = f"https://api.github.com/repos/{owner}/{repo}/git/matching-refs/tags/{prefix}"
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        refs = json.load(resp)
    pattern = re.compile(rf"refs/tags/{re.escape(lang)}/{re.escape(name)}/v([0-9.]+)$")
    versions = []
    for ref in refs:
        m = pattern.match(ref.get("ref", ""))
        if m:
            versions.append(m.group(1))
    if not versions:
        return None
    return max(versions, key=_version_tuple)


# --- section 5: download + syntax-only validation ----------------------------
def download(owner, repo, lang, name, version, timeout=10):
    url = (
        f"https://raw.githubusercontent.com/{owner}/{repo}/"
        f"{lang}/{name}/v{version}/platforms/{lang}/{name}/{name}.py"
    )
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read().decode("utf-8")


def validate_parses(content, name="<update>"):
    try:
        compile(content, name, "exec")
        return True
    except SyntaxError:
        return False


# --- section 6: apply — in place (preferred) or memory fallback -------------
def apply_in_place(script_path, new_content, original_argv):
    tmp = f"{script_path}.tmp{os.getpid()}"
    try:
        with open(tmp, "w") as f:
            f.write(new_content)
        os.replace(tmp, script_path)  # atomic on POSIX and Windows
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False
    # Re-exec so this invocation also runs the new version (section 6).
    os.execv(sys.executable, [sys.executable, script_path] + original_argv)


def run_from_memory(new_content, original_argv):
    # Executes entirely in-process — no temp file touches disk.
    sys.argv = [sys.argv[0]] + original_argv
    code = compile(new_content, "<autoupdate>", "exec")
    exec(code, {"__name__": "__main__"})
    raise SystemExit(0)


# --- section 8: startup banner note ------------------------------------------
def banner_note(outcome, detail=None, detail2=None):
    if outcome == "check_failed":
        return f" (update check failed: {detail})"
    if outcome == "updated_in_place":
        return f" (updated in place from v{detail})"
    if outcome == "ran_from_memory":
        return f" (fetched v{detail}, running from memory this run only - could not update in place: {detail2})"
    if outcome == "parse_failed":
        return f" (fetched v{detail} failed to parse - running v{detail2})"
    return ""
