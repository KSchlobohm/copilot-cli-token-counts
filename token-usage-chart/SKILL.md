---
name: token-usage-chart
description: "Generates a GitHub-themed token usage bar chart PNG from Copilot CLI sessionEnd hook JSON reports. Use when: asked to chart, visualize, or compare token usage across phases of an fx2dotnet workshop run. Knows how to locate token-usage/ in the workspace, consolidate sessions by numbered phase prefix, and render the chart with PowerShell."
---

# Token Usage Chart Skill

## Purpose

Produce a GitHub-dark-themed horizontal bar chart of Copilot CLI token usage grouped by numbered phase, using only PowerShell and .NET charting (no Python dependency). Outputs a PNG to `C:\dev\workspace\token-usage\`.

## Context: Flow Repo vs. Workspace Repo

| Concept | Location |
|---------|----------|
| **Workshop content** (scripts, templates, agents, skills) | `C:\dev\flow\` — this repository |
| **Migration target workspace** | Provided to the chart script as `-TokenUsagePath` (typically `C:\dev\workspace\token-usage`) |
| **Token hook JSON reports** | `{WorkspacePath}\token-usage\*.json` — written by `capture-session-tokens.ps1` at session end |
| **Chart output** | `{WorkspacePath}\token-usage\` — **always write images here** |
| **Summarize-TokenUsage.ps1** | `C:\dev\flow\scripts\Summarize-TokenUsage.ps1` — produces deterministic phase totals from the same JSON reports |

Preferred invocation (explicit token-usage path):

```powershell
pwsh -NoProfile -File .github/skills/token-usage-chart/Generate-TokenUsageChart.ps1 `
  -TokenUsagePath 'C:\dev\workspace\token-usage'
```

`-WorkspacePath` is supported as a fallback, but the skill should prefer and provide `-TokenUsagePath`.

## JSON Report Schema

Each file in `token-usage/` follows `copilot-cli-session-token-usage/v1`:

```json
{
  "schema": "copilot-cli-session-token-usage/v1",
  "session_id": "<guid>",
  "label": "04-sdk-conversion-run",
  "totals": {
    "api_calls": 42,
    "input_tokens_total": 12500000,
    "input_tokens_fresh": 8000000,
    "cached_input_tokens": 4000000,
    "cache_write_tokens": 500000,
    "output_tokens": 300000,
    "reasoning_tokens": 50000
  },
  "by_model": [ ... ]
}
```

### Deduplication

A single phase may produce multiple session files. Always deduplicate by `session_id` before summing — if `session_id` has already been seen, skip that file.

## Phase Consolidation and Label Override Rule

Use the token-usage **file name** as the primary source for phase label text, with fallback to JSON `label`.

1. Start with file base name (without `.json`), and if it matches `<label>__<session-id>`, use only `<label>`.
2. Extract the leading phase number with `'^\s*(\d{1,2})(?:\D|$)'`.
3. If there is no phase number, **exclude** the item from the chart.
4. Zero-pad phase number (for lookup/sorting) and sum token values by that phase number.
5. Build display labels from a **label override table** keyed by phase number.
6. If a phase is not in overrides, derive a short label from the text after the phase prefix.

This keeps re-runs/retries consolidated while allowing readable labels.

### Label Override Table

Keep this table in the script so names are short and stable:

```powershell
$phaseLabelOverrides = @{
  '00' = 'setup'
  # add/adjust as needed:
  # '01' = 'assessment'
  # '02' = 'constitution'
  # '03' = 'planning'
}
```

## Rendering Rules

- **Chart type:** Horizontal bar (PowerShell `SeriesChartType::Bar`) — phases on Y axis, tokens on X axis.
- **Sort order:** By numeric phase sequence, with direction configurable for journey storytelling. Current default is reverse journey (`09` → `00`) so the earliest phase appears at the bottom.
- **X axis:** Token values in Millions (`#,##0,,"M"`), labeled `Total Tokens (Millions)` at the bottom.
- **Y axis:** Every phase label shown (`AxisX.Interval = 1`, `AxisX.IsLabelAutoFit = $false`). No Y-axis title.
- **Bar values:** Use **total tokens** per phase (`input_tokens_fresh + cached_input_tokens + cache_write_tokens + output_tokens`).
- **Bar colors:** Render stacked segments by token bucket with distinct colors and a legend:
  - Fresh input: `#1f6feb`
  - Cached input: `#2ea043`
  - Cache write: `#bf8700`
  - Output: `#a371f7`
- **No grid lines** on either axis.
- **GitHub dark theme colors:**

| Element | Hex |
|---------|-----|
| Canvas background | `#0d1117` |
| Chart area background | `#161b22` |
| Bar fill | `#2ea043` |
| Label / axis text | `#c9d1d9` |
| Axis lines / muted | `#8b949e` |

- **Font:** `Segoe UI Semibold` for phase labels (16pt) and bar value labels (11pt); `Segoe UI` for X-axis tick labels (11pt); `Segoe UI Semibold` for X-axis title (12pt) and chart title (16pt).

## Reference PowerShell Implementation

