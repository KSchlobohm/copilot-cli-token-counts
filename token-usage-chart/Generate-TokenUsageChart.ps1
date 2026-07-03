#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generates GitHub-themed token usage charts from token-usage hook JSON reports.

.DESCRIPTION
    Reads token usage JSON files from a provided token-usage folder path, deduplicates by session_id,
    aggregates by numbered phase prefix, and renders stacked horizontal bar charts.

    By default, this script generates BOTH:
      - widescreen: token-phases-github.png
      - square:     token-phases-github-square.png

    Output is always written under <WorkspacePath>\token-usage.
#>
param(
    [string]$TokenUsagePath,
    [string]$WorkspacePath,
    [ValidateSet('both', 'wide', 'square')]
    [string]$Format = 'both',
    [string]$OutputBaseName = 'token-phases-github'
)

$ErrorActionPreference = 'Stop'

if (-not $TokenUsagePath) {
    if (-not $WorkspacePath) {
        throw 'Provide -TokenUsagePath (recommended) or -WorkspacePath.'
    }
    $workspaceRoot = (Resolve-Path -LiteralPath $WorkspacePath).Path
    $TokenUsagePath = Join-Path $workspaceRoot 'token-usage'
}

if (-not (Test-Path -LiteralPath $TokenUsagePath)) {
    throw "Token usage directory was not found: $TokenUsagePath"
}
$tokenDir = (Resolve-Path -LiteralPath $TokenUsagePath).Path

Add-Type -AssemblyName System.Windows.Forms.DataVisualization
Add-Type -AssemblyName System.Drawing

function Format-M {
    param([long]$Value)
    $absValue = [Math]::Abs([double]$Value)
    if ($absValue -lt 1000000) {
        return ('{0:0.0}M' -f ([double]$Value / 1000000.0))
    }
    return ('{0:#,##0,,"M"}' -f [double]$Value)
}

$phaseLabelOverrides = @{
    '00' = 'setup'
    '01' = 'assessment'
    '02' = 'constitution'
    '03' = 'planning'
    '04' = 'sdk conversion'
    '05' = 'package updates'
    '06' = 'multitargeting'
    '07' = 'web migration'
    '08' = 'completion report'
    '09' = 'debugging'
}

$seenSessions = @{}
$phaseAgg = @{}
$sourceLabelByPhase = @{}
$skipStats = [ordered]@{
    parseError      = 0
    duplicate       = 0
    missingLabel    = 0
    nonNumbered     = 0
}
$skipExamples = [ordered]@{
    parseError      = New-Object System.Collections.Generic.List[string]
    duplicate       = New-Object System.Collections.Generic.List[string]
    missingLabel    = New-Object System.Collections.Generic.List[string]
    nonNumbered     = New-Object System.Collections.Generic.List[string]
}

Get-ChildItem -LiteralPath $tokenDir -Filter '*.json' -File |
    Sort-Object Name |
    ForEach-Object {
        try {
            $report = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        } catch {
            $skipStats.parseError += 1
            if ($skipExamples.parseError.Count -lt 3) { $skipExamples.parseError.Add($_.Name) }
            return
        }

        $sessionId = [string]$report.session_id
        if ($sessionId -and $seenSessions.ContainsKey($sessionId)) {
            $skipStats.duplicate += 1
            if ($skipExamples.duplicate.Count -lt 3) { $skipExamples.duplicate.Add($_.Name) }
            return
        }
        if ($sessionId) { $seenSessions[$sessionId] = $true }

        $nameLabel = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
        if ($nameLabel -match '^(?<label>.+?)__[^_]+$') {
            $nameLabel = $Matches['label']
        }
        $label = if ([string]::IsNullOrWhiteSpace($nameLabel)) { [string]$report.label } else { $nameLabel }
        if ([string]::IsNullOrWhiteSpace($label)) {
            $skipStats.missingLabel += 1
            if ($skipExamples.missingLabel.Count -lt 3) { $skipExamples.missingLabel.Add($_.Name) }
            return
        }
        if ($label -notmatch '^\s*(\d{1,2})(?:\D|$)') {
            $skipStats.nonNumbered += 1
            if ($skipExamples.nonNumbered.Count -lt 3) { $skipExamples.nonNumbered.Add($_.Name) }
            return
        }

        $phase = $Matches[1].PadLeft(2, '0')
        if (-not $phaseAgg.ContainsKey($phase)) {
            $phaseAgg[$phase] = [ordered]@{
                fresh  = [long]0
                cached = [long]0
                write  = [long]0
                output = [long]0
            }
        }

        $phaseAgg[$phase].fresh  += [long]$report.totals.input_tokens_fresh
        $phaseAgg[$phase].cached += [long]$report.totals.cached_input_tokens
        $phaseAgg[$phase].write  += [long]$report.totals.cache_write_tokens
        $phaseAgg[$phase].output += [long]$report.totals.output_tokens

        if (-not $sourceLabelByPhase.ContainsKey($phase)) {
            $sourceLabelByPhase[$phase] = $label
        }
    }

