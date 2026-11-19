---
name: sync-check
description: Use only when the user asks to verify that agent-sync works. Replies that the sync-check skill is loaded on this machine and tool. Harmless test skill.
---

# sync-check

Test skill used to verify skills sync between Claude Code, OpenCode and machines via agent-sync.

When invoked, reply with exactly one line: `sync-check skill loaded`, plus the name of the tool you are running in (Claude Code or OpenCode). Do nothing else.
