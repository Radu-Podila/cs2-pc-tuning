<#
  Saves or restores a complete "known good" CS2 setup.

  powershell -ExecutionPolicy Bypass -File perfect-state.ps1 save               (any time; CS2 closed is best)
  powershell -ExecutionPolicy Bypass -File perfect-state.ps1 list
  powershell -ExecutionPolicy Bypass -File perfect-state.ps1 restore            (latest save; admin; CS2 closed)
  powershell -ExecutionPolicy Bypass -File perfect-state.ps1 restore <folder>   (a specific save)
  powershell -ExecutionPolicy Bypass -File perfect-state.ps1 restore -WithConvars   (also crosshair/sens/etc.; Steam closed)

  Saved: NVIDIA driver settings database, cs2_video.txt, CS2 convars, prolasso.ini,
         Windows mouse acceleration, core parking (both plans), launch options (for reference),
         lab state.json, a readable summary.
  Restore always saves the current state first into a new folder, so it can be undone with another restore.
#>
param(
  [Parameter(Position=0)][ValidateSet('save','list','restore')][string]$Command = 'list',
  [Parameter(Position=1)][string]$From,
  [switch]$WithConvars
)
$ErrorActionPreference = 'Stop'
$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root  = Join-Path $Here 'saved-states'
$Drs   = 'C:\ProgramData\NVIDIA Corporation\Drs'
$Cfg   = 'C:\Program Files (x86)\Steam\userdata\177599511\730\local\cfg'
$Vdf   = 'C:\Program Files (x86)\Steam\userdata\177599511\config\localconfig.vdf'
$Ini   = 'C:\ProgramData\ProcessLasso\config\prolasso.ini'
$LassoExe = 'C:\Program Files\Process Lasso\processlasso.exe'
$NvSvc = 'NVDisplay.ContainerLocalSystem'
$DrsFiles = 'nvdrsdb0.bin','nvdrsdb1.bin','nvdrssel.bin'
$Convars  = 'cs2_machine_convars.vcfg','cs2_user_convars_0_slot0.vcfg'
$Plans = @{ 'Ultimate'='99999999-9999-9999-9999-999999999999'; 'Bitsum'='ca60a626-eb0e-40e9-ab1a-e53a7fccec73' }

Add-Type -Namespace W -Name Spi -MemberDefinition '[DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint a, uint b, int[] c, uint d);' -ErrorAction SilentlyContinue

function Launch-Options { $c = Get-Content $Vdf -Raw; $i = $c.IndexOf('"730"'); while ($i -ge 0) { $s = $c.Substring($i, [math]::Min(1500, $c.Length - $i)); if ($s -match '"LaunchOptions"\s+"([^"]*)"') { return $matches[1] }; $i = $c.IndexOf('"730"', $i + 5) }; '' }
function CpMin($guid) { $l = powercfg /query $guid sub_processor CPMINCORES | Select-String 'Current AC'; [Convert]::ToInt32(($l.Line -split ':')[1].Trim(), 16) }

function Save-State([string]$name) {
  $dir = Join-Path $Root $name
  New-Item -ItemType Directory -Force $dir | Out-Null
  foreach ($n in $DrsFiles) { Copy-Item (Join-Path $Drs $n) $dir }
  Copy-Item (Join-Path $Cfg 'cs2_video.txt') $dir
  foreach ($n in $Convars) { Copy-Item (Join-Path $Cfg $n) $dir }
  Copy-Item $Ini $dir
  $lab = Join-Path $Here 'state.json'; if (Test-Path $lab) { Copy-Item $lab (Join-Path $dir 'lab-state.json') }
  $m = Get-ItemProperty 'HKCU:\Control Panel\Mouse'
  $info = [ordered]@{
    saved         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    cs2Running    = [bool](Get-Process cs2 -ErrorAction SilentlyContinue)
    launchOptions = Launch-Options
    mouseSpeed    = $m.MouseSpeed; mouseThreshold1 = $m.MouseThreshold1; mouseThreshold2 = $m.MouseThreshold2; mouseSensitivity = $m.MouseSensitivity
    cpMinUltimate = CpMin $Plans.Ultimate; cpMinBitsum = CpMin $Plans.Bitsum
    activePlan    = (powercfg /getactivescheme)
    lassoAffinity = [string](Get-Content $Ini | Where-Object { $_ -like 'DefaultAffinitiesEx=*' } | Select-Object -First 1)
    nvidiaDriver  = [string](& nvidia-smi --query-gpu=driver_version --format=csv,noheader)
  }
  $info | ConvertTo-Json | Set-Content (Join-Path $dir 'summary.json') -Encoding UTF8
  $dir
}

