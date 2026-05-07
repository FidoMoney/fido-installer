#!/bin/bash
#
# Fido Agents Setup & Update Script
# -----------------------------------
# One-shot installer: dev tools, Claude Code, Fido agents, AWS VPN, and
# all cluster MCP servers. Idempotent — safe to rerun for updates.
#
# Quickstart (new employees):
#   bash <(curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-installer/main/install.sh)
#
# Usage (when run from a downloaded copy):
#   bash install.sh                       # full setup (interactive)
#   bash install.sh --mcp-only            # just (re)install MCPs
#   bash install.sh --token <TOKEN>       # supply MCP token up front
#   bash install.sh --mcp-only --all      # all MCPs, no checklist
#   bash install.sh --skip-mcp            # skip MCP step entirely
#
# Environment:
#   FIDO_MCP_TOKEN=<T>     same as --token
#   SKIP_MCP_INSTALL=1     same as --skip-mcp
#   FIDO_INSTALL_DIR=<D>   where to put fido-agent/  (default: $HOME when piped,
#                          else the script's directory)
#

set -euo pipefail

# ── Arg parsing ──────────────────────────────────────────────────
MCP_ONLY=0
SKIP_MCP="${SKIP_MCP_INSTALL:-0}"
SKIP_REPOS=0
MCP_TOKEN="${FIDO_MCP_TOKEN:-}"
MCP_MODE="interactive"
MCP_ONLY_LIST=""
MCP_DRY_RUN=0
MCP_SKIP_DNS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mcp-only)  MCP_ONLY=1; shift ;;
        --skip-mcp)  SKIP_MCP=1; shift ;;
        --token)     MCP_TOKEN="$2"; shift 2 ;;
        --all)       MCP_MODE="all"; shift ;;
        --only)      MCP_MODE="only"; MCP_ONLY_LIST="${2:-}"; shift 2 ;;
        --dry-run)   MCP_DRY_RUN=1; shift ;;
        --skip-dns)  MCP_SKIP_DNS=1; shift ;;
        -h|--help)   sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

ORG="FidoMoney"

# Internal DNS zones the VPN tunnel exposes. MCP servers live under
# global-private.fido.money; private.fido.money serves the data backends
# many MCPs talk to. Both resolvers must be in place for MCP installs to
# verify reachability.
MCP_DNS_DOMAIN="global-private.fido.money"
MCP_DNS_ZONES=(
    "global-private.fido.money:10.3.0.2"
    "private.fido.money:10.30.0.2"
    "gh-prod-private.fido.money:10.20.0.2"
    "ug-prod-private.fido.money:10.40.0.2"
    "zm-prod-private.fido.money:10.50.0.2"
)

# Resolve install location. When invoked from a real file we co-locate
# fido-agent/ next to the script (back-compat with the in-repo workflow).
# When piped (`curl|bash`) or process-substituted (`bash <(curl ...)`),
# `$0` is `bash` or `/dev/fd/N` — neither is a useful directory — so we
# default to $HOME. Override with FIDO_INSTALL_DIR.
if [ -n "${FIDO_INSTALL_DIR:-}" ]; then
    SCRIPT_DIR="$FIDO_INSTALL_DIR"
