<#
  Re-applies your own NVIDIA settings from a saved driver database onto the current (newer) driver,
  without copying the old database over it.

  powershell -ExecutionPolicy Bypass -File nv-migrate.ps1 dump              (read-only: lists user-set settings now)
  powershell -ExecutionPolicy Bypass -File nv-migrate.ps1 run [-WhatIf]     (admin, CS2 closed)
  powershell -ExecutionPolicy Bypass -File nv-migrate.ps1 export            (read-only: writes nvidia-settings.json)
  powershell -ExecutionPolicy Bypass -File nv-migrate.ps1 apply [-WhatIf]   (any NVIDIA PC; admin, CS2 closed)

  export / apply move your settings to another PC: export reads the user-set values of the global and CS2
  profiles from this driver into nvidia-settings.json; apply writes them onto the driver of the PC it runs on.
  Hardware-specific settings (Optimus/hybrid-GPU, OpenGL GPU choice) are left out.

  run:
    1. backs up the current database to migrate-<time>\current\
    2. loads the saved database briefly, reads every user-set (non-predefined) setting of the global and CS2 profiles
    3. puts the current database back
    4. applies those values onto the current driver, then verifies them
  -WhatIf stops after step 3 and only prints what would be applied.
#>
param(
  [Parameter(Position=0)][ValidateSet('dump','run','export','apply')][string]$Command = 'dump',
  [string]$From,
  [string]$Json,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$Here  = $PSScriptRoot
if (-not $From) { $From = Join-Path $Here 'saved-states\perfect-20261108-024908' }
if (-not $Json) { $Json = Join-Path $Here 'nvidia-settings.json' }
# Hybrid-GPU (Optimus) flags and the OpenGL GPU choice depend on the machine; never copied between PCs.
$HardwareSpecific = @(0x10F9DC80, 0x10F9DC81, 0x10F9DC84, 0x20D0F3E6)
$Drs   = 'C:\ProgramData\NVIDIA Corporation\Drs'
$NvSvc = 'NVDisplay.ContainerLocalSystem'
$DrsFiles = 'nvdrsdb0.bin','nvdrsdb1.bin','nvdrssel.bin'

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Collections.Generic; using System.Text;
public class NvSet { public string Profile; public uint Id; public uint Type; public uint Predef; public uint Dword; public string Str; }
public static class NvM {
  [DllImport("nvapi64.dll", EntryPoint="nvapi_QueryInterface", CallingConvention=CallingConvention.Cdecl)] static extern IntPtr QI(uint id);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D0();
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DOut(out IntPtr a);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D1(IntPtr a);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DOut2(IntPtr s, out IntPtr p);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DFind(IntPtr s, IntPtr name, out IntPtr prof, IntPtr app);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DEnum(IntPtr s, IntPtr p, uint start, ref uint count, IntPtr buf);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DSet(IntPtr s, IntPtr p, IntPtr setting);
  const int SETSZ=12320, APPSZ=12296;
  static T F<T>(uint id) where T: class { IntPtr p=QI(id); if(p==IntPtr.Zero) throw new Exception("NVAPI fn missing 0x"+id.ToString("X8")); return (T)(object)Marshal.GetDelegateForFunctionPointer(p,typeof(T)); }
  static IntPtr Z(int n){ IntPtr p=Marshal.AllocHGlobal(n); for(int i=0;i<n;i+=4) Marshal.WriteInt32(p,i,0); return p; }
  static void Chk(int r,string w){ if(r!=0) throw new Exception(w+" failed, NVAPI status "+r); }
  static IntPtr s, glob, cs2;
  public static void Open(){
    Chk(F<D0>(0x0150E828)(),"Initialize"); Chk(F<DOut>(0x0694D52E)(out s),"CreateSession"); Chk(F<D1>(0x375DBD6B)(s),"LoadSettings");
    Chk(F<DOut2>(0x617BFF9F)(s,out glob),"GetCurrentGlobalProfile");
    IntPtr name=Z(4096); byte[] b=Encoding.Unicode.GetBytes("cs2.exe"); Marshal.Copy(b,0,name,b.Length);
    IntPtr app=Z(APPSZ); Marshal.WriteInt32(app,0,APPSZ|(1<<16));
    Chk(F<DFind>(0xEEE566B2)(s,name,out cs2,app),"FindApplicationByName"); Marshal.FreeHGlobal(name); Marshal.FreeHGlobal(app);
  }
  public static void Close(){ F<D1>(0xDAD9CFF8)(s); }
  static IntPtr P(string which){ return which=="global" ? glob : cs2; }
  public static List<NvSet> Read(string which){
    var res=new List<NvSet>(); var fn=F<DEnum>(0xAE3039DA); IntPtr buf=Marshal.AllocHGlobal(SETSZ*64); uint start=0;
    while(true){
      uint count=64;
      for(int i=0;i<64;i++){ IntPtr e=new IntPtr(buf.ToInt64()+i*SETSZ); for(int k=0;k<SETSZ;k+=4) Marshal.WriteInt32(e,k,0); Marshal.WriteInt32(e,0,SETSZ|(1<<16)); }
      int r=fn(s,P(which),start,ref count,buf); if(r==-7) break; Chk(r,"EnumSettings");
      for(uint i=0;i<count;i++){ IntPtr e=new IntPtr(buf.ToInt64()+i*SETSZ); var x=new NvSet(); x.Profile=which;
        x.Id=(uint)Marshal.ReadInt32(e,4100); x.Type=(uint)Marshal.ReadInt32(e,4104); x.Predef=(uint)Marshal.ReadInt32(e,4112);
        x.Dword=(uint)Marshal.ReadInt32(e,8220); if(x.Type==3) x.Str=Marshal.PtrToStringUni(new IntPtr(e.ToInt64()+8220)); res.Add(x); }
      start+=count; if(count<64) break;
    }
    Marshal.FreeHGlobal(buf); return res;
  }
  public static void Set(string which, uint id, uint type, uint dword, string str){
    IntPtr e=Z(SETSZ); Marshal.WriteInt32(e,0,SETSZ|(1<<16)); Marshal.WriteInt32(e,4100,(int)id); Marshal.WriteInt32(e,4104,(int)type);
    if(type==0) Marshal.WriteInt32(e,8220,(int)dword); else { byte[] b=Encoding.Unicode.GetBytes(str??""); Marshal.Copy(b,0,new IntPtr(e.ToInt64()+8220),Math.Min(b.Length,4094)); }
    int r=F<DSet>(0x577DD202)(s,P(which),e); Marshal.FreeHGlobal(e); Chk(r,"SetSetting 0x"+id.ToString("X8"));
  }
  public static void Save(){ Chk(F<D1>(0xFCBC7E14)(s),"SaveSettings"); }
}
"@

function UserSet {
  [NvM]::Open()
  try {
    $seen = @{}
    @([NvM]::Read('global')) + @([NvM]::Read('cs2')) | Where-Object { $_.Predef -eq 0 -and ($_.Type -eq 0 -or $_.Type -eq 3) } |
      Where-Object { $k = "$($_.Profile)|$($_.Id)"; if ($seen.ContainsKey($k)) { $false } else { $seen[$k] = 1; $true } }
  }
  finally { [NvM]::Close() }
}
function Same($a, $b) { if (-not $a -or -not $b -or $a.Type -ne $b.Type) { return $false }; if ($a.Type -eq 0) { $a.Dword -eq $b.Dword } else { $a.Str -eq $b.Str } }
function Show($rows) { $rows | ForEach-Object { '{0,-6} 0x{1:X8} = {2}' -f $_.Profile, $_.Id, $(if ($_.Type -eq 0) { '0x{0:X8}' -f $_.Dword } else { "'" + $_.Str + "'" }) } }
function Swap-Db($dir) { Stop-Service $NvSvc -Force; try { foreach ($n in $DrsFiles) { Copy-Item (Join-Path $dir $n) (Join-Path $Drs $n) -Force } } finally { Start-Service $NvSvc }; Start-Sleep -Seconds 3 }

if ($Command -eq 'dump') { $u = @(UserSet); "User-set settings on the current driver: $($u.Count)"; Show $u; return }

if ($Command -eq 'export') {
  $u = @(UserSet | Where-Object { $HardwareSpecific -notcontains $_.Id })
  $doc = [ordered]@{
    exported = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    driver   = [string](& nvidia-smi --query-gpu=driver_version --format=csv,noheader)
    gpu      = [string](& nvidia-smi --query-gpu=name --format=csv,noheader)
    note     = 'User-set values of the global and cs2.exe NVIDIA profiles. Apply with: nv-migrate.ps1 apply'
    settings = @($u | ForEach-Object { [ordered]@{ profile = $_.Profile; id = ('0x{0:X8}' -f $_.Id); type = [int]$_.Type; value = $(if ($_.Type -eq 0) { '0x{0:X8}' -f $_.Dword } else { $_.Str }) } })
  }
  $doc | ConvertTo-Json -Depth 4 | Set-Content -Path $Json -Encoding UTF8
  "Exported $($u.Count) settings to $Json"
  return
}

if ($Command -eq 'apply') {
  if (-not (Test-Path $Json)) { throw "Settings file not found: $Json" }
  $doc = Get-Content $Json -Raw | ConvertFrom-Json
  $wanted = @($doc.settings | Where-Object { $HardwareSpecific -notcontains [Convert]::ToUInt32($_.id.Substring(2), 16) } | ForEach-Object {
    $x = New-Object NvSet; $x.Profile = $_.profile; $x.Id = [Convert]::ToUInt32($_.id.Substring(2), 16); $x.Type = [uint32]$_.type
    if ($x.Type -eq 0) { $x.Dword = [Convert]::ToUInt32($_.value.Substring(2), 16) } else { $x.Str = [string]$_.value }; $x })
  "Settings file: $($wanted.Count) settings, exported $($doc.exported) from driver $($doc.driver) ($($doc.gpu))."
  "This PC: driver $(& nvidia-smi --query-gpu=driver_version --format=csv,noheader) ($(& nvidia-smi --query-gpu=name --format=csv,noheader))."
  $now = @{}; foreach ($x in @(UserSet)) { $now["$($x.Profile)|$($x.Id)"] = $x }
  $todo = @($wanted | Where-Object { $o = $now["$($_.Profile)|$($_.Id)"]; -not (Same $o $_) })
  "To apply: $($todo.Count)"; Show $todo
  if ($WhatIf -or $todo.Count -eq 0) { if ($WhatIf) { 'WhatIf: nothing was applied.' } else { 'Nothing to do.' }; return }

  if (Get-Process cs2 -ErrorAction SilentlyContinue) { throw 'CS2 is running. Close it first; nothing was changed.' }
  $pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as Administrator; nothing was changed.' }
  $bk = Join-Path $Here ('apply-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '\current')
  New-Item -ItemType Directory -Force $bk | Out-Null
  foreach ($n in $DrsFiles) { Copy-Item (Join-Path $Drs $n) $bk }
  "Current NVIDIA database backed up to $bk"

  [NvM]::Open()
  try {
    $failed = @()
    foreach ($x in $todo) { try { [NvM]::Set($x.Profile, $x.Id, $x.Type, $x.Dword, $x.Str) } catch { $failed += ('{0} 0x{1:X8}: {2}' -f $x.Profile, $x.Id, $_.Exception.Message) } }
    [NvM]::Save()
  } finally { [NvM]::Close() }
  if ($failed) { 'Not applied (this driver refused them):'; $failed }
  $after = @{}; foreach ($x in @(UserSet)) { $after["$($x.Profile)|$($x.Id)"] = $x }
  $bad = @($todo | Where-Object { $a = $after["$($_.Profile)|$($_.Id)"]; -not (Same $a $_) })
  "Verified: $($todo.Count - $bad.Count) of $($todo.Count) applied."
  "Undo: as Administrator with CS2 closed: Stop-Service $NvSvc -Force; Copy-Item `"$bk\nvdrs*.bin`" `"$Drs`" -Force; Start-Service $NvSvc"
  return
}

if (Get-Process cs2 -ErrorAction SilentlyContinue) { throw 'CS2 is running. Close it first; nothing was changed.' }
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as Administrator; nothing was changed.' }
foreach ($n in $DrsFiles) { if (-not (Test-Path (Join-Path $From $n))) { throw "Saved database missing: $From\$n" } }

$work = Join-Path $Here ('migrate-' + (Get-Date -Format 'yyyyMMdd-HHmmss')); $cur = Join-Path $work 'current'
New-Item -ItemType Directory -Force $cur | Out-Null
foreach ($n in $DrsFiles) { Copy-Item (Join-Path $Drs $n) $cur }
"Current database backed up to $cur"

$wanted = $null
try {
  Swap-Db $From
  $wanted = @(UserSet)
  "Read $($wanted.Count) user-set settings from the saved database."
} finally {
  Swap-Db $cur
  'Current database is back in place.'
}
$wanted | Select-Object Profile, Id, Type, Dword, Str | ConvertTo-Json | Set-Content (Join-Path $work 'saved-user-settings.json') -Encoding UTF8
if ($wanted.Count -lt 10) { throw "Only $($wanted.Count) settings were read from the saved database; the driver may not have accepted it. Nothing was applied." }

$now = @{}; foreach ($x in @(UserSet)) { $now["$($x.Profile)|$($x.Id)"] = $x }
$todo = $wanted | Where-Object { $o = $now["$($_.Profile)|$($_.Id)"]; -not (Same $o $_) }
"To apply: $($todo.Count)"; Show $todo
if ($WhatIf) { 'WhatIf: nothing was applied.'; return }

[NvM]::Open()
try {
  $failed = @()
  foreach ($x in $todo) { try { [NvM]::Set($x.Profile, $x.Id, $x.Type, $x.Dword, $x.Str) } catch { $failed += ('{0} 0x{1:X8}: {2}' -f $x.Profile, $x.Id, $_.Exception.Message) } }
  [NvM]::Save()
} finally { [NvM]::Close() }
if ($failed) { 'Not applied (driver refused):'; $failed }

$after = @{}; foreach ($x in @(UserSet)) { $after["$($x.Profile)|$($x.Id)"] = $x }
$bad = $todo | Where-Object { $a = $after["$($_.Profile)|$($_.Id)"]; -not (Same $a $_) }
"Verified: $($todo.Count - @($bad).Count) of $($todo.Count) applied."
"Undo: stop $NvSvc, copy $cur\nvdrs*.bin back to $Drs, start the service (or use perfect-state.ps1 with that folder)."
