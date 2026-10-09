<#
  Measures the process GPU cost of a running target (by default xgame_desktop)
  with the same counters the Windows task manager reads:
  \GPU Engine(*)\Utilization Percentage.

  Two numbers matter and they are not the same thing:

    * app  - every engine instance whose instance name carries the target pid,
             summed per sample. This is "what this process asked the GPU to do".
    * busy - the busiest engine type over *all* processes (the task manager's
             own GPU card: whole-GPU, busiest engine). Reported for context.

  Usage:
    pwsh -File tool/gpu_sample.ps1 -ProcessName xgame_desktop -Seconds 20
    pwsh -File tool/gpu_sample.ps1 -Label "blur16" -Csv out.csv -Start

  -Start launches the Release build first and waits for its window; without it
  the script samples whatever is already running.
#>
param(
  [string]$ProcessName = 'xgame_desktop',
  [string]$Exe = "$PSScriptRoot\..\build\windows\x64\runner\Release\xgame_desktop.exe",
  [int]$Seconds = 20,
  [int]$WarmupSeconds = 12,
  [string]$Label = 'sample',
  [string]$Csv,
  [switch]$Start
)

$ErrorActionPreference = 'Stop'

function Get-CounterSet {
  $samples = Get-Counter '\GPU Engine(*)\Utilization Percentage' -MaxSamples 1 -ErrorAction Stop
  return $samples.CounterSamples
}

function New-Row($samples, [int]$targetPid) {
  $app = 0.0
  $byType = @{}
  $busyAll = 0.0
  $dwmBusy = 0.0
  foreach ($s in $samples) {
    $inst = $s.InstanceName
    $v = [double]$s.CookedValue
    $m = [regex]::Match($inst, 'engtype_(.*)$')
    if (-not $m.Success) { continue }
    $type = $m.Groups[1].Value
    if ($v -gt $busyAll) { $busyAll = $v }
    if ($inst -like "pid_$targetPid`_*") {
      $app += $v
      if ($byType.ContainsKey($type)) { $byType[$type] += $v } else { $byType[$type] = $v }
    }
  }
  return [pscustomobject]@{
    App   = [math]::Round($app, 2)
    Busy  = [math]::Round($busyAll, 2)
    Types = (($byType.GetEnumerator() | Sort-Object Value -Descending |
      Select-Object -First 4 | ForEach-Object { "$($_.Key)=$([math]::Round($_.Value,1))" }) -join ' ')
  }
}

if ($Start) {
  Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 500
  $full = (Resolve-Path $Exe).Path
  Start-Process -FilePath $full -WorkingDirectory (Split-Path $full) | Out-Null
  Write-Host "launched $full; waiting ${WarmupSeconds}s for boot"
  Start-Sleep -Seconds $WarmupSeconds
}

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { throw "no $ProcessName process" }
$targetPid = $proc.Id
$ws = [math]::Round($proc.WorkingSet64 / 1MB, 0)
Write-Host "== $Label == pid=$targetPid ws=${ws}MB =="

# A first read only primes the rate counters; PDH needs two collects.
Get-CounterSet | Out-Null

$rows = @()
for ($i = 1; $i -le $Seconds; $i++) {
  $row = New-Row (Get-CounterSet) $targetPid
  $row | Add-Member -NotePropertyName T -NotePropertyValue $i
  $rows += $row
  Write-Host ("t={0,3}s  app={1,6:N2}%  busiest={2,6:N2}%  {3}" -f $i, $row.App, $row.Busy, $row.Types)
}

$appVals = $rows | ForEach-Object { $_.App }
$stats = [pscustomobject]@{
  Label   = $Label
  Seconds = $Seconds
  AppMean = [math]::Round(($appVals | Measure-Object -Average).Average, 2)
  AppP95  = [math]::Round(($appVals | Sort-Object)[[int][math]::Floor($appVals.Count * 0.95)], 2)
  AppMax  = [math]::Round(($appVals | Measure-Object -Maximum).Maximum, 2)
  BusyMax = [math]::Round((($rows | ForEach-Object { $_.Busy }) | Measure-Object -Maximum).Maximum, 2)
}
Write-Host ("-- {0}: app mean {1}%  p95 {2}%  max {3}%   whole-GPU busiest max {4}%" -f `
  $stats.Label, $stats.AppMean, $stats.AppP95, $stats.AppMax, $stats.BusyMax)

if ($Csv) {
  $rows | Select-Object T, App, Busy, Types | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
  Write-Host "csv: $Csv"
}

