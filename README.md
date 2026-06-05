# copilot-token-counts

A workspace-specific GitHub Copilot CLI hook that automatically captures and records billing-relevant token usage for each session.

Unlike global Copilot plugins, this setup is **fully workspace-specific** and **opt-in per repository**. Copilot CLI natively supports repository-level hooks defined in `.github/hooks/`. When you run `copilot` inside this directory, it automatically discovers the hook and runs it when your session ends.

## Features

- **Automatic session tracking:** Records per-model token usage (fresh input, cached input, cache write, and output) on `sessionEnd`.
- **Zero-config installation:** Works immediately when Copilot CLI is launched in this workspace. No global plugins or marketplaces to configure.
- **Clean output:** Writes a breakdown to `token-usage/<session-id>.json`, or prefixes the file with either your explicit label or the Copilot-assigned session name when available.
- **Failure-focused diagnostics:** Writes `token-usage/<session-id>.err.log` only when the hook records warnings or recoverable errors.

## How it Works

Copilot CLI automatically loads hooks from `.github/hooks/` in your repository. 

1. At `sessionEnd`, Copilot CLI executes `.github/hooks/capture-session-tokens.ps1` via the configuration in `.github/hooks/token-counts.json`.
2. The script parses the Copilot process-log telemetry for the session and generates a per-model JSON breakdown matching GitHub's billing and pricing columns:

| Field | Pricing Column | Description |
|---|---|---|
| `input_tokens_fresh` | Input (fresh, non-cached) | Billed at the standard input rate |
| `cached_input_tokens` | Cached input | Billed at the cached input rate |
| `cache_write_tokens` | Cache write | Billed at the cache write rate (Anthropic only) |
| `output_tokens` | Output | Billed at the standard output rate (includes reasoning) |

## Layout

```
copilot-token-counts/
├── .github/
│   └── hooks/
│       ├── token-counts.json           # declares the sessionEnd hook
│       └── capture-session-tokens.ps1  # the capture script (self-contained)
├── .gitignore
├── LICENSE
└── README.md
```

## Setup & Usage

To use this in any workspace/repository:
1. Copy the `.github/hooks/` folder into your repository's root directory.
2. Ensure you have **PowerShell 7+ (`pwsh`)** on your PATH (the hook invokes `pwsh`).
3. Run `copilot` normally. Upon exit, your token usage report will be saved to `<workspace>/token-usage/<session-id>.json`, unless a label or session name is available to prefix it.

### Labeled / Named Sessions (e.g., for Workshops)

To organize reports into sortable steps, set the `$env:COPILOT_TOKEN_USAGE_LABEL` variable **before launching `copilot`**:

```powershell
$env:COPILOT_TOKEN_USAGE_LABEL = "01-clone-repo"
copilot
# ...run the step, then exit...

$env:COPILOT_TOKEN_USAGE_LABEL = "02-add-tests"
copilot
```

This creates:
```
token-usage/
  01-clone-repo__<session-id>.json
  02-add-tests__<session-id>.json
```

If you do not set `COPILOT_TOKEN_USAGE_LABEL`, the hook falls back to the Copilot CLI session name when one exists. For example, a session named `Review Hook and Script` will produce:

```
token-usage/
  Review-Hook-and-Script__<session-id>.json
```

### Manual / Backfill Run

To manually generate a report for a past session (or to run backfills):

```powershell
pwsh -NoProfile -File .github/hooks/capture-session-tokens.ps1 -SessionId <session-guid> -Json
```

## Requirements

- **GitHub Copilot CLI** with local hook support.
- **PowerShell 7+ (`pwsh`)** installed on PATH.
- Access to global logs at `~/.copilot/logs` (or `$env:COPILOT_HOME/logs`).

## License

MIT
