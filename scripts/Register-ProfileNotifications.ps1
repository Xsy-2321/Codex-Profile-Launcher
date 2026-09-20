param([Parameter(Mandatory)][string]$Runtime)
$ErrorActionPreference='Stop'
$identity=Get-Content -Raw -LiteralPath (Join-Path $Runtime 'resources\profile-identity.json') | ConvertFrom-Json
$exe=Join-Path $Runtime 'ChatGPT.exe'
$arguments='--user-data-dir="'+(Join-Path $identity.profileRoot 'web-data')+'" --profile-fresh-start'
$link=Join-Path ([Environment]::GetFolderPath('Programs')) ('Codex - '+$identity.label+'.lnk')
$shell=New-Object -ComObject WScript.Shell
$shortcut=$shell.CreateShortcut($link)
$shortcut.TargetPath=$exe
$shortcut.Arguments=$arguments
$shortcut.WorkingDirectory=$identity.profileRoot
$shortcut.IconLocation=(Join-Path $Runtime 'resources\icon-chatgpt.ico')+',0'
$shortcut.Description='Codex '+$identity.label+' notification entry'
$shortcut.Save()
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class ProfileShortcut {
  [StructLayout(LayoutKind.Sequential, Pack=4)] public struct Key { public Guid fmtid; public uint pid; public Key(uint id){fmtid=new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");pid=id;} }
  [StructLayout(LayoutKind.Explicit,Size=24)] public struct Value { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr ptr; }
  [ComImport,Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface Store {
    uint GetCount(); void GetAt(uint i,out Key key); void GetValue(ref Key key,out Value value); void SetValue(ref Key key,ref Value value); void Commit();
  }
  public static void Set(string file,string id,string clsid){
    object link=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
    try {
      ((IPersistFile)link).Load(file,2); var store=(Store)link;
      var k=new Key(5); var v=new Value{vt=31,ptr=Marshal.StringToCoTaskMemUni(id)};
      try{store.SetValue(ref k,ref v);}finally{Marshal.FreeCoTaskMem(v.ptr);}
      k=new Key(26);v=new Value{vt=72,ptr=Marshal.AllocCoTaskMem(16)};
      try{Marshal.StructureToPtr(new Guid(clsid),v.ptr,false);store.SetValue(ref k,ref v);}finally{Marshal.FreeCoTaskMem(v.ptr);}
      store.Commit();((IPersistFile)link).Save(file,true);
    }finally{Marshal.FinalReleaseComObject(link);}
  }
}
'@
[ProfileShortcut]::Set($link,$identity.appId,$identity.clsid)
$key='HKCU:\Software\Classes\AppUserModelId\'+$identity.appId
New-Item -Path $key -Force | Out-Null
New-ItemProperty -Path $key -Name DisplayName -Value ('Codex - '+$identity.label) -PropertyType String -Force | Out-Null
New-ItemProperty -Path $key -Name CustomActivator -Value $identity.clsid -PropertyType String -Force | Out-Null
$server='HKCU:\Software\Classes\CLSID\'+$identity.clsid+'\LocalServer32'
New-Item -Path $server -Force | Out-Null
Set-Item -Path $server -Value ('"'+$exe+'" '+$arguments)
[pscustomobject]@{Shortcut=$link;AppId=$identity.appId;CLSID=$identity.clsid;Executable=$exe}
