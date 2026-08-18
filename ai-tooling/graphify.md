---
title: Codebase Mapping with Graphify
summary: Wiring Graphify's AST knowledge graph into a VS Code + Antigravity workflow — git hook automation, cross-editor config, prompt blueprints, and Claude Code / Codex integration.
emoji: 🧩
---

# Developer Guide: Codebase Mapping with Graphify

This guide outlines the standard operating procedure for integrating **Graphify** into a dual-development workflow combining **VS Code** and **Google Antigravity**. By maintaining a localized Abstract Syntax Tree (AST) knowledge graph, this setup optimizes AI agent performance, slashes LLM token consumption, and provides real-time architectural visualization.

---

## 🛠️ 1. Global & Project Installation

Run these setup commands once per machine or project environment using a standard system terminal (CMD/PowerShell on Windows, or terminal on macOS/Linux).

### Step 1: Initialize the Graph
Navigate to your project root folder and generate the baseline knowledge graph and cache layers.
```bash
# Explicitly target the current directory to index code structures
graphify update .
```
*This command generates a `graphify-out/` directory containing your index files (`graph.json`, `graph.html`, and `GRAPH_REPORT.md`) alongside an internal `cache/` folder.*

### Step 2: Clean Your Git History
To prevent your temporary cache states and heavy build files from cluttering remote repositories, append Graphify outputs to your `.gitignore` file immediately.

```text
# .gitignore
graphify-out/cache/
graphify-out/graph.json
graphify-out/graph.html
```

*Note: You may choose to leave `GRAPH_REPORT.md` tracked if you want incoming remote developers or cloud-based agents to have instant access to the codebase map without rebuilding it.*

---

## 🪝 2. Automating Updates via Git Hooks

Manually running terminal updates causes drift between your active code and your AI context. Enable the native Git hook to automatically sync changes on every commit.

```bash
# Register the hook with the local .git configuration
graphify hook install
```

### How It Works Under the Hood
* Whenever a `git commit` is executed, the hook runs a background delta-scan.
* It uses the `graphify-out/cache/` folder to check file hashes, processing *only* the modified files.
* Your graph maps are rewritten in milliseconds before the commit finalizes, providing zero-maintenance synchronization.

---

## 🖥️ 3. Cross-Editor Workspace Configurations

Configure both development environments to point to the shared `graphify-out/` outputs.

### Environment A: VS Code (The Visual Anchor)
Use VS Code for manual writing, granular debugging, and macro architectural visualization.
1. Open the project folder in VS Code (`code .`).
2. Open the extensions panel and install the **Graphify** extension.
3. Open `Ctrl+Shift+P` (Command Palette) and run: `Graphify: Load Existing Graph`.
4. Right-click `graphify-out/graph.html` and open it via a **Live Server** or browser preview to view an interactive call-graph.

### Environment B: Google Antigravity (The AI Engine)
Use Antigravity to let autonomous AI agents plan, refactor, and generate structural code modifications.
1. Open your project folder in Google Antigravity.
2. Open the AI Agent chat panel.
3. Explicitly seed the graph into the agent context by typing:
   ```text
   /context graphify-out/GRAPH_REPORT.md
   ```

---

## 🤖 4. AI Prompting Engineering Blueprint

When interacting with Antigravity, do not ask the AI to blindly scan directories. Leverage the graph structure explicitly using these optimized prompt templates:

### Prompt 1: Impact Analysis (Before major refactors)
> "Analyze `graphify-out/GRAPH_REPORT.md`. If I modify the function signature of `[FunctionName]` in `[FileName]`, what upstream dependents and modules will be impacted? List them in order of risk."

### Prompt 2: Architectural Discovery
> "Based on the local graph structure, identify any circular dependencies or tightly coupled module clusters within the current architecture."

### Prompt 3: Context-Aware Code Generation
> "Using the import structures defined in `graphify-out/graph.json`, generate a new service module for `[Feature Name]`. Ensure it complies with our existing architectural patterns and uses current utility exports."

---

## 📈 5. Developer Benefits

* **70%+ Token Cost Reduction:** Traditional AI extensions pass raw file bundles into the LLM context window. Graphify passes condensed structural metadata maps, protecting your context limits and reducing compute costs.
* **Zero Hallucination Imports:** Because the AI relies on a strict Abstract Syntax Tree (AST) lookup table, generated code features perfectly mapped file paths, correct import declarations, and valid function arguments.
* **Dual-Brain Workflow:** Offload macro codebase tracing to a dedicated visual tab in VS Code, freeing up screen real estate while utilizing Antigravity strictly for high-speed agentic code generation.

---

## 🔍 6. Troubleshooting & Diagnostics

### Verifying Graph Health
If you suspect the graph is out of sync, run a hard diagnostics validation check:
```bash
# Clear cache metrics and run a clean, top-to-bottom re-index
graphify update . --force
```

### Removing Git Hooks
If a workspace transition requires disabling automated hook triggers, uninstall the Git configuration hooks cleanly:
```bash
graphify hook uninstall
```

## 🚀 7. Terminal AI Integrations: Claude Code & OpenAI Codex

Terminal-based AI environments can be configured to read the graph directly from your terminal session using specific platform arguments.

### A. Setup for Claude Code
Claude Code relies on a `PreToolUse` hook. This hook intercepts common filesystem searches and silently redirects Claude to read your pre-built Graphify knowledge graph instead.

1. **Install the Platform Bridge**
   From your project root, execute the specific target installer:
   ```bash
   graphify claude install
   ```
   *This command injects a custom skill wrapper into `~/.claude/skills/graphify/` and updates your local `.claude/settings.json` file.*

2. **Trigger the In-Session Initialization**
   Boot up your Claude Code environment:
   ```bash
   claude
   ```
   Inside the Claude prompt window, call the slash command to anchor it to your workspace:
   ```text
   /graphify .
   ```
   *Claude will output a graph verification check showing the total number of mapped nodes, active dependencies, and clustered code communities.*

### B. Setup for OpenAI Codex / OpenCode
Codex environments utilize a universal skill injection file to intercept context windows.

1. **Register the Global Platform Flag**
   Configure the engine using the global registration tool:
   ```bash
   graphify install --platform codex
   ```
   *This command auto-generates a local `.codexrules` and a fallback `AGENTS.md` context reference directly in your repository root.*

2. **Pass Graph Context to Codex Calls**
   When invoking Codex via CLI pipelines, append the structured markdown map directly into your prompt context payload:
   ```bash
   codex --context graphify-out/GRAPH_REPORT.md "Refactor the error handling in our main loop."
   ```

---

## 💡 8. Advanced Session Workflows: "Caveman Mode"

When working inside a terminal session with Claude Code or Codex, token overhead can accumulate rapidly if the AI outputs verbose explanations. Pair Graphify with **Caveman Mode** to maximize efficiency.

* **Graphify** optimizes the **input context** (replacing hundreds of raw code file reads with a single structural map lookup).
* **Caveman Mode** minimizes the **output generation** (forcing the AI to respond in blunt, highly compressed, technical fragments).

### The Command Flow
Inside your Claude Code or Codex session, run the configuration command:

```text
/graphify .
/caveman full
```

### Prompting Example
> **User:** "Explain how data passes through our data layer."
>
> **AI Response (with Graphify + Caveman):**
> `Data -> API_Route -> ValidatorMiddleware -> BaseController -> PostgresDB.`
> `Schema verification handled in models/user.py:12.`
> `Transactions execute statelessly.`

This approach provides a fast, direct technical answer using minimal input and output tokens.