elif [ -f "$0" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
else
    SCRIPT_DIR="${HOME}"
fi
AGENT_REPO_DIR="${SCRIPT_DIR}/fido-agent"
ROMAN_DIR="${AGENT_REPO_DIR}/roman"

# ── Colors & Helpers ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2;37m'
PINK='\033[38;2;214;8;107m'   # Fido brand pink (#d6086b)
NC='\033[0m'

# All diagnostics go to stderr so functions that need to return a value
# via stdout (sso_oidc_login → access token, sso_list_accounts → count,
# sso_pick_account_role → tab-separated picks) can call them freely
# without their progress lines getting captured by `$(...)`.
info()    { echo -e "${BLUE}ℹ${NC}  $1" >&2; }
success() { echo -e "${GREEN}✔${NC}  $1" >&2; }
warn()    { echo -e "${YELLOW}⚠${NC}  $1" >&2; }
fail()    { echo -e "${RED}✖${NC}  $1" >&2; }

# Run `gh repo clone $remote $dest` with an animated braille spinner so the
# user can see progress instead of staring at a frozen "Cloning…" line.
# Returns gh's exit status.
clone_with_spinner() {
    local label="$1" remote="$2" dest="$3"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local nframes=${#frames[@]}
    local i=0 rc=0
    gh repo clone "$remote" "$dest" -- --quiet >/dev/null 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${BLUE}%s${NC} Cloning %s..." "${frames[i % nframes]}" "$label"
        i=$((i + 1))
        sleep 0.1
    done
    wait "$pid" || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf "\r  ${GREEN}✔${NC} Cloning %s... ${GREEN}done${NC}    \n" "$label"
    else
        printf "\r  ${RED}✖${NC} Cloning %s... ${RED}failed${NC}  \n" "$label"
    fi
    return $rc
}

# Single-select picker via fzf. Echoes the chosen line, or empty on cancel.
# Lines are passed as args. Caller decides how to interpret the result.
fzf_pick() {
    local prompt="$1"; shift
    printf '%s\n' "$@" | fzf --height=40% --reverse --border --no-multi \
        --prompt="${prompt} > " \
        --header="↑↓ to move, Enter to select, Esc to cancel"
}

# Write the /etc/resolver/* files for every Fido internal zone. Idempotent:
# skips zones whose resolver already points at the right nameserver, only
# prompts for sudo if at least one zone needs writing.
configure_dns_resolvers() {
    [ "$MCP_SKIP_DNS" = "1" ] && { info "Skipping DNS resolver setup (--skip-dns)"; return 0; }
    local zone_entry zone ns resolver_file sudo_prompted=0
    for zone_entry in "${MCP_DNS_ZONES[@]}"; do
        zone="${zone_entry%%:*}"
        ns="${zone_entry##*:}"
        resolver_file="/etc/resolver/${zone}"
        if [ -f "$resolver_file" ] && grep -q "$ns" "$resolver_file"; then
            success "DNS resolver for *.${zone} already configured"
            continue
        fi
        if [ "$sudo_prompted" = "0" ]; then
            info "Configuring DNS resolvers (sudo) — may prompt for your Mac password"
            sudo_prompted=1
        fi
        if [ "$MCP_DRY_RUN" = "1" ]; then
            echo "  [dry-run] sudo tee $resolver_file <<< 'nameserver ${ns}'"
        else
            sudo mkdir -p /etc/resolver
            echo "nameserver ${ns}" | sudo tee "$resolver_file" >/dev/null
            success "Wrote ${resolver_file} → ${ns}"
        fi
    done
}

# Returns 0 if DNS resolves an internal MCP host (i.e. VPN is up).
vpn_is_up() {
    dscacheutil -q host -a name "superset-mcp.${MCP_DNS_DOMAIN}" 2>/dev/null | grep -q "ip_address"
}

# Open AWS VPN Client and wait (up to ~60s) for connectivity. macOS doesn't
# expose a CLI to connect a profile, so we open the GUI and poll DNS until
# it resolves the internal MCP host. The user can press Enter at any time
# to skip the wait.
launch_vpn_and_wait() {
    if vpn_is_up; then
        success "VPN is already up"
        return 0
    fi
    info "Launching ${BOLD}AWS VPN Client${NC}..."
    open -a "AWS VPN Client" 2>/dev/null || warn "Couldn't open AWS VPN Client"
    echo ""
    if [ "${VPN_PROFILE_AUTO_IMPORTED:-0}" != "1" ] \
        && [ -n "${VPN_PROFILE_PATH:-}" ] && [ -f "$VPN_PROFILE_PATH" ]; then
        info "If the profile isn't already loaded, add it now:"
        info "  ${BOLD}File → Manage Profiles → Add Profile${NC}  →  ${VPN_PROFILE_PATH}"
    fi
    info "Click ${BOLD}Connect${NC} on the Fido profile in AWS VPN Client."
    echo ""
    info "Waiting for VPN to come up (up to 60s)... press ${BOLD}Enter${NC} to skip."
    local i
    for i in $(seq 1 30); do
        if vpn_is_up; then
            success "VPN is up — DNS resolves"
            return 0
        fi
        # Non-blocking poll for Enter — 2s timeout per iteration.
        if read -r -t 2 -n 1 _ 2>/dev/null; then
            warn "Skipped VPN wait — continuing without verifying connectivity"
            return 1
        fi
    done
    warn "Timed out waiting for VPN — continuing anyway"
    return 1
}

# Banner — slant-figlet "Fido Installer", Fido pink, with subtitle.
print_banner() {
    echo ""
    echo -e "${BOLD}${PINK}    _______     __         ____           __        ____         ${NC}"
    echo -e "${BOLD}${PINK}   / ____(_)___/ /___     /  _/___  _____/ /_____ _/ / /__  _____${NC}"
    echo -e "${BOLD}${PINK}  / /_  / / __  / __ \\    / // __ \\/ ___/ __/ __ \`/ / / _ \\/ ___/${NC}"
    echo -e "${BOLD}${PINK} / __/ / / /_/ / /_/ /  _/ // / / (__  ) /_/ /_/ / / /  __/ /    ${NC}"
    echo -e "${BOLD}${PINK}/_/   /_/\\__,_/\\____/  /___/_/ /_/____/\\__/\\__,_/_/_/\\___/_/     ${NC}"
    echo -e "${DIM}                                                  by platform team${NC}"
    echo ""
}

print_banner

if [ "$MCP_ONLY" = "1" ]; then
    echo -e "${BOLD}   MCP Servers only${NC}"
else
    echo -e "${BOLD}   Setup & update${NC}"
fi
echo ""

# Upfront preamble — what's about to happen, and what touches the system,
# so the user has a chance to bail before sudo/network calls. Skipped in
# --mcp-only mode (smaller scope) and in non-interactive runs.
if [ "$MCP_ONLY" = "0" ] && [ -t 0 ]; then
    echo -e "${BOLD}This installer will:${NC}"
    echo "  • Install Homebrew packages: gh, fzf, AWS VPN Client (cask)"
    echo "  • Install AWS CLI from Amazon's official pkg (awscli.amazonaws.com)"
    echo "  • Install Claude Code (via the official installer at claude.ai/install.sh)"
    echo "  • Sign you in to Fido AWS SSO via your browser (no password to type)"
    echo "  • Clone/update Fido repos under ${BOLD}${SCRIPT_DIR}/fido-agent/${NC}"
    echo "  • Configure macOS DNS resolvers under ${BOLD}/etc/resolver/${NC} (asks for sudo)"
    echo "  • Import a Fido VPN profile into ${BOLD}~/.config/AWSVPNClient/${NC}"
    echo "  • Register Fido cluster MCP servers with Claude Code (user scope)"
    echo ""
    echo -e "  ${BOLD}Will read/write${NC}: ~/.aws  ~/.config/AWSVPNClient  ~/.claude  /etc/resolver/"
    echo -e "  ${BOLD}Network access${NC}: Homebrew, GitHub, AWS SSO browser, MCP hosts (via VPN)"
    echo ""
    echo "  Re-running is safe — every step is idempotent."
    echo ""
    read -r -p "$(echo -e "${BOLD}Press Enter to continue, or Ctrl-C to abort: ${NC}")" _
    echo ""
fi

# Initialize counters so they're safe when --mcp-only skips the repo section.
CLONED=0; SKIPPED=0; CLONE_FAILED=0; UPDATED=0; UPDATE_FAILED=0

# Skip the entire onboarding flow in --mcp-only mode.
if [ "$MCP_ONLY" = "0" ]; then

# ── Step 1: Ensure Xcode Command Line Tools (provides git) ───────
# `xcode-select --install` shows a system popup. If the user clicks
# "Install" the install runs in the background; we poll for `git`.
# If they hit "Cancel" / dismiss it, the popup goes away and `git`
# never appears — so cap the wait at 15 minutes with a recovery hint
# instead of spinning forever.
if ! command -v git &> /dev/null; then
    info "Installing developer tools (this includes git)..."
    info "A popup will appear — click ${BOLD}Install${NC} and wait for it to finish."
    xcode-select --install 2>/dev/null || true

    waited=0
    until command -v git &> /dev/null; do
        sleep 5
        waited=$((waited + 5))
        if [ "$waited" -ge 900 ]; then
            fail "Timed out waiting for the Command Line Tools install (15 min)."
            fail "If you dismissed the popup, run this in another terminal:"
            fail "  ${BOLD}xcode-select --install${NC}"
            fail "Then re-run this installer once it finishes."
            exit 1
        fi
    done
    success "Developer tools installed"
else
    success "git is installed"
fi

# ── Step 2: Ensure Homebrew ──────────────────────────────────────
if ! command -v brew &> /dev/null; then
    info "Installing Homebrew (Mac package manager)..."
    info "You may be asked for your Mac password — that's normal."
    echo ""
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    if [ -f /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    success "Homebrew installed"
else
    success "Homebrew is installed"
fi

# ── Step 3: Ensure CLI tools (gh, fzf) ──────────────────────────
install_brew_pkg() {
    local cmd="$1" pkg="$2" label="$3"
    if command -v "$cmd" &> /dev/null; then
        success "${label} is installed"
    else
        info "Installing ${label}..."
        brew install "$pkg"
        success "${label} installed"
    fi
}

install_brew_pkg gh  gh      "GitHub CLI"
install_brew_pkg fzf fzf     "fzf (nice multi-select UI)"

# AWS CLI — install Amazon's official pkg, not brew's awscli. The brew
# bottle has a recurring breakage where a python@3.14 bump leaves
# pyexpat referencing a libexpat symbol the system dylib doesn't export
# (`_XML_SetAllocTrackerActivationThreshold`), so every `aws` invocation
# crashes at import time. The Apple-signed pkg from awscli.amazonaws.com
# bundles its own runtime and avoids the entanglement entirely.
ensure_aws_cli() {
    if command -v aws &>/dev/null && aws --version &>/dev/null; then
        success "AWS CLI is installed ($(aws --version 2>&1))"
        return 0
    fi

    if command -v aws &>/dev/null; then
        warn "AWS CLI is present but \`aws --version\` fails — replacing with the official pkg"
        if brew list awscli &>/dev/null; then
            info "Removing the broken Homebrew awscli..."
            brew uninstall awscli &>/dev/null || true
            hash -r 2>/dev/null || true
        fi
    else
        info "Installing AWS CLI (Amazon's official pkg)..."
    fi

    local tmpdir pkg
    tmpdir="$(mktemp -d)"
    pkg="${tmpdir}/AWSCLIV2.pkg"
    if ! curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "$pkg"; then
        rm -rf "$tmpdir"
        fail "Couldn't download AWS CLI installer from awscli.amazonaws.com"
        return 1
    fi
    info "Running AWS CLI installer (sudo — may prompt for your Mac password)..."
    if ! sudo installer -pkg "$pkg" -target / >/dev/null; then
        rm -rf "$tmpdir"
        fail "AWS CLI installation failed."
        return 1
    fi
    rm -rf "$tmpdir"

    # Official installer drops `aws` at /usr/local/bin/aws — make sure
    # it's on PATH for the rest of this script run.
    if ! command -v aws &>/dev/null && [ -x /usr/local/bin/aws ]; then
        export PATH="/usr/local/bin:${PATH}"
    fi
    hash -r 2>/dev/null || true
    if aws --version &>/dev/null; then
        success "AWS CLI installed ($(aws --version 2>&1))"
        return 0
    fi
    fail "AWS CLI installed but \`aws --version\` still fails — open a new terminal and rerun."
    return 1
}

# ── Validate Fido AWS access via SSO OIDC device flow ───────────
# We deliberately don't shell out to `aws` for validation. The brew
# bottle of awscli has a recurring breakage that takes the CLI down
# at import time, and the validation step needs to keep working even
# when the CLI is stale, broken, or not yet installed. AWS publishes
# the SSO OIDC API as plain HTTP — three documented endpoints are
# enough to get an access token:
#   POST oidc.<region>.amazonaws.com/client/register
#   POST oidc.<region>.amazonaws.com/device_authorization
#   POST oidc.<region>.amazonaws.com/token
# Then list-accounts on portal.sso.<region>.amazonaws.com proves the
# token actually has Fido AWS access (not just Auth0/SSO sign-in).
# We also write the access token to ~/.aws/sso/cache/ in the format
# the AWS CLI looks up, so the user's first `aws` command after this
# installer runs inherits the live session — no second login.

FIDO_SSO_START_URL="https://fido.awsapps.com/start/"
FIDO_SSO_REGION="eu-west-1"
FIDO_SSO_NAME="fido"
SSO_OIDC_URL="https://oidc.${FIDO_SSO_REGION}.amazonaws.com"
SSO_PORTAL_URL="https://portal.sso.${FIDO_SSO_REGION}.amazonaws.com"

# Read a top-level scalar field from a JSON string. Empty if missing.
json_field() {
    python3 -c '
import json, sys
try:    d = json.loads(sys.argv[1])
except: d = {}
v = d.get(sys.argv[2])
print("" if v is None else v)
' "$1" "$2" 2>/dev/null
}

# Sha1-hex the given string. Used to compute the AWS SSO cache filename.
sha1_hex() { printf '%s' "$1" | shasum -a 1 | awk '{print $1}'; }

# Print the cached access token if a valid (non-expired) Fido SSO
# session exists, else fail. The CLI may have written the cache under
# either the sso-session-name hash or the start-url hash, so we scan
# everything in the cache dir and match by startUrl.
sso_cached_token() {
    local cache_dir="${HOME}/.aws/sso/cache"
    [ -d "$cache_dir" ] || return 1
    python3 - "$cache_dir" "$FIDO_SSO_START_URL" <<'PY' 2>/dev/null
import json, os, sys
from datetime import datetime, timezone
cache_dir, start_url = sys.argv[1:3]
now = datetime.now(timezone.utc)
for f in sorted(os.listdir(cache_dir)):
    if not f.endswith('.json'): continue
    try:
        with open(os.path.join(cache_dir, f)) as fh: d = json.load(fh)
    except Exception:
        continue
    if d.get('startUrl') != start_url: continue
    expires = (d.get('expiresAt') or '').replace('Z', '+00:00')
    try:
        if datetime.fromisoformat(expires) > now and d.get('accessToken'):
            print(d['accessToken']); sys.exit(0)
    except Exception:
        continue
sys.exit(1)
PY
}

# Run the SSO OIDC device-authorization flow against Fido's IdC. On
# success, prints the access token, writes ~/.aws/sso/cache/<sha1>.json
# in AWS-CLI-compatible format, and returns 0.
sso_oidc_login() {
    local cache_dir="${HOME}/.aws/sso/cache"
    mkdir -p "$cache_dir"
    chmod 700 "${HOME}/.aws" "${HOME}/.aws/sso" "$cache_dir" 2>/dev/null || true

    info "Registering OIDC client..."
    local resp client_id client_secret
    if ! resp=$(curl -fsS -X POST "${SSO_OIDC_URL}/client/register" \
        -H 'Content-Type: application/json' \
        -d '{"clientName":"fido-installer","clientType":"public","scopes":["sso:account:access"]}'); then
        fail "OIDC client registration failed (network or AWS endpoint problem)"
        return 1
    fi
    client_id=$(json_field "$resp" clientId)
    client_secret=$(json_field "$resp" clientSecret)
    [ -n "$client_id" ] && [ -n "$client_secret" ] || { fail "OIDC register: bad response"; return 1; }

    info "Starting device authorization..."
    local body device_code verification_uri user_code interval expires_in
    body=$(printf '{"clientId":"%s","clientSecret":"%s","startUrl":"%s"}' \
        "$client_id" "$client_secret" "$FIDO_SSO_START_URL")
    if ! resp=$(curl -fsS -X POST "${SSO_OIDC_URL}/device_authorization" \
        -H 'Content-Type: application/json' -d "$body"); then
        fail "Device authorization request failed"
        return 1
    fi
    device_code=$(json_field "$resp" deviceCode)
    verification_uri=$(json_field "$resp" verificationUriComplete)
    user_code=$(json_field "$resp" userCode)
    interval=$(json_field "$resp" interval); interval="${interval:-5}"
    expires_in=$(json_field "$resp" expiresIn); expires_in="${expires_in:-600}"
    [ -n "$device_code" ] && [ -n "$verification_uri" ] || { fail "Bad device_authorization response"; return 1; }

    echo ""
    info "Opening Fido SSO in your browser..."
    info "Verification code: ${BOLD}${user_code}${NC}"
    info "If the browser doesn't open: ${BOLD}${verification_uri}${NC}"
    open "$verification_uri" 2>/dev/null || true
    echo ""
    info "Waiting for you to approve in the browser (up to $((expires_in/60))min)..."

    # Poll /token until the user finishes the browser flow. While the
    # user is still authenticating, /token returns HTTP 400 with
    # {"error":"authorization_pending"}; we don't use -f so we can read
    # the error JSON. AWS uses "slow_down" to ask us to back off.
    local token_body deadline now access_token expires_in_token err
    token_body=$(printf '{"clientId":"%s","clientSecret":"%s","grantType":"urn:ietf:params:oauth:grant-type:device_code","deviceCode":"%s"}' \
        "$client_id" "$client_secret" "$device_code")
    deadline=$(($(date +%s) + expires_in))
    while :; do
        now=$(date +%s)
        [ "$now" -ge "$deadline" ] && { fail "Timed out waiting for browser sign-in"; return 1; }
        resp=$(curl -sS -X POST "${SSO_OIDC_URL}/token" \
            -H 'Content-Type: application/json' -d "$token_body" 2>/dev/null || true)
        access_token=$(json_field "$resp" accessToken)
        if [ -n "$access_token" ]; then
            expires_in_token=$(json_field "$resp" expiresIn); expires_in_token="${expires_in_token:-28800}"
            break
        fi
        err=$(json_field "$resp" error)
        case "$err" in
            authorization_pending) ;;
            slow_down)             interval=$((interval + 5)) ;;
            '')                    warn "Empty response from /token — retrying" ;;
            *)                     fail "Sign-in failed (${err})"; return 1 ;;
        esac
        sleep "$interval"
    done

    # Write the cache file. Modern AWS CLI (v2.9+) uses sha1 of the
    # sso-session name; legacy CLI uses sha1 of the start URL. Write
    # under both so any CLI version finds it.
    local key1 key2 expires_at
    key1=$(sha1_hex "$FIDO_SSO_NAME")
    key2=$(sha1_hex "$FIDO_SSO_START_URL")
    expires_at=$(python3 -c "from datetime import datetime,timezone,timedelta;print((datetime.now(timezone.utc)+timedelta(seconds=int($expires_in_token))).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    if ! python3 - "$cache_dir" "$key1" "$key2" "$FIDO_SSO_START_URL" "$FIDO_SSO_REGION" "$access_token" "$expires_at" "$client_id" "$client_secret" <<'PY'; then
import json, os, sys, tempfile
cache_dir, key1, key2, start_url, region, token, expires_at, client_id, client_secret = sys.argv[1:10]
data = {
    'startUrl':     start_url,
    'region':       region,
    'accessToken':  token,
    'expiresAt':    expires_at,
    'clientId':     client_id,
    'clientSecret': client_secret,
}
for key in {key1, key2}:
    path = os.path.join(cache_dir, f'{key}.json')
    fd, tmp = tempfile.mkstemp(prefix='.cp.', dir=cache_dir)
    with os.fdopen(fd, 'w') as f: json.dump(data, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
PY
        fail "Couldn't write SSO cache file"
        return 1
    fi

    echo "$access_token"
    return 0
}

# Validate the token by listing accounts. Prints the account count on
# stdout, returns 0 if ≥1 account, 1 otherwise (or on HTTP failure).
sso_list_accounts() {
    local token="$1" resp
    resp=$(curl -fsS -H "x-amz-sso_bearer_token: ${token}" \
        "${SSO_PORTAL_URL}/federation/list-accounts?max_result=100") || return 1
    python3 -c '
import json, sys
n = len(json.load(sys.stdin).get("accountList", []))
print(n); sys.exit(0 if n > 0 else 1)
' <<<"$resp"
}

# Have the user pick an (account, role). On success prints
# "<account_id>\t<account_name>\t<role_name>" and returns 0.
sso_pick_account_role() {
    local token="$1" accounts roles lines role_lines picked role
    accounts=$(curl -fsS -H "x-amz-sso_bearer_token: ${token}" \
        "${SSO_PORTAL_URL}/federation/list-accounts?max_result=100") || return 1
    lines=$(python3 -c '
import json, sys
for a in json.load(sys.stdin).get("accountList", []):
    print(f"{a[\"accountId\"]}\t{a[\"accountName\"]}")
' <<<"$accounts")
    [ -n "$lines" ] || return 1

    if [ "$(printf '%s\n' "$lines" | grep -c .)" = "1" ]; then
        picked="$lines"
    else
        picked=$(printf '%s\n' "$lines" | fzf --height=50% --reverse --border --no-multi \
            --delimiter=$'\t' --with-nth=2 \
            --prompt="Pick an AWS account > " \
            --header="↑↓ to move, Enter to select")
    fi
    [ -z "$picked" ] && return 1

    local account_id account_name
    account_id=$(awk -F'\t' '{print $1}' <<<"$picked")
    account_name=$(awk -F'\t' '{print $2}' <<<"$picked")

    roles=$(curl -fsS -H "x-amz-sso_bearer_token: ${token}" \
        "${SSO_PORTAL_URL}/federation/list-account-roles?account_id=${account_id}&max_result=100") || return 1
    role_lines=$(python3 -c '
import json, sys
for r in json.load(sys.stdin).get("roleList", []):
    print(r["roleName"])
' <<<"$roles")
    [ -n "$role_lines" ] || return 1

    if [ "$(printf '%s\n' "$role_lines" | grep -c .)" = "1" ]; then
        role="$role_lines"
    else
        role=$(printf '%s\n' "$role_lines" | fzf --height=40% --reverse --border --no-multi \
            --prompt="Pick a role > " --header="↑↓ to move, Enter to select")
    fi
    [ -z "$role" ] && return 1

    printf '%s\t%s\t%s\n' "$account_id" "$account_name" "$role"
}

# Add/update [sso-session fido] + [profile fido] in ~/.aws/config.
# Uses configparser so existing sections (other profiles, sessions)
# are preserved verbatim.
sso_write_config() {
    local account_id="$1" role_name="$2"
    local cfg="${AWS_CONFIG_FILE:-${HOME}/.aws/config}"
    mkdir -p "$(dirname "$cfg")"
    chmod 700 "$(dirname "$cfg")" 2>/dev/null || true

    python3 - "$cfg" "$FIDO_SSO_NAME" "$FIDO_SSO_START_URL" "$FIDO_SSO_REGION" "$account_id" "$role_name" <<'PY' || return 1
import configparser, os, sys, tempfile
cfg_path, session_name, start_url, region, account_id, role_name = sys.argv[1:7]
parser = configparser.RawConfigParser()
parser.optionxform = str   # preserve key case
if os.path.exists(cfg_path):
    parser.read(cfg_path)

ssec, psec = f'sso-session {session_name}', f'profile {session_name}'
if not parser.has_section(ssec): parser.add_section(ssec)
parser.set(ssec, 'sso_start_url',           start_url)
parser.set(ssec, 'sso_region',              region)
parser.set(ssec, 'sso_registration_scopes', 'sso:account:access')

if not parser.has_section(psec): parser.add_section(psec)
parser.set(psec, 'sso_session',    session_name)
parser.set(psec, 'sso_account_id', account_id)
parser.set(psec, 'sso_role_name',  role_name)
parser.set(psec, 'region',         region)
parser.set(psec, 'output',         'json')

dirn = os.path.dirname(cfg_path) or '.'
fd, tmp = tempfile.mkstemp(prefix='.cp.', dir=dirn)
with os.fdopen(fd, 'w') as f: parser.write(f)
os.chmod(tmp, 0o600)
os.replace(tmp, cfg_path)
PY
}

# Top-level: ensure the user has working Fido SSO access. Cached
# session short-circuits; otherwise run the device flow and (for new
# users) write a default profile.
ensure_fido_sso() {
    local token n cfg picked account_id account_name role_name

    if token=$(sso_cached_token); then
        success "Active Fido SSO session found"
        export AWS_PROFILE="${AWS_PROFILE:-${FIDO_SSO_NAME}}"
        return 0
    fi

    [ -t 0 ] || {
        fail "No active Fido SSO session and stdin isn't a terminal — can't run the device flow."
        return 1
    }

    info "Starting Fido AWS SSO sign-in (no AWS CLI required)..."
    token=$(sso_oidc_login) || return 1

    info "Validating Fido AWS account access..."
    if ! n=$(sso_list_accounts "$token"); then
        fail "Sign-in succeeded but no AWS accounts are assigned to your Fido SSO user."
        return 1
    fi
    success "Fido SSO sign-in succeeded — ${BOLD}${n}${NC} account(s) available"

    cfg="${AWS_CONFIG_FILE:-${HOME}/.aws/config}"
    if [ ! -s "$cfg" ] || ! grep -q 'fido\.awsapps\.com/start' "$cfg" 2>/dev/null; then
        info "Picking a default AWS account+role for the ${BOLD}${FIDO_SSO_NAME}${NC} profile..."
        if picked=$(sso_pick_account_role "$token"); then
            account_id=$(awk -F'\t' '{print $1}' <<<"$picked")
            account_name=$(awk -F'\t' '{print $2}' <<<"$picked")
            role_name=$(awk -F'\t' '{print $3}' <<<"$picked")
            if sso_write_config "$account_id" "$role_name"; then
                success "Wrote profile ${BOLD}${FIDO_SSO_NAME}${NC} → ${account_name} (${role_name})"
                info "To make this your default, add ${BOLD}export AWS_PROFILE=${FIDO_SSO_NAME}${NC} to your shell rc."
            else
                warn "Couldn't write ~/.aws/config — run \`aws configure sso\` later if you want a CLI profile."
            fi
        else
            warn "Skipped account/role picker — run \`aws configure sso\` later if you want a CLI profile."
        fi
    else
        success "Fido SSO already in ~/.aws/config — refreshed session cache"
    fi

    export AWS_PROFILE="${AWS_PROFILE:-${FIDO_SSO_NAME}}"
    return 0
}

# Validate Fido SSO access first (cheap, no sudo). If the user has no
# Fido AWS account we can fail before prompting for a Mac password.
if ! ensure_fido_sso; then
    echo ""
    fail "Couldn't establish Fido AWS SSO access."
    echo ""
    info "${BOLD}Don't have a Fido AWS account yet?${NC}"
    info "  Ping ${BOLD}#eng-platform${NC} on Slack to request one."
    info "  Once it's created, re-run this installer."
    echo ""
    info "${BOLD}Browser sign-in failed or timed out?${NC}"
    info "  Re-run this installer and complete the SSO step in your browser."
    echo ""
    fail "Aborting installer — re-run once SSO sign-in succeeds."
    exit 1
fi

# Install the AWS CLI for downstream use. The OIDC cache we just wrote
# is in the same format the CLI expects, so the user's first `aws`
# command inherits the live session — no second login.
if ! ensure_aws_cli; then
    exit 1
fi

# AWS VPN Client — installed as a Homebrew cask, OR detected via /Applications
# (covers users who installed from the DMG / by hand instead of brew).
vpn_app_installed() {
    [ -d "/Applications/AWS VPN Client/AWS VPN Client.app" ] \
        || [ -d "/Applications/AWS VPN Client.app" ] \
        || brew list --cask aws-vpn-client &> /dev/null
}

# Detect "AWS VPN Client already has at least one profile imported".
# Profiles are tracked in ~/.config/AWSVPNClient/ConnectionProfiles (JSON);
# the per-profile OpenVPN config is under .../OpenVpnConfigs/<name>.
vpn_has_profile() {
    local f="${HOME}/.config/AWSVPNClient/ConnectionProfiles"
    [ -f "$f" ] && grep -q '"ProfileName"' "$f" 2>/dev/null
}

# Auto-import a Fido VPN .ovpn straight into AWS VPN Client's registry so
# the user doesn't have to do "File → Manage Profiles → Add Profile" by
# hand. Parses the AWS Client VPN endpoint host out of the `remote` line,
# drops the file at ~/.config/AWSVPNClient/OpenVpnConfigs/<name> (no
# extension — that's how AWS VPN Client stores them), and merges a new
# entry into ConnectionProfiles JSON. Idempotent: returns success if a
# profile of the same name is already registered.
# Returns 0 on success, 1 on parse/IO failure (caller should fall back
# to the manual GUI-import path).
import_vpn_profile() {
    local src="$1" name="${2:-Fido VPN}"
    local cfg_dir="${HOME}/.config/AWSVPNClient"
    local registry="$cfg_dir/ConnectionProfiles"
    local ovpn_dir="$cfg_dir/OpenVpnConfigs"

    [ -f "$src" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1

    # Find the AWS Client VPN endpoint hostname anywhere on a `remote` line
    # (covers commercial, GovCloud, and amazonaws.com.cn endpoints — and
    # any future `<random>.cvpn-endpoint-...` host shape).
    local remote_line endpoint region auth_type
    remote_line=$(grep -E '^[[:space:]]*remote[[:space:]]+\S*cvpn-endpoint-[a-z0-9]+\.\S*clientvpn\.[a-z0-9-]+\.amazonaws\.com(\.cn)?' "$src" | head -1 || true)
    [ -z "$remote_line" ] && return 1
    endpoint=$(echo "$remote_line" | grep -oE 'cvpn-endpoint-[a-z0-9]+' | head -1)
    region=$(echo   "$remote_line" | sed -E 's/.*\.clientvpn\.([a-z0-9-]+)\.amazonaws\.com.*/\1/')
    [ -n "$endpoint" ] || return 1

    # FederatedAuthType: 1 = SAML federated SSO, 0 = mutual cert auth.
    # Detect by looking for `auth-federate` directive (federated) or an
    # inline <cert>/<key> block / `auth-user-pass` (mutual). Default 1
    # because Fido uses SAML SSO.
    if grep -qE '^[[:space:]]*auth-federate' "$src"; then
        auth_type=1
    elif grep -qE '^[[:space:]]*<cert>|^[[:space:]]*auth-user-pass' "$src"; then
        auth_type=0
    else
        auth_type=1
    fi

    mkdir -p "$ovpn_dir"
    [ -f "$registry" ] || echo '{"Version":"1","LastSelectedProfileIndex":-1,"ConnectionProfiles":[]}' > "$registry"

    # Idempotency check — pass name via argv to avoid shell-injection
    # via a profile name containing quotes/$.
    if python3 - "$registry" "$name" <<'PY' 2>/dev/null
import json, sys
registry, name = sys.argv[1:3]
d = json.load(open(registry))
sys.exit(0 if any(p.get('ProfileName') == name for p in d.get('ConnectionProfiles', [])) else 1)
PY
    then
        return 0  # already registered — nothing to do
    fi

    local ovpn_dest="$ovpn_dir/$name"
    cp "$src" "$ovpn_dest" || return 1

    python3 - "$registry" "$name" "$ovpn_dest" "$endpoint" "$region" "$auth_type" <<'PY' || return 1
import json, os, sys, tempfile
registry, name, path, endpoint, region, auth_type = sys.argv[1:7]
with open(registry) as f: d = json.load(f)
d.setdefault('Version', '1'); d.setdefault('LastSelectedProfileIndex', -1)
d.setdefault('ConnectionProfiles', []).append({
    'ProfileName': name,
    'OvpnConfigFilePath': path,
    'CvpnEndpointId': endpoint,
    'CvpnEndpointRegion': region,
    'CompatibilityVersion': '2',
    'FederatedAuthType': int(auth_type),
})
fd, tmp = tempfile.mkstemp(prefix='.cp.', dir=os.path.dirname(registry))
with os.fdopen(fd, 'w') as f: json.dump(d, f)
os.replace(tmp, registry)
PY
}

if vpn_app_installed; then
    success "AWS VPN Client is installed"
else
    info "Installing AWS VPN Client (cask — may prompt for your Mac password)..."
    brew install --cask aws-vpn-client
    success "AWS VPN Client installed"
fi

# AWS VPN Client profile — let the user paste the .ovpn or point at a file.
# Saved to ~/Documents/fido-vpn.ovpn so the user can import it via the
# AWS VPN Client GUI (it has no CLI for profile add on macOS).
# Skip the whole prompt if a profile is already imported — the user is
# returning to update; nothing to do here.
echo ""
VPN_PROFILE_DIR="${HOME}/Documents"
VPN_PROFILE_PATH=""

if vpn_has_profile; then
    success "AWS VPN Client already has a profile configured — skipping setup"
else
    echo -e "${BOLD}── AWS VPN Client profile ──${NC}"
    echo ""
    info "AWS VPN Client needs a Fido profile (.ovpn file) to connect."

    if [ -t 0 ]; then
        vpn_choice=$(fzf_pick "AWS VPN profile" \
            "Paste config (.ovpn content) — read until Ctrl-D" \
            "Provide a path to a .ovpn file" \
            "Skip (set it up later in the AWS VPN Client UI)")

        # Stage the user's input at a temp file first; we'll auto-import it
        # into AWS VPN Client's registry below. ~/Documents copy is only
        # kept as a fallback if the auto-import fails.
        vpn_staged=""
        case "$vpn_choice" in
            Paste*)
                echo ""
                info "Paste the full .ovpn content, then press ${BOLD}Ctrl-D${NC} on a blank line:"
                vpn_content="$(cat)"
                if [ -n "$vpn_content" ]; then
                    vpn_staged="$(mktemp "${TMPDIR:-/tmp}/fido-vpn.XXXXXX.ovpn")"
                    printf '%s\n' "$vpn_content" > "$vpn_staged"
                else
                    warn "Empty paste — skipping"
                fi
                ;;
            Provide*)
                read -r -p "  Path to .ovpn: " vpn_src
                vpn_src="${vpn_src/#\~/$HOME}"
                if [ -f "$vpn_src" ]; then
                    vpn_staged="$vpn_src"
                else
                    warn "File not found: ${vpn_src} — skipping"
                fi
                ;;
            *) info "Skipped — set up the profile later via AWS VPN Client → File → Manage Profiles → Add Profile" ;;
        esac

        if [ -n "$vpn_staged" ]; then
            if import_vpn_profile "$vpn_staged" "Fido VPN"; then
                VPN_PROFILE_AUTO_IMPORTED=1
                VPN_PROFILE_PATH="${HOME}/.config/AWSVPNClient/OpenVpnConfigs/Fido VPN"
                success "Imported profile into AWS VPN Client (${BOLD}Fido VPN${NC})"
                info "If AWS VPN Client is already running, quit and reopen it to see the profile."
            else
                # Parse failed — keep the file in ~/Documents so the user
                # can still import it via the GUI.
                mkdir -p "$VPN_PROFILE_DIR"
                VPN_PROFILE_PATH="${VPN_PROFILE_DIR}/fido-vpn.ovpn"
                cp "$vpn_staged" "$VPN_PROFILE_PATH"
                warn "Couldn't auto-import — saved VPN config to ${BOLD}${VPN_PROFILE_PATH}${NC}"
                info "Add it manually via AWS VPN Client → File → Manage Profiles → Add Profile."
            fi
            # Clean up the staged paste-tmp (but not a user-supplied file).
            case "$vpn_choice" in Paste*) rm -f "$vpn_staged" ;; esac
        fi
    else
        warn "Non-interactive run — skipping VPN profile prompt."
        info "To set it up later, re-run interactively, or run:"
        info "  ${BOLD}bash <(curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-installer/main/install.sh)${NC}"
        info "Or import the .ovpn manually via AWS VPN Client → File → Manage Profiles → Add Profile."
    fi
