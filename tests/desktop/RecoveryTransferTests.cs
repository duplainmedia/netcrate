using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using NetCrate.Setup;

public static class RecoveryTransferTests
{
    static void Check(bool value,string message){if(!value)throw new Exception(message);}
    [STAThread] public static void Main(string[] args)
    {
        var service=new RecoveryTransferService(args[0],args[1],args[2]);
        string root=args[3],engine=Path.Combine(root,"Engine"),storage=Path.Combine(root,"Storage");
        var clipboard=new FakeClipboard();var scheduler=new FakeScheduler();
        using(var lifetime=new RecoveryClipboardLifetime(clipboard,scheduler))
        using(var document=service.ExportContentsAsync(engine,CancellationToken.None).Result)
        {
            CheckBusyDispose(document,false);
            CheckBusyDispose(document,true);
            Check(clipboard.Writes==0,"Recovery export touched the user clipboard before an explicit copy action.");
            Check(document.Contents.Contains("netcrate-recovery") && document.ToString().IndexOf("Password",StringComparison.Ordinal)<0,"Export did not supply a dedicated redacted document.");
            lifetime.Copy(document);
            Check(clipboard.Payload.Text==document.Contents,"Clipboard omitted recovery fields.");
            foreach(string format in new[]{"CanIncludeInClipboardHistory","CanUploadToCloudClipboard"})
                Check(clipboard.Payload.Formats.ContainsKey(format) && BitConverter.ToUInt32(clipboard.Payload.Formats[format],0)==0 && clipboard.Payload.Formats[format].Length==4,"Clipboard history/cloud exclusion is not DWORD zero.");
            Check(scheduler.Delay==TimeSpan.FromMinutes(2),"Secret clipboard expiry was not two minutes.");
            clipboard.UserCopy("a later user copy");scheduler.Callback();
            Check(clipboard.Text=="a later user copy","Expiry erased the user's later clipboard copy.");
            lifetime.Copy(document);scheduler.Callback();Check(clipboard.Text==null,"Owned clipboard text did not expire.");
            lifetime.Copy(document);Check(lifetime.ClearNow() && clipboard.Text==null,"Clear now did not clear owned content.");
            lifetime.Copy(document);Action old=scheduler.Callback;lifetime.Copy(document);old();
            Check(clipboard.Text==document.Contents,"An old timer erased a new NetCrate copy.");
            var binding=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(engine,"repositories.json")));
            int reads=0;
            var pasteWindow=new RecoveryPasteWindow(service,delegate{reads++;return document.Contents;});
            Check(reads==0,"Opening paste recovery read the clipboard automatically.");
            var pastePanel=(StackPanel)pasteWindow.Content;
            foreach(var child in pastePanel.Children)if(child is Button && Convert.ToString(((Button)child).Content)=="Paste recovery details")((Button)child).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(reads==1,"Explicit paste did not read the recovery document.");
            var secretDocument=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(document.Contents);
            string password=Convert.ToString(((Dictionary<string,object>)secretDocument["Primary"])["Password"]);
            foreach(var child in pastePanel.Children)if(child is TextBlock)Check(!((TextBlock)child).Text.Contains(password),"Pasted keys appeared in ordinary UI text.");
            pasteWindow.Close();
            foreach(string invalidVersion in new[]{"{}","[]","true","false","\"1\"","\"private-version-canary\"","null","1.5"})
            {
                string invalid="{\"Version\":"+invalidVersion+",\"Kind\":\"netcrate-recovery\",\"Primary\":{\"Id\":\""+new string('a',64)+"\",\"Password\":\"private-password-canary\"},\"Results\":{\"Id\":\""+new string('b',64)+"\",\"Password\":\"private-password-canary\"}}";
                bool rejected=false;
                try{service.CreatePasteContext(invalid,storage);}catch(ArgumentException ex){rejected=ex.Message=="Paste a complete valid NetCrate recovery document." && ex.InnerException==null;}
                Check(rejected,"Malformed Version was accepted or did not produce sanitized validation.");
                var invalidWindow=new RecoveryPasteWindow(service,delegate{return invalid;});
                var invalidPanel=(StackPanel)invalidWindow.Content;bool showedError=false;
                foreach(var child in invalidPanel.Children)if(child is Button && Convert.ToString(((Button)child).Content)=="Paste recovery details")((Button)child).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                foreach(var child in invalidPanel.Children)if(child is TextBlock){string text=((TextBlock)child).Text;Check(!text.Contains("private-version-canary")&&!text.Contains("private-password-canary"),"Malformed pasted document leaked into UI status.");if(text=="Copy and paste a complete NetCrate recovery document.")showedError=true;}
                Check(showedError,"Malformed Version did not leave a recoverable paste validation message.");invalidWindow.Close();
            }
            using(var pasted=service.CreatePasteContext(document.Contents,Convert.ToString(binding["PrimaryPath"])))
            {
                Check(pasted.ToString().IndexOf("Password",StringComparison.Ordinal)<0,"Paste context ToString exposes plaintext.");
                var result=pasted.InvokeRestoreAsync("ListBackups",new RestoreRequest(),CancellationToken.None).Result;
                Check(result.Succeeded && result.Items.Count==1,"Pasted recovery did not list the real generated backup.");
                var children=pasted.InvokeRestoreAsync("ListBackupChildren",new RestoreRequest{SnapshotId=result.Items[0].SnapshotId},CancellationToken.None).Result;
                Check(children.Succeeded && children.Items.Count==1,"Pasted recovery could not browse the originals.");
                var restored=pasted.InvokeRestoreAsync("RestoreSelection",new RestoreRequest{SnapshotId=result.Items[0].SnapshotId,RelativePath="original.txt",DestinationParent=Path.Combine(root,"Recovered")},CancellationToken.None).Result;
                Check(restored.Succeeded && File.ReadAllText(Path.Combine(restored.RestoredPath,"original.txt"))=="recover my bytes","Pasted recovery did not restore verified original bytes.");
            }
            using(var wrong=service.CreatePasteContext(document.Contents.Replace(password,"wrong-private-canary"),Convert.ToString(binding["PrimaryPath"])))
            {
                var result=wrong.InvokeRestoreAsync("ListBackups",new RestoreRequest(),CancellationToken.None).Result;
                Check(!result.Succeeded && !result.Message.Contains("wrong-private-canary") && !result.Message.Contains(password),"Wrong-password recovery succeeded or leaked secrets in generic results.");
            }
            bool bad=false;try{service.CreatePasteContext("{\"secret\":\"must not echo\"}",storage);}catch(ArgumentException ex){bad=!ex.Message.Contains("must not echo");}
            Check(bad,"Invalid pasted document was accepted or echoed.");
            string suggested=service.SuggestSavePath(engine,storage);
            Check(Path.IsPathRooted(suggested) && !suggested.StartsWith(engine,StringComparison.OrdinalIgnoreCase) && !suggested.StartsWith(storage,StringComparison.OrdinalIgnoreCase) && !suggested.Contains("OneDrive"),"Default export is not an ordinary profile location outside state/storage.");
            string destination=Path.Combine(root,"Desktop export.netcrate");
            var save=service.SaveAsync(engine,destination,CancellationToken.None).Result;
            Check(save.Succeeded && save.SavedPath==Path.GetFullPath(destination),"Dedicated ordinary save failed.");
            string existing=File.ReadAllText(destination);
            Check(!service.SaveAsync(engine,destination,CancellationToken.None).Result.Succeeded && File.ReadAllText(destination)==existing,"Dedicated save overwrote existing destination.");
            foreach(string file in Directory.GetFiles(root,"*",SearchOption.AllDirectories))
            {
                if(file.EndsWith(".netcrate")||file.Contains("\\Secrets\\")||file.Contains("\\Storage\\")||file.EndsWith(".exe"))continue;
                string text=File.ReadAllText(file);
                Check(!text.Contains(password) && !text.Contains("wrong-private-canary"),"Recovery password persisted outside explicit export.");
            }
        }
        Check(clipboard.Text==null,"Disposing the clipboard lifetime left owned sensitive contents.");
        Console.WriteLine("PASS: dedicated native recovery export/save/paste, real restore, redaction, clipboard flags, expiry, stale timers, ownership, clear now, busy-dispose retry and malformed-version validation/UI cleanup.");
    }
    static void CheckBusyDispose(RecoveryDocument document,bool laterCopy)
    {
        var clipboard=new FakeClipboard();var scheduler=new FakeScheduler();var lifetime=new RecoveryClipboardLifetime(clipboard,scheduler);
        lifetime.Copy(document);clipboard.Busy=true;bool busy=false;
        try{lifetime.Dispose();}catch(Win32Exception){busy=true;}
        Check(busy,"Busy clipboard disposal did not expose its retryable failure.");
        clipboard.Busy=false;if(laterCopy)clipboard.UserCopy("new user copy after failed disposal");
        scheduler.Callback();
        Check(laterCopy?clipboard.Text=="new user copy after failed disposal":clipboard.Text==null,"Failed Dispose abandoned cleanup eligibility or erased a later user copy.");
        lifetime.Dispose();
    }
    sealed class FakeClipboard:IRecoveryClipboard
    {
        uint version;public string Text;public RecoveryClipboardPayload Payload;public int Writes;public bool Busy;
        public uint Write(RecoveryClipboardPayload payload){Writes++;Payload=payload;Text=payload.Text;return ++version;}
        public bool ClearIfOwned(uint token){if(Busy)throw new Win32Exception("test clipboard busy");if(version!=token)return false;Text=null;++version;return true;}
        public void UserCopy(string text){Text=text;++version;}
    }
    sealed class FakeScheduler:IRecoveryExpiryScheduler
    {
        public TimeSpan Delay;public Action Callback;
        public IDisposable Schedule(TimeSpan delay,Action callback){Delay=delay;Callback=callback;return new Empty();}
        sealed class Empty:IDisposable{public void Dispose(){}}
    }
}
