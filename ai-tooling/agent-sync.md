---
title: Claude Code + OpenCode Sync via Git Master (Skills, MCP, Plugins, RTK)
summary: One master in this repo keeps skills, MCP servers and Claude plugins identical across Claude Code and OpenCode on every Windows machine; a single PowerShell script pulls, pushes and resolves conflicts.
emoji: 🔄
---

# Claude Code + OpenCode Sync via Git Master

Switching between Claude Code and OpenCode, and between machines, means skills and MCP servers drift. This setup keeps a **master** in this repo (`.agent-master/`) and a script that merges each machine into it and back. Windows, PowerShell 5.1+, `git`, authenticated GitHub access (for example `gh auth login`).

> **Note:** this repo is public. The master contains full copies of your skills and MCP definitions. MCP `env`/`headers` values are replaced with `<REDACTED>`, and skills that look like they contain a secret are refused, but you are still publishing skill contents. Skills with restrictive licences should not go in here.

---

## 🗂️ 1. What is stored

```text
.agent-master/
├── skills/<name>/...   # user-owned skills (full copies)
├── mcp.json            # MCP servers, neutral format, secrets redacted
└── plugins.json        # Claude Code plugins + marketplace sources
ai-tooling/agent-sync/
├── agent-sync.ps1      # the sync logic
└── agent-sync.cmd      # menu / wrapper
```

- **User-owned skills** = folders in `C:\Users\<you>\.claude\skills\` and `C:\Users\<you>\.config\opencode\skills\` that are not copies of plugin skills.
- **Plugin skills** (superpowers and so on) are not stored: the plugin list is, and each machine installs the plugins itself with `claude plugin install`. The script then copies plugin skills into OpenCode's skills folder.
- OpenCode reads `C:\Users\<you>\.claude\skills\` natively, so pulled skills go there once and both tools see them.

---

## 🚀 2. First run on a new machine

```powershell
git clone https://github.com/pratiks360/tech-wiki "$HOME\.agent-sync\tech-wiki"
cd "$HOME\.agent-sync\tech-wiki\ai-tooling\agent-sync"
.\agent-sync.cmd Status      # see what would happen, changes nothing
.\agent-sync.cmd Sync        # do it
```

Restart Claude Code and OpenCode afterwards. The script finds the clone it lives in; otherwise it clones to `C:\Users\<you>\.agent-sync\tech-wiki`.

---

## ▶️ 3. Everyday use

```powershell
agent-sync.cmd                      # menu
agent-sync.cmd Sync                 # pull master, apply missing, push new local items
agent-sync.cmd Pull                 # master -> this machine only
agent-sync.cmd Push                 # this machine -> master only
agent-sync.cmd Status               # differences only
agent-sync.cmd Sync -Prefer Local   # conflicts: this machine wins
agent-sync.cmd Sync -Prefer Repo    # conflicts: master wins
agent-sync.cmd Sync -DryRun
```

Typical flow: add a skill or MCP server on machine A, run **Sync** (it lands in the master), then run **Sync** on machine B.

---

## 🧠 4. Rules

- **Nothing is deleted**, ever. To remove an item everywhere, delete it from `.agent-master/` in git *and* from each machine by hand, otherwise Sync re-adds it.
- Same name, different content = **conflict**. It is listed and left alone until you choose `-Prefer Local` or `-Prefer Repo`.
- MCP servers are installed into **both** tools: Claude via `claude mcp add-json -s user`, OpenCode by editing `opencode.jsonc` (a `.bak` is saved; comments in that file are not preserved).
- Neutral MCP format in `mcp.json`: `{"type":"local","command":[...],"env":{}}` or `{"type":"remote","url":"...","headers":{}}`.
- A redacted secret is filled from an **environment variable of the same name** on the pulled machine. If it is not set, that server is skipped with a warning; set the variable and run Sync again.
- RTK: if `rtk` is on PATH and the OpenCode plugin is missing, `rtk init -g --opencode --auto-patch` is run.

---

## ⚠️ 5. Gotchas

- Machine-specific paths in an MCP command (for example `C:\tools\x.exe`) are synced as-is and fail on a machine without them.
- `uvx`-based servers (for example `colab-mcp`) need uv: `winget install astral-sh.uv`.
- Remote servers need sign-in per machine: `opencode mcp auth <name>`.
- claude.ai cloud connectors (Gmail, Supabase and the like) belong to the claude.ai account and are not synced.
- Skills are not slash commands in OpenCode; ask for them by name or check `opencode debug skill`.
- `.agent-master/.gitattributes` sets `* -text` so Windows line-ending conversion does not make identical skills look different.
- Tested on one machine only: dry runs, and earlier a dummy skill/MCP round trip. The multi-machine pull path (installing a master-only skill, MCP server or plugin) is exercised by the first run on the second machine.

---

## 🔧 6. Upgrading RTK

Latest release: <https://github.com/rtk-ai/rtk/releases/latest>. Download `rtk-x86_64-pc-windows-msvc.zip`, verify its SHA256 against `checksums.txt`, back up the old `rtk.exe`, replace it, then:

```powershell
rtk --version
rtk init -g --show     # expect: OpenCode: plugin installed
```