fi
echo ""

# ── DNS resolvers + VPN connect ─────────────────────────────────
# Resolver files first (so internal hostnames route through the VPN
# nameservers once the tunnel is up), then launch AWS VPN Client and
# wait for connectivity.
echo -e "${BOLD}── DNS resolvers + VPN connect ──${NC}"
echo ""
configure_dns_resolvers
echo ""
launch_vpn_and_wait
echo ""

# Claude Code — installed via the official installer (not brew)
if command -v claude &> /dev/null; then
    success "Claude Code is installed"
else
    info "Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    # The installer usually drops `claude` in ~/.local/bin — make sure it's on PATH
    # for the rest of this script run.
    if ! command -v claude &> /dev/null && [ -x "${HOME}/.local/bin/claude" ]; then
        export PATH="${HOME}/.local/bin:${PATH}"
    fi
    if command -v claude &> /dev/null; then
        success "Claude Code installed"
    else
        warn "Claude Code installed but \`claude\` is not on PATH — open a new terminal after this script finishes"
    fi
fi

# ── Step 4: Ensure GitHub login ──────────────────────────────────
if ! gh auth status &> /dev/null; then
    echo ""
    info "You need to log in to GitHub."
    info "Follow the prompts below (select ${BOLD}HTTPS${NC} when asked)."
    echo ""
    gh auth login -h github.com -p https -w
