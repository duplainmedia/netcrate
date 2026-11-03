Set-StrictMode -Version Latest
function Get-NetCrateVersion([string]$Root) {
    $value = [IO.File]::ReadAllText((Join-Path $Root 'VERSION')).TrimEnd("`r", "`n")
    if ($value -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'VERSION must contain three canonical numeric components.' }
    foreach ($part in $value.Split('.')) {
        $number = 0
        if (-not [int]::TryParse($part, [ref]$number) -or $number -gt 65534) { throw 'VERSION component exceeds 65534.' }
    }
    [pscustomobject]@{ Product = $value; Windows = "$value.0" }
}
function Assert-NetCrateTag($Version, [string]$Tag) {
    if (-not [String]::Equals($Tag, ('v' + $Version.Product), [StringComparison]::Ordinal)) { throw "Tag $Tag does not match VERSION $($Version.Product)." }
}
function Get-NetCrateManifestVersion([string]$Path) {
    if (-not ('NetCrateVersionResource' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class NetCrateVersionResource {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr LoadLibraryEx(string name, IntPtr file, uint flags);
 [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
 [DllImport("kernel32.dll", SetLastError=true)] static extern uint SizeofResource(IntPtr module, IntPtr resource);
 [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
 [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr LockResource(IntPtr resource);
 [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
 public static string Read(string path) {
  IntPtr m=LoadLibraryEx(path, IntPtr.Zero, 2); if(m==IntPtr.Zero) throw new Win32Exception();
  try { IntPtr r=FindResource(m,(IntPtr)1,(IntPtr)24); if(r==IntPtr.Zero) throw new Win32Exception();
   uint size=SizeofResource(m,r); IntPtr p=LockResource(LoadResource(m,r)); if(p==IntPtr.Zero || size==0) throw new Win32Exception();
   byte[] bytes=new byte[size]; Marshal.Copy(p,bytes,0,(int)size); return Encoding.UTF8.GetString(bytes).TrimStart('\uFEFF');
  } finally { FreeLibrary(m); }
 }
}
'@
    }
    [xml]$manifest = [NetCrateVersionResource]::Read([IO.Path]::GetFullPath($Path))
    $identity = $manifest.SelectSingleNode("/*[local-name()='assembly']/*[local-name()='assemblyIdentity']")
    if ($null -eq $identity) { throw 'Embedded manifest identity is missing.' }
    return $identity.GetAttribute('version')
}
function Assert-NetCrateExecutable([string]$Path, $Version) {
    $full = [IO.Path]::GetFullPath($Path)
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($full))
    $info = $assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute], $false)
    $file = [Diagnostics.FileVersionInfo]::GetVersionInfo($full)
    if (-not [String]::Equals($assembly.GetName().Version.ToString(), $Version.Windows, [StringComparison]::Ordinal) -or -not [String]::Equals($file.FileVersion, $Version.Windows, [StringComparison]::Ordinal) -or $info.Count -ne 1 -or -not [String]::Equals($info[0].InformationalVersion, $Version.Product, [StringComparison]::Ordinal) -or -not [String]::Equals((Get-NetCrateManifestVersion $full), $Version.Windows, [StringComparison]::Ordinal)) { throw 'Executable version metadata does not match VERSION; rebuild before packaging.' }
}
Export-ModuleMember -Function Get-NetCrateVersion, Assert-NetCrateTag, Get-NetCrateManifestVersion, Assert-NetCrateExecutable
