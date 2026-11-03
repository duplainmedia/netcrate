using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Threading;
using System.Linq;
using NetCrate.Setup;

namespace NetCrate {
 public sealed class BoundScheduleService : IScheduleService {
  readonly WindowsSetupService service;readonly SetupState state;
  public BoundScheduleService(WindowsSetupService service,SetupState state){this.service=service;this.state=state.Copy();}
  public Task<SetupResult> InvokeScheduleAsync(string action,ScheduleRequest request,CancellationToken token){return service.InvokeScheduleAsync(action,state,request,token);}
 }
 public sealed class ScheduleEditor {
  readonly IScheduleService service;
  public IList<ScheduleItem> Items {get;private set;}
  public string Message {get;private set;}
  bool messageIsError;
  public ScheduleEditor(IScheduleService service){this.service=service;Items=new List<ScheduleItem>();Message="";}
  internal void RecordFailure(){Message="The schedule could not be read or saved. Check the folder and try again.";messageIsError=true;}
  async Task<bool> Run(string action,ScheduleRequest request,CancellationToken token,bool preserveMessage=false){
   SetupResult result;
   try{result=await service.InvokeScheduleAsync(action,request,token);}catch(Exception){RecordFailure();return false;}
   if(!result.Succeeded){Message=result.Message;messageIsError=true;return false;}
   Items=result.Schedules;
   if(!preserveMessage||!messageIsError){Message=Items.Count==0?"No automatic backups yet. Choose a folder and a daily local time.":result.Message;messageIsError=false;}
   return true;
  }
  public Task<bool> RefreshAsync(CancellationToken token,bool preserveMessage=false){return Run("ListSchedules",new ScheduleRequest(),token,preserveMessage);}
  public Task<bool> SaveAsync(string project,string time,bool enabled,CancellationToken token){return Run("SaveSchedule",new ScheduleRequest{Project=project,TimeOfDay=time,Enabled=enabled},token);}
  public Task<bool> DisableAsync(ScheduleItem item,CancellationToken token){return Run("DisableSchedule",new ScheduleRequest{Project=item.Project},token);}
 }
 public sealed class ScheduleView : Window {
  readonly ScheduleEditor editor;readonly Func<string> chooseFolder;
  readonly ListBox list=new ListBox{MinHeight=130};readonly TextBox folder=new TextBox(),time=new TextBox{Text="09:00"};
  readonly CheckBox enabled=new CheckBox{Content="Enabled",IsChecked=true};readonly TextBlock status=new TextBlock{TextWrapping=TextWrapping.Wrap};readonly StackPanel commands=new StackPanel{Orientation=Orientation.Horizontal};
  readonly DispatcherTimer refresh=new DispatcherTimer{Interval=TimeSpan.FromSeconds(30)};
  bool busy,rendering;
  public ScheduleView(ScheduleEditor editor,Func<string> chooseFolder){
   this.editor=editor;this.chooseFolder=chooseFolder;Title="Automatic backups · NetCrate";Width=840;Height=580;MinWidth=640;MinHeight=480;
   StackPanel panel=new StackPanel{Margin=new Thickness(20)};Content=new ScrollViewer{Content=panel};
   panel.Children.Add(new TextBlock{Text="Both computers must be on, signed in to Windows and connected. Backups continue when you close the app. Missed days catch up once.",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,12)});
   list.ItemsSource=editor.Items;AutomationProperties.SetName(list,"Backup schedules");panel.Children.Add(list);
   list.SelectionChanged+=delegate{ScheduleItem item=list.SelectedItem as ScheduleItem;if(item!=null&&!rendering)SetFields(item);};
   panel.Children.Add(new TextBlock{Text="Folder",Margin=new Thickness(0,12,0,4)});AutomationProperties.SetName(folder,"Schedule folder");folder.IsReadOnly=true;panel.Children.Add(folder);
   Button pick=Command("Choose folder",delegate{string path=chooseFolder();if(!String.IsNullOrEmpty(path)){folder.Text=path;list.SelectedItem=null;enabled.IsChecked=true;}});panel.Children.Add(pick);
   panel.Children.Add(new TextBlock{Text="Daily local time (HH:mm)",Margin=new Thickness(0,8,0,4)});AutomationProperties.SetName(time,"Daily local time");panel.Children.Add(time);panel.Children.Add(enabled);panel.Children.Add(commands);
   commands.Children.Add(Command("Save schedule",async delegate{await Run(()=>editor.SaveAsync(folder.Text,time.Text,enabled.IsChecked==true,CancellationToken.None));}));
   commands.Children.Add(Command("Disable schedule",async delegate{ScheduleItem item=list.SelectedItem as ScheduleItem;if(item!=null)await Run(()=>editor.DisableAsync(item,CancellationToken.None));else{status.Text="Select a schedule to disable.";}}));
   commands.Children.Add(Command("Refresh",async delegate{await Run(()=>editor.RefreshAsync(CancellationToken.None));}));panel.Children.Add(status);status.Margin=new Thickness(0,12,0,0);
   refresh.Tick+=async delegate{await RefreshStatusAsync();};
   Loaded+=async delegate{await Run(()=>editor.RefreshAsync(CancellationToken.None));refresh.Start();};Closed+=delegate{refresh.Stop();};Render();
  }
  Button Command(string name,Action action){var button=new Button{Content=name,Margin=new Thickness(0,6,8,4),Padding=new Thickness(10,6,10,6)};AutomationProperties.SetName(button,name);button.Click+=delegate{action();};return button;}
  void SetFields(ScheduleItem item){folder.Text=item.Project;time.Text=item.TimeOfDay;enabled.IsChecked=item.Enabled;}
  void Render(bool preserveInput=false){
   ScheduleItem selected=list.SelectedItem as ScheduleItem;string project=selected==null?null:selected.Project;
   rendering=true;try{list.ItemsSource=null;list.ItemsSource=editor.Items;list.SelectedItem=editor.Items.FirstOrDefault(i=>String.Equals(i.Project,project,StringComparison.OrdinalIgnoreCase));}finally{rendering=false;}
   if(!preserveInput&&list.SelectedItem!=null)SetFields((ScheduleItem)list.SelectedItem);status.Text=editor.Message;
  }
  internal Task RefreshStatusAsync(){return Run(()=>editor.RefreshAsync(CancellationToken.None,true),true);}
  async Task Run(Func<Task<bool>> action,bool preserveInput=false){if(busy)return;busy=true;commands.IsEnabled=false;try{bool succeeded=await action();Render(preserveInput||!succeeded);}catch(Exception){editor.RecordFailure();status.Text=editor.Message;}finally{busy=false;commands.IsEnabled=true;}}
 }
}
