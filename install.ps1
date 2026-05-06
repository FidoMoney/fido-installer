#Requires -Version 5.1
<#
  Fido Agents Setup & Update Script (Windows / PowerShell)
  --------------------------------------------------------
  One-shot installer: dev tools, Claude Code, Fido agents, AWS VPN, and
  all cluster MCP servers. Idempotent — safe to rerun for updates.

  Quickstart (new employees):
    iex (irm https://raw.githubusercontent.com/FidoMoney/fido-installer/main/install.ps1)

  Usage (when run from a downloaded copy):
    powershell -ExecutionPolicy Bypass -File .\install.ps1                 # full setup
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -McpOnly        # MCPs only
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Token <T>      # supply token
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -McpOnly -All   # all MCPs, no checklist
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -SkipMcp        # skip MCP step

  Environment:
    FIDO_MCP_TOKEN=<T>     same as -Token
    SKIP_MCP_INSTALL=1     same as -SkipMcp
    FIDO_INSTALL_DIR=<D>   where to put fido-agent\  (default: $HOME)

  Notes:
    - DNS NRPT rules require an Administrator PowerShell. The script will
      prompt to relaunch elevated if needed (or use -SkipDns if your VPN
      already pushes DNS suffixes).
#>
[CmdletBinding()]
param(
    [switch]$McpOnly,
    [switch]$SkipMcp,
    [switch]$All,
    [switch]$DryRun,
    [switch]$SkipDns,
    [string]$Token,
    [string]$Only,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'

# ── Config ───────────────────────────────────────────────────
$ORG            = 'FidoMoney'
$MCP_DNS_DOMAIN = 'global-private.fido.money'
$MCP_DNS_ZONES  = @(
    @{ Zone = 'global-private.fido.money';  Server = '10.3.0.2'  }
    @{ Zone = 'private.fido.money';         Server = '10.30.0.2' }
    @{ Zone = 'gh-prod-private.fido.money'; Server = '10.20.0.2' }
    @{ Zone = 'ug-prod-private.fido.money'; Server = '10.40.0.2' }
    @{ Zone = 'zm-prod-private.fido.money'; Server = '10.50.0.2' }
)
$MCP_GITOPS_REPO = 'FidoMoney/platform-team-gitops'
$MCP_GITOPS_PATH = 'applications/mcp-servers'

# Resolve flags / env
if (-not $Token -and $env:FIDO_MCP_TOKEN) { $Token = $env:FIDO_MCP_TOKEN }
if ($env:SKIP_MCP_INSTALL -eq '1')        { $SkipMcp = $true }
if (-not $InstallDir -and $env:FIDO_INSTALL_DIR) { $InstallDir = $env:FIDO_INSTALL_DIR }

$McpMode = if ($All) { 'all' } elseif ($Only) { 'only' } else { 'interactive' }

# Install location — when piped via `iex (irm …)` there's no $PSCommandPath,
# so default to $HOME. Override with -InstallDir or $env:FIDO_INSTALL_DIR.
if ($InstallDir) {
    $ScriptDir = $InstallDir
} elseif ($PSCommandPath) {
    $ScriptDir = Split-Path -Parent $PSCommandPath
} else {
    $ScriptDir = $HOME
}
$AgentRepoDir = Join-Path $ScriptDir 'fido-agent'
$RomanDir     = Join-Path $AgentRepoDir 'roman'

# ── Helpers ───────────────────────────────────────────────────
function Write-Info    { param([string]$m) Write-Host "i  $m" -ForegroundColor Cyan }
function Write-OK      { param([string]$m) Write-Host "OK $m" -ForegroundColor Green }
function Write-Warn2   { param([string]$m) Write-Host "!  $m" -ForegroundColor Yellow }
function Write-Fail    { param([string]$m) Write-Host "X  $m" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path','User')
}

function Has-Cmd { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# Reliable "is the user actually at a TTY?" check. [Environment]::UserInteractive
# returns $true under VS Code, PS ISE, scheduled tasks, and SYSTEM contexts —
# not what we want. [Console]::IsInputRedirected being $false means stdin is
# attached to a real terminal (the bash equivalent is `[ -t 0 ]`).
function Test-Interactive {
    try { return -not [Console]::IsInputRedirected } catch { return $false }
}

function Print-Banner {
    Write-Host ""
    $pink = "$([char]27)[38;2;214;8;107m"
    $rst  = "$([char]27)[0m"
    Write-Host "${pink}    _______     __         ____           __        ____         ${rst}"
    Write-Host "${pink}   / ____(_)___/ /___     /  _/___  _____/ /_____ _/ / /__  _____${rst}"
    Write-Host "${pink}  / /_  / / __  / __ \    / // __ \/ ___/ __/ __ ``/ / / _ \/ ___/${rst}"
    Write-Host "${pink} / __/ / / /_/ / /_/ /  _/ // / / (__  ) /_/ /_/ / / /  __/ /    ${rst}"
    Write-Host "${pink}/_/   /_/\__,_/\____/  /___/_/ /_/____/\__/\__,_/_/_/\___/_/     ${rst}"
    Write-Host "                                                  by platform team" -ForegroundColor DarkGray
    Write-Host ""
}

# Returns $true if internal MCP DNS resolves (proxy for VPN being up).
function Test-VpnUp {
    try {
        $null = Resolve-DnsName -Name "superset-mcp.$MCP_DNS_DOMAIN" -ErrorAction Stop -QuickTimeout
        return $true
    } catch {
        return $false
    }
}

# Windows DNS routing equivalent of /etc/resolver/* on macOS: NRPT rules
# (Name Resolution Policy Table). Each rule sends queries for *.zone to a
# specific nameserver. Requires admin. Idempotent.
function Configure-DnsResolvers {
    if ($SkipDns) { Write-Info "Skipping DNS resolver setup (-SkipDns)"; return }

    if (-not (Test-Admin)) {
        Write-Warn2 "Not running as Administrator — cannot configure NRPT rules."
        Write-Warn2 "AWS VPN Client often pushes DNS automatically; if the VPN connects but"
        Write-Warn2 "internal hosts don't resolve, re-run this script in an elevated PowerShell"
        Write-Warn2 "(right-click → Run as Administrator), or pass -SkipDns to ignore."
        return
    }

    foreach ($z in $MCP_DNS_ZONES) {
        $namespace = ".$($z.Zone)"
        $existing = Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Namespace -contains $namespace -and $_.NameServers -contains $z.Server }
        if ($existing) {
            Write-OK "DNS NRPT rule for *.$($z.Zone) already configured"
            continue
        }
        if ($DryRun) {
            Write-Host "  [dry-run] Add-DnsClientNrptRule -Namespace $namespace -NameServers $($z.Server)"
        } else {
            try {
                Add-DnsClientNrptRule -Namespace $namespace -NameServers $z.Server | Out-Null
                Write-OK "Added NRPT rule for *.$($z.Zone) -> $($z.Server)"
            } catch {
                Write-Warn2 "Failed to add NRPT rule for *.$($z.Zone): $_"
            }
        }
    }
}

# Open AWS VPN Client and wait (~60s) for connectivity. Windows AWS VPN
# Client doesn't expose a CLI to connect a profile, so we launch the GUI
# and poll DNS. The user can press a key to skip the wait.
function Connect-Vpn {
    if (Test-VpnUp) { Write-OK "VPN is already up"; return $true }

    Write-Info "Launching AWS VPN Client..."
    $candidates = @(
        "${env:ProgramFiles}\Amazon\AWS VPN Client\AWS VPN Client.exe",
        "${env:ProgramFiles(x86)}\Amazon\AWS VPN Client\AWS VPN Client.exe"
    )
    $vpnExe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($vpnExe) {
        Start-Process -FilePath $vpnExe | Out-Null
    } else {
        Write-Warn2 "AWS VPN Client not found in default locations — open it manually."
    }

    if (-not $script:VpnProfileAutoImported -and $script:VpnProfilePath -and (Test-Path $script:VpnProfilePath)) {
        Write-Host ""
        Write-Info "If the profile isn't already loaded, add it now:"
        Write-Info "  File -> Manage Profiles -> Add Profile  ->  $script:VpnProfilePath"
    }
    Write-Host ""
    Write-Info "Click Connect on the Fido profile in AWS VPN Client."
    Write-Info "Waiting for VPN to come up (up to 60s)... press any key to skip."
    Write-Host ""

    for ($i = 0; $i -lt 30; $i++) {
        if (Test-VpnUp) { Write-OK "VPN is up — DNS resolves"; return $true }
        if ([Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
            Write-Warn2 "Skipped VPN wait — continuing without verifying connectivity"
            return $false
        }
        Start-Sleep -Seconds 2
    }
    Write-Warn2 "Timed out waiting for VPN — continuing anyway"
    return $false
}

# fzf-style single picker. Falls back to a numbered prompt if fzf is missing.
function Select-One {
    param([string]$Prompt, [string[]]$Items)
    if (Has-Cmd 'fzf') {
        return ($Items | & fzf --height=40% --reverse --border --no-multi `
            --prompt "$Prompt > " --header "Up/Down to move, Enter to select, Esc to cancel")
    }
    Write-Host ""
    Write-Host $Prompt -ForegroundColor White
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  {0,2}) {1}" -f ($i + 1), $Items[$i])
    }
    $reply = Read-Host "Choice (number, blank to cancel)"
    if (-not $reply) { return '' }
    if ([int]::TryParse($reply, [ref]$null)) {
        $n = [int]$reply
        if ($n -ge 1 -and $n -le $Items.Count) { return $Items[$n - 1] }
    }
    return ''
}

# ── Entry ───────────────────────────────────────────────────────
Print-Banner
if ($McpOnly) { Write-Host "   MCP Servers only" -ForegroundColor White }
else          { Write-Host "   Setup & update"   -ForegroundColor White }
Write-Host ""

# Upfront preamble — what's about to happen, and what touches the system,
# so the user has a chance to bail before sudo/network calls. Skipped in
# -McpOnly mode (smaller scope) and in non-interactive runs.
if (-not $McpOnly -and (Test-Interactive)) {
    Write-Host "This installer will:" -ForegroundColor White
    Write-Host "  - Install winget packages: git, gh, fzf, awscli, Node.js, AWS VPN Client"
    Write-Host "  - Install Claude Code (via the official installer)"
    Write-Host "  - Verify AWS credentials, or walk you through 'aws configure sso' on first run"
    Write-Host "  - Clone/update Fido repos under $ScriptDir\fido-agent\"
    Write-Host "  - Configure DNS NRPT rules (requires Administrator)"
    Write-Host "  - Import a Fido VPN profile into $env:LOCALAPPDATA\AWSVPNClient\"
    Write-Host "  - Register Fido cluster MCP servers with Claude Code (-s user scope)"
    Write-Host ""
    Write-Host "  Will read/write: $HOME\.aws  $env:LOCALAPPDATA\AWSVPNClient  $HOME\.claude"
    Write-Host "  Network access: winget, GitHub, AWS SSO browser, MCP hosts (via VPN)"
    Write-Host ""
    Write-Host "  Re-running is safe - every step is idempotent."
    Write-Host ""
    Read-Host "Press Enter to continue, or Ctrl-C to abort" | Out-Null
    Write-Host ""
}

# Counters used in the summary even when -McpOnly skips the repo section.
$Cloned = 0; $Skipped = 0; $CloneFailed = 0; $Updated = 0; $UpdateFailed = 0

if (-not $McpOnly) {

    # ── Step 1: winget (provides everything else) ────────────────
    if (-not (Has-Cmd 'winget')) {
        Write-Fail "winget is required but not found."
        Write-Host ""
        Write-Info "winget ships with App Installer on Windows 10 1709+ and Windows 11."
        Write-Info "Three ways to fix this:"
        Write-Info "  1) Install 'App Installer' from the Microsoft Store:"
        Write-Info "     https://apps.microsoft.com/detail/9NBLGGH4NNS1"
        Write-Info "  2) If the Microsoft Store is disabled (managed laptops), download"
        Write-Info "     the latest .msixbundle from:"
        Write-Info "     https://github.com/microsoft/winget-cli/releases/latest"
        Write-Info "     Then run:  Add-AppxPackage <downloaded.msixbundle>"
        Write-Info "  3) Ask #eng-platform on Slack — IT can install it remotely."
        Write-Host ""
        Write-Info "Once winget is available, re-run this script."
        exit 1
    }
    Write-OK "winget is available"

    # ── Step 2: CLI tools ────────────────────────────────────────
    function Install-WingetPkg {
        param([string]$Cmd, [string]$Id, [string]$Label)
        if ($Cmd -and (Has-Cmd $Cmd)) { Write-OK "$Label is installed"; return }
        Write-Info "Installing $Label..."
        try {
            winget install --id $Id -e --accept-package-agreements --accept-source-agreements --silent | Out-Null
            Write-OK "$Label installed"
        } catch {
            Write-Warn2 "winget failed for $Label ($Id): $_"
        }
    }

    Install-WingetPkg -Cmd 'git'  -Id 'Git.Git'         -Label 'Git'
    Install-WingetPkg -Cmd 'gh'   -Id 'GitHub.cli'      -Label 'GitHub CLI'
    Install-WingetPkg -Cmd 'fzf'  -Id 'junegunn.fzf'    -Label 'fzf (multi-select UI)'
    Install-WingetPkg -Cmd 'aws'  -Id 'Amazon.AWSCLI'   -Label 'AWS CLI'
    Install-WingetPkg -Cmd 'node' -Id 'OpenJS.NodeJS'   -Label 'Node.js (for Claude Code)'

    # AWS VPN Client — no CLI binary, install by id only.
    Install-WingetPkg -Cmd $null  -Id 'Amazon.AWSVPNClient' -Label 'AWS VPN Client'

    Refresh-Path

    # ── Verify AWS credentials are configured ────────────────────
    # Same flow as install.sh: try the default profile, try each
    # named profile from `aws configure list-profiles`, offer
    # `aws sso login` if there's an SSO profile, and finally walk
    # first-time users through `aws configure sso` with the Fido
    # SSO start URL/region pre-shown. Hard-exit with explicit next
    # steps when nothing works (incl. "no AWS account yet — ping
    # #eng-platform").

    $script:AwsCallerOutput = ''
    $FidoSsoStartUrl = 'https://fido.awsapps.com/start/'
    $FidoSsoRegion   = 'eu-west-1'

    function Get-AwsProfiles {
        try {
            $out = & aws configure list-profiles 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $out) { return @() }
            return @($out | Where-Object { $_ -and $_.Trim() })
        } catch {
            return @()
        }
    }

    function Test-AwsProfileIsSso {
        param([string]$Name)
        $cfg = if ($env:AWS_CONFIG_FILE) { $env:AWS_CONFIG_FILE } else { Join-Path $HOME '.aws\config' }
        if (-not (Test-Path $cfg)) { return $false }
        $inSection = $false
        foreach ($line in Get-Content -LiteralPath $cfg) {
            if ($line -match '^\s*\[(profile\s+)?([^\]]+)\]\s*$') {
                $inSection = ($Matches[2].Trim() -eq $Name)
                continue
            }
            if ($line -match '^\s*\[') { $inSection = $false; continue }
            if ($inSection -and $line -match '^\s*sso_(start_url|session)\s*=') {
                return $true
            }
        }
        return $false
    }

    function Invoke-AwsStsCheck {
        param([string]$ProfileName)
        $cmdArgs = @('sts','get-caller-identity','--output','json')
        if ($ProfileName) { $cmdArgs += @('--profile', $ProfileName) }
        $out = & aws @cmdArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            $arn = $null
            $m = [regex]::Match(($out | Out-String), '"Arn":\s*"([^"]+)"')
            if ($m.Success) { $arn = $m.Groups[1].Value }
            return @{ Ok = $true; Arn = $arn }
        }
        $script:AwsCallerOutput = ($out | Out-String).Trim()
        return @{ Ok = $false; Arn = $null }
    }

    function Verify-AwsCreds {
        $r = Invoke-AwsStsCheck -ProfileName ''
        if ($r.Ok) {
            Write-OK "AWS credentials valid ($($r.Arn))"
            return $true
        }

        $profiles = @(Get-AwsProfiles | Sort-Object -Unique)
        foreach ($p in $profiles) {
            $r = Invoke-AwsStsCheck -ProfileName $p
            if ($r.Ok) {
                $env:AWS_PROFILE = $p
                Write-OK "AWS credentials valid via profile $p ($($r.Arn))"
                Write-Info "Using AWS_PROFILE=$p for this installer run."
                Write-Info "To make it permanent, run: setx AWS_PROFILE $p"
                return $true
            }
        }

        $ssoProfiles = @($profiles | Where-Object { Test-AwsProfileIsSso $_ })
        if ($ssoProfiles.Count -eq 0) { return $false }
        if (-not (Test-Interactive)) { return $false }

        $chosen = if ($ssoProfiles.Count -eq 1) {
            Write-Info "Found SSO profile $($ssoProfiles[0]) — running aws sso login..."
            $ssoProfiles[0]
        } else {
            Select-One -Prompt 'Pick AWS SSO profile to log in' -Items $ssoProfiles
        }
        if (-not $chosen) { return $false }

        & aws sso login --profile $chosen
        if ($LASTEXITCODE -ne 0) { return $false }

        $r = Invoke-AwsStsCheck -ProfileName $chosen
        if ($r.Ok) {
            $env:AWS_PROFILE = $chosen
            Write-OK "AWS credentials valid via profile $chosen ($($r.Arn))"
            Write-Info "Using AWS_PROFILE=$chosen for this installer run."
            Write-Info "To make it permanent, run: setx AWS_PROFILE $chosen"
            return $true
        }
        return $false
    }

    function Bootstrap-AwsSso {
        if (-not (Test-Interactive)) { return $false }

        Write-Host ""
        Write-Host "── First-time AWS SSO setup ──" -ForegroundColor White
        Write-Host ""
        Write-Info "No working AWS credentials found. Let's set up Fido AWS SSO."
        Write-Info "I'll run 'aws configure sso' — when prompted, enter these values:"
        Write-Host ""
        Write-Info "  SSO session name:        fido"
        Write-Info "  SSO start URL:           $FidoSsoStartUrl"
        Write-Info "  SSO region:              $FidoSsoRegion"
        Write-Info "  SSO registration scopes: sso:account:access (or press Enter)"
        Write-Host ""
        Write-Info "A browser will open for you to authenticate to Fido SSO."
        Write-Info "After login you'll pick your account and role from a list."
        Write-Host ""
        Write-Info "Final prompts:"
        Write-Info "  CLI default Region:  $FidoSsoRegion"
        Write-Info "  CLI default output:  json"
        Write-Info "  CLI profile name:    fido (any name works)"
        Write-Host ""
        Read-Host "Press Enter to start, or Ctrl-C to abort" | Out-Null
        Write-Host ""

        & aws configure sso
        if ($LASTEXITCODE -ne 0) { return $false }

        Write-Host ""
        Write-OK "'aws configure sso' completed."
        if (Verify-AwsCreds) { return $true }
        Write-Warn2 "Setup finished but credentials still don't validate — see message below."
        return $false
    }

    if (-not (Verify-AwsCreds) -and -not (Bootstrap-AwsSso)) {
        Write-Host ""
        Write-Fail "Couldn't establish working AWS credentials."
        if ($script:AwsCallerOutput) { Write-Fail "Details: $script:AwsCallerOutput" }
        Write-Host ""
        Write-Info "Don't have a Fido AWS account yet?"
        Write-Info "  Ping #eng-platform on Slack to request one."
        Write-Info "  Once it's created, re-run this installer."
        Write-Host ""
        Write-Info "SSO login failed (browser/auth error)?"
        Write-Info "  Re-run 'aws configure sso' manually, then re-run this installer."
        Write-Host ""
        Write-Info "Already configured under a different profile?"
        Write-Info "  Run 'setx AWS_PROFILE <your-profile-name>' before rerunning,"
        Write-Info "  or 'aws sso login --profile <your-profile-name>' to refresh."
        Write-Host ""
        Write-Fail "Aborting installer — re-run once AWS access is set up."
        exit 1
    }

    # ── AWS VPN Client profile ───────────────────────────────────
    # Skip the prompt entirely if AWS VPN Client already has at least
    # one profile imported. The profile registry is JSON at one of the
    # known LocalAppData paths; presence of "ProfileName" inside it
    # means the user has already set up the VPN previously.
    function Test-VpnHasProfile {
        foreach ($f in (Get-VpnRegistryCandidates)) {
            if (Test-Path $f) {
                if (Select-String -LiteralPath $f -Pattern '"ProfileName"' -Quiet) { return $true }
            }
        }
        return $false
    }

    function Get-VpnRegistryCandidates {
        @(
            (Join-Path $env:LOCALAPPDATA 'AWSVPNClient\ConnectionProfiles'),
            (Join-Path $env:LOCALAPPDATA 'Amazon\AWS VPN Client\ConnectionProfiles')
        )
    }

    # Auto-import a Fido VPN .ovpn straight into AWS VPN Client's registry
    # (parallel to import_vpn_profile in install.sh). Parses the AWS Client
    # VPN endpoint host out of the `remote` line, drops the file at the
    # OpenVpnConfigs dir (no extension), and merges a new entry into
    # ConnectionProfiles JSON. Returns $true on success, $false if parsing
    # fails or any IO breaks (caller should fall back to GUI-import path).
    function Import-VpnProfile {
        param([string]$SourcePath, [string]$Name = 'Fido VPN')

        if (-not (Test-Path $SourcePath)) { return $false }

        $contents = Get-Content -LiteralPath $SourcePath
        # Match the AWS Client VPN endpoint hostname anywhere on a `remote`
        # line. Accept commercial AWS, GovCloud, and amazonaws.com.cn —
        # plus any future <random>.cvpn-endpoint-... host shape.
        $remoteLine = ($contents | Where-Object {
            $_ -match '^\s*remote\s+\S*cvpn-endpoint-[a-z0-9]+\S*\.clientvpn\.[a-z0-9-]+\.amazonaws\.com(\.cn)?'
        } | Select-Object -First 1)
        if (-not $remoteLine) { return $false }

        $epMatch = [regex]::Match($remoteLine, 'cvpn-endpoint-[a-z0-9]+')
        if (-not $epMatch.Success) { return $false }
        $endpoint = $epMatch.Value
        # Region pattern accepts both commercial AWS (.amazonaws.com) and
        # China (.amazonaws.com.cn). Mirrors the gate above.
        if ($remoteLine -notmatch '\.clientvpn\.(?<region>[a-z0-9-]+)\.amazonaws\.com(\.cn)?') { return $false }
        $region = $Matches['region']

        # FederatedAuthType: 1 = SAML federated SSO, 0 = mutual cert auth.
        # Same precedence as bash (auth-federate wins, then mutual-auth
        # markers, otherwise default to 1 — Fido uses SAML).
        $hasFederate = [bool]($contents | Where-Object { $_ -match '^\s*auth-federate' })
        $hasMutual   = [bool]($contents | Where-Object { $_ -match '^\s*<cert>|^\s*auth-user-pass' })
        if     ($hasFederate) { $authType = 1 }
        elseif ($hasMutual)   { $authType = 0 }
        else                  { $authType = 1 }

        # Pick the first candidate registry path whose parent dir already
        # exists (i.e. the AWS VPN Client variant the user has installed).
        # Fall back to the modern path if neither parent exists yet.
        $registry = $null
        foreach ($cand in (Get-VpnRegistryCandidates)) {
            if (Test-Path (Split-Path -Parent $cand)) { $registry = $cand; break }
        }
        if (-not $registry) { $registry = (Get-VpnRegistryCandidates)[0] }
        $cfgDir  = Split-Path -Parent $registry
        $ovpnDir = Join-Path $cfgDir 'OpenVpnConfigs'

        try {
            if (-not (Test-Path $cfgDir))  { New-Item -ItemType Directory -Path $cfgDir  -Force | Out-Null }
            if (-not (Test-Path $ovpnDir)) { New-Item -ItemType Directory -Path $ovpnDir -Force | Out-Null }
            if (-not (Test-Path $registry)) {
                '{"Version":"1","LastSelectedProfileIndex":-1,"ConnectionProfiles":[]}' |
                    Set-Content -LiteralPath $registry -Encoding UTF8
            }

            $data = Get-Content -LiteralPath $registry -Raw | ConvertFrom-Json
            # @(...) forces an array even when ConvertFrom-Json deserializes
            # a single-element array as a scalar (PowerShell unwrap quirk).
            $existing = @($data.ConnectionProfiles) | Where-Object { $_ -and $_.ProfileName -eq $Name }
            if ($existing) {
                return $true  # already registered — idempotent success
            }

            $ovpnDest = Join-Path $ovpnDir $Name
            Copy-Item -LiteralPath $SourcePath -Destination $ovpnDest -Force

            $entry = [pscustomobject]@{
                ProfileName          = $Name
                OvpnConfigFilePath   = $ovpnDest
                CvpnEndpointId       = $endpoint
                CvpnEndpointRegion   = $region
                CompatibilityVersion = '2'
                FederatedAuthType    = $authType
            }
            if (-not $data.ConnectionProfiles) {
                $data | Add-Member -NotePropertyName ConnectionProfiles -NotePropertyValue @($entry) -Force
            } else {
                $data.ConnectionProfiles = @($data.ConnectionProfiles) + $entry
            }
            # Atomic write: stage to a tempfile in the same directory, then
            # use [System.IO.File]::Replace which calls NTFS's transactional
            # rename. (Move-Item -Force expands to MoveFileEx with
            # REPLACE_EXISTING — that's a delete-then-rename, not atomic.)
            $tmp = "$registry.tmp"
            ($data | ConvertTo-Json -Depth 8 -Compress) |
                Set-Content -LiteralPath $tmp -Encoding UTF8
            [System.IO.File]::Replace($tmp, $registry, $null)
            return $true
        } catch {
            return $false
        }
    }

    $VpnProfileDir  = Join-Path $HOME 'Documents'
    $script:VpnProfilePath = $null
    $script:VpnProfileAutoImported = $false

    Write-Host ""
    if (Test-VpnHasProfile) {
        Write-OK "AWS VPN Client already has a profile configured — skipping setup"
    } else {
        Write-Host "── AWS VPN Client profile ──" -ForegroundColor White
        Write-Host ""
        Write-Info "AWS VPN Client needs a Fido profile (.ovpn file) to connect."

        if ((Test-Interactive)) {
            $choice = Select-One -Prompt "AWS VPN profile" -Items @(
                "Paste config (.ovpn content) — finish with a blank line",
                "Provide a path to a .ovpn file",
                "Skip (set it up later in the AWS VPN Client UI)"
            )
            # Stage the user's input at a temp file first; we'll auto-import
            # below. Fall back to ~/Documents only if auto-import fails.
            $staged = $null
            $cleanupStaged = $false
            switch -Wildcard ($choice) {
                'Paste*' {
                    Write-Info "Paste the full .ovpn content. Press Enter on a blank line to finish:"
                    $lines = New-Object System.Collections.Generic.List[string]
                    while ($true) {
                        $l = Read-Host
                        if ([string]::IsNullOrEmpty($l)) { break }
                        $lines.Add($l)
                    }
                    if ($lines.Count -gt 0) {
                        $staged = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "fido-vpn-$([guid]::NewGuid().ToString('N')).ovpn")
                        $lines -join "`n" | Set-Content -LiteralPath $staged -Encoding UTF8
                        $cleanupStaged = $true
                    } else {
                        Write-Warn2 "Empty paste — skipping"
                    }
                }
                'Provide*' {
                    $src = Read-Host "  Path to .ovpn"
                    if (Test-Path $src) {
                        $staged = $src
                    } else {
                        Write-Warn2 "File not found: $src — skipping"
                    }
                }
                default {
                    Write-Info "Skipped — set up later via AWS VPN Client -> File -> Manage Profiles -> Add Profile"
                }
            }

            if ($staged) {
                if (Import-VpnProfile -SourcePath $staged -Name 'Fido VPN') {
                    $script:VpnProfileAutoImported = $true
                    $script:VpnProfilePath = Join-Path $env:LOCALAPPDATA 'AWSVPNClient\OpenVpnConfigs\Fido VPN'
                    Write-OK "Imported profile into AWS VPN Client (Fido VPN)"
                    Write-Info "If AWS VPN Client is already running, quit and reopen it to see the profile."
                } else {
                    if (-not (Test-Path $VpnProfileDir)) { New-Item -ItemType Directory -Path $VpnProfileDir | Out-Null }
                    $script:VpnProfilePath = Join-Path $VpnProfileDir 'fido-vpn.ovpn'
                    Copy-Item -LiteralPath $staged -Destination $script:VpnProfilePath -Force
                    Write-Warn2 "Couldn't auto-import — saved VPN config to $script:VpnProfilePath"
                    Write-Info "Add it manually via AWS VPN Client -> File -> Manage Profiles -> Add Profile."
                }
                if ($cleanupStaged -and (Test-Path $staged)) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue }
            }
        } else {
            Write-Warn2 "Non-interactive run — skipping VPN profile prompt."
            Write-Info "To set it up later, re-run interactively, or run:"
            Write-Info "  iex (irm https://raw.githubusercontent.com/FidoMoney/fido-installer/main/install.ps1)"
            Write-Info "Or import the .ovpn manually via AWS VPN Client -> File -> Manage Profiles -> Add Profile."
        }
    }
    Write-Host ""

    # ── DNS resolvers + VPN connect ──────────────────────────────
    Write-Host "── DNS resolvers + VPN connect ──" -ForegroundColor White
    Write-Host ""
    Configure-DnsResolvers
    Write-Host ""
    Connect-Vpn | Out-Null
    Write-Host ""

    # ── Claude Code ──────────────────────────────────────────────
    if (-not (Has-Cmd 'claude')) {
        Write-Info "Installing Claude Code..."
        try {
            iex (irm 'https://claude.ai/install.ps1')
            Refresh-Path
        } catch {
            Write-Warn2 "Official installer failed — falling back to npm."
            if (Has-Cmd 'npm') {
                npm install -g '@anthropic-ai/claude-code' | Out-Null
            } else {
                Write-Warn2 "npm not on PATH yet — open a new terminal and run: npm install -g @anthropic-ai/claude-code"
            }
        }
        Refresh-Path
        if (Has-Cmd 'claude') { Write-OK "Claude Code installed" }
        else { Write-Warn2 "Claude Code installed but 'claude' is not on PATH — open a new terminal after this script finishes" }
    } else {
        Write-OK "Claude Code is installed"
    }

    # ── GitHub login ─────────────────────────────────────────────
    & gh auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Info "You need to log in to GitHub."
        Write-Info "Follow the prompts (select HTTPS when asked)."
        Write-Host ""
        gh auth login -h github.com -p https -w
    }
    $githubUser = (& gh api user --jq '.login' 2>$null)
    if (-not $githubUser) { $githubUser = 'unknown' }
    Write-OK "Logged in to GitHub as $githubUser"
    Write-Host ""

    # ── Clone or update fido-agent ───────────────────────────────
    Write-Host "── Setting up fido-agent ──" -ForegroundColor White
    Write-Host ""

    if (Test-Path (Join-Path $AgentRepoDir '.git')) {
        Write-Info "fido-agent already cloned — pulling latest..."
        Push-Location $AgentRepoDir
        try {
            git fetch --all --prune --quiet 2>$null
            $defaultBranch = (& git symbolic-ref refs/remotes/origin/HEAD 2>$null) -replace '^refs/remotes/origin/', ''
            if (-not $defaultBranch) {
                foreach ($b in 'main','master','develop') {
                    & git rev-parse --verify "origin/$b" *> $null
                    if ($LASTEXITCODE -eq 0) { $defaultBranch = $b; break }
                }
            }
            if ($defaultBranch) {
                & git checkout $defaultBranch --quiet 2>$null
                $dirty = (& git status --porcelain 2>$null)
                if ($dirty) {
                    $changedCount = ($dirty -split "`n" | Where-Object { $_ }).Count
                    Write-Warn2 "fido-agent — discarding uncommitted local changes ($changedCount file(s))"
                }
                & git reset --hard "origin/$defaultBranch" --quiet 2>$null
            }
            Write-OK "fido-agent updated"
        } finally { Pop-Location }
    } else {
        Write-Host -NoNewline "  Cloning fido-agent... "
        & gh repo clone "$ORG/fido-agent" $AgentRepoDir -- --quiet 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "done" -ForegroundColor Green
            Write-OK "fido-agent cloned"
        } else {
            Write-Host "failed" -ForegroundColor Red
            Write-Fail "Could not clone fido-agent — check your access permissions"
            exit 1
        }
    }
    Write-Host ""

    if (-not (Test-Path $RomanDir)) {
        Write-Fail "Expected roman\ directory inside fido-agent but it doesn't exist"
        exit 1
    }
    Write-OK "Agents folder ready: $RomanDir"
    Write-Host ""

    # ── Repo list (lives inside fido-agent) ──────────────────────
    $repoListFile = Join-Path $AgentRepoDir 'roman-repos.txt'
    if (-not (Test-Path $repoListFile)) {
        Write-Fail "Repo list not found: $repoListFile"
        Write-Fail "Expected it to ship with fido-agent. Ask #eng-platform."
        exit 1
    }
    $repos = Get-Content $repoListFile |
        ForEach-Object { ($_ -split '#', 2)[0].Trim() } |
        Where-Object { $_ }
    Write-Info "Active repositories: $($repos.Count) (from $repoListFile)"
    Write-Host ""

    # ── Clone missing repos ──────────────────────────────────────
    Write-Host "── Cloning new repositories ──" -ForegroundColor White
    Write-Host ""
    foreach ($r in $repos) {
        $dest = Join-Path $RomanDir $r
        if (Test-Path (Join-Path $dest '.git')) { $Skipped++; continue }
        Write-Host -NoNewline "  Cloning $r... "
        & gh repo clone "$ORG/$r" $dest -- --quiet 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "done" -ForegroundColor Green
            $Cloned++
        } else {
            Write-Host "failed" -ForegroundColor Red
            $CloneFailed++
        }
    }
    if ($Cloned -gt 0)      { Write-OK   "Cloned $Cloned new repositories" }
    if ($Skipped -gt 0)     { Write-Info "$Skipped repositories already exist locally" }
    if ($CloneFailed -gt 0) { Write-Warn2 "$CloneFailed repositories failed to clone (you may not have access)" }
    Write-Host ""

    # ── Fetch updates in parallel ────────────────────────────────
    Write-Host "── Downloading latest updates ──" -ForegroundColor White
    Write-Host ""
    Write-Info "Fetching updates for all repositories..."
    $jobs = @()
    Get-ChildItem -Path $RomanDir -Directory | ForEach-Object {
        if (Test-Path (Join-Path $_.FullName '.git')) {
            $jobs += Start-Job -ArgumentList $_.FullName -ScriptBlock {
                param($p)
                Set-Location $p
                git fetch --all --prune --quiet 2>$null
                git remote set-head origin --auto *> $null
            }
        }
    }
    if ($jobs) {
        $jobs | Wait-Job | Out-Null
        $jobs | Remove-Job
    }
    Write-OK "All updates downloaded"
    Write-Host ""

    # ── Reset each repo to its default branch ────────────────────
    Write-Host "── Updating to latest versions ──" -ForegroundColor White
    Write-Host ""
    Get-ChildItem -Path $RomanDir -Directory | ForEach-Object {
        if (-not (Test-Path (Join-Path $_.FullName '.git'))) { return }
        Push-Location $_.FullName
        try {
            $db = (& git symbolic-ref refs/remotes/origin/HEAD 2>$null) -replace '^refs/remotes/origin/', ''
            if (-not $db) {
                foreach ($b in 'main','master','develop') {
                    & git rev-parse --verify "origin/$b" *> $null
                    if ($LASTEXITCODE -eq 0) { $db = $b; break }
                }
            }
            if (-not $db) { return }

            $current = (& git branch --show-current 2>$null)
            $dirty   = (& git status --porcelain 2>$null)
            if ($dirty) {
                $changedCount = ($dirty -split "`n" | Where-Object { $_ }).Count
                Write-Warn2 "$($_.Name) — discarding uncommitted local changes ($changedCount file(s))"
                & git reset --hard HEAD --quiet 2>$null
                & git clean -fd --quiet 2>$null
            }
            if ($current -ne $db) {
                & git checkout $db --quiet 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warn2 "$($_.Name) — could not switch to $db"
                    $script:UpdateFailed++
                    return
                }
            }
            & git reset --hard "origin/$db" --quiet 2>$null
            if ($LASTEXITCODE -eq 0) { $script:Updated++ }
            else { Write-Warn2 "$($_.Name) — could not update"; $script:UpdateFailed++ }
        } finally { Pop-Location }
    }
    Write-Host ""

    # ── Roman / .claude config ───────────────────────────────────
    Write-Host "── Setting up Agents (Claude Code workspace) ──" -ForegroundColor White
    Write-Host ""

    $ClaudeDir = Join-Path $RomanDir '.claude'
    $SkillsDir = Join-Path $RomanDir 'skills'

    if (Test-Path $SkillsDir) {
        New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeDir 'hooks') | Out-Null

        $linkPath = Join-Path $ClaudeDir 'skills'
        if (Test-Path $linkPath) {
            $item = Get-Item $linkPath -Force
            if ($item.LinkType) {
                Remove-Item $linkPath -Force
                cmd /c mklink /J "$linkPath" "$SkillsDir" | Out-Null
                Write-OK "Updated skills junction"
            } else {
                Write-Info "skills\ already exists (not a junction) — skipping"
            }
        } else {
            cmd /c mklink /J "$linkPath" "$SkillsDir" | Out-Null
            Write-OK "Linked skills into .claude\"
        }

        $sharedHooks = Join-Path $SkillsDir '_shared\hooks'
        if (Test-Path $sharedHooks) {
            Copy-Item "$sharedHooks\*" (Join-Path $ClaudeDir 'hooks') -Force -ErrorAction SilentlyContinue
            Write-OK "Hooks updated"
        }

        $settingsPath = Join-Path $ClaudeDir 'settings.json'
        if (-not (Test-Path $settingsPath)) {
@'
{
  "permissions": {
    "allow": [
      "Read",
      "Glob",
      "Grep",
      "Bash(ls *)",
      "Bash(cat *)",
      "Bash(head *)",
      "Bash(tail *)",
      "Bash(wc *)",
      "Bash(find *)",
      "Bash(echo *)",
      "Bash(pwd)",
      "Bash(git status*)",
      "Bash(git log*)",
      "Bash(git diff*)",
      "Bash(git show*)",
      "Bash(git branch*)",
      "Bash(gh *)"
    ],
    "deny": []
  }
}
'@ | Set-Content -Path $settingsPath -Encoding UTF8
            Write-OK "Created settings.json (read-only permissions)"
        } else {
            Write-OK "settings.json already exists"
        }

        if (Test-Path (Join-Path $RomanDir 'CLAUDE.md')) { Write-OK "CLAUDE.md present" }
        else { Write-Warn2 "CLAUDE.md not found in $RomanDir" }

        Write-OK "Agents are ready to use"
    } else {
        Write-Warn2 "skills directory not found in fido-agent — Agents setup skipped"
    }
    Write-Host ""

    # ── ~/fido-money entry-point junction ────────────────────────
    $fidoMoneyLink = Join-Path $HOME 'fido-money'
    if ((Test-Path $fidoMoneyLink) -and -not ((Get-Item $fidoMoneyLink -Force).LinkType)) {
        Write-Warn2 "$fidoMoneyLink already exists and isn't a symlink — leaving it alone"
    } else {
        if (Test-Path $fidoMoneyLink) { Remove-Item $fidoMoneyLink -Force }
        cmd /c mklink /J "$fidoMoneyLink" "$RomanDir" | Out-Null
        Write-OK "Linked $fidoMoneyLink -> $RomanDir"
    }
    Write-Host ""

    # ── Fido Skills repo (user choice of location) ───────────────
    Write-Host "── Fido Skills (Claude Code skills) ──" -ForegroundColor White
    Write-Host ""
    Write-Info "FidoMoney/skills is a private repo of Claude Code skills curated by Fido."
    Write-Host ""

    $defaultSkillsDir   = Join-Path $HOME '.claude\skills\fido'
    $colocatedSkillsDir = Join-Path $HOME 'fido-money\skills-repo'
    $skillsRepoDir = ''

    if ((Test-Interactive)) {
        $items = @(
            "$defaultSkillsDir   (user-scope, picked up by every Claude session)",
            "$colocatedSkillsDir   (colocated with the install)",
            "Custom path",
            "Skip"
        )
        $pick = Select-One -Prompt "Where to clone FidoMoney/skills" -Items $items
        switch -Wildcard ($pick) {
            "$defaultSkillsDir*"   { $skillsRepoDir = $defaultSkillsDir }
            "$colocatedSkillsDir*" { $skillsRepoDir = $colocatedSkillsDir }
            'Custom*'              { $skillsRepoDir = Read-Host "  Path" }
            default                { $skillsRepoDir = '' }
        }
    } else {
        $skillsRepoDir = $defaultSkillsDir
    }

    if ($skillsRepoDir) {
        if (Test-Path (Join-Path $skillsRepoDir '.git')) {
            Write-Info "Skills repo already at $skillsRepoDir — pulling latest..."
            Push-Location $skillsRepoDir
            try {
                & git fetch --all --prune --quiet 2>$null
                & git reset --hard origin/main --quiet 2>$null
                Write-OK "Skills updated"
            } catch { Write-Warn2 "Skills update failed" }
            finally { Pop-Location }
        } else {
            $parent = Split-Path $skillsRepoDir -Parent
            if ($parent -and -not (Test-Path $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            & gh repo clone "$ORG/skills" $skillsRepoDir -- --quiet 2>$null
            if ($LASTEXITCODE -eq 0) { Write-OK "Skills cloned to $skillsRepoDir" }
            else { Write-Warn2 "Could not clone $ORG/skills — check your access permissions" }
        }
    } else {
        Write-Info "Skipped skills clone"
    }
    Write-Host ""

    # ── Setup summary ────────────────────────────────────────────
    Write-Host "==================================================" -ForegroundColor White
    Write-Host "   Setup Complete"                                   -ForegroundColor White
    Write-Host "==================================================" -ForegroundColor White
    Write-Host ""
    if ($Cloned -gt 0)       { Write-OK   "New repos cloned:   $Cloned" }
    Write-OK   "Repos up to date:   $Updated"
    if ($UpdateFailed -gt 0) { Write-Warn2 "Need attention:     $UpdateFailed" }
    if ($CloneFailed  -gt 0) { Write-Warn2 "Clone failures:     $CloneFailed (check access permissions)" }
    Write-Host ""
    Write-OK "Agents are at:     $fidoMoneyLink"
    if ($skillsRepoDir -and (Test-Path $skillsRepoDir)) { Write-OK "Fido Skills:       $skillsRepoDir" }
    Write-Host ""

}  # end of -McpOnly skip


# ═══════════════════════════════════════════════════════════════
#   MCP installer
# ═══════════════════════════════════════════════════════════════

function Build-McpCatalog {
    $tree = (& gh api "repos/$MCP_GITOPS_REPO/git/trees/main?recursive=1" --jq '.tree[] | select(.type == "tree") | .path' 2>$null)
    if (-not $tree) { return @() }

    $services = $tree -split "`n" |
        Where-Object { $_ -match "^$([regex]::Escape($MCP_GITOPS_PATH))/[^/]+$" } |
        ForEach-Object { ($_ -replace "^$([regex]::Escape($MCP_GITOPS_PATH))/", '') } |
        Where-Object { $_ -ne 'mcp-shared-resources' } |
        Sort-Object -Unique

    $catalog = @()
    foreach ($s in $services) {
        if (-not $s) { continue }
        $subPattern = "^$([regex]::Escape($MCP_GITOPS_PATH))/$([regex]::Escape($s))/overlays/global/[^/]+$"
        $subs = $tree -split "`n" |
            Where-Object { $_ -match $subPattern } |
            ForEach-Object { ($_ -replace "^$([regex]::Escape($MCP_GITOPS_PATH))/$([regex]::Escape($s))/overlays/global/", '') } |
            Sort-Object -Unique
        if ($subs) {
            foreach ($sub in $subs) { if ($sub) { $catalog += "$s-$sub" } }
        } else {
            $catalog += $s
        }
    }
    return $catalog
}

if ($SkipMcp) {
    Write-Info "Skipping MCP install (-SkipMcp / SKIP_MCP_INSTALL=1)"
    Write-Host ""
    if (-not $McpOnly) {
        Write-Host "  To use agents:  cd $HOME\fido-money; claude" -ForegroundColor White
        Write-Host ""
    }
    exit 0
}

Write-Host "── Fido MCP servers (Datadog, Snowflake, Slack, Mambu, ...) ──" -ForegroundColor White
Write-Host ""
Write-Info "MCP servers let Claude Code query Fido's data from the cluster."
Write-Info "You'll need: VPN ON and the Fido MCP bearer token (ask in #eng-platform)."
Write-Host ""

if (-not $McpOnly -and (Test-Interactive)) {
    $reply = Read-Host "  Install MCP servers now? [Y/n]"
    if ([string]::IsNullOrEmpty($reply)) { $reply = 'Y' }
    if ($reply -notmatch '^(y|Y|yes|YES)$') {
        Write-Info "Skipped. Run later: powershell -ExecutionPolicy Bypass -File .\install.ps1 -McpOnly"
        Write-Host ""
        exit 0
    }
}

if (-not (Has-Cmd 'claude')) {
    Write-Fail "'claude' CLI not found on PATH. Open a new terminal and rerun."
    exit 1
}
if (-not (Has-Cmd 'gh')) {
    Write-Fail "'gh' CLI not found. Run the full installer first (without -McpOnly)."
    exit 1
}
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "'gh' not authenticated. Run: gh auth login  then rerun."
    exit 1
}

