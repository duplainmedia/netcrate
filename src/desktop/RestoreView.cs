using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using Microsoft.Win32;
using NetCrate.Setup;
using Forms = System.Windows.Forms;

namespace NetCrate {
    public sealed class RestoreBrowser {
        readonly IRestoreService service;
        readonly RestoreRequest context;
        public IList<BackupItem> Items { get; private set; }
        public BackupItem Backup { get; private set; }
        public BackupItem Selection { get; private set; }
        public string RelativePath { get; private set; }
        public string NextCursor { get; private set; }
        public string Message { get; private set; }
        public string RestoredPath { get; private set; }
        public RestoreBrowser(IRestoreService service, RestoreRequest context) {
            this.service=service;this.context=context.Copy();Items=new List<BackupItem>();RelativePath="";
        }
        public async Task LoadAsync(CancellationToken token) {
            Backup=null;Selection=null;RelativePath="";RestoredPath=null;
            await FetchAsync(false,token);
        }
        async Task FetchAsync(bool more,CancellationToken token) {
            RestoreRequest request=context.Copy();request.SnapshotId=Backup==null?null:Backup.SnapshotId;request.RelativePath=RelativePath;request.Cursor=more?NextCursor:null;
            SetupResult result=await service.InvokeRestoreAsync(Backup==null?"ListBackups":"ListBackupChildren",request,token);
            Message=result.Message;NextCursor=result.Succeeded?result.NextCursor:null;
            if(!more || !result.Succeeded)Items=new List<BackupItem>();
            if(result.Succeeded)foreach(BackupItem item in result.Items)Items.Add(item);
        }
        public Task MoreAsync(CancellationToken token) { return FetchAsync(true,token); }
        public async Task OpenBackupAsync(BackupItem backup,CancellationToken token) {
            Backup=backup;RelativePath="";Selection=null;RestoredPath=null;await FetchAsync(false,token);
        }
        public async Task BrowseAsync(string relative,CancellationToken token) {
            if(Backup==null)throw new InvalidOperationException("Choose a dated backup first.");
            RelativePath=relative;Selection=null;await FetchAsync(false,token);
        }
        public void Select(BackupItem item){Selection=item;}
        public string Review(string parent) {
            if(Backup==null)throw new InvalidOperationException("Choose a dated backup first.");
            string path=Selection==null?RelativePath:Selection.RelativePath;
            DateTimeOffset date=DateTimeOffset.Parse(Backup.BackupCompletedUtc);
            string name="Recovered-"+date.ToString("yyyyMMdd-HHmmss")+"-"+Backup.SnapshotId.Substring(0,8);
            return "Source: "+Backup.Project+"\nBackup: "+date.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")+"\nCompletion: "+Backup.Completion+
                "\nSelection: "+(String.IsNullOrEmpty(path)?"Whole backup":path)+"\nRestore to a new folder:\n"+Path.Combine(parent,name)+
                "\n\nExisting files are preserved. If this folder name exists, a new suffix is added. Verification may take a while; keep NetCrate open until it finishes.";
        }
        public async Task RestoreAsync(string parent,CancellationToken token) {
            if(Backup==null)throw new InvalidOperationException("Choose a dated backup first.");
            RestoreRequest request=context.Copy();request.SnapshotId=Backup.SnapshotId;request.RelativePath=Selection==null?RelativePath:Selection.RelativePath;request.DestinationParent=parent;
            SetupResult result=await service.InvokeRestoreAsync("RestoreSelection",request,token);
            Message=result.Message;RestoredPath=result.Succeeded?result.RestoredPath:null;
        }
    }