if ($skipStats.parseError -gt 0) {
    Write-Warning ("Skipped {0} file(s) due to JSON parse errors. Example(s): {1}" -f $skipStats.parseError, ($skipExamples.parseError -join ', '))
}
if ($skipStats.duplicate -gt 0) {
    Write-Warning ("Skipped {0} duplicate session file(s) based on session_id. Example(s): {1}" -f $skipStats.duplicate, ($skipExamples.duplicate -join ', '))
}
if ($skipStats.missingLabel -gt 0) {
    Write-Warning ("Skipped {0} file(s) with missing label data. Example(s): {1}" -f $skipStats.missingLabel, ($skipExamples.missingLabel -join ', '))
}
if ($skipStats.nonNumbered -gt 0) {
    Write-Warning ("Skipped {0} file(s) whose labels do not start with a phase number. Example(s): {1}" -f $skipStats.nonNumbered, ($skipExamples.nonNumbered -join ', '))
}

if ($phaseAgg.Count -eq 0) {
    throw 'No numbered phase labels were found in token-usage JSON files.'
}

$rows = foreach ($phase in ($phaseAgg.Keys | Sort-Object -Descending)) {
    $displayBase = if ($phaseLabelOverrides.ContainsKey($phase)) {
        [string]$phaseLabelOverrides[$phase]
    } else {
        $raw = [string]$sourceLabelByPhase[$phase]
        $short = ($raw -replace '^\s*\d{1,2}[-_\s]*', '').Trim()
        $short = $short -replace '[-_]+', ' '
        if ([string]::IsNullOrWhiteSpace($short)) { "phase $phase" } else { $short }
    }
    $display = '{0} {1}' -f $phase, $displayBase

    $fresh = [long]$phaseAgg[$phase].fresh
    $cached = [long]$phaseAgg[$phase].cached
    $write = [long]$phaseAgg[$phase].write
    $output = [long]$phaseAgg[$phase].output
    $total = $fresh + $cached + $write + $output

    [pscustomobject]@{
        Label  = $display
        Fresh  = $fresh
        Cached = $cached
        Write  = $write
        Output = $output
        Total  = $total
    }
}

$grandFresh = [long](($rows | Measure-Object -Property Fresh -Sum).Sum)
$grandCached = [long](($rows | Measure-Object -Property Cached -Sum).Sum)
$grandWrite = [long](($rows | Measure-Object -Property Write -Sum).Sum)
$grandOutput = [long](($rows | Measure-Object -Property Output -Sum).Sum)
$grandTotal = $grandFresh + $grandCached + $grandWrite + $grandOutput

$tickStep = 20000000.0
$maxTotal = [double](($rows | Measure-Object -Property Total -Maximum).Maximum)
$axisMax = [Math]::Ceiling(($maxTotal * 1.06) / $tickStep) * $tickStep
if ($axisMax -lt $tickStep) { $axisMax = $tickStep }

$bg = [System.Drawing.ColorTranslator]::FromHtml('#0d1117')
$panel = [System.Drawing.ColorTranslator]::FromHtml('#161b22')
$text = [System.Drawing.ColorTranslator]::FromHtml('#c9d1d9')
$muted = [System.Drawing.ColorTranslator]::FromHtml('#8b949e')
$freshC = [System.Drawing.ColorTranslator]::FromHtml('#1f6feb')
$cachedC = [System.Drawing.ColorTranslator]::FromHtml('#2ea043')
$writeC = [System.Drawing.ColorTranslator]::FromHtml('#bf8700')
$outputC = [System.Drawing.ColorTranslator]::FromHtml('#a371f7')

function New-StackSeries {
    param(
        [string]$Name,
        [System.Drawing.Color]$Color
    )
    $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series
    $series.Name = $Name
    $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::StackedBar
    $series.Color = $Color
    $series['PointWidth'] = '0.68'
    return $series
}