Write-Info "Reading MCP catalog from $MCP_GITOPS_REPO/$MCP_GITOPS_PATH..."
$catalog = Build-McpCatalog
if (-not $catalog -or $catalog.Count -eq 0) {
    Write-Fail "Could not read MCP catalog from $MCP_GITOPS_REPO."
    Write-Fail "Check that your GitHub account has access to that repo."
    exit 1
}
Write-OK "Found $($catalog.Count) MCP servers"
Write-Host ""

if ($McpMode -eq 'interactive' -and (Test-Interactive)) {
    Write-Host "Quick option: install all $($catalog.Count) MCP servers in one shot." -ForegroundColor White
    Write-Host "  - Press Y (or Enter) to install everything" -ForegroundColor DarkGray
    Write-Host "  - Press N to pick servers from a list"      -ForegroundColor DarkGray
    $reply = Read-Host "  Install all? [Y/n]"
    if ($reply -notmatch '^(n|N|no|NO)$') { $McpMode = 'all'; Write-Info "Installing all MCPs..." }
    Write-Host ""
}

# Token — flag / env / hidden prompt.
if (-not $Token) {
    if ((Test-Interactive)) {
        Write-Info "Paste the Fido MCP bearer token (input hidden):"
        $secure = Read-Host -AsSecureString "  >"
        $Token = [System.Net.NetworkCredential]::new('', $secure).Password
    }
}
if (-not $Token) {
    Write-Fail "No token. Pass -Token <T> or set FIDO_MCP_TOKEN."
    exit 1
}
Write-OK "Token loaded (length=$($Token.Length))"
Write-Host ""

