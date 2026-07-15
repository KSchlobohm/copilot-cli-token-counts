# copilot-token-counts

A workspace-specific GitHub Copilot CLI hook that automatically captures and records billing-relevant token usage for each session.

Unlike global Copilot plugins, this setup is **fully workspace-specific** and **opt-in per repository**. Copilot CLI natively supports repository-level hooks defined in `.github/hooks/`. When you run `copilot` inside this directory, it automatically discovers the hook and runs it when your session ends.

## Features

- **Automatic session tracking:** Records per-model token usage (fresh input, cached input, cache write, and output) on `sessionEnd`.
- **Informational request details:** Captures `reasoning_effort` alongside token totals so you can correlate token usage with model effort settings.
- **Zero-config installation:** Works immediately when Copilot CLI is launched in this workspace. No global plugins or marketplaces to configure.
- **Clean output:** Writes a breakdown to `token-usage/<session-id>.json`, or prefixes the file with either your explicit label or the Copilot-assigned session name when available.
- **Failure-focused diagnostics:** Writes `token-usage/<session-id>.err.log` only when the hook records warnings or recoverable errors.

## How it Works

Copilot CLI automatically loads hooks from `.github/hooks/` in your repository. 

1. At `sessionEnd`, Copilot CLI executes the capture script declared in `.github/hooks/token-counts.json`. This repository includes both a PowerShell implementation (`capture-session-tokens.ps1`) and an equivalent Bash/Python implementation (`capture-session-tokens.sh`).
2. The script parses the Copilot process-log telemetry for the session and generates a per-model JSON breakdown matching GitHub's billing and pricing columns:

| Field | Pricing Column | Description |
|---|---|---|
| `input_tokens_fresh` | Input (fresh, non-cached) | Billed at the standard input rate |
| `cached_input_tokens` | Cached input | Billed at the cached input rate |
| `cache_write_tokens` | Cache write | Billed at the cache write rate (Anthropic only) |
| `output_tokens` | Output | Billed at the standard output rate (includes reasoning) |

It also records informational metadata that helps explain how the tokens were produced:

| Field | Description |
|---|---|
| `reasoning_effort` | The normalized `assistant_usage.properties.reasoning_effort` value for a model, or `mixed` when the session used multiple effort levels |
| `effort_breakdown` | A per-effort count of API calls, at both the session totals level and for each model |

## Layout

```
copilot-token-counts/
├── .github/
│   └── hooks/
│       ├── token-counts.json           # declares the sessionEnd hook
│       ├── capture-session-tokens.ps1  # PowerShell capture script
│       └── capture-session-tokens.sh   # Bash entrypoint + Python parser
├── .gitignore
├── LICENSE
└── README.md
```

## Setup & Usage

To use this in any workspace/repository:
1. Copy the `.github/hooks/` folder into your repository's root directory.
2. Ensure the runtime used by your hook configuration is available:
   - **PowerShell 7+ (`pwsh`)** for `capture-session-tokens.ps1`.
   - **Bash** plus **Python 3** (or `python`) for `capture-session-tokens.sh`; no `jq` dependency is required.
3. Run `copilot` normally. Upon exit, your token usage report will be saved to `<workspace>/token-usage/<session-id>.json`, unless a label or session name is available to prefix it.

`token-counts.json` can choose a different command per shell. For example, to use the Bash/Python port for Bash-based Copilot CLI runs:

```json
{
  "version": 1,
  "hooks": {
    "sessionEnd": [
      {
        "type": "command",
        "powershell": "pwsh -NoProfile -ExecutionPolicy Bypass -File \".github/hooks/capture-session-tokens.ps1\"",
        "bash": "bash \".github/hooks/capture-session-tokens.sh\"",
        "timeoutSec": 30
      }
    ]
  }
}
```

### Optional Session Start Trace

If you are debugging hook discovery or want a visible trace when a Copilot CLI session starts, add a `sessionStart` prompt hook alongside `sessionEnd` in `.github/hooks/token-counts.json`:

```json
"sessionStart": [
  {
    "type": "prompt",
    "prompt": "Display exactly this message and nothing else: ==== Copilot CLI session started ======="
  }
]
```

### Labeled / Named Sessions (e.g., for Workshops)

To organize reports into sortable steps, set the `$env:COPILOT_TOKEN_USAGE_LABEL` variable **before launching `copilot`**:

```powershell
$env:COPILOT_TOKEN_USAGE_LABEL = "01-clone-repo"
copilot
# ...run the step, then exit...

$env:COPILOT_TOKEN_USAGE_LABEL = "02-add-tests"
copilot
```

In Bash:

```bash
export COPILOT_TOKEN_USAGE_LABEL="01-clone-repo"
copilot
# ...run the step, then exit...

export COPILOT_TOKEN_USAGE_LABEL="02-add-tests"
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

Or with the Bash/Python port:

```bash
bash .github/hooks/capture-session-tokens.sh --session-id <session-guid> --json
```

### Script Fingerprint

After copying the `.github/hooks/` folder from a release tag, use `-Fingerprint` to verify
that the installed PowerShell script matches the released version:

```powershell
# Compare the installed script's output with the fingerprint published for the release tag.
pwsh -NoProfile -File .github/hooks/capture-session-tokens.ps1 -Fingerprint
```

It emits compact JSON containing `script_version` and `content_sha256`. The content hash
normalizes line endings before hashing, so it is safe to compare copies stored with CRLF
or LF line endings.

## Requirements

- **GitHub Copilot CLI** with local hook support.
- One supported script runtime:
  - **PowerShell 7+ (`pwsh`)** for `capture-session-tokens.ps1`.
  - **Bash** and **Python 3** (or `python`) for `capture-session-tokens.sh`.
- Access to global logs at `~/.copilot/logs` (or `$env:COPILOT_HOME/logs`).

## License

MIT
