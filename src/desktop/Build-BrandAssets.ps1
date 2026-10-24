# Package the approved standalone crate with transparency; no background tile.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$assets=Join-Path $PSScriptRoot 'Assets'
$source=Join-Path $assets 'NetCrate-Crate-Transparent.png'
if(-not(Test-Path -LiteralPath $source)){throw 'Approved NetCrate artwork is missing.'}
$board=[Drawing.Bitmap]::new($source)
$tile=[Drawing.Bitmap]::new(512,512,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g=[Drawing.Graphics]::FromImage($tile)
try{
 $g.Clear([Drawing.Color]::Transparent)
 $g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
 $g.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
 # Keep every transparent gap and the approved square canvas. Do not add a plate.
 if($board.Width -ne $board.Height -or $board.GetPixel(0,0).A -ne 0){throw 'Expected the approved transparent square logo asset.'}
 $g.DrawImage($board,[Drawing.Rectangle]::new(0,0,512,512),[Drawing.Rectangle]::new(0,0,$board.Width,$board.Height),[Drawing.GraphicsUnit]::Pixel)
 $tile.Save((Join-Path $assets 'NetCrate-AppIcon.png'),[Drawing.Imaging.ImageFormat]::Png)
 $payloads=@(foreach($dimension in @(16,20,24,32,40,48,64,128,256)){
  $small=[Drawing.Bitmap]::new($dimension,$dimension,[Drawing.Imaging.PixelFormat]::Format32bppArgb);$sg=[Drawing.Graphics]::FromImage($small);$ms=[IO.MemoryStream]::new()
  try{$sg.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic;$sg.DrawImage($tile,0,0,$dimension,$dimension);$small.Save($ms,[Drawing.Imaging.ImageFormat]::Png);[pscustomobject]@{Size=$dimension;Bytes=$ms.ToArray()}}finally{$sg.Dispose();$small.Dispose();$ms.Dispose()}
 })
 $file=[IO.File]::Create((Join-Path $PSScriptRoot 'NetCrate.ico'));$writer=[IO.BinaryWriter]::new($file)
 try{
  $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$payloads.Count);$offset=6+16*$payloads.Count
  foreach($entry in $payloads){$dimension=if($entry.Size -eq 256){0}else{$entry.Size};$writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0);$writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$entry.Bytes.Length);$writer.Write([uint32]$offset);$offset+=$entry.Bytes.Length}
  foreach($entry in $payloads){$writer.Write([byte[]]$entry.Bytes)}
 }finally{$writer.Dispose();$file.Dispose()}
}finally{$g.Dispose();$tile.Dispose();$board.Dispose()}
'Packaged approved NetCrate artwork in nine native icon sizes.'