# DNS — call again so -McpOnly re-runs on a fresh box still configure resolvers.
Configure-DnsResolvers
if (-not $SkipDns) {
    if (Test-VpnUp) { Write-OK "VPN/DNS reachable" }
    else            { Write-Warn2 "Cannot resolve superset-mcp.$MCP_DNS_DOMAIN — is the VPN on? Continuing anyway." }
}

# Selection.
function Select-McpsFzf {
    return ($catalog | & fzf --multi --height=60% --reverse --border `
        --header "TAB to toggle, Enter to confirm, Ctrl-C to cancel  [$($catalog.Count) servers]" `
        --prompt "Install which MCPs? ")
}

function Select-McpsNumbered {
    $sel = New-Object 'bool[]' $catalog.Count
    while ($true) {
        Write-Host ""
        Write-Host "Available MCP servers" -ForegroundColor White
        Write-Host "----------------------------------------"
        for ($i = 0; $i -lt $catalog.Count; $i++) {
            $mark = if ($sel[$i]) { '[x]' } else { '[ ]' }
            Write-Host ("  {0} {1,2}) {2}" -f $mark, ($i + 1), $catalog[$i])
        }
        Write-Host ""
        Write-Host "  numbers/ranges to toggle (e.g. '1 3 5-8'), 'a'=all, 'n'=none, 'i'=invert, Enter=install, 'q'=quit"
        $input = Read-Host ">"
        if (-not $input) { break }
        switch -Regex ($input) {
            '^(q|Q)$' { exit 0 }
            '^(a|A)$' { for ($k = 0; $k -lt $catalog.Count; $k++) { $sel[$k] = $true } ; continue }
            '^(n|N)$' { for ($k = 0; $k -lt $catalog.Count; $k++) { $sel[$k] = $false } ; continue }
            '^(i|I)$' { for ($k = 0; $k -lt $catalog.Count; $k++) { $sel[$k] = -not $sel[$k] } ; continue }
            default {
                foreach ($tok in ($input -split '\s+')) {
                    if ($tok -match '^(\d+)-(\d+)$') {
                        $a = [int]$Matches[1]; $b = [int]$Matches[2]
                        if ($a -lt 1) { $a = 1 }; if ($b -gt $catalog.Count) { $b = $catalog.Count }
                        for ($k = $a; $k -le $b; $k++) { $sel[$k - 1] = -not $sel[$k - 1] }
                    } elseif ($tok -match '^\d+$') {
                        $n = [int]$tok
                        if ($n -ge 1 -and $n -le $catalog.Count) { $sel[$n - 1] = -not $sel[$n - 1] }
                    }
                }
            }
        }
    }
    $picked = @()
    for ($k = 0; $k -lt $catalog.Count; $k++) { if ($sel[$k]) { $picked += $catalog[$k] } }
    return $picked
}