```powershell
Add-Type -AssemblyName System.Windows.Forms.DataVisualization
Add-Type -AssemblyName System.Drawing

$config       = & C:\dev\flow\scripts\Get-WorkshopConfig.ps1
$tokenDir     = Join-Path $config.WorkspacePath 'token-usage'
$out          = Join-Path $tokenDir 'token-phases-github.png'

$seen = @{}
$totalsByPhaseNumber = @{}
$displayLabelByPhaseNumber = @{}

$phaseLabelOverrides = @{
  '00' = 'setup'
}

Get-ChildItem -LiteralPath $tokenDir -Filter *.json -File | Sort-Object Name | ForEach-Object {
  try { $r = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { return }

  $sid = [string]$r.session_id
  if ($sid -and $seen.ContainsKey($sid)) { return }
  if ($sid) { $seen[$sid] = $true }

  $nameLabel = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
  if ($nameLabel -match '^(?<label>.+?)__[^_]+$') { $nameLabel = $Matches['label'] }
  $label = if ([string]::IsNullOrWhiteSpace($nameLabel)) { [string]$r.label } else { $nameLabel }
  if ([string]::IsNullOrWhiteSpace($label)) { return }
  if ($label -notmatch '^\s*(\d{1,2})(?:\D|$)') { return }

  $phaseNumber = $Matches[1].PadLeft(2,'0')
  $val = [long]($r.totals.input_tokens_total)

  if (-not $totalsByPhaseNumber.ContainsKey($phaseNumber)) { $totalsByPhaseNumber[$phaseNumber] = 0L }
  $totalsByPhaseNumber[$phaseNumber] += $val

  if (-not $displayLabelByPhaseNumber.ContainsKey($phaseNumber)) {
    if ($phaseLabelOverrides.ContainsKey($phaseNumber)) {
      $displayLabelByPhaseNumber[$phaseNumber] = [string]$phaseLabelOverrides[$phaseNumber]
    } else {
      $short = ($label -replace '^\s*\d{1,2}[-_\s]*', '').Trim()
      $short = $short -replace '[-_]+', ' '
      if ([string]::IsNullOrWhiteSpace($short)) { $short = "phase $phaseNumber" }
      $displayLabelByPhaseNumber[$phaseNumber] = $short
    }
  }
}

if ($totalsByPhaseNumber.Count -eq 0) { throw 'No numbered phase labels found.' }

# Keep sequence by phase number and reverse direction for journey rendering (09 -> 00).
$items = foreach ($phase in ($totalsByPhaseNumber.Keys | Sort-Object -Descending)) {
  [pscustomobject]@{
    phase = $phase
    label = $displayLabelByPhaseNumber[$phase]
    tokens = [long]$totalsByPhaseNumber[$phase]
  }
}
$count = $items.Count

$bg    = [System.Drawing.ColorTranslator]::FromHtml('#0d1117')
$panel = [System.Drawing.ColorTranslator]::FromHtml('#161b22')
$text  = [System.Drawing.ColorTranslator]::FromHtml('#c9d1d9')
$muted = [System.Drawing.ColorTranslator]::FromHtml('#8b949e')
$bar   = [System.Drawing.ColorTranslator]::FromHtml('#2ea043')

$chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
$chart.Width = 1800
$chart.Height = [Math]::Max(900, 95 * $count)
$chart.BackColor = $bg
$chart.TextAntiAliasingQuality = 'High'

$ca = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
$ca.BackColor = $panel
$ca.Position.Auto = $false
$ca.Position.X = 14; $ca.Position.Y = 10; $ca.Position.Width = 82; $ca.Position.Height = 82

$ca.AxisX.Interval = 1; $ca.AxisX.LabelStyle.Interval = 1
$ca.AxisX.IsLabelAutoFit = $false
$ca.AxisX.LabelStyle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$ca.AxisX.LabelStyle.ForeColor = $text
$ca.AxisX.MajorGrid.Enabled = $false; $ca.AxisX.MajorTickMark.Enabled = $false
$ca.AxisX.LineColor = $muted; $ca.AxisX.Title = ''

$ca.AxisY.IsLabelAutoFit = $false
$ca.AxisY.LabelStyle.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$ca.AxisY.LabelStyle.ForeColor = $text
$ca.AxisY.LabelStyle.Format = '#,##0,,"M"'
$ca.AxisY.MajorGrid.Enabled = $false; $ca.AxisY.LineColor = $muted
$ca.AxisY.Title = 'Tokens (Millions)'
$ca.AxisY.TitleFont = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$ca.AxisY.TitleForeColor = $text
$chart.ChartAreas.Add($ca)

$s = New-Object System.Windows.Forms.DataVisualization.Charting.Series
$s.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Bar
$s.Color = $bar; $s['PointWidth'] = '0.72'
$s.IsValueShownAsLabel = $true
$s.LabelForeColor = $text
$s.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$s.LabelFormat = '#,##0,,"M"'

foreach ($item in $items) {
  $pt = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
  $pt.SetValueY([double]$item.tokens); $pt.AxisLabel = [string]$item.label
  [void]$s.Points.Add($pt)
}
$chart.Series.Add($s)

$t = New-Object System.Windows.Forms.DataVisualization.Charting.Title
$t.Text = 'Copilot Token Usage by Phase (input_tokens_total)'
$t.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$t.ForeColor = $text
$chart.Titles.Add($t) | Out-Null

$chart.SaveImage($out, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png)
Write-Output $out
```

## Output

The chart is always written to:

```
{WorkspacePath}\token-usage\token-phases-github.png
```

For `C:\dev\workspace` this is:

```
C:\dev\workspace\token-usage\token-phases-github.png
```

Do not write chart images to any other location.