    public sealed class RestoreView : Window {
        readonly RestoreBrowser browser;
        readonly StackPanel breadcrumbs=new StackPanel { Orientation=Orientation.Horizontal };
        readonly ListBox list=new ListBox { MinHeight=160 };
        readonly TextBlock status=new TextBlock { TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,12,0,12) };
        readonly StackPanel commands=new StackPanel { Orientation=Orientation.Horizontal };
        readonly CancellationTokenSource cancellation=new CancellationTokenSource();
        bool busy,restoring;
        public RestoreView(RestoreBrowser browser) {
            this.browser=browser;Title="Restore files · NetCrate";Width=900;Height=650;MinWidth=650;MinHeight=450;
            WindowStartupLocation=WindowStartupLocation.CenterOwner;
            Grid panel=new Grid {Margin=new Thickness(24)};Content=panel;
            panel.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});panel.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});
            panel.RowDefinitions.Add(new RowDefinition());panel.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});panel.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});
            panel.Children.Add(new TextBlock {Text="Choose a backup date, then a file or folder to restore.",FontSize=19,Margin=new Thickness(0,0,0,12)});
            Grid.SetRow(breadcrumbs,1);panel.Children.Add(breadcrumbs);
            Grid.SetRow(list,2);panel.Children.Add(list);AutomationProperties.SetName(list,"Backed-up dates and files");
            Grid.SetRow(status,3);panel.Children.Add(status);Grid.SetRow(commands,4);panel.Children.Add(commands);
            list.SelectionChanged+=delegate {browser.Select(list.SelectedItem as BackupItem);};
            list.MouseDoubleClick+=async delegate {BackupItem item=list.SelectedItem as BackupItem;if(item==null||busy)return;await RunAsync(async ()=>{if(browser.Backup==null)await browser.OpenBackupAsync(item,cancellation.Token);else if(item.Type=="dir")await browser.BrowseAsync(item.RelativePath,cancellation.Token);});};
            list.KeyDown+=async delegate(object sender,System.Windows.Input.KeyEventArgs e) {if(e.Key!=System.Windows.Input.Key.Enter||busy)return;BackupItem item=list.SelectedItem as BackupItem;if(item==null)return;e.Handled=true;await RunAsync(async ()=>{if(browser.Backup==null)await browser.OpenBackupAsync(item,cancellation.Token);else if(item.Type=="dir")await browser.BrowseAsync(item.RelativePath,cancellation.Token);});};
            Loaded+=async delegate {await RunAsync(()=>browser.LoadAsync(cancellation.Token));};
            Closing+=delegate(object sender,System.ComponentModel.CancelEventArgs e){if(restoring){e.Cancel=true;status.Text="Verification is still running. This window will stay open until recovery finishes.";}else cancellation.Cancel();};
            Draw();
        }
        Button Command(string name,Action action) {
            Button b=new Button {Content=name,Padding=new Thickness(12,8,12,8),Margin=new Thickness(0,0,8,8)};AutomationProperties.SetName(b,name);b.Click+=delegate{action();};return b;
        }
        void Draw() {
            breadcrumbs.Children.Clear();commands.Children.Clear();
            breadcrumbs.Children.Add(Command("Backup dates",async ()=>await RunAsync(()=>browser.LoadAsync(cancellation.Token))));
            if(browser.Backup!=null) {
                breadcrumbs.Children.Add(Command("Whole backup",async ()=>await RunAsync(()=>browser.BrowseAsync("",cancellation.Token))));
                string accumulated="";
                foreach(string part in browser.RelativePath.Split(new[]{'/'},StringSplitOptions.RemoveEmptyEntries)) {
                    accumulated=accumulated.Length==0?part:accumulated+"/"+part;string path=accumulated;
                    breadcrumbs.Children.Add(Command(part,async ()=>await RunAsync(()=>browser.BrowseAsync(path,cancellation.Token))));
                }
            }
            list.ItemsSource=browser.Items;list.Items.Refresh();status.Text=browser.Message??"Choose a dated backup.";
            if(!String.IsNullOrEmpty(browser.RestoredPath))status.Text+="\nVerified output: "+browser.RestoredPath;
            Button restore=Command("Restore to a new folder",Restore);restore.IsEnabled=browser.Backup!=null;commands.Children.Add(restore);
            if(!String.IsNullOrEmpty(browser.NextCursor))commands.Children.Add(Command("More",async ()=>await RunAsync(()=>browser.MoreAsync(cancellation.Token))));
            commands.Children.Add(Command("Refresh",async ()=>await RunAsync(()=>browser.LoadAsync(cancellation.Token))));
            if(!String.IsNullOrEmpty(browser.RestoredPath))commands.Children.Add(Command("Open recovered folder",()=>Process.Start(new ProcessStartInfo(browser.RestoredPath){UseShellExecute=true})));
        }
        async Task RunAsync(Func<Task> action) {
            if(busy)return;busy=true;list.IsEnabled=false;commands.IsEnabled=false;breadcrumbs.IsEnabled=false;status.Text="Reading and verifying backups…";
            try{await action();Draw();}catch(OperationCanceledException){}catch(Exception){status.Text="Recovery could not finish. Check the backup drive, recovery file and available space, then choose Refresh to try again.";}
            finally{busy=false;list.IsEnabled=true;commands.IsEnabled=true;breadcrumbs.IsEnabled=true;}
        }
        async void Restore() {
            if(busy||browser.Backup==null)return;
            using(Forms.FolderBrowserDialog picker=new Forms.FolderBrowserDialog {Description="Choose an existing parent for a new recovery folder",ShowNewFolderButton=false}) {
                if(picker.ShowDialog()!=Forms.DialogResult.OK)return;
                string parent=picker.SelectedPath;
                if(MessageBox.Show(this,browser.Review(parent),"Restore selected files?",MessageBoxButton.OKCancel,MessageBoxImage.Information)!=MessageBoxResult.OK)return;
                restoring=true;try{await RunAsync(()=>browser.RestoreAsync(parent,cancellation.Token));}finally{restoring=false;}
            }
        }
        public static void OpenRecovery(Window owner,IRestoreService service) {
            OpenFileDialog file=new OpenFileDialog {Title="Choose your saved NetCrate recovery file",Filter="NetCrate recovery file (*.json)|*.json",CheckFileExists=true};
            if(file.ShowDialog(owner)!=true)return;
            using(Forms.FolderBrowserDialog folder=new Forms.FolderBrowserDialog {Description="Choose the originals folder on your connected backup drive",ShowNewFolderButton=false}) {
                if(folder.ShowDialog()!=Forms.DialogResult.OK)return;
                new RestoreView(new RestoreBrowser(service,new RestoreRequest {RecoveryFile=file.FileName,RepositoryPath=folder.SelectedPath})) {Owner=owner}.Show();
            }
        }
    }
}
