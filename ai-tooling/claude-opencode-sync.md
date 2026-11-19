---
title: Sync Claude Code and OpenCode (Skills, MCP, RTK)
summary: One PowerShell script that mirrors skills and MCP servers between Claude Code and OpenCode on Windows, in either direction, plus RTK setup and a prompt to rebuild it on another machine.
emoji: 🔄
---

# Sync Claude Code and OpenCode (Skills, MCP, RTK)

If you switch between Claude Code and OpenCode, skills and MCP servers you set up in one are missing in the other. This guide ships a script that copies them across in either direction, never deletes anything, and a prompt for rebuilding it on a new machine. Windows only (PowerShell 5.1+).

---

## 📦 1. What is in the folder

| File | Purpose |
|---|---|
| [`claude-opencode-sync/sync-agents.ps1`](claude-opencode-sync/sync-agents.ps1) | The sync logic |
| [`claude-opencode-sync/sync-agents.cmd`](claude-opencode-sync/sync-agents.cmd) | Wrapper: interactive menu, or pass a direction |

Put both files in `C:\Users\<you>\.claude\scripts\`.

---

## ▶️ 2. Run it

```powershell
# Interactive menu
C:\Users\<you>\.claude\scripts\sync-agents.cmd

# Direct
sync-agents.cmd ToOpenCode      # Claude   -> OpenCode
sync-agents.cmd ToClaude        # OpenCode -> Claude
sync-agents.cmd Both            # union of both
sync-agents.cmd Both -DryRun    # show changes, touch nothing
sync-agents.cmd ToOpenCode -Force   # overwrite entries that already exist
```

Restart Claude Code / OpenCode afterwards; both read skills and MCP config at startup.

---

## 🧠 3. What it actually does

**Skills**
- OpenCode already reads `C:\Users\<you>\.claude\skills\*` natively, so those are *not* copied.
- Plugin skills (from `installed_plugins.json` install paths and `%APPDATA%\Claude\rpm\*\*\plugin_*\skills\*`) are copied into `C:\Users\<you>\.config\opencode\skills\`.
- OpenCode to Claude copies skills Claude does not know about into `C:\Users\<you>\.claude\skills\`.

**MCP servers** are read from `.claude.json` (top level and every project entry) and from each plugin's `.mcp.json`.

| Claude | OpenCode (`mcp` key in `opencode.jsonc`) |
|---|---|
| stdio `{command, args, env}` | `{"type":"local","command":[command,...args],"environment":env,"enabled":true}` |
| http / sse `{url, headers}` | `{"type":"remote","url":...,"headers":...,"enabled":true}` |

Going back, OpenCode entries are added with `claude mcp add-json -s user`, so `.claude.json` is never edited directly while Claude is running.

**RTK**: if `rtk` is on PATH and `C:\Users\<you>\.config\opencode\plugins\rtk.ts` is missing, it runs `rtk init -g --opencode --auto-patch`.

> **Crucial:** `opencode.jsonc` is rewritten as plain JSON, so comments in it are lost. A `.bak` is saved first.

> **Crucial:** passing JSON from PowerShell 5.1 to a native exe strips quotes. The script escapes `"` as `\"` before calling `claude mcp add-json`.

---

## ⚠️ 4. Gotchas

- **Skills are not slash commands in OpenCode.** The agent loads them through its `skill` tool; ask for one by name ("use the ui-ux-pro-max skill ...") or check with `opencode debug skill`.
- **Missing runtime = failed MCP.** `colab-mcp` runs through `uvx`; without uv (`winget install astral-sh.uv`) it shows `Connection closed`.
- **Remote servers need sign-in:** `opencode mcp auth <name>`.
- **claude.ai cloud connectors** (Gmail, Supabase, Sheets, ...) authenticate through your claude.ai account and cannot be copied. Re-add them in OpenCode as remote servers by hand if needed.
- Existing target entries are skipped unless `-Force`. Nothing is ever deleted.
- Tested: dry run both ways, plus a dummy skill and dummy stdio MCP round trip in both directions. Not tested: remote servers with headers, and macOS/Linux.

---

## 🛠️ 5. Upgrading RTK

Latest release: <https://github.com/rtk-ai/rtk/releases/latest>. On Windows download `rtk-x86_64-pc-windows-msvc.zip`, verify its SHA256 against `checksums.txt`, back up the old `rtk.exe`, replace it, then check:

```powershell
rtk --version
rtk init -g --show     # expect: OpenCode: plugin installed
```

---

## 🖥️ 6. Prompt for a new machine

Paste this into Claude Code on the other machine (or just copy the two script files over):

````markdown
Sync my Claude Code and OpenCode setups on this Windows machine. Both are installed. Do not delete anything; back up before editing; show me a dry run before changing anything.

Paths (Windows, PowerShell 5.1 compatible, no Linux paths):
- Claude user skills: %USERPROFILE%\.claude\skills\<name>\SKILL.md
- Claude plugin skills: installPath\skills\* for each entry in %USERPROFILE%\.claude\plugins\installed_plugins.json, plus %APPDATA%\Claude\rpm\*\*\plugin_*\skills\*
- Claude MCP servers: "mcpServers" in %USERPROFILE%\.claude.json (top level and under each entry of "projects"), plus .mcp.json inside each installed plugin
- OpenCode config: %USERPROFILE%\.config\opencode\opencode.jsonc (or opencode.json; may contain comments), MCP under the "mcp" key
- OpenCode skills: %USERPROFILE%\.config\opencode\skills\<name>\SKILL.md (OpenCode also reads %USERPROFILE%\.claude\skills natively, so do not copy those)

Do this:
1. Write a script %USERPROFILE%\.claude\scripts\sync-agents.ps1 with parameters -Direction ToOpenCode|ToClaude|Both (default Both), -DryRun, -Force, plus a sync-agents.cmd wrapper (interactive menu when run with no arguments).
2. ToOpenCode: copy plugin skills (not ~/.claude/skills ones) into the OpenCode skills folder; convert MCP servers: Claude stdio {command,args,env} -> OpenCode {"type":"local","command":[command,...args],"environment":env,"enabled":true}; Claude http/sse {url,headers} -> {"type":"remote","url":...,"headers":...,"enabled":true}. Run `rtk init -g --opencode --auto-patch` if rtk is on PATH and %USERPROFILE%\.config\opencode\plugins\rtk.ts is missing.
3. ToClaude: copy OpenCode skills not already known to Claude into %USERPROFILE%\.claude\skills; add OpenCode MCP servers missing from Claude with `claude mcp add-json -s user <name> <json>` (escape double quotes as \" when passing JSON from PowerShell 5.1), converting the other way ("local" -> stdio with command/args/env, "remote" -> http).
4. Skip entries that already exist on the target unless -Force. Back up opencode.jsonc to .bak before editing. Strip JSONC comments and trailing commas safely (string-aware) when parsing.
5. Test it: -DryRun both ways, then a round trip with a dummy skill and dummy MCP server, then remove the dummies.
6. Check RTK: `rtk --version` against the latest release at https://github.com/rtk-ai/rtk/releases/latest; if older, download rtk-x86_64-pc-windows-msvc.zip, verify its SHA256 against checksums.txt, back up the old rtk.exe, replace it. Then confirm `rtk init -g --show` reports "OpenCode: plugin installed".
7. Tell me what was synced, what failed (for example an MCP server whose runtime such as uvx or npx is missing), and which MCP servers need sign-in (`opencode mcp auth <name>`). claude.ai cloud connectors (Gmail, Supabase and similar) cannot be copied; just list them.
````