fi

GITHUB_USER=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
success "Logged in to GitHub as ${BOLD}${GITHUB_USER}${NC}"
echo ""

# ── Step 5: Clone or update fido-agent ───────────────────────────
echo -e "${BOLD}── Setting up fido-agent ──${NC}"
echo ""

if [ -d "${AGENT_REPO_DIR}/.git" ]; then
    info "fido-agent already cloned — pulling latest..."
    cd "$AGENT_REPO_DIR"
    git fetch --all --prune --quiet 2>/dev/null
    DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    if [ -z "$DEFAULT_BRANCH" ]; then
        for branch in main master develop; do
            if git rev-parse --verify "origin/${branch}" &>/dev/null; then
                DEFAULT_BRANCH="$branch"
                break
            fi
        done
    fi
    if [ -n "$DEFAULT_BRANCH" ]; then
        git checkout "$DEFAULT_BRANCH" --quiet 2>/dev/null || true
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            warn "fido-agent — discarding uncommitted local changes ($(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') file(s))"
        fi
        git reset --hard "origin/${DEFAULT_BRANCH}" --quiet 2>/dev/null || true
    fi
    cd "$SCRIPT_DIR"
    success "fido-agent updated"
else
    if clone_with_spinner "fido-agent" "${ORG}/fido-agent" "$AGENT_REPO_DIR"; then
        success "fido-agent cloned"
    else
        fail "Could not clone fido-agent — check your access permissions"
        exit 1
    fi
