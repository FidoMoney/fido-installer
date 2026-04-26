# Fido Agent Installer

One-shot installer for Fido engineering tooling. Run it on a fresh Mac and you get:

- Xcode Command Line Tools (`git`)
- Homebrew, GitHub CLI (`gh`), `fzf`
- [Claude Code](https://claude.ai/code)
- The `fido-agent` repo and all the repos Roman knows about
- Cluster MCP servers (Datadog, Snowflake, Slack, Mambu, Superset, ...)

The script is idempotent — re-run it any time to update.

## Quickstart

You'll need:

1. A Mac (Apple Silicon or Intel)
2. Your **Fido GitHub account**
3. **VPN connected** (required for MCP DNS resolution)
4. The **Fido MCP bearer token** — ask in `#eng-platform`

Then run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-agent-installer/main/install.sh)
```

The script will walk you through:

- Installing developer tools and Claude Code
- Logging in to GitHub (`gh auth login` opens a browser)
- Cloning `fido-agent` into `~/fido-agent/`
- Cloning every repo Roman uses into `~/fido-agent/roman/`
- Setting up Roman's `.claude/` config
- Picking which MCP servers to install (TAB to multi-select)
- Pasting your MCP token (input is hidden)

When it finishes:

```bash
cd ~/fido-agent/roman && claude
```

## Common variations

| What you want                        | Command                                                                                                   |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| Skip the MCP step entirely           | `bash <(curl -fsSL …/install.sh) --skip-mcp`                                                              |
| Reinstall just the MCPs              | `bash <(curl -fsSL …/install.sh) --mcp-only`                                                              |
| Install **all** MCPs, no prompt      | `bash <(curl -fsSL …/install.sh) --mcp-only --all`                                                        |
| Install a specific subset            | `bash <(curl -fsSL …/install.sh) --mcp-only --only datadog,snowflake,slack`                               |
| Pass the token non-interactively     | `FIDO_MCP_TOKEN=xxx bash <(curl -fsSL …/install.sh)`                                                      |
| Install somewhere other than `$HOME` | `FIDO_INSTALL_DIR=~/work bash <(curl -fsSL …/install.sh)`                                                 |
| Dry run (show what it would do)      | `bash <(curl -fsSL …/install.sh) --mcp-only --dry-run`                                                    |

(Replace `…/install.sh` with the full URL — `https://raw.githubusercontent.com/FidoMoney/fido-agent-installer/main/install.sh`.)

## What lives where

After install:

```
~/fido-agent/                ← Fido's agent platform
~/fido-agent/roman/          ← Roman + skills + every repo it indexes
~/fido-agent/roman/.claude/  ← Claude Code config (read-only permissions by default)
```

Override the install root with `FIDO_INSTALL_DIR=...`.

## Security notes

- The MCP bearer token is read from `--token`, `FIDO_MCP_TOKEN`, or a hidden prompt — never logged or written to disk by this script.
- The token is passed to `claude mcp add` via an `Authorization` header argument, which means it is briefly visible in `ps aux` while that command runs. This is a Claude CLI limitation, not specific to this installer.
- This script is downloaded over HTTPS from GitHub. Inspect it first if you'd rather: `curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-agent-installer/main/install.sh | less`.
- The script writes `/etc/resolver/global-private.fido.money` (requires `sudo`) so `*-mcp.global-private.fido.money` resolves over VPN. Skip with `--skip-dns` if you've already configured DNS another way.

## Troubleshooting

**"`claude` not found" after install** — open a new terminal so PATH picks up `~/.local/bin`.

**MCP install fails / hangs** — check VPN. Test with `dscacheutil -q host -a name superset-mcp.global-private.fido.money`.

**"Could not clone fido-agent"** — your GitHub account needs membership in the `FidoMoney` org. Ping `#eng-platform`.

**"No token"** — the prompt is skipped if stdin isn't a TTY. Use `FIDO_MCP_TOKEN=xxx bash <(curl ...)` or `--token <T>`.

## Reporting issues

File an issue in this repo or post in `#eng-platform`.
