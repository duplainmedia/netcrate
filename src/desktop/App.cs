using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Diagnostics;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Interop;
using System.Windows.Markup;
using Microsoft.Win32;
using Forms=System.Windows.Forms;

namespace NetCrate {
 public partial class JobApplication:Application {
  readonly Settings settings;readonly JavaScriptSerializer json=new JavaScriptSerializer();
  readonly string stateRoot=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),@"NetCrate\Monitor");
  public JobApplication():this(Settings.Local()){}
  private JobApplication(Settings settings){this.settings=settings;}
  Window window;TextBlock headingStatus,activity,footer;Button notificationButton;Forms.NotifyIcon tray;
  NotificationMemory memory;JobReader reader;System.Threading.Timer poll,noticeTimer;int reading;bool quitting,dark;Dashboard latest;
  Queue<Notice> manualNotices=new Queue<Notice>();DateTime lastNotice=DateTime.MinValue;EventWaitHandle showEvent,testEvent,exitEvent;RegisteredWaitHandle showWait,testWait,exitWait;
  string bg,card,border,fg,muted,accent;
  [DllImport("dwmapi.dll")]static extern int DwmSetWindowAttribute(IntPtr hwnd,int attribute,ref int value,int size);
  [DllImport("user32.dll")]static extern bool SetProcessDpiAwarenessContext(IntPtr context);
  static string EventPrefix(){return @"Local\NetCrate-"+System.Security.Principal.WindowsIdentity.GetCurrent().User.Value;}
  [STAThread]public static void Main(string[] args){
   try {
    try{SetProcessDpiAwarenessContext(new IntPtr(-4));}catch{}
    if(args.Length>=2&&args[0]=="--render-setup"){SetupStartup.Render(args[1],args.Contains("--folders"),args.Contains("--compact"),args.Contains("--connect"));return;}
    if(args.Length==2&&args[0]=="--dump"){File.WriteAllText(args[1],new JavaScriptSerializer().Serialize(new JobReader(Settings.Local()).Read()));return;}
    if(args.Length==2&&args[0]=="--render"){JobApplication preview=new JobApplication(Settings.Preview(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(args[1])),"preview-data")));preview.ShutdownMode=ShutdownMode.OnExplicitShutdown;preview.BuildWindow();preview.Apply(new JobReader(preview.settings).Read());preview.window.Show();preview.window.Dispatcher.Invoke(System.Windows.Threading.DispatcherPriority.Render,new Action(delegate{}));preview.window.UpdateLayout();RenderTargetBitmap bitmap=new RenderTargetBitmap((int)preview.window.ActualWidth,(int)preview.window.ActualHeight,96,96,PixelFormats.Pbgra32);bitmap.Render(preview.window);PngBitmapEncoder encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using(FileStream f=File.Create(args[1]))encoder.Save(f);preview.quitting=true;preview.window.Close();preview.Shutdown();return;}
    bool created;using(Mutex mutex=new Mutex(true,EventPrefix()+"-instance",out created)){
     if(!created&&!mutex.WaitOne(1000)){try{using(EventWaitHandle ev=EventWaitHandle.OpenExisting(EventPrefix()+(args.Contains("--exit")?"-exit":args.Contains("--test-notification")?"-test":"-show")))ev.Set();}catch{}return;}
     if(args.Contains("--exit")){mutex.ReleaseMutex();return;}
     if(args.Contains("--setup")||!File.Exists(Settings.DefaultPath)){bool finished=SetupStartup.Run();mutex.ReleaseMutex();if(finished)Process.Start(new ProcessStartInfo(System.Reflection.Assembly.GetExecutingAssembly().Location){UseShellExecute=true});return;}
     JobApplication app=new JobApplication();app.Start(args);app.Run();mutex.ReleaseMutex();
    }
   } catch(Exception ex){try{string root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),@"NetCrate\Monitor");Directory.CreateDirectory(root);File.WriteAllText(Path.Combine(root,"startup-error.json"),new JavaScriptSerializer().Serialize(new{State="NeedsAttention",Message=ex.GetType().Name+": "+ex.Message,UpdatedUtc=DateTime.UtcNow.ToString("o")}));}catch{}if(!args.Contains("--background"))MessageBox.Show("NetCrate could not start. Your existing backup files have not been changed.\n\n"+ex.Message,"NetCrate",MessageBoxButton.OK,MessageBoxImage.Warning);}
  }
  void Start(string[] args){
   ShutdownMode=ShutdownMode.OnExplicitShutdown;Directory.CreateDirectory(stateRoot);reader=new JobReader(settings);
   try{memory=json.Deserialize<NotificationMemory>(File.ReadAllText(Path.Combine(stateRoot,"notifications.json")));}catch{memory=new NotificationMemory();}if(memory==null)memory=new NotificationMemory();
   BuildWindow();tray=new Forms.NotifyIcon();tray.Icon=new System.Drawing.Icon(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"NetCrate.ico"),32,32);tray.Text="NetCrate";tray.Visible=true;
   Forms.ContextMenuStrip menu=new Forms.ContextMenuStrip();menu.Items.Add("Open job status",null,delegate{Dispatcher.BeginInvoke(new Action(OpenWindow));});menu.Items.Add("Test notification",null,delegate{Dispatcher.BeginInvoke(new Action(TestNotification));});menu.Items.Add("Windows notification settings",null,delegate{Process.Start("ms-settings:notifications");});menu.Items.Add(new Forms.ToolStripSeparator());menu.Items.Add("Exit",null,delegate{Dispatcher.BeginInvoke(new Action(ExitApp));});tray.ContextMenuStrip=menu;tray.MouseClick+=delegate(object sender,Forms.MouseEventArgs e){if(e.Button==Forms.MouseButtons.Left)Dispatcher.BeginInvoke(new Action(OpenWindow));};tray.BalloonTipClicked+=delegate{Dispatcher.BeginInvoke(new Action(OpenWindow));};tray.BalloonTipShown+=delegate{WriteState("notification-displayed.json",new{ShownUtc=DateTime.UtcNow.ToString("o"),NativeEvent="NIN_BALLOONSHOW"});};
   showEvent=new EventWaitHandle(false,EventResetMode.AutoReset,EventPrefix()+"-show");testEvent=new EventWaitHandle(false,EventResetMode.AutoReset,EventPrefix()+"-test");exitEvent=new EventWaitHandle(false,EventResetMode.AutoReset,EventPrefix()+"-exit");
   showWait=ThreadPool.RegisterWaitForSingleObject(showEvent,delegate{if(!quitting)Dispatcher.BeginInvoke(new Action(OpenWindow));},null,Timeout.Infinite,false);testWait=ThreadPool.RegisterWaitForSingleObject(testEvent,delegate{if(!quitting)Dispatcher.BeginInvoke(new Action(TestNotification));},null,Timeout.Infinite,false);exitWait=ThreadPool.RegisterWaitForSingleObject(exitEvent,delegate{if(!quitting)Dispatcher.BeginInvoke(new Action(ExitApp));},null,Timeout.Infinite,false);
   poll=new System.Threading.Timer(delegate{Refresh();},null,0,5000);noticeTimer=new System.Threading.Timer(delegate{if(!quitting)Dispatcher.BeginInvoke(new Action(NextNotice));},null,1000,1000);
   if(!args.Contains("--background"))OpenWindow();if(args.Contains("--test-notification"))TestNotification();
  }
  Brush Brush(string color){return new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));}
  TextBlock Text(string text,double size,string color){return new TextBlock{Text=text,FontSize=size,Foreground=Brush(color),TextWrapping=TextWrapping.Wrap};}
  void UpdateNotificationButton(){notificationButton.Content=(memory==null||memory.Enabled)?"Notifications on":"Notifications paused";}
  void Refresh(){if(Interlocked.Exchange(ref reading,1)!=0)return;try{Dashboard d=reader.Read();if(!quitting)Dispatcher.BeginInvoke(new Action(delegate{Apply(d);memory.Observe(d);SaveMemory();WriteHealth(d);}));}catch(Exception ex){if(!quitting)Dispatcher.BeginInvoke(new Action(delegate{activity.Text="Status could not be refreshed. Existing backups continue independently.";WriteState("refresh-error.json",new{Message=ex.GetType().Name,UpdatedUtc=DateTime.UtcNow.ToString("o")});}));}finally{Interlocked.Exchange(ref reading,0);}}
  void OpenFolder(string path){if(!SafeFolders.CanOpen(path,settings)){MessageBox.Show(window,"This project folder is not currently available.","NetCrate",MessageBoxButton.OK,MessageBoxImage.Information);return;}Process.Start(new ProcessStartInfo("explorer.exe","\""+path+"\""){UseShellExecute=true});}
  void OpenWindow(){window.Show();if(window.WindowState==WindowState.Minimized)window.WindowState=WindowState.Normal;window.Activate();}
  void TestNotification(){manualNotices.Enqueue(new Notice{Title="NetCrate",Message="This is a test notification. Future alerts will report completed jobs or anything that needs attention."});lastNotice=DateTime.MinValue;NextNotice();}
  void NextNotice(){if(tray==null||(DateTime.UtcNow-lastNotice).TotalSeconds<10)return;Notice n=manualNotices.Count>0?manualNotices.Dequeue():memory.Enabled&&memory.Pending!=null&&memory.Pending.Count>0?memory.Pending[0]:null;if(n==null)return;tray.ShowBalloonTip(8000,n.Title,n.Message.Length>450?n.Message.Substring(0,447)+"...":n.Message,n.Title.IndexOf("attention",StringComparison.OrdinalIgnoreCase)>=0?Forms.ToolTipIcon.Warning:Forms.ToolTipIcon.Info);memory.MarkDelivered(n.Key);SaveMemory();lastNotice=DateTime.UtcNow;WriteState("last-notification.json",new{Title=n.Title,Message=n.Message,RequestedUtc=lastNotice.ToString("o")});}
  void SaveMemory(){WriteState("notifications.json",memory);}
  void WriteState(string name,object value){try{string path=Path.Combine(stateRoot,name),temp=path+".writing";File.WriteAllText(temp,json.Serialize(value));if(File.Exists(path))File.Replace(temp,path,null);else File.Move(temp,path);}catch{}}
  void WriteHealth(Dashboard d){WriteState("health.json",new{State="Running",ProcessId=Process.GetCurrentProcess().Id,UpdatedUtc=DateTime.UtcNow.ToString("o"),Projects=d.Jobs.Count,Active=d.Jobs.Count(j=>j.Active),NeedsAttention=d.Jobs.Count(j=>j.Attention)+(d.ServiceAttention?1:0),NotificationsEnabled=memory.Enabled,WindowVisible=window.IsVisible});}
  void ExitApp(){quitting=true;if(poll!=null)poll.Dispose();if(noticeTimer!=null)noticeTimer.Dispose();if(showWait!=null)showWait.Unregister(null);if(testWait!=null)testWait.Unregister(null);if(exitWait!=null)exitWait.Unregister(null);if(showEvent!=null)showEvent.Dispose();if(testEvent!=null)testEvent.Dispose();if(exitEvent!=null)exitEvent.Dispose();if(tray!=null){tray.Visible=false;tray.Dispose();}SaveMemory();window.Close();Shutdown();}
 }
}
