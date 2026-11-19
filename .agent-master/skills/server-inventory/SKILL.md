---
name: server-inventory
description: Scan the user's servers (Tailscale, LAN, OCI VMs) over read-only SSH and report or update the private GitHub repo pratiks360/server-inventory, which records what runs where (ports, services, code repos). Use when the user says "scan my servers", "update the server inventory", "what is running on <server>", or asks to re-audit a machine.
argument-hint: "[scan|update] [server ... | all]"
---

Arguments: `$ARGUMENTS`

Parse as `<mode> <targets>`:
- mode `scan` (default if omitted): audit and show a diff against the repo. **Change nothing** (no commit, no push).
- mode `update`: audit, edit the inventory, commit and push. Show the diff first and ask once before pushing if anything was removed or any entry looks unexpected.
- targets: server names from the table, or `all` (default).

## Servers (SSH)
| Name | Connect with | Notes |
|---|---|---|
| oci (mumbai-oci) | `ssh oci` (ubuntu, `~/.ssh/oci.key`) | OCI VM |
| free-e2-micro-mum-2 | `ssh free-e2-micro-mum-2` | OCI VM, sslip.io host |
| dxb-pi | `ssh dxb-pi-ts` (root) or `ssh dxb-pi` on LAN | Tailscale + LAN 192.168.88.222 |
| thane-pi | `ssh root@100.81.64.8` | Tailscale, India |
| kandivali-pi | `ssh root@100.102.38.81` | Tailscale |
| nvirginia-ec2-limited, pune-pi, desktops | not reachable | report "not audited", never guess |

If the repo's README lists servers not in this table, try them the same way (tailscale status shows names/IPs).
Use `-o BatchMode=yes -o ConnectTimeout=10` and run servers in parallel. Only the audit script runs on servers: `ssh <host> 'bash -s' < ~/.claude/skills/server-inventory/audit.sh`. Do not install, edit or restart anything on a server while scanning.

## Steps
1. Clone fresh: `gh repo clone pratiks360/server-inventory <tmpdir>` (use a temp/scratch dir; set `core.autocrlf false`; set git user.email to the user's email).
2. Audit each target; compare with `README.md` (server table + application index) and `servers/<name>.md`.
3. For each app found, find its code repo, in this order: (a) the checkout's `git remote` URL; (b) a name match in `gh repo list pratiks360 --limit 200` (also check the directory/service/package name and, if unsure, the repo's README); (c) upstream software (Prowlarr, rclone, Caddy, Unbound ...) -> record as upstream, no repo. If it is the user's own code and **no repo exists**:
   - `scan`: only report it as "no repo yet".
   - `update`: pull the code off the server, make a **private** repo for it, push, and link it in the inventory. Small glue (cron/systemd helpers, scripts) goes into `pratiks360/server-glue-scripts` under `<server>/`; a real app/project gets its own repo `pratiks360/<app-name>` (kebab-case, ask only if the name is ambiguous).
   - Before pushing anything copied from a server: copy only source/config templates (never `node_modules`, venvs, logs, data dirs, `.git` of someone else), then grep the copy for secrets (tokens, passwords, `BEGIN .* PRIVATE KEY`, `ocid1.*key`, `AAE`/bot-token shapes, `.env` files). Replace any hit with an env var or placeholder and list it for the user to rotate. If it cannot be cleaned confidently, do **not** push; report it instead.
   - If the checkout has a remote but local commits/changes that are not pushed, report that rather than pushing to someone else's repo.
4. Report: new apps, apps gone, port changes, services failing, unmatched apps, and servers not reachable.
5. `update` only: edit `README.md` and the server page(s), keep the "Last audited" date, commit, push.

## Never commit secrets
Do not copy or print: `*.env`, WireGuard/PiVPN confs, SSH/OCI keys (`*.pem`, `*.key`), bot tokens, passwords, `store_*.toml`, rclone configs. Record only that such a file exists and where. If a script has a hardcoded secret, replace it with an env var in the copy and tell the user to rotate it.

## Writing the files
- Python on Windows defaults to cp1252: when editing with Python use `encoding='utf-8'` and prefer plain ASCII punctuation.
- Keep `README.md` as the one place with the server table (name, type, address, OS, link) and the application index (app, server, port, code repo).
- Per-server page: addresses, SSH method, services (unit, what, port, path/code link), cron, notes.
