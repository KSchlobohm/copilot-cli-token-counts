# token-counts (Copilot CLI plugin)

Records billing-relevant token usage for each GitHub Copilot CLI session.

On `sessionEnd`, the plugin's hook scrapes the CLI's process-log telemetry for the ending
session and writes a per-model breakdown to `<workspace>/token-usage/<session-id>.json`,
using buckets that match the CLI's status line and GitHub's pricing columns:

| Field | Pricing column |
|-------|----------------|
| `input_tokens_fresh`  | Input (fresh, non-cached) |
| `cached_input_tokens` | Cached input |
| `cache_write_tokens`  | Cache write (Anthropic) |
| `output_tokens`       | Output (includes reasoning) |

The output directory is the **session's working directory** (taken from the `sessionEnd`
hook payload's `cwd`), so even though the plugin is installed once, each report lands in the
workspace where that session ran. Override with `$env:COPILOT_TOKEN_USAGE_DIR`.

## Layout

```
plugins/token-counts/
└── hooks/
    ├── hooks.json                  # declares the sessionEnd command hook
    └── capture-session-tokens.ps1  # the capture script (self-contained)
```

Copilot CLI auto-discovers plugin hooks from `hooks/hooks.json` in the plugin's install
directory (see the [hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)).

## Requirements

- **PowerShell 7+ (`pwsh`)** on PATH — the hook invokes `pwsh` for both the `powershell`
  and `bash` hook entries.
- Reads global logs at `~/.copilot/logs` (or `$COPILOT_HOME/logs`).

## Manual / backfill run

```powershell
pwsh -NoProfile -File hooks/capture-session-tokens.ps1 -SessionId <session-guid> -Json
```

Use `-NoWait` when backfilling from an already-complete log.

## Notes / caveats

- **Path resolution:** the hook command references `hooks/capture-session-tokens.ps1`
  relative to the plugin's install directory. If your CLI version resolves plugin-hook
  working directories differently, adjust the path in `hooks/hooks.json` accordingly.
- The final turn's `assistant_usage` telemetry is flushed asynchronously (~1–2s after
  `sessionEnd`). The script polls until the session's event count settles (`-StableSeconds`,
  default 2) or `-MaxWaitSeconds` (default 12) elapses, so it never reports zeros for the
  last turn. The hook timeout is 30s.
- The process-log format is internal and undocumented; verified against Copilot CLI v1.0.57.
  Re-verify field names if your `/version` differs.