switch ($McpMode) {
    'all'  { $selected = $catalog }
    'only' { $selected = $Only -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
    default {
        if (Has-Cmd 'fzf') { $selected = Select-McpsFzf }
        else               { $selected = Select-McpsNumbered }
    }
}

if (-not $selected -or $selected.Count -eq 0) {
    Write-Warn2 "Nothing selected — exiting"
    exit 0
}

Write-Host ""
Write-Host "Will install:" -ForegroundColor White
$selected | ForEach-Object { Write-Host "  - $_" }
Write-Host ""

# Cache `claude mcp list` once (it's slow).
Write-Info "Checking already-registered MCPs..."
$existingRaw = (& claude mcp list 2>$null) -split "`n"
$existingNames = @()
foreach ($l in $existingRaw) {
    if ($l -match '^([a-zA-Z0-9_-]+):') { $existingNames += $Matches[1] }
}

function Test-Known { param([string]$Name) return ($catalog -contains $Name) }

$installed = 0; $kept = 0; $failures = 0
foreach ($name in $selected) {
    if (-not $name) { continue }
    if (-not (Test-Known $name)) { Write-Fail "Unknown MCP '$name'"; $failures++; continue }

    $url = "http://$name-mcp.$MCP_DNS_DOMAIN/mcp"

    if ($existingNames -contains $name) {
        $decision = 'no'
        if ((Test-Interactive)) {
            $reply = Read-Host "  ? $name already configured. Overwrite? [y/N]"
            if ($reply -match '^(y|Y|yes|YES)$') { $decision = 'yes' }
        }
        if ($decision -eq 'no') { Write-Info "kept existing $name"; $kept++; continue }
        Write-Info "overwriting $name"
        if (-not $DryRun) { & claude mcp remove --scope user $name *> $null }
    }

    if ($DryRun) {
        Write-Host "  [dry-run] claude mcp add $name $url --transport http --scope user -H 'Authorization: Bearer ***'"
        $installed++
        continue
    }

    & claude mcp add $name $url --transport http --scope user -H "Authorization: Bearer $Token" *> $null
    if ($LASTEXITCODE -eq 0) { Write-OK "installed $name"; $installed++ }
    else { Write-Fail "failed to install $name"; $failures++ }
}

Write-Host ""
if ($failures -eq 0) {
    Write-OK "MCP install complete — $installed installed, $kept kept as-is"
    Write-Info "Verify with: claude mcp list"
} else {
    Write-Warn2 "MCP install finished with errors — $installed installed, $kept kept, $failures failed"
}

Write-Host ""
if (-not $McpOnly) {
    Write-Host "  To use agents:                cd $HOME\fido-money; claude"               -ForegroundColor White
    Write-Host "  To rerun MCP install later:   .\install.ps1 -McpOnly"                    -ForegroundColor White
    Write-Host ""
}
$pink = "$([char]27)[38;2;214;8;107m"
$rst  = "$([char]27)[0m"
Write-Host "${pink}  All set — welcome to Fido!${rst}"
Write-Host ""
