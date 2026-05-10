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
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -KeepLocal      # don't reset repos with uncommitted edits
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -AssumeYes      # auto-accept every [Y/n] prompt

  Environment:
    FIDO_MCP_TOKEN=<T>     same as -Token
    SKIP_MCP_INSTALL=1     same as -SkipMcp
    FIDO_KEEP_LOCAL=1      same as -KeepLocal
    FIDO_ASSUME_YES=1      same as -AssumeYes
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
    [switch]$KeepLocal,
    [Alias('y','Yes')]
    [switch]$AssumeYes,
    [string]$Token,
    [string]$Only,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'

# ── Config ───────────────────────────────────────────────────
$ORG            = 'FidoMoney'
# INSTALLER_VERSION — keep in sync with install.sh. Surfaced under the
# banner so support tickets can pin which revision a user actually ran.
$INSTALLER_VERSION = '2026.05.10'
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
if ($env:FIDO_KEEP_LOCAL  -eq '1')        { $KeepLocal = $true }
if ($env:FIDO_ASSUME_YES  -eq '1')        { $AssumeYes = $true }
if (-not $InstallDir -and $env:FIDO_INSTALL_DIR) { $InstallDir = $env:FIDO_INSTALL_DIR }

# Counts repos kept due to -KeepLocal (surfaced in the summary).
$script:KeptLocal = 0

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