fi
echo ""

# ── Step 6: Verify Roman folder inside fido-agent ──────────────
if [ ! -d "$ROMAN_DIR" ]; then
    fail "Expected roman/ directory inside fido-agent but it doesn't exist"
    exit 1
fi
success "Agents folder ready: ${BOLD}${ROMAN_DIR}${NC}"
echo ""

# ── Optional: clone the per-team repos into roman/ ──────────────
echo -e "${BOLD}── Per-team repositories ──${NC}"
echo ""
info "The installer can clone every Fido team repo (listed in roman-repos.txt)"
info "into ${BOLD}${ROMAN_DIR}${NC} so Claude can browse them locally. This can take a while."
echo ""

if [ -t 0 ]; then
    read -r -p "$(echo -e "  Clone all repositories now? [Y/n] ")" reply
    case "${reply:-Y}" in
        n|N|no|NO) SKIP_REPOS=1; info "Skipped — rerun the installer to clone them."; echo "" ;;
        *) ;;
    esac
fi

if [ "$SKIP_REPOS" = "0" ]; then

# ── Step 7: Load repo list from fido-agent ───────────────────────
#
# The list of repos to clone into roman/ lives inside the (private)
# fido-agent repo at `roman-repos.txt`. Format: one repo name per line,
# comments start with `#`, blank lines ignored. Keeping the list there
# (instead of hardcoding it here) avoids leaking internal repo names
# when this installer is published to a public URL.