switch ($Command) {
  'save' {
    $dir = Save-State ('perfect-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    "Saved to $dir"
    Get-Content (Join-Path $dir 'summary.json')
    if (Get-Process cs2 -ErrorAction SilentlyContinue) { 'Note: CS2 is running; in-game changes made in this session are written to disk when CS2 closes. Save again after closing it to include them.' }
  }
  'list' {
    if (-not (Test-Path $Root)) { 'No saves yet.'; return }
    Get-ChildItem $Root -Directory | Sort-Object Name | ForEach-Object { $s = Get-Content (Join-Path $_.FullName 'summary.json') -Raw | ConvertFrom-Json; '{0}  saved {1}' -f $_.Name, $s.saved }
  }
  'restore' {
    if (Get-Process cs2 -ErrorAction SilentlyContinue) { throw 'CS2 is running. Close it first; nothing was changed.' }
    if ($WithConvars -and (Get-Process steam -ErrorAction SilentlyContinue)) { throw 'Close Steam first (convars sync with Steam Cloud); nothing was changed.' }
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as Administrator; nothing was changed.' }
    $src = if ($From) { (Resolve-Path $From).Path } else { (Get-ChildItem $Root -Directory | Where-Object { $_.Name -like 'perfect-*' } | Sort-Object Name | Select-Object -Last 1).FullName }
    if (-not $src) { throw 'No save found.' }
    $s = Get-Content (Join-Path $src 'summary.json') -Raw | ConvertFrom-Json
    "Restoring $src (saved $($s.saved))"
    $undo = Save-State ('before-restore-' + (Get-Date -Format 'yyyyMMdd-HHmmss')); "Current state saved to $undo"

    Stop-Service $NvSvc -Force
    try { foreach ($n in $DrsFiles) { Copy-Item (Join-Path $src $n) (Join-Path $Drs $n) -Force } } finally { Start-Service $NvSvc }
    'NVIDIA settings restored.'
    Copy-Item (Join-Path $src 'cs2_video.txt') (Join-Path $Cfg 'cs2_video.txt') -Force; 'cs2_video.txt restored.'
    if ($WithConvars) { foreach ($n in $Convars) { Copy-Item (Join-Path $src $n) (Join-Path $Cfg $n) -Force }; 'Convars restored.' }

    $gui = [bool](Get-Process processlasso -ErrorAction SilentlyContinue)
    Get-Process processlasso -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Service ProcessGovernor -Force
    try { Copy-Item (Join-Path $src 'prolasso.ini') $Ini -Force } finally { Start-Service ProcessGovernor; if ($gui) { Start-Process $LassoExe } }
    'Process Lasso config restored.'

    Set-ItemProperty 'HKCU:\Control Panel\Mouse' -Name MouseSpeed -Value ([string]$s.mouseSpeed)
    Set-ItemProperty 'HKCU:\Control Panel\Mouse' -Name MouseThreshold1 -Value ([string]$s.mouseThreshold1)
    Set-ItemProperty 'HKCU:\Control Panel\Mouse' -Name MouseThreshold2 -Value ([string]$s.mouseThreshold2)
    [void][W.Spi]::SystemParametersInfo(0x0004, 0, [int[]]([int]$s.mouseThreshold1, [int]$s.mouseThreshold2, [int]$s.mouseSpeed), 0x03)
    'Mouse acceleration restored.'

    powercfg /setacvalueindex $Plans.Ultimate sub_processor CPMINCORES $s.cpMinUltimate
    powercfg /setacvalueindex $Plans.Bitsum   sub_processor CPMINCORES $s.cpMinBitsum
    powercfg /setactive scheme_current
    'Core parking restored.'
    & nvidia-smi -rgc | Out-Null; 'GPU clock lock cleared.'
    if (Test-Path (Join-Path $src 'lab-state.json')) { Copy-Item (Join-Path $src 'lab-state.json') (Join-Path $Here 'state.json') -Force }

    $now = Launch-Options
    if ($now -ne $s.launchOptions) { "Launch options differ. Set them in Steam > CS2 > Properties to:`n  $($s.launchOptions)" } else { 'Launch options already match.' }
    "Undo with: powershell -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" restore `"$undo`""
  }
}