# Run `gh repo clone $Remote $Dest` with an animated spinner so the user can
# see progress instead of staring at a frozen "Cloning…" line. Returns gh's
# exit code.
function Invoke-CloneWithSpinner {
    param(
        [Parameter(Mandatory)] [string]$Label,
        [Parameter(Mandatory)] [string]$Remote,
        [Parameter(Mandatory)] [string]$Dest
    )
    $frames = @('|', '/', '-', '\')
    $job = Start-Job -ScriptBlock {
        param($r, $d)
        & gh repo clone $r $d -- --quiet *> $null
        return $LASTEXITCODE
    } -ArgumentList $Remote, $Dest
    $i = 0
    while ($job.State -eq 'Running') {
        Write-Host -NoNewline ("`r  {0} Cloning {1}..." -f $frames[$i % $frames.Count], $Label)
        Start-Sleep -Milliseconds 120
        $i++
    }
    $rc = [int]((Receive-Job $job) | Select-Object -Last 1)
    Remove-Job $job | Out-Null
    if ($rc -eq 0) {
        Write-Host -NoNewline ("`r  + Cloning {0}... " -f $Label)
        Write-Host "done    " -ForegroundColor Green
    } else {
        Write-Host -NoNewline ("`r  X Cloning {0}... " -f $Label)
        Write-Host "failed  " -ForegroundColor Red
    }
    return $rc
}

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
    Write-Host "                                       by platform team · v$INSTALLER_VERSION" -ForegroundColor DarkGray
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
if (-not $McpOnly -and (Test-Interactive) -and -not $AssumeYes) {
    Write-Host "This installer will:" -ForegroundColor White
    Write-Host "  - Install winget packages: git, gh, fzf, Node.js, AWS VPN Client"
    Write-Host "  - Install AWS CLI (winget, with fallback to Amazon's official MSI)"
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
    Install-WingetPkg -Cmd 'node' -Id 'OpenJS.NodeJS'   -Label 'Node.js (for Claude Code)'

    # AWS VPN Client — no CLI binary, install by id only.
    Install-WingetPkg -Cmd $null  -Id 'Amazon.AWSVPNClient' -Label 'AWS VPN Client'

    Refresh-Path

    # AWS CLI — winget first; if that fails (managed laptops with the Store
    # disabled, or ships a broken bundle), fall back to Amazon's official
    # MSI from awscli.amazonaws.com. We always smoke-test `aws --version`
    # afterwards so a broken install fails with a clear message instead of
    # surfacing later as a confusing traceback inside Verify-AwsCreds.
    function Test-AwsRuns {
        try { & aws --version *> $null; return ($LASTEXITCODE -eq 0) }
        catch { return $false }
    }

    function Install-AwsCliMsi {
        $msi = Join-Path ([System.IO.Path]::GetTempPath()) "AWSCLIV2-$([guid]::NewGuid().ToString('N')).msi"
        try {
            Write-Info "Downloading AWS CLI MSI from awscli.amazonaws.com..."
            Invoke-WebRequest -Uri 'https://awscli.amazonaws.com/AWSCLIV2.msi' -OutFile $msi -UseBasicParsing
            Write-Info "Running MSI installer (UAC may prompt)..."
            $proc = Start-Process -Wait -PassThru msiexec.exe -ArgumentList @('/i', $msi, '/qb')
            return ($proc.ExitCode -eq 0)
        } catch {
            Write-Warn2 "AWS CLI MSI install failed: $_"
            return $false
        } finally {
            Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        }
    }

    function Ensure-AwsCli {
        Refresh-Path
        if ((Has-Cmd 'aws') -and (Test-AwsRuns)) {
            $ver = (& aws --version 2>&1) -join ' '
            Write-OK "AWS CLI is installed ($ver)"
            return $true
        }
        if (Has-Cmd 'aws') {
            Write-Warn2 "AWS CLI is present but 'aws --version' fails — reinstalling"
        } else {
            Write-Info "Installing AWS CLI..."
        }

        try {
            winget install --id 'Amazon.AWSCLI' -e --accept-package-agreements --accept-source-agreements --silent | Out-Null
        } catch {
            Write-Warn2 "winget failed for AWS CLI: $_"
        }
        Refresh-Path
        if ((Has-Cmd 'aws') -and (Test-AwsRuns)) {
            Write-OK "AWS CLI installed (via winget)"
            return $true
        }

        Write-Warn2 "winget didn't produce a working 'aws' — falling back to direct MSI."
        if (-not (Install-AwsCliMsi)) { return $false }
        Refresh-Path
        if ((Has-Cmd 'aws') -and (Test-AwsRuns)) {
            $ver = (& aws --version 2>&1) -join ' '
            Write-OK "AWS CLI installed via MSI ($ver)"
            return $true
        }
        Write-Fail "AWS CLI installed but 'aws --version' still fails — open a new terminal and rerun."
        return $false
    }

    # ── Validate Fido AWS access via SSO OIDC device flow ────────
    # We deliberately don't shell out to `aws` for validation. The
    # AWS CLI on the box may be stale, broken, or not yet installed
    # — we want validation to keep working anyway. AWS publishes the
    # SSO OIDC API as plain HTTP — three documented endpoints get us
    # an access token, then list-accounts on the portal proves the
    # token actually has Fido AWS access (not just SSO sign-in).
    # We also write the access token to ~/.aws/sso/cache/ in the
    # exact format the AWS CLI looks up, so the user's first `aws`
    # command after this installer runs inherits the live session.

    $FidoSsoStartUrl = 'https://fido.awsapps.com/start/'
    $FidoSsoRegion   = 'eu-west-1'
    $FidoSsoName     = 'fido'
    $SsoOidcUrl      = "https://oidc.$FidoSsoRegion.amazonaws.com"
    $SsoPortalUrl    = "https://portal.sso.$FidoSsoRegion.amazonaws.com"

    function Get-Sha1Hex {
        param([string]$s)
        $sha = [System.Security.Cryptography.SHA1]::Create()
        try {
            $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
            return -join ($hash | ForEach-Object { $_.ToString('x2') })
        } finally { $sha.Dispose() }
    }

    # Stage to <path>.tmp then move into place. Uses UTF-8 *without*
    # BOM — PS5.1's `Set-Content -Encoding UTF8` writes a BOM that
    # some JSON parsers choke on. We avoid [System.IO.File]::Replace
    # because the null-backup overload throws on .NET Core/macOS.
    function Write-FileNoBom {
        param([string]$Path, [string]$Content)
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $tmp = "$Path.tmp"
        [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }

    # Pull the {"error":"..."} field out of a 4xx response body.
    # Works on PS5.1 (response stream) and PS7 (ErrorDetails.Message).
    function Get-OidcErrorCode {
        param($ErrorRecord)
        $body = $null
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $body = $ErrorRecord.ErrorDetails.Message
        } elseif ($ErrorRecord.Exception.Response) {
            try {
                $stream = $ErrorRecord.Exception.Response.GetResponseStream()
                if ($stream.CanSeek) { $stream.Position = 0 }
                $body = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
            } catch { }
        }
        if (-not $body) { return $null }
        try { return ($body | ConvertFrom-Json).error } catch { return $null }
    }

    # Returns the cached access token if a valid (non-expired) Fido
    # SSO session exists, else $null.
    #
    # Subtlety: ConvertFrom-Json auto-coerces ISO 8601 strings to
    # System.DateTime. Going back through [DateTimeOffset]::Parse on
    # that DateTime loses the UTC kind and re-applies the host's local
    # offset, which silently inverts the comparison under non-UTC
    # timezones. Read the DateTime's universal time directly instead.
    function Get-CachedFidoSsoToken {
        $cache = Join-Path $HOME '.aws\sso\cache'
        if (-not (Test-Path $cache)) { return $null }
        $now = [DateTimeOffset]::UtcNow
        foreach ($f in (Get-ChildItem -LiteralPath $cache -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try { $d = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            if ($d.startUrl -ne $FidoSsoStartUrl) { continue }
            try {
                $exp = if ($d.expiresAt -is [datetime]) {
                    [DateTimeOffset]::new($d.expiresAt.ToUniversalTime())
                } else {
                    [DateTimeOffset]::Parse([string]$d.expiresAt,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
                        [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                }
            } catch { continue }
            if ($exp -gt $now -and $d.accessToken) { return $d.accessToken }
        }
        return $null
    }

    # Run the SSO OIDC device-authorization flow. On success returns
    # the access token (string) and writes the cache file. Returns
    # $null on any failure.
    function Invoke-FidoSsoOidcLogin {
        $cache = Join-Path $HOME '.aws\sso\cache'
        New-Item -ItemType Directory -Force -Path $cache | Out-Null

        Write-Info "Registering OIDC client..."
        try {
            $reg = Invoke-RestMethod -Method Post -Uri "$SsoOidcUrl/client/register" `
                -ContentType 'application/json' `
                -Body '{"clientName":"fido-installer","clientType":"public","scopes":["sso:account:access"]}'
        } catch {
            Write-Fail "OIDC client registration failed: $_"
            return $null
        }
        if (-not $reg.clientId -or -not $reg.clientSecret) {
            Write-Fail "OIDC register: bad response"
            return $null
        }

        Write-Info "Starting device authorization..."
        $body = (@{ clientId=$reg.clientId; clientSecret=$reg.clientSecret; startUrl=$FidoSsoStartUrl } |
                 ConvertTo-Json -Compress)
        try {
            $auth = Invoke-RestMethod -Method Post -Uri "$SsoOidcUrl/device_authorization" `
                -ContentType 'application/json' -Body $body
        } catch {
            Write-Fail "Device authorization request failed: $_"
            return $null
        }
        if (-not $auth.deviceCode -or -not $auth.verificationUriComplete) {
            Write-Fail "Bad device_authorization response"
            return $null
        }
        $interval  = if ($auth.interval)  { [int]$auth.interval }  else { 5 }
        $expiresIn = if ($auth.expiresIn) { [int]$auth.expiresIn } else { 600 }

        Write-Host ""
        Write-Info "Opening Fido SSO in your browser..."
        Write-Info "Verification code: $($auth.userCode)"
        Write-Info "If the browser doesn't open: $($auth.verificationUriComplete)"
        try { Start-Process $auth.verificationUriComplete | Out-Null } catch { }
        Write-Host ""
        Write-Info "Waiting for you to approve in the browser (up to $([math]::Floor($expiresIn/60))min)..."

        # Poll /token until the user finishes the browser flow. While
        # the user is still authenticating, /token returns HTTP 400 +
        # {"error":"authorization_pending"}; we catch that and keep
        # polling. AWS uses "slow_down" to ask us to back off.
        $tokenBody = (@{
            clientId     = $reg.clientId
            clientSecret = $reg.clientSecret
            grantType    = 'urn:ietf:params:oauth:grant-type:device_code'
            deviceCode   = $auth.deviceCode
        } | ConvertTo-Json -Compress)
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($expiresIn)

        $accessToken    = $null
        $expiresInToken = 28800
        while ([DateTimeOffset]::UtcNow -lt $deadline) {
            try {
                $tok = Invoke-RestMethod -Method Post -Uri "$SsoOidcUrl/token" `
                    -ContentType 'application/json' -Body $tokenBody -ErrorAction Stop
                if ($tok.accessToken) {
                    $accessToken = $tok.accessToken
                    if ($tok.expiresIn) { $expiresInToken = [int]$tok.expiresIn }
                    break
                }
            } catch {
                $err = Get-OidcErrorCode -ErrorRecord $_
                switch ($err) {
                    'authorization_pending' { }
                    'slow_down'             { $interval += 5 }
                    $null                   { Write-Warn2 "Empty error from /token, retrying" }
                    default                 { Write-Fail "Sign-in failed ($err)"; return $null }
                }
            }
            Start-Sleep -Seconds $interval
        }
        if (-not $accessToken) { Write-Fail "Timed out waiting for browser sign-in"; return $null }

        # Write cache under both name-hash and url-hash keys (modern +
        # legacy CLI lookup paths).
        $expiresAt = ([DateTimeOffset]::UtcNow.AddSeconds($expiresInToken)).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $cacheData = [pscustomobject]@{
            startUrl     = $FidoSsoStartUrl
            region       = $FidoSsoRegion
            accessToken  = $accessToken
            expiresAt    = $expiresAt
            clientId     = $reg.clientId
            clientSecret = $reg.clientSecret
        }
        $json = $cacheData | ConvertTo-Json -Compress
        $keys = @((Get-Sha1Hex $FidoSsoName), (Get-Sha1Hex $FidoSsoStartUrl)) | Sort-Object -Unique
        foreach ($k in $keys) {
            $path = Join-Path $cache "$k.json"
            try { Write-FileNoBom -Path $path -Content $json }
            catch { Write-Warn2 "Couldn't write cache file ${path}: $_" }
        }

        return $accessToken
    }

    # Validate access by listing accounts. Returns the count.
    function Get-FidoSsoAccountCount {
        param([string]$Token)
        try {
            $r = Invoke-RestMethod -Uri "$SsoPortalUrl/federation/list-accounts?max_result=100" `
                -Headers @{ 'x-amz-sso_bearer_token' = $Token } -ErrorAction Stop
            return @($r.accountList).Count
        } catch { return 0 }
    }

    # Have the user pick an account & role. Returns
    # @{accountId; accountName; roleName} or $null.
    function Select-FidoSsoAccountRole {
        param([string]$Token)
        $headers = @{ 'x-amz-sso_bearer_token' = $Token }
        try {
            $accounts = Invoke-RestMethod -Uri "$SsoPortalUrl/federation/list-accounts?max_result=100" `
                -Headers $headers -ErrorAction Stop
        } catch { return $null }
        $accountList = @($accounts.accountList)
        if ($accountList.Count -eq 0) { return $null }

        $a = $null
        if ($accountList.Count -eq 1) {
            $a = $accountList[0]
        } else {
            $items = $accountList | ForEach-Object { "$($_.accountName)  ($($_.accountId))" }
            $pick = Select-One -Prompt 'Pick an AWS account' -Items $items
            if (-not $pick) { return $null }
            $a = $accountList | Where-Object { "$($_.accountName)  ($($_.accountId))" -eq $pick } | Select-Object -First 1
        }
        if (-not $a) { return $null }

        try {
            $roles = Invoke-RestMethod -Uri "$SsoPortalUrl/federation/list-account-roles?account_id=$($a.accountId)&max_result=100" `
                -Headers $headers -ErrorAction Stop
        } catch { return $null }
        $roleList = @($roles.roleList)
        if ($roleList.Count -eq 0) { return $null }

        $role = $null
        if ($roleList.Count -eq 1) {
            $role = $roleList[0].roleName
        } else {
            $names = $roleList | ForEach-Object { $_.roleName }
            $role = Select-One -Prompt 'Pick a role' -Items $names
            if (-not $role) { return $null }
        }
        return @{ accountId = $a.accountId; accountName = $a.accountName; roleName = $role }
    }

    # Hand-rolled INI editor for ~/.aws/config. Replaces the named
    # section in-place and preserves every other section verbatim.
    # Appends if the section doesn't already exist.
    function Set-AwsConfigSection {
        param([string]$Path, [string]$Section, [hashtable]$KeyValues)
        $lines = if (Test-Path $Path) { @(Get-Content -LiteralPath $Path) } else { @() }
        $out = New-Object System.Collections.Generic.List[string]
        $inTarget = $false
        $written  = $false
        foreach ($line in $lines) {
            if ($line -match '^\s*\[(.+?)\]\s*$') {
                $inTarget = ($Matches[1] -eq $Section)
                $out.Add($line)
                if ($inTarget) {
                    foreach ($k in $KeyValues.Keys) { $out.Add("$k = $($KeyValues[$k])") }
                    $written = $true
                }
                continue
            }
            if ($inTarget) { continue }   # drop the old contents of the target section
            $out.Add($line)
        }
        if (-not $written) {
            if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne '') { $out.Add('') }
            $out.Add("[$Section]")
            foreach ($k in $KeyValues.Keys) { $out.Add("$k = $($KeyValues[$k])") }
        }
        Write-FileNoBom -Path $Path -Content (($out -join "`n") + "`n")
    }

    function Write-FidoSsoConfig {
        param([string]$AccountId, [string]$RoleName)
        $cfg = if ($env:AWS_CONFIG_FILE) { $env:AWS_CONFIG_FILE } else { Join-Path $HOME '.aws\config' }
        Set-AwsConfigSection -Path $cfg -Section "sso-session $FidoSsoName" -KeyValues @{
            sso_start_url           = $FidoSsoStartUrl
            sso_region              = $FidoSsoRegion
            sso_registration_scopes = 'sso:account:access'
        }
        Set-AwsConfigSection -Path $cfg -Section "profile $FidoSsoName" -KeyValues @{
            sso_session    = $FidoSsoName
            sso_account_id = $AccountId
            sso_role_name  = $RoleName
            region         = $FidoSsoRegion
            output         = 'json'
        }
    }

    function Ensure-FidoSso {
        $token = Get-CachedFidoSsoToken
        if ($token) {
            Write-OK "Active Fido SSO session found"
            if (-not $env:AWS_PROFILE) { $env:AWS_PROFILE = $FidoSsoName }
            return $true
        }

        if (-not (Test-Interactive)) {
            Write-Fail "No active Fido SSO session and stdin isn't a terminal — can't run the device flow."
            return $false
        }

        Write-Info "Starting Fido AWS SSO sign-in (no AWS CLI required)..."
        $token = Invoke-FidoSsoOidcLogin
        if (-not $token) { return $false }

        Write-Info "Validating Fido AWS account access..."
        $n = Get-FidoSsoAccountCount -Token $token
        if ($n -lt 1) {
            Write-Fail "Sign-in succeeded but no AWS accounts are assigned to your Fido SSO user."
            return $false
        }
        Write-OK "Fido SSO sign-in succeeded — $n account(s) available"

        $cfg = if ($env:AWS_CONFIG_FILE) { $env:AWS_CONFIG_FILE } else { Join-Path $HOME '.aws\config' }
        $hasFido = (Test-Path $cfg) -and (Select-String -LiteralPath $cfg -Pattern 'fido\.awsapps\.com/start' -Quiet)
        if (-not $hasFido) {
            Write-Info "Picking a default AWS account+role for the $FidoSsoName profile..."
            $picked = Select-FidoSsoAccountRole -Token $token
            if ($picked) {
                try {
                    Write-FidoSsoConfig -AccountId $picked.accountId -RoleName $picked.roleName
                    Write-OK "Wrote profile $FidoSsoName -> $($picked.accountName) ($($picked.roleName))"
                    Write-Info "To make it your default, run: setx AWS_PROFILE $FidoSsoName"
                } catch {
                    Write-Warn2 "Couldn't write ~/.aws/config: $_"
                }
            } else {
                Write-Warn2 "Skipped account/role picker — run 'aws configure sso' later if you want a CLI profile."
            }
        } else {
            Write-OK "Fido SSO already in ~/.aws/config — refreshed session cache"
        }
        if (-not $env:AWS_PROFILE) { $env:AWS_PROFILE = $FidoSsoName }
        return $true
    }

    # Validate Fido SSO access first (cheap, no admin rights). If the
    # user has no Fido AWS account we can fail before installing the
    # CLI and before prompting for elevation.
    if (-not (Ensure-FidoSso)) {
        Write-Host ""
        Write-Fail "Couldn't establish Fido AWS SSO access."
        Write-Host ""
        Write-Info "Don't have a Fido AWS account yet?"
        Write-Info "  Ping #eng-platform on Slack to request one."
        Write-Info "  Once it's created, re-run this installer."
        Write-Host ""
        Write-Info "Browser sign-in failed or timed out?"
        Write-Info "  Re-run this installer and complete the SSO step in your browser."
        Write-Host ""
        Write-Fail "Aborting installer — re-run once SSO sign-in succeeds."
        exit 1
    }

    # Install the AWS CLI for downstream use. The OIDC cache we just
    # wrote is in the format the CLI expects, so the user's first
    # `aws` command inherits the live session — no second login.
    if (-not (Ensure-AwsCli)) { exit 1 }

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

        # -AssumeYes has no safe default for the VPN profile (the user has
        # to paste config or supply a path). Skip the prompt the same way
        # the non-tty branch below does.
        if ((Test-Interactive) -and -not $AssumeYes) {
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
                if ($dirty -and $KeepLocal) {
                    Write-Warn2 "fido-agent — uncommitted changes; -KeepLocal set, leaving as-is"
                    $script:KeptLocal++
                } else {
                    if ($dirty) {
                        $changedCount = ($dirty -split "`n" | Where-Object { $_ }).Count
                        Write-Warn2 "fido-agent — discarding uncommitted local changes ($changedCount file(s))"
                    }
                    & git reset --hard "origin/$defaultBranch" --quiet 2>$null
                }
            }
            Write-OK "fido-agent updated"
        } finally { Pop-Location }
    } else {
        $rc = Invoke-CloneWithSpinner -Label 'fido-agent' -Remote "$ORG/fido-agent" -Dest $AgentRepoDir
        if ($rc -eq 0) {
            Write-OK "fido-agent cloned"
        } else {
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
        $rc = Invoke-CloneWithSpinner -Label $r -Remote "$ORG/$r" -Dest $dest
        if ($rc -eq 0) { $Cloned++ } else { $CloneFailed++ }
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
                if ($KeepLocal) {
                    # -KeepLocal: warn but DON'T reset/clean. We still ran
                    # `git fetch` earlier so `git status` will show the
                    # user they're behind origin — they can rebase manually.
                    Write-Warn2 "$($_.Name) — uncommitted changes; -KeepLocal set, leaving as-is ($changedCount file(s))"
                    $script:KeptLocal++
                    return
                }
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

    if ((Test-Interactive) -and -not $AssumeYes) {
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
            $rc = Invoke-CloneWithSpinner -Label 'skills' -Remote "$ORG/skills" -Dest $skillsRepoDir
            if ($rc -eq 0) { Write-OK "Skills cloned to $skillsRepoDir" }
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
    if ($Cloned -gt 0)        { Write-OK   "New repos cloned:   $Cloned" }
    Write-OK   "Repos up to date:   $Updated"
    if ($script:KeptLocal -gt 0) { Write-Warn2 "Kept (local edits): $script:KeptLocal (-KeepLocal; rebase manually)" }
    if ($UpdateFailed -gt 0)  { Write-Warn2 "Need attention:     $UpdateFailed" }
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

if (-not $McpOnly -and (Test-Interactive) -and -not $AssumeYes) {
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

# -AssumeYes promotes interactive mode to 'all' without prompting. Explicit
# -All / -Only still take precedence because they pin $McpMode before this
# gate runs.
if ($McpMode -eq 'interactive' -and $AssumeYes) {
    $McpMode = 'all'
    Write-Info "Installing all MCPs (-AssumeYes implies install-all default)..."
} elseif ($McpMode -eq 'interactive' -and (Test-Interactive)) {
    Write-Host "Quick option: install all $($catalog.Count) MCP servers in one shot." -ForegroundColor White
    Write-Host "  - Press Y (or Enter) to install everything" -ForegroundColor DarkGray
    Write-Host "  - Press N to pick servers from a list"      -ForegroundColor DarkGray
    $reply = Read-Host "  Install all? [Y/n]"
    if ($reply -notmatch '^(n|N|no|NO)$') { $McpMode = 'all'; Write-Info "Installing all MCPs..." }
    Write-Host ""
}

# Token — flag / env / hidden prompt. Under -AssumeYes we deliberately do
# NOT prompt (-AssumeYes is for unattended runs; the token must come from
# -Token / env). The fail-fast block below catches the missing-token case.
if (-not $Token) {
    if ((Test-Interactive) -and -not $AssumeYes) {
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
        # -AssumeYes intentionally does NOT auto-overwrite — that would let
        # -AssumeYes silently rewrite a working user's MCP config with a
        # possibly-wrong token. Treat -AssumeYes the same as no-tty: keep.
        $decision = 'no'
        if ((Test-Interactive) -and -not $AssumeYes) {
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
