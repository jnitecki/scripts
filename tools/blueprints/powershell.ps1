# Reference blueprint — PowerShell — for the autoupdate mechanism defined in
# docs/requirements/generic/script-autoupdate-convention.md.
#
# Sketch only: no PowerShell script exists in this repo yet (see
# platforms/), so this has not been exercised against a real script. Treat
# it as a starting point to refine once the first platforms/powershell/
# script adopts autoupdate, not as a finished, tested implementation.
#
# Like the bash blueprint, this is NOT sourced by a deployed script at
# runtime — scripts are self-contained single files; copy/adapt the
# relevant functions directly into the adopting script.

# --- Identity, read from the adopting script's own header (section 1) ------
# $ScriptPath    = $MyInvocation.MyCommand.Path
# $ScriptLang    = 'powershell'
# $ScriptName    = 'example-script'          # matches platforms/<lang>/<name>/
# $LocalVersion  = '1.0.0'                   # parsed from own "# Version:" line
# $UpdateOwner   = 'jnitecki'
# $UpdateRepo    = 'scripts'
# $UpdateTimeout = 10                        # seconds

# --- section 2: should a check even happen this run? -----------------------
function Test-AutoupdateShouldCheck {
    param([bool]$NoAutoupdate, [bool]$Force, [string]$CacheFile)
    if ($NoAutoupdate) { return $false }
    if ($Force) { return $true }
    if (-not (Test-Path $CacheFile)) { return $true }
    $lastChecked = [int](Get-Content $CacheFile -First 1 -ErrorAction SilentlyContinue)
    if (-not $lastChecked) { return $true }
    $cooldownSeconds = 24 * 3600
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return ($now - $lastChecked) -ge $cooldownSeconds
}

# --- section 3-4: discover highest matching tag, compare versions ----------
function Find-AutoupdateLatestVersion {
    param([string]$Owner, [string]$Repo, [string]$Lang, [string]$Name, [int]$TimeoutSec = 10)
    $prefix = "$Lang/$Name/v"
    $uri = "https://api.github.com/repos/$Owner/$Repo/git/matching-refs/tags/$prefix"
    $refs = Invoke-RestMethod -Uri $uri -TimeoutSec $TimeoutSec -ErrorAction Stop
    $versions = $refs | ForEach-Object {
        if ($_.ref -match "refs/tags/$([regex]::Escape("$Lang/$Name/v"))([0-9.]+)$") {
            [version]$Matches[1]
        }
    }
    if ($versions) { ($versions | Sort-Object)[-1] }
}

# --- section 5: download + syntax-only validation ---------------------------
function Get-AutoupdateContent {
    param([string]$Owner, [string]$Repo, [string]$Lang, [string]$Name, [string]$Version, [int]$TimeoutSec = 10)
    $uri = "https://raw.githubusercontent.com/$Owner/$Repo/$Lang/$Name/v$Version/platforms/$Lang/$Name/$Name.ps1"
    Invoke-RestMethod -Uri $uri -TimeoutSec $TimeoutSec -ErrorAction Stop
}

function Test-AutoupdateParses {
    param([string]$Content)
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$errors)
    return ($errors.Count -eq 0)
}

# --- section 6: apply — in place (preferred) or memory fallback ------------
function Update-AutoupdateInPlace {
    param([string]$ScriptPath, [string]$NewContent, [string[]]$OriginalArgs)
    $tmp = "$ScriptPath.tmp$([guid]::NewGuid().ToString('N'))"
    try {
        Set-Content -Path $tmp -Value $NewContent -NoNewline -ErrorAction Stop
        Move-Item -Path $tmp -Destination $ScriptPath -Force -ErrorAction Stop
        # Re-exec so this invocation also runs the new version (section 6).
        & pwsh -NoProfile -File $ScriptPath @OriginalArgs
        exit $LASTEXITCODE
    } catch {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        return $false
    }
}

function Invoke-AutoupdateFromMemory {
    param([string]$NewContent, [string[]]$OriginalArgs)
    # Runs entirely in-process — no temp file touches disk.
    $scriptBlock = [scriptblock]::Create($NewContent)
    & $scriptBlock @OriginalArgs
    exit $LASTEXITCODE
}

# --- section 8: startup banner note -----------------------------------------
function Get-AutoupdateBannerNote {
    param([string]$Outcome, [string]$Detail, [string]$Detail2)
    switch ($Outcome) {
        'check_failed'      { " (update check failed: $Detail)" }
        'updated_in_place'  { " (updated in place from v$Detail)" }
        'ran_from_memory'   { " (fetched v$Detail, running from memory this run only - could not update in place: $Detail2)" }
        'parse_failed'      { " (fetched v$Detail failed to parse - running v$Detail2)" }
        default             { '' }
    }
}
