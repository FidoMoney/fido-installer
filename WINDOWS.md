# Fido MCP setup on Windows

Short guide for the data team. Mirrors the macOS flow — same VPN, same DNS
zones, same MCP catalog — but uses PowerShell + `winget` + Windows NRPT
for DNS instead of Homebrew + `/etc/resolver/`.

## What you need

1. Windows 10/11 (any modern build with `winget` — install **App Installer**
   from the Microsoft Store if `winget --version` errors)
2. Your **Fido GitHub account** (member of `FidoMoney` org)
3. **AWS VPN** `.ovpn` profile (paste it during setup or have the file path ready)
4. The **Fido MCP bearer token** — ask in `#eng-platform`
5. An **elevated PowerShell** (Run as Administrator) — only required for the
   DNS step. The script will still run without admin and warn you, which is
   fine if your VPN already pushes the right DNS suffixes.

## One-shot install

Open PowerShell **as Administrator**, then:

```powershell
iex (irm https://raw.githubusercontent.com/FidoMoney/fido-agent-installer/main/install.ps1)
```

That single line:

- installs Git, GitHub CLI, fzf, AWS CLI, Node.js, AWS VPN Client, Claude Code
- imports your `.ovpn` profile to `~\Documents\fido-vpn.ovpn`
- writes NRPT rules so `*.global-private.fido.money` and `*.private.fido.money`
  resolve over the VPN tunnel
- launches AWS VPN Client and waits up to 60s for the tunnel to come up
- logs you in to GitHub (`gh auth login` → browser flow)
- clones `fido-agent` and every Roman repo into `~\fido-agent\`
- creates a `~\fido-money` junction as the entry point
- prompts for your MCP bearer token (input hidden) and registers every MCP
  server from the cluster catalog

When it finishes:

```powershell
cd ~\fido-money
claude
```

## Common variations

| What you want                       | Command                                                                  |
| ----------------------------------- | ------------------------------------------------------------------------ |
| Skip the MCP step                   | `iex (irm …/install.ps1) -SkipMcp`                                       |
| Reinstall just the MCPs             | `.\install.ps1 -McpOnly`                                                 |
| Install **all** MCPs, no prompt     | `.\install.ps1 -McpOnly -All`                                            |
| Install a specific subset           | `.\install.ps1 -McpOnly -Only "datadog,snowflake,slack"`                 |
| Pass the token non-interactively    | `$env:FIDO_MCP_TOKEN = "xxx"; .\install.ps1`                             |
| Install somewhere other than `$HOME`| `$env:FIDO_INSTALL_DIR = "C:\work"; .\install.ps1`                       |
| Dry run                             | `.\install.ps1 -McpOnly -DryRun`                                         |

> Piped form (`iex (irm …)`) doesn't accept positional flags. Download
> `install.ps1` first and run it with the parameters above.

## What lives where (after install)

```
~\fido-money              -> junction to ~\fido-agent\roman   ← cd here, run `claude`
~\fido-agent\             ← cloned `fido-agent` repo
~\fido-agent\roman\       ← Roman + every repo it indexes
~\.claude\skills\fido     ← FidoMoney/skills clone (default; you pick the path)
~\Documents\fido-vpn.ovpn ← imported AWS VPN profile (if you provided one)
```

## DNS resolvers (NRPT)

The script adds two NRPT (Name Resolution Policy Table) rules — the Windows
equivalent of macOS `/etc/resolver/*`:

| Namespace                       | Nameserver | Used by                                            |
| ------------------------------- | ---------- | -------------------------------------------------- |
| `.global-private.fido.money`    | `10.3.0.2` | MCP servers (`*-mcp.global-private.fido.money`)    |
| `.private.fido.money`           | `10.30.0.2`| Internal data services that MCPs talk to           |

Inspect with:

```powershell
Get-DnsClientNrptRule | ? Namespace -match 'fido.money'
```

Skip with `-SkipDns` if your VPN already pushes the right resolvers.

## Verifying

After the script finishes:

```powershell
# 1. VPN + DNS — should return an IP
Resolve-DnsName superset-mcp.global-private.fido.money

# 2. Claude finds the MCPs
claude mcp list

# 3. Run the agent
cd ~\fido-money
claude
```

Inside Claude, `/mcp` lists active servers and connection state.

## Troubleshooting

**`winget` not found** — install **App Installer** from the Microsoft Store,
then close and reopen PowerShell.

**`Resolve-DnsName` doesn't resolve internal hosts** — VPN isn't fully up, or
NRPT rules weren't written (you ran without admin). Re-run the script in an
**elevated** PowerShell.

**`claude` not found after install** — open a fresh PowerShell so PATH picks
up Node's global bin (or `~\.local\bin` if the official installer was used).

**`gh` clone fails** — your GitHub account must be a member of the `FidoMoney`
org. Ping `#eng-platform`.

**MCP install fails / hangs** — VPN. Test:
`Resolve-DnsName superset-mcp.global-private.fido.money`. Also confirm the
token is correct (`#eng-platform`).

**ExecutionPolicy error** — you can run the downloaded file with:
`powershell -ExecutionPolicy Bypass -File .\install.ps1`.

**AWS VPN Client doesn't see my profile** — open the app, `File → Manage
Profiles → Add Profile`, point at `~\Documents\fido-vpn.ovpn`.

## Security notes

- The MCP bearer token comes from `-Token`, `$env:FIDO_MCP_TOKEN`, or a hidden
  prompt — never logged or written to disk.
- The token is passed to `claude mcp add` as an `Authorization` header — it is
  briefly visible to other processes on the box (`Get-Process` arg list) while
  that command runs. Claude CLI limitation.
- The `.ovpn` profile lands in `~\Documents\fido-vpn.ovpn`.
- The script is downloaded over HTTPS from GitHub. Inspect first if you'd
  rather: `irm https://raw.githubusercontent.com/FidoMoney/fido-agent-installer/main/install.ps1 | more`.

## Reporting issues

File an issue in this repo or post in `#eng-platform`.
