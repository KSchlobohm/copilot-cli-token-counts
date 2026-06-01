<#
.SYNOPSIS
    Capture raw, billing-relevant token counts for a Copilot CLI session, grouped by model.

.DESCRIPTION
    Intended to be run from a Copilot CLI `sessionEnd` hook. It reads the hook's JSON
    payload from stdin (to learn the sessionId), scans the Copilot CLI process logs for
    that session's per-API-call usage telemetry, and writes a per-model token breakdown.

    It deliberately reports ONLY token counts (the raw numbers that pricing is based on).
    It does NOT compute costs, AI credits, or dollars.

    This is a self-contained tool with NO dependency on spec-kit / specify.

    -------------------------------------------------------------------------------------
    WHY THIS DATA SOURCE
    -------------------------------------------------------------------------------------
    Copilot CLI bills by token consumption (abstracted by GitHub as "AI Credits",
    1 credit = $0.01 USD). The published pricing table charges on four token buckets:

        Pricing column   ->  Telemetry field (metrics.*)
        ---------------      ---------------------------
        Input            ->  input_tokens_uncached   (fresh, non-cached input)
        Cached input     ->  cache_read_tokens       (reused/cached input)
        Cache write      ->  cache_write_tokens      (Anthropic only)
        Output           ->  output_tokens           (includes reasoning tokens)

    These fields appear ONLY in the CLI's `assistant_usage` telemetry events, which are
    written to the process log and are already normalized across providers (so GPT vs
    Claude vs Gemini format differences do not matter here). Each event carries the
    `session_id`, the `properties.model`, and a unique `properties.event_id`.

    -------------------------------------------------------------------------------------
    ASSUMPTIONS (verified against Copilot CLI v1.0.57 on win32)
    -------------------------------------------------------------------------------------
    1.  Token usage lives in the process logs, NOT in hook payloads, the session
        transcript (events.jsonl), or session.db. Hook payloads contain no token data,
        so this script derives everything from the logs.
    2.  Process logs are at  <COPILOT_HOME>\logs\process-*.log  where COPILOT_HOME is
        $env:COPILOT_HOME if set, otherwise %USERPROFILE%\.copilot. (The logs are global
        per machine even though this hook is committed in the repository.)
    3.  Each billable model call emits a telemetry block of the form:
            <timestamp> [DEBUG] [Telemetry] cli.telemetry:
            { ... "kind": "assistant_usage", "properties": { "model": ..., "event_id": ... },
              "metrics": { "input_tokens", "input_tokens_uncached", "output_tokens",
                           "cache_read_tokens", "cache_write_tokens", "reasoning_tokens", ... },
              "session_id": "<id>" ... }
        The JSON object is pretty-printed; its top-level closing brace is a line that is
        exactly "}" (no indentation). This script extracts blocks on that basis.
    4.  A single session may span MULTIPLE process logs (the PID, and therefore the log
        filename, changes on restart / resume). So ALL logs are scanned and filtered by
        session_id; duplicate events across overlapping logs are removed by event_id.
    5.  `assistant_usage` covers conversational agent + subagent calls (initiator =
        "user" or "agent"). Internal utility calls (e.g. session-title generation on
        gpt-4o-mini, embeddings) are NOT emitted as `assistant_usage` and are therefore
        not counted here. `output_tokens` already accounts for reasoning tokens; the
        reasoning count is reported separately for transparency only.

    -------------------------------------------------------------------------------------
    CAVEATS
    -------------------------------------------------------------------------------------
    *  The process-log format is INTERNAL and UNDOCUMENTED. It can change between CLI
       versions. This script was written and verified against:
           Copilot CLI v1.0.57
       Check your version with `copilot --version` or the `/version` slash command and
       re-verify the field names below if it differs.
    *  `sessionEnd` may not fire on a hard kill (SIGKILL / power loss); in that case the
       data is still in the log and you can re-run this script manually with -SessionId.
    *  The final turn's `assistant_usage` telemetry is flushed to the process log
       ASYNCHRONOUSLY, and can land a second or two AFTER `sessionEnd` fires. If this
       script scanned the log immediately it would miss the last turn (or, for a
       single-turn session, report all zeros). To avoid that race it polls the log until
       the session's event count stops growing (stable for -StableSeconds) or -MaxWaitSeconds
       elapses. Use -NoWait to skip the wait for manual backfill of an already-complete log.
    *  Some models reported here may be internal / non-GA (e.g. "mai-code-*") and may not
       be billable to you. This script reports raw tokens only; reconcile against the
       authoritative GitHub billing usage report for an actual bill.

    -------------------------------------------------------------------------------------
    REFERENCES (current as of CLI v1.0.57)
    -------------------------------------------------------------------------------------
    *  Hooks reference:   https://docs.github.com/en/copilot/reference/hooks-reference
    *  Using hooks (CLI): https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
    *  Models & pricing:  https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing
    *  CLI changelog:     run `/changelog` in Copilot CLI, or see the in-product /version output.

