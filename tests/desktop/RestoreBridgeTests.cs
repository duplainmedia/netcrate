using System;
using System.IO;
using System.Linq;
using System.Threading;
using NetCrate.Setup;
class RestoreBridgeTests {
 static int Main(string[] args) {
  try {
   string root=Path.GetFullPath(args[0]);var service=new WindowsSetupService(args[1],Path.Combine(root,"Bridge","Setup"));
   var context=new RestoreRequest { RecoveryFile=Path.Combine(root,"recovery.json"),RepositoryPath=Path.Combine(root,"Moved drive","originals") };
   var r=service.InvokeRestoreAsync("ListBackups",context,CancellationToken.None).GetAwaiter().GetResult();
   if(!r.Succeeded||r.Items.Count!=2)throw new Exception("Native recovery bridge could not list completed backups: "+r.Message);
   var backup=r.Items[1];
   if(!backup.Project.EndsWith("日本語 [set]"))throw new Exception("PS5.1 to pinned PS7 corrupted Unicode metadata.");
   context.SnapshotId=backup.SnapshotId;context.RelativePath="nested [a]";
   r=service.InvokeRestoreAsync("ListBackupChildren",context,CancellationToken.None).GetAwaiter().GetResult();
   if(!r.Succeeded||!r.Items.Any(i=>i.Name=="café [1].txt"))throw new Exception("The native bridge corrupted a literal Unicode child.");
   context.RelativePath="nested [a]/café [1].txt";context.DestinationParent=Path.Combine(root,"Récupération 日本語");Directory.CreateDirectory(context.DestinationParent);
   r=service.InvokeRestoreAsync("RestoreSelection",context,CancellationToken.None).GetAwaiter().GetResult();
   if(!r.Succeeded||!r.RestoredPath.StartsWith(context.DestinationParent))throw new Exception("The native bridge corrupted the verified output location: "+r.Message);
   if(!File.ReadAllBytes(Path.Combine(r.RestoredPath,"café [1].txt")).SequenceEqual(new byte[]{1,2,3,4}))throw new Exception("The native bridge restored different file bytes.");
   context.RelativePath="binary.bin";
   r=service.InvokeRestoreAsync("RestoreSelection",context,CancellationToken.None).GetAwaiter().GetResult();
   if(!r.Succeeded||!File.ReadAllBytes(Path.Combine(r.RestoredPath,"binary.bin")).SequenceEqual(Enumerable.Range(0,256).Select(i=>(byte)i)))throw new Exception("The native bridge corrupted NUL or bytes 0..255.");
   if(Directory.GetFiles(Path.Combine(root,"Bridge","Setup"),"action-*.json").Length!=0)throw new Exception("The action bridge retained ephemeral input files.");
   if(Directory.Exists(Path.Combine(root,"Bridge","Engine")))throw new Exception("Independent recovery created installed state.");
   var rejected=service.InvokeRestoreAsync("ListBackups",new RestoreRequest { InstallationId="invalid" },CancellationToken.None).GetAwaiter().GetResult();
   if(rejected.Succeeded)throw new Exception("An unowned installed restore context was accepted.");
   Console.WriteLine("PASS: real Windows PowerShell 5.1 → pinned PowerShell 7 UTF8 metadata, literal children, verified bytes and output path; ephemeral inputs removed.");return 0;
  }catch(Exception e){Console.Error.WriteLine(e.Message);return 1;}
 }
}
