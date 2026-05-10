# Fido Installer

One-shot installer for Fido engineering tooling. Run it on a fresh Mac and you get:

- Xcode Command Line Tools (`git`)
- Homebrew, GitHub CLI (`gh`), `fzf`, AWS CLI
- AWS VPN Client (and an optional profile import)
- [Claude Code](https://claude.ai/code)
- The `fido-agent` repo and every repo Roman knows about (cloned under `~/fido-agent/`, surfaced as `~/fido-money`)
- The `FidoMoney/skills` repo, cloned to a path of your choice
- Cluster MCP servers (Datadog, Snowflake, Slack, Mambu, Superset, ...)

The script is idempotent — re-run it any time to update.

## Quickstart

You'll need:

1. A Mac (Apple Silicon or Intel)
2. Your **Fido GitHub account**
3. **VPN connected** (required for MCP DNS resolution)
4. The **Fido MCP bearer token** — ask in `#eng-platform`
5. (Optional) Your **AWS VPN `.ovpn` profile** ready to paste or as a file

Then run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-installer/main/install.sh)
```

The script will walk you through:

- Installing developer tools, AWS CLI, AWS VPN Client, and Claude Code
- Importing your AWS VPN profile (paste it or point at a file — saved to `~/Documents/fido-vpn.ovpn`)
- Writing the `/etc/resolver/*.fido.money` files (sudo) and launching AWS VPN Client to connect
- Logging in to GitHub (`gh auth login` opens a browser)
- Cloning `fido-agent` + every agent repo into `~/fido-agent/`, plus a `~/fido-money` symlink as the entry point
- Setting up the agents' `.claude/` config
- Cloning the Fido `skills` repo — you pick where via an `fzf` picker
- Picking which MCP servers to install — there's a one-tap "install all" option, otherwise multi-select with TAB
- Pasting your MCP bearer token (input is hidden)

When it finishes:

```bash
cd ~/fido-money && claude
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
| Re-run without nuking local edits    | `bash <(curl -fsSL …/install.sh) --keep-local`                                                            |
| Unattended (CI / scripted)           | `FIDO_MCP_TOKEN=xxx bash <(curl -fsSL …/install.sh) -y`                                                   |

> **`--keep-local`**: by default, the per-team-repo update step does
> `git reset --hard` + `git clean -fd` on every repo, **discarding any
> uncommitted edits** with a warning. That's right for a fresh laptop;
> it's brutal for re-runs as the documented update path. With
> `--keep-local` (env: `FIDO_KEEP_LOCAL=1`) the installer still runs
> `git fetch` everywhere, but **skips** the reset on any repo with a
> dirty working tree — `git status` will show you you're behind origin
> so you can rebase manually. The summary surfaces a "Kept (local edits)"
> count.

> **`-y` / `--yes`**: auto-accepts `[Y/n]` prompts. Two prompts
> deliberately do **not** auto-accept under `--yes`: (1) the per-MCP
> "overwrite existing" prompt — keeps the existing entry, mirroring the
> non-tty default, so `--yes` can't silently rewrite a working config
> with a wrong token; (2) the hidden token prompt — `--yes` runs
> unattended, so the token must come from `--token` / `FIDO_MCP_TOKEN`
> (the script fails fast if neither is set). The VPN-profile prompt is
> also skipped under `--yes` (no safe default for "paste your config").

(Replace `…/install.sh` with the full URL — `https://raw.githubusercontent.com/FidoMoney/fido-installer/main/install.sh`.)

## What lives where

After install:

```
~/fido-money         → symlink to ~/fido-agent/roman   ← cd here, run `claude`
~/fido-agent/        ← cloned `fido-agent` repo
~/fido-agent/roman/  ← Roman + every repo it indexes
<chosen-path>        ← FidoMoney/skills clone (default: ~/.claude/skills/fido)
~/Documents/fido-vpn.ovpn  ← imported AWS VPN profile (if you provided one)
```

Override the install root with `FIDO_INSTALL_DIR=...`.

## DNS resolvers (written with `sudo`)

The script writes two macOS resolver files so internal Fido hostnames resolve over the VPN:

| File                                       | Nameserver | Used by                                |
| ------------------------------------------ | ---------- | -------------------------------------- |
| `/etc/resolver/global-private.fido.money`  | `10.3.0.2` | MCP servers (`*-mcp.global-private.fido.money`) |
| `/etc/resolver/private.fido.money`         | `10.30.0.2`| Internal data services that MCPs talk to       |

Skip with `--skip-dns` if you've configured DNS another way.

## Security notes

- The MCP bearer token is read from `--token`, `FIDO_MCP_TOKEN`, or a hidden prompt — never logged or written to disk by this script.
- The token is passed to `claude mcp add` via an `Authorization` header argument, so it is briefly visible in `ps aux` while that command runs. Claude CLI limitation, not specific to this installer.
- The VPN profile you paste/import is written to `~/Documents/fido-vpn.ovpn` (mode `0644` — readable only by your user).
- This script is downloaded over HTTPS from GitHub. Inspect it first if you'd rather: `curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-installer/main/install.sh | less`.

### Third-party installers we pipe to bash

This installer is itself piped to `bash`, and it in turn pipes a few
upstream installers to `bash`/`installer(1)`. None are pinned by hash —
we trust them by reference, not by checksum. Be aware of:

| Source | What it does | How we invoke it |
| --- | --- | --- |
| `raw.githubusercontent.com/Homebrew/install/HEAD/install.sh` | Installs Homebrew | `curl … \| bash` |
| `claude.ai/install.sh` | Installs the Claude Code CLI | `curl … \| bash` |
| `awscli.amazonaws.com/AWSCLIV2.pkg` | Apple-signed AWS CLI v2 pkg | `sudo installer -pkg` |

The trust chain therefore relies on (a) HTTPS to the upstream domain and
(b) GitHub's release / Amazon's code signing on each side. If your
threat model needs stronger guarantees, download `install.sh`, audit it,
and run it from a local copy.

## Troubleshooting

**"`claude` not found" after install** — open a new terminal so PATH picks up `~/.local/bin`.

**MCP install fails / hangs** — check VPN. Test with `dscacheutil -q host -a name superset-mcp.global-private.fido.money`.

**"Could not clone fido-agent"** — your GitHub account needs membership in the `FidoMoney` org. Ping `#eng-platform`.

**"No token"** — the prompt is skipped if stdin isn't a TTY. Use `FIDO_MCP_TOKEN=xxx bash <(curl ...)` or `--token <T>`.

**AWS VPN Client doesn't see my profile** — open the app, go to `File → Manage Profiles → Add Profile`, and pick `~/Documents/fido-vpn.ovpn`.

## Reporting issues

File an issue in this repo or post in `#eng-platform`.