.PARAMETER SessionId
    Session id to report on. If omitted, it is read from the hook JSON payload on stdin
    (`sessionId` or `session_id`).

.PARAMETER LogDir
    Directory containing process-*.log files. Defaults to <COPILOT_HOME>\logs.

.PARAMETER OutDir
    Directory to write the per-session JSON report to. Resolution order:
      1. -OutDir parameter
      2. $env:COPILOT_TOKEN_USAGE_DIR
      3. <session cwd>\token-usage, where the session cwd comes from the hook payload
         (so a globally-installed plugin writes into whichever workspace the session ran in)
      4. <current directory>\token-usage

.PARAMETER MaxWaitSeconds
    Upper bound (seconds) on how long to wait for the final turn's telemetry to be flushed
    to the log before writing the report. Default 12. Stays well under the hook's timeout.

.PARAMETER StableSeconds
    Stop waiting once the session's telemetry event count has not changed for this many
    seconds (i.e. the log has settled). Default 2.

.PARAMETER PollSeconds
    Interval (seconds) between log re-scans while waiting. Default 0.5.

.PARAMETER NoWait
    Skip the settle wait entirely and scan the log exactly once. Use for manual backfill of
    a session whose log is already complete.

.PARAMETER Json
    Also emit the report JSON to stdout (in addition to writing the file).

.EXAMPLE
    # As a Copilot CLI plugin hook (declared in the plugin's hooks/hooks.json) — reads the
    # sessionId AND the session cwd from the hook payload on stdin.

.EXAMPLE
    # Manual / backfill run for a known session:
    pwsh -NoProfile -File capture-session-tokens.ps1 -SessionId <session-guid> -Json