REPO_LIST_FILE="${AGENT_REPO_DIR}/roman-repos.txt"
if [ ! -f "$REPO_LIST_FILE" ]; then
    fail "Repo list not found: ${REPO_LIST_FILE}"
    fail "Expected it to ship with fido-agent. Ask #eng-platform."
    exit 1
fi

REPOS=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"                                    # strip inline comments
    line="${line#"${line%%[![:space:]]*}"}"               # ltrim
    line="${line%"${line##*[![:space:]]}"}"               # rtrim
    [ -z "$line" ] && continue
    REPOS+=("$line")
done < "$REPO_LIST_FILE"

TOTAL=${#REPOS[@]}
if [ "$TOTAL" -eq 0 ]; then
    warn "Repo list is empty — nothing to clone"
fi
info "Active repositories: ${BOLD}${TOTAL}${NC} (from ${REPO_LIST_FILE#$HOME/~})"
echo ""

# ── Step 8: Clone missing repos into Roman/ ──────────────────────
CLONED=0
SKIPPED=0
CLONE_FAILED=0

echo -e "${BOLD}── Cloning new repositories ──${NC}"
echo ""

for repo in "${REPOS[@]}"; do
    if [ -d "${ROMAN_DIR}/${repo}/.git" ]; then
        SKIPPED=$((SKIPPED + 1))
    elif clone_with_spinner "${repo}" "${ORG}/${repo}" "${ROMAN_DIR}/${repo}"; then
        CLONED=$((CLONED + 1))
    else
        CLONE_FAILED=$((CLONE_FAILED + 1))
    fi
done

if [ "$CLONED" -gt 0 ]; then
    success "Cloned ${BOLD}${CLONED}${NC} new repositories"
fi
if [ "$SKIPPED" -gt 0 ]; then
    info "${SKIPPED} repositories already exist locally"
fi
if [ "$CLONE_FAILED" -gt 0 ]; then
    warn "${CLONE_FAILED} repositories failed to clone (you may not have access)"
fi
echo ""

# ── Step 9: Fetch updates in parallel ────────────────────────────
echo -e "${BOLD}── Downloading latest updates ──${NC}"
echo ""
info "Fetching updates for all repositories (this may take a minute)..."

FETCH_PIDS=()
for dir in "${ROMAN_DIR}"/*/; do
    if [ -d "${dir}/.git" ]; then
        (
            cd "$dir"
            git fetch --all --prune --quiet 2>/dev/null
            git remote set-head origin --auto > /dev/null 2>&1
        ) &
        FETCH_PIDS+=($!)
    fi
done

for pid in "${FETCH_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

success "All updates downloaded"
echo ""

# ── Step 10: Reset each repo to latest default branch ───────────
echo -e "${BOLD}── Updating to latest versions ──${NC}"
echo ""

UPDATED=0
UPDATE_FAILED=0

for dir in "${ROMAN_DIR}"/*/; do
    if [ -d "${dir}/.git" ]; then
        REPO_NAME=$(basename "$dir")

        cd "$dir"

        DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
        if [ -z "$DEFAULT_BRANCH" ]; then
            for branch in main master develop; do
                if git rev-parse --verify "origin/${branch}" &>/dev/null; then
                    DEFAULT_BRANCH="$branch"
                    break
                fi
            done
        fi

        if [ -z "$DEFAULT_BRANCH" ]; then
            cd "${ROMAN_DIR}"
            continue
        fi

        CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            warn "${REPO_NAME} — discarding uncommitted local changes (was: $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') file(s))"
            git reset --hard HEAD --quiet 2>/dev/null || true
            git clean -fd --quiet 2>/dev/null || true
        fi

        if [ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]; then
            git checkout "$DEFAULT_BRANCH" --quiet 2>/dev/null || {
                warn "${REPO_NAME} — could not switch to ${DEFAULT_BRANCH}"
                UPDATE_FAILED=$((UPDATE_FAILED + 1))
                cd "${ROMAN_DIR}"
                continue
            }
        fi

        if git reset --hard "origin/${DEFAULT_BRANCH}" --quiet 2>/dev/null; then
            UPDATED=$((UPDATED + 1))
        else
            warn "${REPO_NAME} — could not update"
            UPDATE_FAILED=$((UPDATE_FAILED + 1))
        fi

        cd "${ROMAN_DIR}"
    fi
done

echo ""

fi  # end of `if [ "$SKIP_REPOS" = "0" ]`

# ── Step 11: Set up Roman (Claude Code AI assistant) ─────────────
echo -e "${BOLD}── Setting up Agents (Claude Code workspace) ──${NC}"
echo ""

CLAUDE_DIR="${ROMAN_DIR}/.claude"
SKILLS_DIR="${ROMAN_DIR}/skills"

if [ -d "$SKILLS_DIR" ]; then
    mkdir -p "${CLAUDE_DIR}/hooks"

    # Symlink skills into .claude/skills
    if [ -L "${CLAUDE_DIR}/skills" ]; then
        rm "${CLAUDE_DIR}/skills"
        ln -s "$SKILLS_DIR" "${CLAUDE_DIR}/skills"
        success "Updated skills symlink"
    elif [ -d "${CLAUDE_DIR}/skills" ]; then
        info "skills/ directory already exists (not a symlink) — skipping"
    else
        ln -s "$SKILLS_DIR" "${CLAUDE_DIR}/skills"
        success "Linked skills into .claude/"
    fi

    # Copy hooks from skills if they exist
    if [ -d "${SKILLS_DIR}/_shared/hooks" ]; then
        cp -f "${SKILLS_DIR}/_shared/hooks/"* "${CLAUDE_DIR}/hooks/" 2>/dev/null || true
        chmod +x "${CLAUDE_DIR}/hooks/"*.sh 2>/dev/null || true
        success "Hooks updated"
    fi

    # Create settings.json if it doesn't exist
    if [ ! -f "${CLAUDE_DIR}/settings.json" ]; then
        cat > "${CLAUDE_DIR}/settings.json" << 'SETTINGS_EOF'
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
SETTINGS_EOF
        success "Created settings.json (read-only permissions)"
    else
        success "settings.json already exists"
    fi

    # CLAUDE.md is shipped at roman/CLAUDE.md by fido-agent
    if [ -f "${ROMAN_DIR}/CLAUDE.md" ]; then
        success "CLAUDE.md present"
    else
        warn "CLAUDE.md not found in ${ROMAN_DIR}"
    fi

    success "Agents are ready to use"
else
    warn "skills directory not found in fido-agent — Agents setup skipped"
fi
echo ""

# ── Step 12: Symlink ~/fido-money → roman/ ──────────────────────
# The user-facing entry point is `~/fido-money` so people don't have to
# remember the fido-agent/roman/ nesting. Idempotent: -n stops `ln` from
# descending into an existing symlink; -f replaces it.
FIDO_MONEY_LINK="${HOME}/fido-money"
if [ -e "$FIDO_MONEY_LINK" ] && [ ! -L "$FIDO_MONEY_LINK" ]; then
    warn "${FIDO_MONEY_LINK} already exists and isn't a symlink — leaving it alone"
else
    ln -sfn "$ROMAN_DIR" "$FIDO_MONEY_LINK"
    success "Symlinked ${BOLD}${FIDO_MONEY_LINK}${NC} → ${ROMAN_DIR}"
fi
echo ""

# ── Step 13: Clone Fido Skills repo to a user-chosen location ───
echo -e "${BOLD}── Fido Skills (Claude Code skills) ──${NC}"
echo ""
info "FidoMoney/skills is a private repo of Claude Code skills curated by Fido."
echo ""

DEFAULT_SKILLS_DIR="${HOME}/.claude/skills/fido"
COLOCATED_SKILLS_DIR="${HOME}/fido-money/skills-repo"

if [ -t 0 ]; then
    skills_choice=$(fzf_pick "Where to clone FidoMoney/skills" \
        "${DEFAULT_SKILLS_DIR}  (user-scope, picked up by every Claude session)" \
        "${COLOCATED_SKILLS_DIR}  (colocated with the install)" \
        "Custom path" \
        "Skip")
    case "$skills_choice" in
        "${DEFAULT_SKILLS_DIR}"*)   SKILLS_REPO_DIR="$DEFAULT_SKILLS_DIR" ;;
        "${COLOCATED_SKILLS_DIR}"*) SKILLS_REPO_DIR="$COLOCATED_SKILLS_DIR" ;;
        "Custom path")              read -r -p "  Path: " SKILLS_REPO_DIR ;;
        "Skip"|"")                  SKILLS_REPO_DIR="" ;;
        *)                          SKILLS_REPO_DIR="$DEFAULT_SKILLS_DIR" ;;
    esac