function Render-Chart {
    param(
        [int]$Width,
        [int]$Height,
        [string]$OutPath
    )

    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Width = $Width
    $chart.Height = $Height
    $chart.BackColor = $bg
    $chart.TextAntiAliasingQuality = 'High'

    $chartArea = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $chartArea.BackColor = $panel
    $chartArea.Position.Auto = $false
    $chartArea.Position.X = 8
    $chartArea.Position.Y = 18
    $chartArea.Position.Width = 88
    $chartArea.Position.Height = 74
    $chartArea.InnerPlotPosition.Auto = $false
    $chartArea.InnerPlotPosition.X = 10
    $chartArea.InnerPlotPosition.Y = 6
    $chartArea.InnerPlotPosition.Width = 86
    $chartArea.InnerPlotPosition.Height = 91

    $chartArea.AxisX.Interval = 1
    $chartArea.AxisX.LabelStyle.Interval = 1
    $chartArea.AxisX.IsLabelAutoFit = $false
    $chartArea.AxisX.LabelStyle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
    $chartArea.AxisX.LabelStyle.ForeColor = $text
    $chartArea.AxisX.MajorGrid.Enabled = $false
    $chartArea.AxisX.MajorTickMark.Enabled = $false
    $chartArea.AxisX.LineColor = $muted

    $chartArea.AxisY.IsLabelAutoFit = $false
    $chartArea.AxisY.LabelStyle.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $chartArea.AxisY.LabelStyle.ForeColor = $text
    $chartArea.AxisY.LabelStyle.Format = '#,##0,,"M"'
    $chartArea.AxisY.MajorGrid.Enabled = $false
    $chartArea.AxisY.MajorTickMark.Enabled = $true
    $chartArea.AxisY.MajorTickMark.LineColor = $muted
    $chartArea.AxisY.Interval = $tickStep
    $chartArea.AxisY.Minimum = 0
    $chartArea.AxisY.Maximum = $axisMax
    $chartArea.AxisY.LineColor = $muted
    $chartArea.AxisY.Title = 'Total Tokens (Millions)'
    $chartArea.AxisY.TitleFont = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
    $chartArea.AxisY.TitleForeColor = $text
    $chart.ChartAreas.Add($chartArea)

    $freshSeries = New-StackSeries ("Input (Fresh): {0}" -f (Format-M $grandFresh)) $freshC
    $cachedSeries = New-StackSeries ("Input (Cached): {0}" -f (Format-M $grandCached)) $cachedC
    $writeSeries = New-StackSeries ("Cache Write: {0}" -f (Format-M $grandWrite)) $writeC
    $outputSeries = New-StackSeries ("Output: {0}" -f (Format-M $grandOutput)) $outputC
    $labelSeries = New-StackSeries 'Total Label Anchor' ([System.Drawing.Color]::Transparent)
    $labelSeries.IsVisibleInLegend = $false

    foreach ($row in $rows) {
        $p1 = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $p1.SetValueY([double]$row.Fresh)
        $p1.AxisLabel = [string]$row.Label
        [void]$freshSeries.Points.Add($p1)

        $p2 = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $p2.SetValueY([double]$row.Cached)
        $p2.AxisLabel = [string]$row.Label
        [void]$cachedSeries.Points.Add($p2)

        $p3 = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $p3.SetValueY([double]$row.Write)
        $p3.AxisLabel = [string]$row.Label
        [void]$writeSeries.Points.Add($p3)

        $p4 = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $p4.SetValueY([double]$row.Output)
        $p4.AxisLabel = [string]$row.Label
        [void]$outputSeries.Points.Add($p4)

        $pl = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $pl.SetValueY(0)
        $pl.AxisLabel = [string]$row.Label
        $pl.Label = ('  {0}' -f (Format-M $row.Total))
        $pl.LabelForeColor = $text
        $pl.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
        $pl['BarLabelStyle'] = 'Left'
        [void]$labelSeries.Points.Add($pl)
    }

    $chart.Series.Add($freshSeries)
    $chart.Series.Add($cachedSeries)
    $chart.Series.Add($writeSeries)
    $chart.Series.Add($outputSeries)
    $chart.Series.Add($labelSeries)

    $legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend
    $legend.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Top
    $legend.Alignment = [System.Drawing.StringAlignment]::Center
    $legend.ForeColor = $text
    $legend.BackColor = $panel
    $legend.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $legend.IsTextAutoFit = $false
    $chart.Legends.Add($legend)

    $title = New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $title.Text = 'Copilot Token Usage by Phase Journey (Total Tokens)'
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
    $title.ForeColor = $text
    $title.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Top
    $chart.Titles.Add($title) | Out-Null

    $subtitle = New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $subtitle.Text = ('Total Tokens: {0}' -f (Format-M $grandTotal))
    $subtitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
    $subtitle.ForeColor = $text
    $subtitle.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Top
    $chart.Titles.Add($subtitle) | Out-Null

    $chart.SaveImage($OutPath, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png)
}

$outputs = New-Object System.Collections.Generic.List[string]

if ($Format -in @('both', 'wide')) {
    $widePath = Join-Path $tokenDir ("{0}.png" -f $OutputBaseName)
    Render-Chart -Width 1920 -Height 1080 -OutPath $widePath
    $outputs.Add($widePath)
}

if ($Format -in @('both', 'square')) {
    $squarePath = Join-Path $tokenDir ("{0}-square.png" -f $OutputBaseName)
    Render-Chart -Width 1400 -Height 1400 -OutPath $squarePath
    $outputs.Add($squarePath)
}

$outputs.ToArray()