#>
param(
    [string]$SessionId,
    [string]$LogDir,
    [string]$OutDir,
    [int]$MaxWaitSeconds = 12,
    [double]$StableSeconds = 2,
    [double]$PollSeconds = 0.5,
    [switch]$NoWait,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Get-CopilotHome {
    if ($env:COPILOT_HOME) { return $env:COPILOT_HOME }
    return (Join-Path $env:USERPROFILE ".copilot")
}

# --- Resolve sessionId and session cwd: prefer parameter, else read hook payload from stdin ---
$SessionCwd = $null
if (-not $SessionId) {
    $raw = ""
    if ([Console]::IsInputRedirected) {
        $raw = [Console]::In.ReadToEnd()
    }
    if ($raw -and $raw.Trim()) {
        try {
            $payload = $raw | ConvertFrom-Json
            if ($payload.sessionId)      { $SessionId = $payload.sessionId }
            elseif ($payload.session_id) { $SessionId = $payload.session_id }
            if ($payload.cwd)            { $SessionCwd = [string]$payload.cwd }
        } catch {
            # Hook fired with unexpected/empty stdin; fail open so we never block the CLI.
            Write-Warning "capture-session-tokens: could not parse hook payload: $_"
        }
    }
}

if (-not $SessionId) {
    Write-Warning "capture-session-tokens: no sessionId provided or found on stdin; nothing to do."
    exit 0
}

$home_ = Get-CopilotHome
if (-not $LogDir) { $LogDir = Join-Path $home_ "logs" }
if (-not $OutDir) {
    if ($env:COPILOT_TOKEN_USAGE_DIR) {
        $OutDir = $env:COPILOT_TOKEN_USAGE_DIR
    } elseif ($SessionCwd -and (Test-Path $SessionCwd)) {
        $OutDir = Join-Path $SessionCwd "token-usage"
    } else {
        $OutDir = Join-Path (Get-Location).Path "token-usage"
    }
}

if (-not (Test-Path $LogDir)) {
    Write-Warning "capture-session-tokens: log directory not found: $LogDir"
    exit 0
}

# --- Extract pretty-printed telemetry JSON objects following a 'cli.telemetry:' marker ---
function Get-TelemetryBlocks {
    param([string[]]$Lines)
    $blocks = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '\[Telemetry\] cli\.telemetry:') {
            $j = $i + 1
            while ($j -lt $Lines.Count -and $Lines[$j].Trim() -eq '') { $j++ }
            if ($j -ge $Lines.Count -or $Lines[$j].TrimEnd() -ne '{') { continue }
            $sb = New-Object System.Text.StringBuilder
            for ($k = $j; $k -lt $Lines.Count; $k++) {
                [void]$sb.AppendLine($Lines[$k])
                if ($Lines[$k] -eq '}') { break }   # top-level close has no indentation
            }
            try { $blocks.Add(($sb.ToString() | ConvertFrom-Json)) } catch { }
        }
    }
    return $blocks
}

# --- Collect this session's assistant_usage events across all logs, de-duped by event_id ---
function Get-SessionUsageEvents {
    param([string]$LogDir, [string]$SessionId)
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $events = New-Object System.Collections.Generic.List[object]
    Get-ChildItem -Path $LogDir -Filter "process-*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime |
        ForEach-Object {
            $path = $_.FullName
            # Cheap pre-filter: only fully parse logs that mention this session.
            if (-not (Select-String -Path $path -Pattern $SessionId -SimpleMatch -Quiet)) { return }
            $lines = Get-Content -Path $path
            foreach ($b in (Get-TelemetryBlocks $lines)) {
                if ($b.kind -ne 'assistant_usage') { continue }
                if ($b.session_id -ne $SessionId)  { continue }
                $eid = [string]$b.properties.event_id
                if ($eid -and -not $seen.Add($eid)) { continue }   # skip duplicate across overlapping logs
                $events.Add($b)
            }
        }
    return ,$events
}

# The final turn's assistant_usage telemetry is flushed asynchronously and can land a
# second or two after sessionEnd fires. Poll until the event count settles (no growth for
# StableSeconds) or MaxWaitSeconds elapses, so we don't write a report that misses the last
# turn (or, for a single-turn session, reports all zeros).
$events = Get-SessionUsageEvents -LogDir $LogDir -SessionId $SessionId
if (-not $NoWait) {
    $deadline    = (Get-Date).AddSeconds($MaxWaitSeconds)
    $lastCount   = $events.Count
    $stableSince = Get-Date
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $events = Get-SessionUsageEvents -LogDir $LogDir -SessionId $SessionId
        if ($events.Count -ne $lastCount) {
            $lastCount   = $events.Count
            $stableSince = Get-Date
        } elseif (((Get-Date) - $stableSince).TotalSeconds -ge $StableSeconds) {
            break
        }
    }
}

