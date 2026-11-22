<#
  CS2 NVIDIA Lab - reversible experimental driver settings, for cs2.exe's profile only.

  powershell -ExecutionPolicy Bypass -File cs2-nv.ps1 list
  powershell -ExecutionPolicy Bypass -File cs2-nv.ps1 status
  powershell -ExecutionPolicy Bypass -File cs2-nv.ps1 apply <name> [<name>...]   (admin, CS2 closed)
  powershell -ExecutionPolicy Bypass -File cs2-nv.ps1 apply <name> -WhatIf       (shows the plan, writes nothing)
  powershell -ExecutionPolicy Bypass -File cs2-nv.ps1 revert <name> [<name>...]  (admin, CS2 closed)
  powershell -ExecutionPolicy Bypass -File cs2-nv.ps1 restore                    (admin, CS2 closed)
  powershell -ExecutionPolicy Bypass -File cs2-nv.ps1 selftest                   (read-only)

  Original values are stored in state.json the first time a setting is touched.
  A copy of the driver's settings database goes to backup\ before the first write.
#>
param(
  [Parameter(Position=0)][ValidateSet('list','status','apply','revert','restore','selftest')][string]$Command = 'status',
  [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$Names,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$Exe   = 'cs2.exe'
$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$State = Join-Path $Here 'state.json'
$Drs   = 'C:\ProgramData\NVIDIA Corporation\Drs'

# Each entry changes one or two DWORD settings. Risk reflects how easily it can hurt, not how much it helps.
$Catalog = [ordered]@{
  'os-vrr-off'      = @{ Risk='low';    Why='Denies OS VRR for CS2 (matches your G-SYNC off setup).';              Set=@(,@(0x00A879FF, 1)) }
  'no-app-stats'    = @{ Risk='low';    Why='Disables NVIDIA App statistics for CS2.';                             Set=@(,@(0x809D5F60, 0x10000000)) }
  'foreground-force'= @{ Risk='low';    Why='Driver always treats CS2 as foreground.';                             Set=@(,@(0x0078EEE8, 1)) }
  'cmd-queue-low'   = @{ Risk='medium'; Why='Smaller pending command queue. May cut queueing, may cost FPS.';      Set=@(,@(0x00C63A79, 1)) }
  'present-async'   = @{ Risk='medium'; Why='Forces async present. Whether DX11 honours this DX10 key is unknown.';Set=@(,@(0x0005F512, 0x89624578)) }
  'present-sync'    = @{ Risk='medium'; Why='Forces sync present (the opposite test).';                            Set=@(,@(0x0005F512, 0x53855200)) }
  'shader-threads-1'= @{ Risk='medium'; Why='NVIDIA preset for CS2 is 4. Less background compile, maybe more stutter.'; Set=@(,@(0x00313537, 1)) }
  'fastsync'        = @{ Risk='high';   Why='Fast Sync: no tearing, needs FPS well above 360. Can stutter.';       Set=@(@(0x00A879CF, 0x18888888), @(0x0045AB1F, 1)) }
  'rbar-off'        = @{ Risk='medium'; Why='Turns off forced rBAR for CS2 only. ID is from memory; confirm in Profile Inspector.'; Set=@(,@(0x000F00BA, 0)) }
}
$Ultra = 'os-vrr-off','no-app-stats','foreground-force','cmd-queue-low'

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Collections.Generic; using System.Text;
public class NvRow { public uint Id; public uint Type; public uint Loc; public uint Cur; }
public static class NvDrs {
  [DllImport("nvapi64.dll", EntryPoint="nvapi_QueryInterface", CallingConvention=CallingConvention.Cdecl)] static extern IntPtr QI(uint id);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D0();
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DOut(out IntPtr a);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D1(IntPtr a);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DFind(IntPtr s, IntPtr name, out IntPtr prof, IntPtr app);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DEnum(IntPtr s, IntPtr p, uint start, ref uint count, IntPtr buf);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DSet(IntPtr s, IntPtr p, IntPtr setting);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DDel(IntPtr s, IntPtr p, uint id);
  const uint INIT=0x0150E828, CREATE=0x0694D52E, DESTROY=0xDAD9CFF8, LOAD=0x375DBD6B, SAVE=0xFCBC7E14,
             FINDAPP=0xEEE566B2, ENUM=0xAE3039DA, SET=0x577DD202, DEL=0xE4A26362;
  const int SETSZ=12320, APPSZ=12296;
  static T F<T>(uint id) where T: class { IntPtr p=QI(id); if(p==IntPtr.Zero) throw new Exception("NVAPI function missing: 0x"+id.ToString("X8")); return (T)(object)Marshal.GetDelegateForFunctionPointer(p,typeof(T)); }
  static IntPtr Zeroed(int n){ IntPtr p=Marshal.AllocHGlobal(n); for(int i=0;i<n;i+=4) Marshal.WriteInt32(p,i,0); return p; }
  static void Chk(int r,string what){ if(r!=0) throw new Exception(what+" failed, NVAPI status "+r); }
  static IntPtr session, profile;
  public static string[] Verify(){ var l=new List<string>(); foreach(uint id in new uint[]{INIT,CREATE,DESTROY,LOAD,SAVE,FINDAPP,ENUM,SET,DEL}) l.Add("0x"+id.ToString("X8")+" "+(QI(id)!=IntPtr.Zero?"ok":"MISSING")); return l.ToArray(); }
  public static void Open(string exe){
    Chk(F<D0>(INIT)(),"Initialize"); Chk(F<DOut>(CREATE)(out session),"CreateSession"); Chk(F<D1>(LOAD)(session),"LoadSettings");
    IntPtr name=Zeroed(4096); byte[] b=Encoding.Unicode.GetBytes(exe); Marshal.Copy(b,0,name,b.Length);
    IntPtr app=Zeroed(APPSZ); Marshal.WriteInt32(app,0,APPSZ|(1<<16));
    Chk(F<DFind>(FINDAPP)(session,name,out profile,app),"FindApplicationByName");
    Marshal.FreeHGlobal(name); Marshal.FreeHGlobal(app);
  }
  public static void Close(){ F<D1>(DESTROY)(session); }
  public static List<NvRow> Rows(){
    var res=new List<NvRow>(); var fn=F<DEnum>(ENUM); IntPtr buf=Marshal.AllocHGlobal(SETSZ*64); uint start=0;
    while(true){
      uint count=64;
      for(int i=0;i<64;i++){ IntPtr e=new IntPtr(buf.ToInt64()+i*SETSZ); for(int k=0;k<SETSZ;k+=4) Marshal.WriteInt32(e,k,0); Marshal.WriteInt32(e,0,SETSZ|(1<<16)); }
      int r=fn(session,profile,start,ref count,buf);
      if(r==-7) break; Chk(r,"EnumSettings");
      for(uint i=0;i<count;i++){ IntPtr e=new IntPtr(buf.ToInt64()+i*SETSZ); var w=new NvRow();
        w.Id=(uint)Marshal.ReadInt32(e,4100); w.Type=(uint)Marshal.ReadInt32(e,4104); w.Loc=(uint)Marshal.ReadInt32(e,4108); w.Cur=(uint)Marshal.ReadInt32(e,8220); res.Add(w); }
      start+=count; if(count<64) break;
    }
    Marshal.FreeHGlobal(buf); return res;
  }
  public static void SetDword(uint id,uint val){
    IntPtr s=Zeroed(SETSZ); Marshal.WriteInt32(s,0,SETSZ|(1<<16)); Marshal.WriteInt32(s,4100,(int)id); Marshal.WriteInt32(s,4104,0); Marshal.WriteInt32(s,8220,(int)val);
    int r=F<DSet>(SET)(session,profile,s); Marshal.FreeHGlobal(s); Chk(r,"SetSetting 0x"+id.ToString("X8"));
  }
  public static void Delete(uint id){ int r=F<DDel>(DEL)(session,profile,id); if(r!=0 && r!=-160) Chk(r,"DeleteProfileSetting 0x"+id.ToString("X8")); }
  public static void Save(){ Chk(F<D1>(SAVE)(session),"SaveSettings"); }
}
"@

function Hex([uint32]$v) { '0x{0:X8}' -f $v }
function U32($v) { [BitConverter]::ToUInt32([BitConverter]::GetBytes([int64]$v), 0) }
function Current { $m=@{}; foreach($r in [NvDrs]::Rows()){ if($r.Type -eq 0){ $m[$r.Id]=$r.Cur } }; $m }
function Load-State { if(Test-Path $State){ $o=@{}; (Get-Content $State -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $o[$_.Name]=$_.Value }; $o } else { @{} } }
function Save-State($s) { $s | ConvertTo-Json | Set-Content -Path $State -Encoding UTF8 }

function Assert-CanWrite {
  if(Get-Process cs2 -ErrorAction SilentlyContinue){ throw 'CS2 is running. Close it first; nothing was changed.' }
  $p=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){ throw 'Run PowerShell as Administrator; nothing was changed.' }
}
function Backup-Db {
  $dir=Join-Path $Here 'backup'
  if(Test-Path $dir){ return }
  New-Item -ItemType Directory -Force $dir | Out-Null
  Get-ChildItem $Drs -Filter 'nvdrs*.bin' | Copy-Item -Destination $dir
  "Driver settings database copied to $dir"
}
function Expand-Names($list) {
  $out=@(); foreach($n in $list){ if($n -eq 'ultra'){ $out+=$Ultra } elseif($Catalog.Contains($n)){ $out+=$n } else { throw "Unknown setting: $n (see: list)" } }
  $out | Select-Object -Unique
}

switch($Command){
  'list' {
    $Catalog.GetEnumerator() | ForEach-Object { '{0,-18} {1,-7} {2}' -f $_.Key,$_.Value.Risk,$_.Value.Why }
    ''; "ultra = " + ($Ultra -join ', ')
  }
  'selftest' {
    [NvDrs]::Verify()
    [NvDrs]::Open($Exe); try { $c=Current; "profile read ok: $($c.Count) DWORD settings on $Exe" } finally { [NvDrs]::Close() }
    "state file: " + (Test-Path $State)
  }
  'status' {
    $st=Load-State
    [NvDrs]::Open($Exe); try { $c=Current } finally { [NvDrs]::Close() }
    foreach($e in $Catalog.GetEnumerator()){
      $on=$true; $vals=@()
      foreach($pair in $e.Value.Set){ $id=U32 $pair[0]; $want=U32 $pair[1]; $has=$c.ContainsKey($id); if(-not $has -or $c[$id] -ne $want){ $on=$false }; $vals+=$(if($has){Hex $c[$id]}else{'not set'}) }
      '{0,-18} {1,-4} {2}' -f $e.Key,$(if($on){'ON'}else{'off'}),($vals -join ', ')
    }
    ''; "Settings with a saved original: $($st.Count)"
  }
  'apply' {
    if(-not $Names){ throw 'Name at least one setting (or: ultra). See: list' }
    $list=Expand-Names $Names
    if($list -contains 'present-async' -and $list -contains 'present-sync'){ throw 'present-async and present-sync conflict; pick one.' }
    if(-not $WhatIf){ Assert-CanWrite }
    [NvDrs]::Open($Exe)
    try {
      $c=Current; $st=Load-State
      foreach($n in $list){ foreach($pair in $Catalog[$n].Set){
        $id=U32 $pair[0]; $val=U32 $pair[1]; $k=Hex $id
        $old=if($c.ContainsKey($id)){Hex $c[$id]}else{'not set'}
        "$n : $k  $old -> $(Hex $val)"
      } }
      if($WhatIf){ 'WhatIf: nothing was written.'; return }
      Backup-Db
      foreach($n in $list){ foreach($pair in $Catalog[$n].Set){
        $id=U32 $pair[0]; $val=U32 $pair[1]; $k=Hex $id
        if(-not $st.ContainsKey($k)){ $st[$k]=if($c.ContainsKey($id)){Hex $c[$id]}else{$null} }
        [NvDrs]::SetDword($id,$val)
      } }
      Save-State $st
      [NvDrs]::Save()
      $after=Current
      foreach($n in $list){ foreach($pair in $Catalog[$n].Set){ $id=U32 $pair[0]; if($after[$id] -ne (U32 $pair[1])){ throw "Verification failed for $(Hex $id)" } } }
      'Applied and verified. Start CS2 to use it.'
    } finally { [NvDrs]::Close() }
  }
  'revert' {
    if(-not $Names){ throw 'Name at least one setting (or: ultra). See: list' }
    Assert-CanWrite; $list=Expand-Names $Names
    [NvDrs]::Open($Exe)
    try {
      $st=Load-State
      foreach($n in $list){ foreach($pair in $Catalog[$n].Set){
        $id=U32 $pair[0]; $k=Hex $id
        if(-not $st.ContainsKey($k)){ "$n : $k was not changed by this tool"; continue }
        $o=$st[$k]; if($o){ [NvDrs]::SetDword($id,[Convert]::ToUInt32($o.Substring(2),16)) } else { [NvDrs]::Delete($id) }
        $st.Remove($k); "$n : $k -> $(if($o){$o}else{'not set'})"
      } }
      [NvDrs]::Save(); Save-State $st; 'Reverted.'
    } finally { [NvDrs]::Close() }
  }
  'restore' {
    Assert-CanWrite; $st=Load-State
    if($st.Count -eq 0){ 'Nothing to restore.'; return }
    [NvDrs]::Open($Exe)
    try {
      foreach($k in @($st.Keys)){ $id=[Convert]::ToUInt32($k.Substring(2),16); $o=$st[$k]
        if($o){ [NvDrs]::SetDword($id,[Convert]::ToUInt32($o.Substring(2),16)) } else { [NvDrs]::Delete($id) }
        "$k -> $(if($o){$o}else{'not set'})" }
      [NvDrs]::Save(); Remove-Item $State; 'All original values restored.'
    } finally { [NvDrs]::Close() }
  }
}
