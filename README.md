# copilot-token-counts

A **GitHub Copilot CLI plugin marketplace** that captures billing-relevant token usage for
each Copilot CLI session.

This repo is structured as a Copilot CLI plugin marketplace: `.github/plugin/marketplace.json`
lists the plugins, and each plugin lives under `plugins/<name>/`.

## Plugins

| Plugin | Description |
|--------|-------------|
| [`token-counts`](plugins/token-counts) | On `sessionEnd`, records per-model token usage (fresh / cached / cache-write / output) for the session into `<workspace>/token-usage/<session-id>.json`. |

## Install

In Copilot CLI, use the `/plugin` command to add this marketplace and install the plugin:

```
/plugin
```

Then add the marketplace by its repository (or local path during development) and install
`token-counts`. Once installed, the plugin's `sessionEnd` hook is auto-discovered from
`plugins/token-counts/hooks/hooks.json` and runs at the end of every Copilot CLI session.

> **Scope:** A Copilot CLI plugin is installed once and applies to **all** your CLI sessions.
> Each session's report is still written into the workspace where that session ran (the hook
> uses the session `cwd` from its payload), so per-project data stays separated.

## Layout

```
copilot-token-counts/
├── .github/plugin/marketplace.json     # marketplace manifest (lists plugins)
├── plugins/
│   └── token-counts/
│       ├── hooks/
│       │   ├── hooks.json              # declares the sessionEnd command hook
│       │   └── capture-session-tokens.ps1
│       └── README.md
├── LICENSE
└── README.md
```

## Requirements

- **GitHub Copilot CLI** with plugin support.
- **PowerShell 7+ (`pwsh`)** on PATH (the hook runs `pwsh`).

## Caveat

GitHub's official plugin collection currently lists hooks as *"coming soon,"* and plugin-hook
working-directory resolution is not fully documented. This plugin is built to the published
[hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference) spec; if a CLI
version resolves plugin paths differently, adjust the script path in
`plugins/token-counts/hooks/hooks.json`. See the [plugin README](plugins/token-counts/README.md)
for details.

## License

MIT