else
    SKILLS_REPO_DIR="$DEFAULT_SKILLS_DIR"
fi

if [ -n "$SKILLS_REPO_DIR" ]; then
    SKILLS_REPO_DIR="${SKILLS_REPO_DIR/#\~/$HOME}"   # tilde expansion
    if [ -d "${SKILLS_REPO_DIR}/.git" ]; then
        info "Skills repo already at ${SKILLS_REPO_DIR} — pulling latest..."
        (cd "$SKILLS_REPO_DIR" && git fetch --all --prune --quiet && git reset --hard origin/main --quiet) \
            && success "Skills updated" \
            || warn "Skills update failed"
    else
        mkdir -p "$(dirname "$SKILLS_REPO_DIR")"
        if clone_with_spinner "skills" "${ORG}/skills" "$SKILLS_REPO_DIR"; then
            success "Skills cloned to ${BOLD}${SKILLS_REPO_DIR}${NC}"
        else
            warn "Could not clone ${ORG}/skills — check your access permissions"
        fi
    fi
else
    info "Skipped skills clone"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────
echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   Setup Complete${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
echo ""
if [ "$SKIP_REPOS" = "1" ]; then
    info "Per-team repos: skipped"
else
    [ "$CLONED" -gt 0 ]       && success "New repos cloned:   ${CLONED}"
    success "Repos up to date:   ${UPDATED}"
    [ "$UPDATE_FAILED" -gt 0 ] && warn "Need attention:     ${UPDATE_FAILED}"
    [ "$CLONE_FAILED" -gt 0 ]  && warn "Clone failures:     ${CLONE_FAILED} (check access permissions)"
fi
echo ""
success "Agents are at:     ${BOLD}${FIDO_MONEY_LINK}${NC}"
[ -n "$SKILLS_REPO_DIR" ] && [ -d "$SKILLS_REPO_DIR" ] && success "Fido Skills:       ${BOLD}${SKILLS_REPO_DIR}${NC}"
echo ""

fi  # end of `if [ "$MCP_ONLY" = "0" ]`

# ═════════════════════════════════════════════════════════════════
#  MCP installer (inline)
# ═════════════════════════════════════════════════════════════════

# DNS constants live at the top of the script (used by both the early
# VPN-connect step and the MCP installer below).

# Source of truth for the MCP catalog — derived at runtime from
# https://github.com/FidoMoney/platform-team-gitops/tree/main/applications/mcp-servers
# so adding a new MCP cluster-side automatically lights it up here on
# the next install. Skips `mcp-shared-resources` (infra, not an MCP);
# expands services with sub-overlays under overlays/global/ (e.g. argocd
# → argocd-nonprod, argocd-prod) into one catalog entry per overlay.
MCP_GITOPS_REPO="FidoMoney/platform-team-gitops"
MCP_GITOPS_PATH="applications/mcp-servers"
MCP_CATALOG=()

build_mcp_catalog() {
    local tree services service sub_overlays sub
    tree=$(gh api "repos/${MCP_GITOPS_REPO}/git/trees/main?recursive=1" \
        --jq '.tree[] | select(.type == "tree") | .path' 2>/dev/null) || return 1
    [ -z "$tree" ] && return 1

    services=$(echo "$tree" \
        | grep -E "^${MCP_GITOPS_PATH}/[^/]+$" \
        | sed "s|${MCP_GITOPS_PATH}/||" \
        | grep -v '^mcp-shared-resources$' \
        | sort -u || true)
    [ -z "$services" ] && return 1

    while IFS= read -r service; do
        [ -z "$service" ] && continue
        sub_overlays=$(echo "$tree" \
            | grep -E "^${MCP_GITOPS_PATH}/${service}/overlays/global/[^/]+$" \
            | sed "s|${MCP_GITOPS_PATH}/${service}/overlays/global/||" \
            | sort -u || true)
        if [ -n "$sub_overlays" ]; then
            while IFS= read -r sub; do
                [ -z "$sub" ] && continue
                MCP_CATALOG+=("${service}-${sub}")
            done <<< "$sub_overlays"
        else
            MCP_CATALOG+=("$service")
        fi
    done <<< "$services"
    return 0
}

if [ "$SKIP_MCP" = "1" ]; then
    info "Skipping MCP install (--skip-mcp / SKIP_MCP_INSTALL=1)"
    echo ""
    if [ "$MCP_ONLY" = "0" ]; then
        echo -e "  ${BOLD}To use agents${NC}:  ${BOLD}cd ~/fido-money && claude${NC}"
        echo ""
    fi
    exit 0
fi

echo -e "${BOLD}── Fido MCP servers (Datadog, Snowflake, Slack, Mambu, ...) ──${NC}"
echo ""
info "MCP servers let Claude Code query Fido's data from the cluster."
info "You'll need: ${BOLD}VPN ON${NC} and the ${BOLD}Fido MCP bearer token${NC} (ask in #eng-platform)."
echo ""

# Prompt y/N only in full-setup interactive mode (skip in --mcp-only).
if [ "$MCP_ONLY" = "0" ] && [ -t 0 ]; then
    read -r -p "$(echo -e "  Install MCP servers now? [Y/n] ")" reply
    case "${reply:-Y}" in
        y|Y|yes|YES) ;;
        *) info "Skipped. Run later:  ${BOLD}bash <(curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-installer/main/install.sh) --mcp-only${NC}"; echo ""; exit 0 ;;
    esac
fi

# Require claude CLI.
if ! command -v claude &> /dev/null; then
    if [ -x "${HOME}/.local/bin/claude" ]; then
        export PATH="${HOME}/.local/bin:${PATH}"
    fi
fi
if ! command -v claude &> /dev/null; then
    fail "\`claude\` CLI not found on PATH. Open a new terminal and rerun."
    exit 1
fi

# Require gh CLI authenticated — needed to read the catalog from the
# private platform-team-gitops repo. In full setup we already did this;
# --mcp-only re-runs need it too.
if ! command -v gh &> /dev/null; then
    fail "\`gh\` CLI not found. Run the full installer first (without --mcp-only)."
    exit 1
fi
if ! gh auth status &> /dev/null; then
    fail "\`gh\` not authenticated. Run \`gh auth login\` then rerun."
    exit 1
fi

# Build the catalog from gitops. Done before token prompt so a missing-
# access failure errors out before the user goes hunting for their token.
info "Reading MCP catalog from ${MCP_GITOPS_REPO}/${MCP_GITOPS_PATH}..."
if ! build_mcp_catalog || [ "${#MCP_CATALOG[@]}" -eq 0 ]; then
    fail "Could not read MCP catalog from ${MCP_GITOPS_REPO}."
    fail "Check that your GitHub account has access to that repo."
    exit 1