# --- Aggregate per model ---
$byModel = @{}
foreach ($e in $events) {
    $model = [string]$e.properties.model
    if (-not $model) { $model = "unknown" }
    if (-not $byModel.ContainsKey($model)) {
        $byModel[$model] = [ordered]@{
            model                 = $model
            api_calls             = 0
            input_tokens_total    = 0   # metrics.input_tokens (fresh + cached)
            input_tokens_fresh    = 0   # metrics.input_tokens_uncached  -> "Input" rate
            cached_input_tokens   = 0   # metrics.cache_read_tokens       -> "Cached input" rate
            cache_write_tokens    = 0   # metrics.cache_write_tokens      -> "Cache write" (Anthropic)
            output_tokens         = 0   # metrics.output_tokens           -> "Output" rate
            reasoning_tokens      = 0   # informational; included within output_tokens
        }
    }
    $m = $e.metrics
    $byModel[$model].api_calls           += 1
    $byModel[$model].input_tokens_total  += [long]$m.input_tokens
    $byModel[$model].input_tokens_fresh  += [long]$m.input_tokens_uncached
    $byModel[$model].cached_input_tokens += [long]$m.cache_read_tokens
    $byModel[$model].cache_write_tokens  += [long]$m.cache_write_tokens
    $byModel[$model].output_tokens       += [long]$m.output_tokens
    $byModel[$model].reasoning_tokens    += [long]$m.reasoning_tokens
}

$models = @($byModel.Values | Sort-Object { $_.input_tokens_total } -Descending)

function Sum-Key($rows, $key) {
    $s = [long]0
    foreach ($r in $rows) { $s += [long]$r[$key] }
    return $s
}

$totals = [ordered]@{
    api_calls           = Sum-Key $models 'api_calls'
    input_tokens_total  = Sum-Key $models 'input_tokens_total'
    input_tokens_fresh  = Sum-Key $models 'input_tokens_fresh'
    cached_input_tokens = Sum-Key $models 'cached_input_tokens'
    cache_write_tokens  = Sum-Key $models 'cache_write_tokens'
    output_tokens       = Sum-Key $models 'output_tokens'
    reasoning_tokens    = Sum-Key $models 'reasoning_tokens'
}

$report = [ordered]@{
    schema           = "copilot-cli-session-token-usage/v1"
    generated_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    cli_version_note = "Field layout verified against Copilot CLI v1.0.57; re-verify if your /version differs."
    session_id       = $SessionId
    field_meaning    = [ordered]@{
        input_tokens_fresh  = "Billed at the model's 'Input' rate (fresh, non-cached input)."
        cached_input_tokens = "Billed at the model's 'Cached input' rate."
        cache_write_tokens  = "Billed at the model's 'Cache write' rate (Anthropic models only)."
        output_tokens       = "Billed at the model's 'Output' rate (includes reasoning tokens)."
        reasoning_tokens    = "Informational only; already counted within output_tokens."
        input_tokens_total  = "fresh + cached input; informational."
    }
    totals           = $totals
    by_model         = $models
}

# --- Write report ---
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outPath = Join-Path $OutDir ("{0}.json" -f $SessionId)
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $outPath -Encoding UTF8

# --- Human-readable summary to stderr (so it never pollutes hook stdout JSON contract) ---
$summary = New-Object System.Text.StringBuilder
[void]$summary.AppendLine("Copilot CLI token usage  (session $SessionId)")
[void]$summary.AppendLine(("{0,-30} {1,6} {2,14} {3,14} {4,14} {5,12}" -f "model","calls","input_fresh","input_cached","cache_write","output"))
foreach ($r in $models) {
    [void]$summary.AppendLine(("{0,-30} {1,6} {2,14} {3,14} {4,14} {5,12}" -f `
        $r.model, $r.api_calls, $r.input_tokens_fresh, $r.cached_input_tokens, $r.cache_write_tokens, $r.output_tokens))
}
[void]$summary.AppendLine(("{0,-30} {1,6} {2,14} {3,14} {4,14} {5,12}" -f `
    "TOTAL", $totals.api_calls, $totals.input_tokens_fresh, $totals.cached_input_tokens, $totals.cache_write_tokens, $totals.output_tokens))
[void]$summary.AppendLine("Saved: $outPath")
[Console]::Error.WriteLine($summary.ToString())

if ($Json) { $report | ConvertTo-Json -Depth 8 }

exit 0
