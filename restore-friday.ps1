<#
  Restores the Friday-night state from Windows' shadow copy of Sat 07 Nov 01:50.

  powershell -ExecutionPolicy Bypass -File restore-friday.ps1 -WhatIf          (shows the plan, writes nothing)
  powershell -ExecutionPolicy Bypass -File restore-friday.ps1                  (admin; CS2 closed)
  powershell -ExecutionPolicy Bypass -File restore-friday.ps1 -WithConvars     (also crosshair/radar/etc.; Steam closed)
  powershell -ExecutionPolicy Bypass -File restore-friday.ps1 -Undo <folder>   (puts back what a restore replaced)

  What it restores:
    1. NVIDIA driver settings database (all profiles, global included)
    2. CS2 video settings (cs2_video.txt)
    3. Process Lasso CPU affinity for cs2.exe / faceitclient.exe (only that one line)
    4. Optional: CS2 convars (crosshair, radar, viewmodel, ...)
  Also clears any GPU clock lock (nvidia-smi -rgc). Core parking is already 100%.
  Everything it replaces is copied first to before-restore-<time>\.
#>
param([switch]$WhatIf, [switch]$WithConvars, [string]$Undo)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Snap = Join-Path $Here 'friday-snapshot'
$Drs  = 'C:\ProgramData\NVIDIA Corporation\Drs'
$Cfg  = 'C:\Program Files (x86)\Steam\userdata\177599511\730\local\cfg'
$Ini  = 'C:\ProgramData\ProcessLasso\config\prolasso.ini'
$LassoExe = 'C:\Program Files\Process Lasso\processlasso.exe'
$NvSvc = 'NVDisplay.ContainerLocalSystem'
$DrsFiles = 'nvdrsdb0.bin','nvdrsdb1.bin','nvdrssel.bin'
$Convars  = 'cs2_machine_convars.vcfg','cs2_user_convars_0_slot0.vcfg'

function Assert-Ready([bool]$needSteamClosed) {
  if (Get-Process cs2 -ErrorAction SilentlyContinue) { throw 'CS2 is running. Close it first; nothing was changed.' }
  if ($needSteamClosed -and (Get-Process steam -ErrorAction SilentlyContinue)) { throw 'Close Steam first (convars sync with Steam Cloud); nothing was changed.' }
  $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as Administrator; nothing was changed.' }
}
function Affinity-Line($path) { (Get-Content -LiteralPath $path | Where-Object { $_ -like 'DefaultAffinitiesEx=*' } | Select-Object -First 1) }
function Copy-Drs($fromDir) {
  Stop-Service $NvSvc -Force
  try { foreach ($n in $DrsFiles) { Copy-Item -LiteralPath (Join-Path $fromDir $n) -Destination (Join-Path $Drs $n) -Force } }
  finally { Start-Service $NvSvc }
}
function Set-LassoAffinity([string]$line) {
  $gui = [bool](Get-Process processlasso -ErrorAction SilentlyContinue)
  Get-Process processlasso -ErrorAction SilentlyContinue | Stop-Process -Force
  Stop-Service ProcessGovernor -Force
  try {
    $lines = Get-Content -LiteralPath $Ini
    $lines = $lines | ForEach-Object { if ($_ -like 'DefaultAffinitiesEx=*') { $line } else { $_ } }
    Set-Content -LiteralPath $Ini -Value $lines -Encoding Ascii
  } finally {
    Start-Service ProcessGovernor
    if ($gui) { Start-Process $LassoExe }
  }
}

if ($Undo) {
  Assert-Ready $false
  $b = (Resolve-Path $Undo).Path
  "Undo from $b"
  if (Test-Path (Join-Path $b 'nvdrsdb0.bin')) { Copy-Drs $b; 'NVIDIA database put back.' }
  if (Test-Path (Join-Path $b 'cs2_video.txt')) { Copy-Item (Join-Path $b 'cs2_video.txt') (Join-Path $Cfg 'cs2_video.txt') -Force; 'cs2_video.txt put back.' }
  foreach ($n in $Convars) { if (Test-Path (Join-Path $b $n)) { Copy-Item (Join-Path $b $n) (Join-Path $Cfg $n) -Force; "$n put back." } }
  if (Test-Path (Join-Path $b 'affinity.txt')) { Set-LassoAffinity (Get-Content (Join-Path $b 'affinity.txt') -Raw).Trim(); 'Process Lasso affinity put back.' }
  return
}

foreach ($n in $DrsFiles + 'cs2_video.txt' + 'prolasso.ini') { if (-not (Test-Path (Join-Path $Snap $n))) { throw "Snapshot file missing: $n" } }
$snapAff = Affinity-Line (Join-Path $Snap 'prolasso.ini')
$nowAff  = Affinity-Line $Ini

'Plan:'
'  NVIDIA database   -> Friday-night copy (stops/starts ' + $NvSvc + '; screen may flicker)'
'  cs2_video.txt     -> Friday night: borderless fullscreen, MSAA off, 1600x1024'
"  Lasso affinity    -> $snapAff   (now: $nowAff)"
'  GPU clock lock    -> cleared (nvidia-smi -rgc)'
if ($WithConvars) { '  CS2 convars       -> Friday night (crosshair, radar, viewmodel, ...)' } else { '  CS2 convars       -> unchanged (add -WithConvars to restore them too)' }
if ($WhatIf) { 'WhatIf: nothing was written.'; return }

Assert-Ready $WithConvars
$bk = Join-Path $Here ('before-restore-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $bk | Out-Null
foreach ($n in $DrsFiles) { Copy-Item (Join-Path $Drs $n) $bk }
Copy-Item (Join-Path $Cfg 'cs2_video.txt') $bk
foreach ($n in $Convars) { Copy-Item (Join-Path $Cfg $n) $bk }
Set-Content (Join-Path $bk 'affinity.txt') $nowAff -Encoding Ascii
"Current state saved to $bk"

Copy-Drs $Snap; 'NVIDIA database restored.'
Copy-Item (Join-Path $Snap 'cs2_video.txt') (Join-Path $Cfg 'cs2_video.txt') -Force; 'cs2_video.txt restored.'
if ($WithConvars) { foreach ($n in $Convars) { Copy-Item (Join-Path $Snap $n) (Join-Path $Cfg $n) -Force }; 'Convars restored.' }
if ($snapAff -and $snapAff -ne $nowAff) { Set-LassoAffinity $snapAff; 'Process Lasso affinity restored.' }
& nvidia-smi -rgc | Out-Null; 'GPU clock lock cleared.'

'--- verify ---'
foreach ($n in $DrsFiles) { $a=(Get-FileHash (Join-Path $Snap $n)).Hash; $c=(Get-FileHash (Join-Path $Drs $n)).Hash; "{0}: {1}" -f $n, $(if ($a -eq $c) { 'match' } else { 'DIFFERENT (driver may have rewritten it)' }) }
"cs2_video.txt: " + $(if ((Get-FileHash (Join-Path $Snap 'cs2_video.txt')).Hash -eq (Get-FileHash (Join-Path $Cfg 'cs2_video.txt')).Hash) { 'match' } else { 'DIFFERENT' })
"Lasso: " + (Affinity-Line $Ini)
"Undo with: powershell -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Undo `"$bk`""
