#!/bin/bash
#
# Fido Agents Setup & Update Script
# -----------------------------------
# One-shot installer: dev tools, Claude Code, Fido agents, AWS VPN, and
# all cluster MCP servers. Idempotent — safe to rerun for updates.
#
# Quickstart (new employees):
#   bash <(curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-agent-installer/main/install.sh)
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

info()    { echo -e "${BLUE}ℹ${NC}  $1"; }
success() { echo -e "${GREEN}✔${NC}  $1"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $1"; }
fail()    { echo -e "${RED}✖${NC}  $1"; }

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
    if [ -n "${VPN_PROFILE_PATH:-}" ] && [ -f "$VPN_PROFILE_PATH" ]; then
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

# Initialize counters so they're safe when --mcp-only skips the repo section.
CLONED=0; SKIPPED=0; CLONE_FAILED=0; UPDATED=0; UPDATE_FAILED=0

# Skip the entire onboarding flow in --mcp-only mode.
if [ "$MCP_ONLY" = "0" ]; then

# ── Step 1: Ensure Xcode Command Line Tools (provides git) ───────
if ! command -v git &> /dev/null; then
    info "Installing developer tools (this includes git)..."
    info "A popup may appear — click ${BOLD}Install${NC} and wait for it to finish."
    xcode-select --install 2>/dev/null || true

    until command -v git &> /dev/null; do
        sleep 5
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

# ── Step 3: Ensure CLI tools (gh, fzf, awscli) ──────────────────
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
install_brew_pkg aws awscli  "AWS CLI"

# AWS VPN Client — installed as a Homebrew cask (handles arch under the hood).
if brew list --cask aws-vpn-client &> /dev/null; then
    success "AWS VPN Client is installed"
else
    info "Installing AWS VPN Client (cask — may prompt for your Mac password)..."
    brew install --cask aws-vpn-client
    success "AWS VPN Client installed"
fi

# AWS VPN Client profile — let the user paste the .ovpn or point at a file.
# Saved to ~/Documents/fido-vpn.ovpn so the user can import it via the
# AWS VPN Client GUI (it has no CLI for profile add on macOS).
echo ""
echo -e "${BOLD}── AWS VPN Client profile ──${NC}"
echo ""
info "AWS VPN Client needs a Fido profile (.ovpn file) to connect."
VPN_PROFILE_DIR="${HOME}/Documents"
VPN_PROFILE_PATH=""

if [ -t 0 ]; then
    vpn_choice=$(fzf_pick "AWS VPN profile" \
        "Paste config (.ovpn content) — read until Ctrl-D" \
        "Provide a path to a .ovpn file" \
        "Skip (set it up later in the AWS VPN Client UI)")

    case "$vpn_choice" in
        Paste*)
            echo ""
            info "Paste the full .ovpn content, then press ${BOLD}Ctrl-D${NC} on a blank line:"
            vpn_content="$(cat)"
            if [ -n "$vpn_content" ]; then
                mkdir -p "$VPN_PROFILE_DIR"
                VPN_PROFILE_PATH="${VPN_PROFILE_DIR}/fido-vpn.ovpn"
                printf '%s\n' "$vpn_content" > "$VPN_PROFILE_PATH"
                success "Saved VPN config to ${BOLD}${VPN_PROFILE_PATH}${NC}"
            else
                warn "Empty paste — skipping"
            fi
            ;;
        Provide*)
            read -r -p "  Path to .ovpn: " vpn_src
            vpn_src="${vpn_src/#\~/$HOME}"
            if [ -f "$vpn_src" ]; then
                mkdir -p "$VPN_PROFILE_DIR"
                VPN_PROFILE_PATH="${VPN_PROFILE_DIR}/fido-vpn.ovpn"
                cp "$vpn_src" "$VPN_PROFILE_PATH"
                success "Copied VPN config to ${BOLD}${VPN_PROFILE_PATH}${NC}"
            else
                warn "File not found: ${vpn_src} — skipping"
            fi
            ;;
        *) info "Skipped — set up the profile later via AWS VPN Client → File → Manage Profiles → Add Profile" ;;
    esac

    if [ -n "$VPN_PROFILE_PATH" ]; then
        info "Profile saved at ${BOLD}${VPN_PROFILE_PATH}${NC} — I'll open AWS VPN Client next so you can add and connect it."
    fi
else
    info "Non-interactive run — skipping VPN profile prompt"
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
        git reset --hard "origin/${DEFAULT_BRANCH}" --quiet 2>/dev/null || true
    fi
    cd "$SCRIPT_DIR"
    success "fido-agent updated"
else
    echo -n "  Cloning fido-agent... "
    if gh repo clone "${ORG}/fido-agent" "$AGENT_REPO_DIR" -- --quiet 2>/dev/null; then
        echo -e "${GREEN}done${NC}"
        success "fido-agent cloned"
    else
        echo -e "${RED}failed${NC}"
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
    else
        echo -n "  Cloning ${repo}... "
        if gh repo clone "${ORG}/${repo}" "${ROMAN_DIR}/${repo}" -- --quiet 2>/dev/null; then
            echo -e "${GREEN}done${NC}"
            CLONED=$((CLONED + 1))
        else
            echo -e "${RED}failed${NC}"
            CLONE_FAILED=$((CLONE_FAILED + 1))
        fi
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
        if gh repo clone "${ORG}/skills" "$SKILLS_REPO_DIR" -- --quiet 2>/dev/null; then
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
[ "$CLONED" -gt 0 ]       && success "New repos cloned:   ${CLONED}"
success "Repos up to date:   ${UPDATED}"
[ "$UPDATE_FAILED" -gt 0 ] && warn "Need attention:     ${UPDATE_FAILED}"
[ "$CLONE_FAILED" -gt 0 ]  && warn "Clone failures:     ${CLONE_FAILED} (check access permissions)"
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
    read -r -p "$(echo -e "  Install MCP servers now? [y/N] ")" reply
    case "${reply:-}" in
        y|Y|yes|YES) ;;
        *) info "Skipped. Run later:  ${BOLD}bash <(curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-agent-installer/main/install.sh) --mcp-only${NC}"; echo ""; exit 0 ;;
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
    echo -e "  ${BOLD}To rerun MCP install later${NC}:  ${BOLD}bash <(curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-agent-installer/main/install.sh) --mcp-only${NC}"
    echo ""
fi
echo -e "${BOLD}${PINK}  🎉  All set — welcome to Fido!${NC}"
echo ""