fi
success "Found ${BOLD}${#MCP_CATALOG[@]}${NC} MCP servers"
echo ""

# Quick "install all" shortcut. Skipped when --all/--only already pinned a
# selection or when stdin isn't interactive.
if [ "$MCP_MODE" = "interactive" ] && [ -t 0 ]; then
    echo -e "${BOLD}Quick option:${NC} install ${BOLD}all ${#MCP_CATALOG[@]}${NC} MCP servers in one shot."
    echo -e "${DIM}  • Press ${NC}${BOLD}Y${NC}${DIM} (or Enter) to install everything${NC}"
    echo -e "${DIM}  • Press ${NC}${BOLD}N${NC}${DIM} to pick servers from a list${NC}"
    read -r -p "  Install all? [Y/n] " reply
    case "${reply:-Y}" in
        n|N|no|NO) ;;
        *) MCP_MODE="all"; info "Installing all MCPs..." ;;
    esac
    echo ""
fi

# Token — flag / env / prompt.
if [ -z "$MCP_TOKEN" ]; then
    if [ -t 0 ]; then
        info "Paste the Fido MCP bearer token (input hidden):"
        read -r -s -p "  > " MCP_TOKEN
        echo ""
    fi
fi
if [ -z "$MCP_TOKEN" ]; then
    fail "No token. Pass --token <T> or set FIDO_MCP_TOKEN."
    exit 1
fi
success "Token loaded (length=${#MCP_TOKEN})"
echo ""

# DNS resolvers — full setup already wrote these right after VPN install,
# but call again here so --mcp-only re-runs on a fresh box still work.
# configure_dns_resolvers is idempotent.
configure_dns_resolvers
if [ "$MCP_SKIP_DNS" = "0" ]; then
    if vpn_is_up; then
        success "VPN/DNS reachable"
    else
        warn "Cannot resolve superset-mcp.${MCP_DNS_DOMAIN} — is the VPN on? Continuing anyway."
    fi
fi

# Selection.
total=${#MCP_CATALOG[@]}

select_with_fzf() {
    printf '%s\n' "${MCP_CATALOG[@]}" | fzf --multi --height=60% --reverse --border \
        --header="TAB to toggle, Enter to confirm, Ctrl-C to cancel  [${total} servers]" \
        --prompt="Install which MCPs? "
}

select_with_numbered_menu() {
    local -a sel=(); local i
    for ((i = 0; i < total; i++)); do sel[i]=0; done

    while true; do
        echo ""
        echo -e "${BOLD}Available MCP servers${NC}"
        echo "────────────────────────────────────────────"
        for ((i = 0; i < total; i++)); do
            if [ "${sel[i]}" = "1" ]; then mark="${GREEN}[x]${NC}"; else mark="[ ]"; fi
            printf "  %b %2d) %s\n" "$mark" "$((i + 1))" "${MCP_CATALOG[i]}"
        done
        echo ""
        echo "  numbers/ranges to toggle (e.g. '1 3 5-8'), 'a'=all, 'n'=none, 'i'=invert, Enter=install, 'q'=quit"
        read -r -p "> " input
        [ -z "$input" ] && break

        case "$input" in
            q|Q) exit 0 ;;
            a|A) for ((i = 0; i < total; i++)); do sel[i]=1; done ;;
            n|N) for ((i = 0; i < total; i++)); do sel[i]=0; done ;;
            i|I) for ((i = 0; i < total; i++)); do sel[i]=$((1 - sel[i])); done ;;
            *)
                for tok in $input; do
                    if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                        start=${BASH_REMATCH[1]}; end=${BASH_REMATCH[2]}
                        ((start < 1))   && start=1
                        ((end > total)) && end=$total
                        for ((n = start; n <= end; n++)); do sel[n - 1]=$((1 - sel[n - 1])); done
                    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
                        ((tok >= 1 && tok <= total)) && sel[tok - 1]=$((1 - sel[tok - 1]))
                    fi
                done
                ;;
        esac
    done

    for ((i = 0; i < total; i++)); do
        [ "${sel[i]}" = "1" ] && echo "${MCP_CATALOG[i]}"
    done
}

case "$MCP_MODE" in
    all)   SELECTED="$(printf '%s\n' "${MCP_CATALOG[@]}")" ;;
    only)  SELECTED="$(echo "$MCP_ONLY_LIST" | tr ',' '\n' | sed '/^[[:space:]]*$/d')" ;;
    *)     if command -v fzf &>/dev/null; then
               SELECTED="$(select_with_fzf)"
           else
               SELECTED="$(select_with_numbered_menu)"
           fi ;;
esac

if [ -z "$SELECTED" ]; then
    warn "Nothing selected — exiting"
    exit 0
fi

echo ""
echo -e "${BOLD}Will install:${NC}"
echo "$SELECTED" | sed 's/^/  • /'
echo ""

# Install loop — cache `claude mcp list` once (it's slow).
info "Checking already-registered MCPs..."
EXISTING_MCPS="$(claude mcp list 2>/dev/null | grep -E '^[a-zA-Z0-9_-]+:' || true)"

is_known() {
    local name="$1" entry
    for entry in "${MCP_CATALOG[@]}"; do
        [ "$entry" = "$name" ] && return 0
    done
    return 1
}

install_one() {
    local name="$1"
    if ! is_known "$name"; then fail "Unknown MCP '$name'"; return 1; fi

    local url="http://${name}-mcp.${MCP_DNS_DOMAIN}/mcp"

    if grep -qE "^${name}: " <<< "$EXISTING_MCPS"; then
        # Already configured — ask per-server whether to overwrite or keep.
        # Read from /dev/tty: the enclosing `while ... <<< "$SELECTED"` loop
        # makes our stdin the piped MCP list, so `read` without /dev/tty would
        # never see the user. Truly non-interactive runs (no tty) default to
        # "keep" to avoid silently clobbering someone's existing config.
        local reply decision="no"
        # `[ -r /dev/tty ]` isn't enough on macOS — the device file is always
        # readable, but opening it fails ("Device not configured") when no
        # controlling terminal is attached (e.g. CI, nohup, this Claude shell).
        # Probe with a real open in a subshell instead.
        if (exec </dev/tty) 2>/dev/null; then
            read -r -p "$(echo -e "  ${YELLOW}?${NC} ${BOLD}${name}${NC} already configured. Overwrite? [y/N] ")" reply </dev/tty
            case "${reply:-}" in
                y|Y|yes|YES) decision="yes" ;;
                *)           decision="no"  ;;
            esac
        fi

        if [ "$decision" = "no" ]; then
            info "kept existing $name"
            MCP_KEPT=$((MCP_KEPT + 1))
            return 0
        fi

        info "overwriting $name"
        if [ "$MCP_DRY_RUN" = "0" ]; then
            claude mcp remove --scope user "$name" >/dev/null 2>&1 || true
        fi
    fi

    if [ "$MCP_DRY_RUN" = "1" ]; then
        echo "  [dry-run] claude mcp add $name $url --transport http --scope user -H 'Authorization: Bearer ***'"
        MCP_INSTALLED=$((MCP_INSTALLED + 1))
        return 0
    fi

    if claude mcp add "$name" "$url" --transport http --scope user \
         -H "Authorization: Bearer ${MCP_TOKEN}" >/dev/null 2>&1; then
        success "installed $name"
        MCP_INSTALLED=$((MCP_INSTALLED + 1))
    else
        fail "failed to install $name"
        return 1
    fi
}

MCP_INSTALLED=0
MCP_KEPT=0
mcp_fail=0
while IFS= read -r name; do
    [ -z "$name" ] && continue
    install_one "$name" || mcp_fail=$((mcp_fail + 1))
done <<< "$SELECTED"

echo ""
if [ "$mcp_fail" = "0" ]; then
    success "MCP install complete — ${BOLD}${MCP_INSTALLED}${NC} installed, ${BOLD}${MCP_KEPT}${NC} kept as-is"
    info "Verify with: ${BOLD}claude mcp list${NC}"
else
    warn "MCP install finished with errors — ${MCP_INSTALLED} installed, ${MCP_KEPT} kept, ${mcp_fail} failed"
fi

echo ""
if [ "$MCP_ONLY" = "0" ]; then
    echo -e "  ${BOLD}To use agents${NC}:  ${BOLD}cd ~/fido-money && claude${NC}"
    echo -e "  ${BOLD}To rerun MCP install later${NC}:  ${BOLD}bash <(curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-installer/main/install.sh) --mcp-only${NC}"
    echo ""
fi
echo -e "${BOLD}${PINK}  🎉  All set — welcome to Fido!${NC}"
echo ""
