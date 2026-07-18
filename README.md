<p align="center">
  <h1 align="center">📚 tech-wiki</h1>
  <p align="center">
    <strong>A personal knowledge base of dev tooling, AI-workflow, and infra guides — written to be reused, not re-googled.</strong>
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/Type-Personal_Wiki-7c3aed?style=for-the-badge" alt="Type">
    <img src="https://img.shields.io/badge/Format-Markdown-000000?style=for-the-badge&logo=markdown&logoColor=white" alt="Markdown">
    <img src="https://img.shields.io/github/last-commit/pratiks360/tech-wiki?style=for-the-badge&label=Last+Commit" alt="Last Commit">
    <img src="https://img.shields.io/github/license/pratiks360/tech-wiki?style=for-the-badge" alt="License">
  </p>
</p>

---

## 📋 Table of Contents

- [What Is This?](#-what-is-this)
- [Contents](#-contents)
- [Repo Structure](#-repo-structure)
- [How to Use This Wiki](#-how-to-use-this-wiki)
- [Adding a New Guide](#-adding-a-new-guide)
- [Troubleshooting](#-troubleshooting)
- [Contributing](#-contributing)
- [License](#-license)

---

## ✨ What Is This?

**tech-wiki** is Pratik's running reference library for the tools, workflows, and infrastructure setups he uses day to day — written up once, in enough detail to be copy-pasted back into a terminal six months later without having to remember the reasoning behind every flag.

> 🧠 Think of it as "future-me's onboarding doc" rather than a public tutorial site.

---

## 🗂️ Contents

| Guide | Description |
|---|---|
| 🧩 **[Graphify + AI Agent Workflow](graphify.md)** | Standard operating procedure for wiring **Graphify**'s AST knowledge graph into a VS Code + Google Antigravity dual-dev setup — installation, Git hook automation, cross-editor config, prompt templates for impact analysis and architecture discovery, and pairing it with Claude Code / Codex terminal integrations |
| 🔐 **[vpn/](vpn/)** | Notes and configs for VPN and network access setups |

---

## 🌳 Repo Structure

```
tech-wiki/
├── graphify.md      # AI-agent codebase mapping workflow (Graphify + Claude Code/Antigravity/Codex)
└── vpn/             # VPN / networking setup notes
```

---

## 🚀 How to Use This Wiki

1. Clone or browse the repo directly on GitHub — there's nothing to install or run.
   ```bash
   git clone https://github.com/pratiks360/tech-wiki.git
   ```
2. Jump to the guide you need from the [Contents](#-contents) table above.
3. Guides are written to be followed top-to-bottom, with copy-pasteable commands and config blocks.

---

## ➕ Adding a New Guide

- One `.md` file (or folder, for multi-file topics) per subject.
- Lead with a one-line summary of what the guide covers and why it exists.
- Prefer runnable command blocks over prose explanations.
- Update the [Contents](#-contents) table in this README when a new guide is added.

---

## 🐛 Troubleshooting

**Q: A guide references a tool version or flag that's changed.**
A: These are living notes tied to Pratik's setup at the time of writing — check the tool's own docs for the current syntax and update the guide accordingly.

**Q: Where do longer, tool-specific troubleshooting steps live?**
A: Inside the guide itself — see the "Troubleshooting & Diagnostics" section of [`graphify.md`](graphify.md) for an example.

---

## 🤝 Contributing

This is a personal reference repo, so it's optimized for Pratik's own workflows first — but issues and suggestions are welcome if something's unclear or out of date.

---

## 📄 License

This project is open source under the [MIT License](LICENSE).

---

<p align="center">
  <sub>Built with ❤️ as a growing second brain for dev tooling and infra know-how.</sub>
</p>
