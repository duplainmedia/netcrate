using System;
using System.IO;
using System.Threading;
using Forms=System.Windows.Forms;
using System.Linq;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Automation;
using Microsoft.Win32;

namespace NetCrate {
 public class JobRow {
  public Job Job{get;set;} public string Title{get;set;} public string DateLabel{get;set;}
  public string Status{get;set;} public Brush StatusColor{get;set;} public string Percent{get;set;} public string Eta{get;set;} public string Updated{get;set;}
  public double PercentValue{get;set;} public double EtaValue{get;set;} public DateTime UpdatedValue{get;set;}
 }
 public partial class JobApplication {
  DataGrid jobsGrid;
  TextBlock selectedTitle,selectedDetail,selectedPath,emptyTitle,emptyHint,searchHint;
  Button openProject,openProxies;
  ProgressBar selectedProgress;
  Border detailArea,noticeArea;
  StackPanel emptyArea;
  TextBox searchBox;
  ColumnDefinition navigationColumn;
  ListBox navigation;
  List<TextBlock> navigationLabels=new List<TextBlock>(),navigationCounts=new List<TextBlock>();
  string gridSignature="";
  bool compactNavigation;

  string FriendlyTitle(string project) {
   if(settings.BackupMode=="Folder")return project;
   string title=System.Text.RegularExpressions.Regex.Replace(project,@"^\d{4}-\d{2}-\d{2}_","").Replace('_',' ');
   title=System.Text.RegularExpressions.Regex.Replace(title,@"(?<=[a-z])(?=[A-Z])"," ");
   return System.Text.RegularExpressions.Regex.Replace(title,@"\bMc ([A-Z])","Mc$1");
  }
  string ProjectDate(string project) {
   DateTime date;
   if(settings.BackupMode=="Folder")return "Folder";
   return project.Length>=10&&DateTime.TryParseExact(project.Substring(0,10),"yyyy-MM-dd",null,System.Globalization.DateTimeStyles.None,out date)?date.ToString("MMM d, yyyy"):"Footage project";
  }
  TextBlock Glyph(string glyph,double size,string color) {
   return new TextBlock { Text=glyph,FontFamily=new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),FontSize=size,Foreground=Brush(color),VerticalAlignment=VerticalAlignment.Center,HorizontalAlignment=HorizontalAlignment.Center };
  }
  object CommandContent(string glyph,string label) {
   StackPanel panel=new StackPanel { Orientation=Orientation.Horizontal };panel.Children.Add(Glyph(glyph,14,fg));
   TextBlock text=Text(label,12,fg);text.Margin=new Thickness(8,0,0,0);panel.Children.Add(text);return panel;
  }
  void BuildWindow() {
   object theme=null;try { theme=Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize","AppsUseLightTheme",1); } catch {}
   dark=true;
   bg=Theme.Background;card=Theme.Surface;border=Theme.Border;fg=Theme.Text;muted=Theme.Muted;accent=Theme.Accent;
   window=new Window { Title="NetCrate",Width=1220,Height=740,MinWidth=1050,MinHeight=580,Background=Brush(bg),FontFamily=new FontFamily("Segoe UI Variable Text, Segoe UI"),WindowStartupLocation=WindowStartupLocation.CenterScreen };
   try { using(System.Drawing.Icon icon=new System.Drawing.Icon(System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"NetCrate.ico"),32,32))window.Icon=Imaging.CreateBitmapSourceFromHIcon(icon.Handle,Int32Rect.Empty,System.Windows.Media.Imaging.BitmapSizeOptions.FromEmptyOptions()); } catch {}
   window.SourceInitialized+=delegate { try { int value=dark?1:0;DwmSetWindowAttribute(new WindowInteropHelper(window).Handle,20,ref value,4); } catch {} };
   window.Closing+=delegate(object sender,System.ComponentModel.CancelEventArgs e) { if(!quitting){e.Cancel=true;window.Hide();} };
   window.PreviewKeyDown+=delegate(object sender,System.Windows.Input.KeyEventArgs e) {
    if(e.Key==System.Windows.Input.Key.F&&(System.Windows.Input.Keyboard.Modifiers&System.Windows.Input.ModifierKeys.Control)!=0){searchBox.Focus();searchBox.SelectAll();e.Handled=true;}
    if(e.Key==System.Windows.Input.Key.Escape&&searchBox.IsKeyboardFocused){searchBox.Clear();e.Handled=true;}
   };
   InstallViewStyles();
   Grid shell=new Grid();window.Content=shell;navigationColumn=new ColumnDefinition { Width=new GridLength(204) };shell.ColumnDefinitions.Add(navigationColumn);shell.ColumnDefinitions.Add(new ColumnDefinition());BuildNavigation(shell);
   Border content=new Border { Background=Brush(card),CornerRadius=new CornerRadius(8,0,0,0),BorderBrush=Brush(border),BorderThickness=new Thickness(1,1,0,0) };Grid.SetColumn(content,1);shell.Children.Add(content);
   Grid main=new Grid();content.Child=main;
   for(int i=0;i<6;i++)main.RowDefinitions.Add(new RowDefinition { Height=i==3?new GridLength(1,GridUnitType.Star):GridLength.Auto });
   BuildHeader(main);BuildCommands(main);
   noticeArea=new Border { Background=Brush(dark?"#111F32":"#F0E7F7"),CornerRadius=new CornerRadius(4),Padding=new Thickness(12,9,12,9),Margin=new Thickness(22,0,22,10),Visibility=Visibility.Collapsed };activity=Text("",12,muted);noticeArea.Child=activity;Grid.SetRow(noticeArea,2);main.Children.Add(noticeArea);
   Grid tableArea=new Grid();Grid.SetRow(tableArea,3);main.Children.Add(tableArea);jobsGrid=CreateJobGrid();tableArea.Children.Add(jobsGrid);
   emptyArea=new StackPanel { VerticalAlignment=VerticalAlignment.Center,HorizontalAlignment=HorizontalAlignment.Center,Margin=new Thickness(30),Visibility=Visibility.Collapsed };emptyArea.Children.Add(Glyph("\uE8A5",30,muted));emptyTitle=Text("No jobs",17,fg);emptyTitle.FontWeight=FontWeights.SemiBold;emptyTitle.HorizontalAlignment=HorizontalAlignment.Center;emptyTitle.Margin=new Thickness(0,16,0,6);emptyArea.Children.Add(emptyTitle);emptyHint=Text("",12,muted);emptyHint.HorizontalAlignment=HorizontalAlignment.Center;emptyArea.Children.Add(emptyHint);tableArea.Children.Add(emptyArea);
   BuildDetails(main);
   Border statusBar=new Border { BorderBrush=Brush(border),BorderThickness=new Thickness(0,1,0,0),Padding=new Thickness(22,9,22,9) };footer=Text("Reading job status...",11,muted);statusBar.Child=footer;Grid.SetRow(statusBar,5);main.Children.Add(statusBar);
  }
  void InstallViewStyles() {
   string button="<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'><Setter Property='Background' Value='Transparent'/><Setter Property='Foreground' Value='"+fg+"'/><Setter Property='FontSize' Value='12'/><Setter Property='Padding' Value='11,8'/><Setter Property='BorderBrush' Value='Transparent'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border x:Name='body' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='1' CornerRadius='4'><ContentPresenter Margin='{TemplateBinding Padding}' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='body' Property='Background' Value='"+(dark?"#183151":"#E9E9E9")+"'/></Trigger><Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='body' Property='BorderBrush' Value='"+accent+"'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.38'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>";window.Resources.Add(typeof(Button),(Style)XamlReader.Parse(button));
   string item="<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='ListBoxItem'><Setter Property='Padding' Value='0'/><Setter Property='Margin' Value='6,2'/><Setter Property='HorizontalContentAlignment' Value='Stretch'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ListBoxItem'><Border x:Name='body' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' Background='Transparent' CornerRadius='4'><Grid><Border x:Name='marker' Width='3' Height='18' CornerRadius='2' HorizontalAlignment='Left' Background='Transparent'/><ContentPresenter Margin='10,0,8,0'/></Grid></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='body' Property='Background' Value='"+(dark?"#111F32":"#EAEAEA")+"'/></Trigger><Trigger Property='IsSelected' Value='True'><Setter TargetName='body' Property='Background' Value='"+(dark?"#132C4A":"#E5E5E5")+"'/><Setter TargetName='marker' Property='Background' Value='"+accent+"'/></Trigger><Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='body' Property='BorderBrush' Value='"+accent+"'/><Setter TargetName='body' Property='BorderThickness' Value='1'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>";window.Resources.Add(typeof(ListBoxItem),(Style)XamlReader.Parse(item));
  }
  void BuildNavigation(Grid shell) {
   DockPanel panel=new DockPanel();shell.Children.Add(panel);
   Button menu=new Button { Content=Glyph("\uE700",16,fg),Width=40,Height=38,HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(8,10,0,18),ToolTip="Expand or collapse navigation" };AutomationProperties.SetName(menu,"Toggle navigation");menu.Click+=delegate { ToggleNavigation(); };DockPanel.SetDock(menu,Dock.Top);panel.Children.Add(menu);
   StackPanel bottom=new StackPanel { Margin=new Thickness(8,0,8,14) };DockPanel.SetDock(bottom,Dock.Bottom);panel.Children.Add(bottom);notificationButton=new Button { Content="Notifications on",ToolTip="Pause or resume job notifications",Padding=new Thickness(8,9,8,9) };notificationButton.Click+=delegate { memory.SetEnabled(!memory.Enabled);SaveMemory();UpdateNotificationButton(); };bottom.Children.Add(notificationButton);
   navigation=new ListBox { Background=Brush("#00000000"),BorderThickness=new Thickness(0),SelectionMode=SelectionMode.Single,Padding=new Thickness(0) };AutomationProperties.SetName(navigation,"Job views");panel.Children.Add(navigation);
   string[] labels={"All jobs","In progress","Completed","Needs attention"},glyphs={"\uE8A5","\uE768","\uE73E","\uE7BA"};
   for(int i=0;i<labels.Length;i++) {
    Grid row=new Grid { Height=39 };row.ColumnDefinitions.Add(new ColumnDefinition { Width=new GridLength(24) });row.ColumnDefinitions.Add(new ColumnDefinition());row.ColumnDefinitions.Add(new ColumnDefinition { Width=GridLength.Auto });row.Children.Add(Glyph(glyphs[i],16,fg));TextBlock label=Text(labels[i],13,fg);label.Margin=new Thickness(10,0,0,0);label.VerticalAlignment=VerticalAlignment.Center;label.TextWrapping=TextWrapping.NoWrap;Grid.SetColumn(label,1);row.Children.Add(label);navigationLabels.Add(label);TextBlock count=Text("",11,muted);count.VerticalAlignment=VerticalAlignment.Center;count.Margin=new Thickness(10,0,2,0);Grid.SetColumn(count,2);row.Children.Add(count);navigationCounts.Add(count);ListBoxItem item=new ListBoxItem { Content=row,ToolTip=labels[i] };AutomationProperties.SetName(item,labels[i]);navigation.Items.Add(item);
   }
   navigation.SelectedIndex=0;navigation.SelectionChanged+=delegate { gridSignature="";if(latest!=null)Apply(latest); };
  }
  void ToggleNavigation() {
   compactNavigation=!compactNavigation;navigationColumn.Width=new GridLength(compactNavigation?58:204);foreach(TextBlock label in navigationLabels)label.Visibility=compactNavigation?Visibility.Collapsed:Visibility.Visible;foreach(TextBlock count in navigationCounts)count.Visibility=compactNavigation?Visibility.Collapsed:Visibility.Visible;notificationButton.Visibility=compactNavigation?Visibility.Collapsed:Visibility.Visible;
  }
  void BuildHeader(Grid main) {
   Grid header=new Grid { Margin=new Thickness(24,20,24,15) };header.ColumnDefinitions.Add(new ColumnDefinition());header.ColumnDefinitions.Add(new ColumnDefinition { Width=new GridLength(290) });main.Children.Add(header);TextBlock title=Text("Jobs",23,fg);title.FontWeight=FontWeights.SemiBold;title.VerticalAlignment=VerticalAlignment.Center;header.Children.Add(title);
   Border search=new Border { Background=Brush(dark?"#111F32":"#FAFAFA"),BorderBrush=Brush(dark?"#425C7D":"#999999"),BorderThickness=new Thickness(0,0,0,1),CornerRadius=new CornerRadius(4),Height=35 };Grid.SetColumn(search,1);header.Children.Add(search);Grid inside=new Grid();search.Child=inside;TextBlock icon=Glyph("\uE721",13,muted);icon.HorizontalAlignment=HorizontalAlignment.Left;icon.Margin=new Thickness(11,0,0,0);inside.Children.Add(icon);searchHint=Text(settings.BackupMode=="Folder"?"Search folders":"Search projects",12,muted);searchHint.Margin=new Thickness(33,0,10,0);searchHint.VerticalAlignment=VerticalAlignment.Center;searchHint.IsHitTestVisible=false;inside.Children.Add(searchHint);searchBox=new TextBox { Background=Brush("#00000000"),BorderThickness=new Thickness(0),Foreground=Brush(fg),CaretBrush=Brush(fg),FontSize=12,Padding=new Thickness(33,8,10,7),VerticalContentAlignment=VerticalAlignment.Center };AutomationProperties.SetName(searchBox,"Search jobs");inside.Children.Add(searchBox);searchBox.TextChanged+=delegate { searchHint.Visibility=searchBox.Text.Length==0?Visibility.Visible:Visibility.Collapsed;gridSignature="";if(latest!=null)Apply(latest); };
  }
  void BuildCommands(Grid main) {
   DockPanel commands=new DockPanel { Margin=new Thickness(24,0,14,10) };Grid.SetRow(commands,1);main.Children.Add(commands);StackPanel actions=new StackPanel { Orientation=Orientation.Horizontal };DockPanel.SetDock(actions,Dock.Right);commands.Children.Add(actions);
   if(settings.Role=="Source") { Button backup=new Button { Content=CommandContent("\uE898",settings.BackupMode=="Folder"?"Back up a folder":"Back up a project") };AutomationProperties.SetName(backup,settings.BackupMode=="Folder"?"Back up a folder":"Back up a project");backup.Click+=delegate { QueueProjectBackup(); };actions.Children.Add(backup); Button restore=new Button { Content="Restore files" };AutomationProperties.SetName(restore,"Restore files");restore.Click+=delegate { Setup.WindowsSetupService service=new Setup.WindowsSetupService(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"install"));new RestoreView(new RestoreBrowser(service,new Setup.RestoreRequest { InstallationId=settings.InstallationId })) { Owner=window }.Show(); };actions.Children.Add(restore); }
   openProject=new Button { Content=CommandContent("\uE8B7",settings.BackupMode=="Folder"?"Open folder":"Open project") };AutomationProperties.SetName(openProject,settings.BackupMode=="Folder"?"Open folder":"Open project");openProject.Click+=delegate { JobRow row=jobsGrid.SelectedItem as JobRow;if(row!=null)OpenFolder(row.Job.ProjectPath); };actions.Children.Add(openProject);openProxies=new Button { Content=CommandContent("\uE714","Open proxies") };AutomationProperties.SetName(openProxies,"Open proxies");openProxies.Click+=delegate { JobRow row=jobsGrid.SelectedItem as JobRow;if(row!=null)OpenFolder(row.Job.ResultFolder); };openProxies.Visibility=settings.BackupMode=="Folder"?Visibility.Collapsed:Visibility.Visible;actions.Children.Add(openProxies);actions.Children.Add(new Border { Background=Brush(border),Width=1,Height=18,Margin=new Thickness(8,0,8,0) });Button refresh=new Button { Content=Glyph("\uE72C",14,fg),ToolTip="Refresh",Width=36 };AutomationProperties.SetName(refresh,"Refresh jobs");refresh.Click+=delegate { Refresh(); };actions.Children.Add(refresh);headingStatus=Text("Reading jobs...",12,muted);headingStatus.VerticalAlignment=VerticalAlignment.Center;commands.Children.Add(headingStatus);
  }
  async void QueueProjectBackup() {
   using(Forms.FolderBrowserDialog picker=new Forms.FolderBrowserDialog()) {
    picker.Description=settings.BackupMode=="Folder"?"Choose your configured folder or a folder inside it":"Choose a project directly inside your project folder";picker.SelectedPath=settings.ActiveRoot;picker.ShowNewFolderButton=false;
    if(picker.ShowDialog()!=Forms.DialogResult.OK)return;
    string path=Path.GetFullPath(picker.SelectedPath).TrimEnd('\\');
    if(!SafeFolders.CanSelectBackup(path,settings)) {
     MessageBox.Show(window,(settings.BackupMode=="Folder"?"Choose the configured folder or a folder inside ":"Choose one project folder directly inside ")+settings.ActiveRoot+".","NetCrate",MessageBoxButton.OK,MessageBoxImage.Information);return;
    }
    Setup.SetupState state=new Setup.SetupState { InstallationId=settings.InstallationId,Role=Setup.ComputerRole.EditingComputer,Folder=settings.ActiveRoot,BackupMode=settings.BackupMode };
    Setup.WindowsSetupService service=new Setup.WindowsSetupService(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"install"));
    try {
     Setup.SetupResult result=await service.InvokePreparationAsync("QueueBackup",state,CancellationToken.None,path);
     MessageBox.Show(window,result.Message,"NetCrate",MessageBoxButton.OK,MessageBoxImage.Information);Refresh();
    }catch(Exception){MessageBox.Show(window,"The backup could not be queued. Check the project folder, then try again.","NetCrate",MessageBoxButton.OK,MessageBoxImage.Information);}
   }
  }
  DataGrid CreateJobGrid() {
   DataGrid grid=new DataGrid { AutoGenerateColumns=false,IsReadOnly=true,CanUserAddRows=false,CanUserDeleteRows=false,CanUserResizeRows=false,CanUserReorderColumns=false,SelectionMode=DataGridSelectionMode.Single,SelectionUnit=DataGridSelectionUnit.FullRow,HeadersVisibility=DataGridHeadersVisibility.Column,RowHeaderWidth=0,RowHeight=38,ColumnHeaderHeight=40,GridLinesVisibility=DataGridGridLinesVisibility.Vertical,VerticalGridLinesBrush=Brush(dark?"#19283C":"#EEEEEE"),Background=Brush(card),Foreground=Brush(fg),BorderThickness=new Thickness(0),FontSize=12 };AutomationProperties.SetName(grid,"Jobs");ScrollViewer.SetHorizontalScrollBarVisibility(grid,ScrollBarVisibility.Disabled);ScrollViewer.SetVerticalScrollBarVisibility(grid,ScrollBarVisibility.Auto);
   Style rowStyle=new Style(typeof(DataGridRow));rowStyle.Setters.Add(new Setter(Control.BackgroundProperty,Brush(card)));rowStyle.Setters.Add(new Setter(Control.BorderThicknessProperty,new Thickness(0)));Trigger hover=new Trigger { Property=DataGridRow.IsMouseOverProperty,Value=true };hover.Setters.Add(new Setter(Control.BackgroundProperty,Brush(dark?"#111F32":"#F6F6F6")));rowStyle.Triggers.Add(hover);Trigger selected=new Trigger { Property=DataGridRow.IsSelectedProperty,Value=true };selected.Setters.Add(new Setter(Control.BackgroundProperty,Brush(dark?"#183151":"#EAEAEA")));rowStyle.Triggers.Add(selected);grid.RowStyle=rowStyle;
   Style cell=new Style(typeof(DataGridCell));cell.Setters.Add(new Setter(Control.BorderThicknessProperty,new Thickness(0)));cell.Setters.Add(new Setter(Control.VerticalContentAlignmentProperty,VerticalAlignment.Center));Trigger selectedCell=new Trigger { Property=DataGridCell.IsSelectedProperty,Value=true };selectedCell.Setters.Add(new Setter(Control.BackgroundProperty,Brush("#00000000")));selectedCell.Setters.Add(new Setter(Control.ForegroundProperty,Brush(fg)));cell.Triggers.Add(selectedCell);grid.CellStyle=cell;
   Style header=new Style(typeof(System.Windows.Controls.Primitives.DataGridColumnHeader));header.Setters.Add(new Setter(Control.BackgroundProperty,Brush(card)));header.Setters.Add(new Setter(Control.ForegroundProperty,Brush(muted)));header.Setters.Add(new Setter(Control.FontWeightProperty,FontWeights.Normal));header.Setters.Add(new Setter(Control.PaddingProperty,new Thickness(14,0,12,0)));header.Setters.Add(new Setter(Control.BorderThicknessProperty,new Thickness(0,0,1,1)));header.Setters.Add(new Setter(Control.BorderBrushProperty,Brush(border)));grid.ColumnHeaderStyle=header;
   string projectTemplate="<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><Grid Margin='23,0,12,0' ToolTip='{Binding Job.Project}'><Grid.ColumnDefinitions><ColumnDefinition Width='20'/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock Text='&#xE714;' FontFamily='Segoe Fluent Icons, Segoe MDL2 Assets' FontSize='14' Foreground='"+accent+"' VerticalAlignment='Center'/><TextBlock Grid.Column='1' Text='{Binding Title}' FontSize='12' Foreground='"+fg+"' TextTrimming='CharacterEllipsis' VerticalAlignment='Center' Margin='9,0,0,0'/></Grid></DataTemplate>";
   grid.Columns.Add(new DataGridTemplateColumn { Header=settings.BackupMode=="Folder"?"Folder":"Project",Width=new DataGridLength(1,DataGridLengthUnitType.Star),MinWidth=250,CellTemplate=(DataTemplate)XamlReader.Parse(projectTemplate),SortMemberPath="Title" });grid.Columns.Add(Column("Status","Status",178,false,true));DataGridTextColumn progress=Column("Progress","Percent",80,true,false);progress.SortMemberPath="PercentValue";grid.Columns.Add(progress);DataGridTextColumn eta=Column("ETA","Eta",112,false,false);eta.SortMemberPath="EtaValue";grid.Columns.Add(eta);DataGridTextColumn updated=Column("Updated","Updated",116,false,false);updated.SortMemberPath="UpdatedValue";grid.Columns.Add(updated);grid.SelectionChanged+=delegate { UpdateSelection(); };return grid;
  }
  DataGridTextColumn Column(string header,string property,double width,bool right,bool status) {
   Style style=new Style(typeof(TextBlock));style.Setters.Add(new Setter(FrameworkElement.MarginProperty,new Thickness(14,0,12,0)));style.Setters.Add(new Setter(FrameworkElement.VerticalAlignmentProperty,VerticalAlignment.Center));style.Setters.Add(new Setter(TextBlock.TextTrimmingProperty,TextTrimming.CharacterEllipsis));style.Setters.Add(new Setter(TextBlock.ForegroundProperty,status?(object)new Binding("StatusColor"):(object)Brush(muted)));if(right)style.Setters.Add(new Setter(TextBlock.TextAlignmentProperty,TextAlignment.Right));return new DataGridTextColumn { Header=header,Binding=new Binding(property),Width=width,ElementStyle=style };
  }
  void BuildDetails(Grid main) {
   detailArea=new Border { BorderBrush=Brush(border),BorderThickness=new Thickness(0,1,0,0),Padding=new Thickness(24,13,24,14) };Grid.SetRow(detailArea,4);main.Children.Add(detailArea);StackPanel details=new StackPanel();detailArea.Child=details;selectedTitle=Text("",13,fg);selectedTitle.FontWeight=FontWeights.SemiBold;details.Children.Add(selectedTitle);selectedDetail=Text("",12,muted);selectedDetail.Margin=new Thickness(0,6,0,0);details.Children.Add(selectedDetail);selectedPath=Text("",11,muted);selectedPath.Margin=new Thickness(0,7,0,0);details.Children.Add(selectedPath);selectedProgress=new ProgressBar { Height=4,Minimum=0,Maximum=100,Foreground=Brush(accent),Background=Brush(border),Margin=new Thickness(0,10,0,0),Visibility=Visibility.Collapsed };details.Children.Add(selectedProgress);
  }
  bool MatchesView(Job job) {
   int mode=navigation.SelectedIndex;if(mode==1&&!job.Active)return false;if(mode==2&&(job.Active||job.Attention||!job.BackupCompleted))return false;if(mode==3&&!job.Attention)return false;string search=searchBox.Text.Trim();return search.Length==0||FriendlyTitle(job.Project).IndexOf(search,StringComparison.CurrentCultureIgnoreCase)>=0||job.Project.IndexOf(search,StringComparison.CurrentCultureIgnoreCase)>=0;
  }
  void Apply(Dashboard d) {
   latest=d;int active=d.Jobs.Count(j=>j.Active),attention=d.Jobs.Count(j=>j.Attention),completed=d.Jobs.Count(j=>!j.Active&&!j.Attention&&j.BackupCompleted);int[] counts={d.Jobs.Count,active,completed,attention};for(int i=0;i<counts.Length;i++)navigationCounts[i].Text=counts[i].ToString();noticeArea.Visibility=d.ServiceAttention||d.Activity.Length>0?Visibility.Visible:Visibility.Collapsed;activity.Text=d.ServiceAttention?d.ServiceMessage:d.Activity;activity.Foreground=Brush(d.ServiceAttention?(dark?"#F3C17B":"#9C4D00"):muted);UpdateNotificationButton();List<Job> visible=d.Jobs.Where(MatchesView).ToList();headingStatus.Text=visible.Count+" job"+(visible.Count==1?"":"s")+(active>0?"  \u00B7  "+active+" in progress":"");
   string signature=navigation.SelectedIndex+"|"+searchBox.Text+"|"+String.Join("|",visible.Select(j=>j.Id+j.Phase+j.Detail+j.Bytes+j.Files+j.Progress+j.EtaSeconds+j.ResultFolder+j.UpdatedUtc.Ticks));
   if(signature!=gridSignature) {
    string selectedId=jobsGrid.SelectedItem is JobRow?((JobRow)jobsGrid.SelectedItem).Job.Id:null;List<JobRow> rows=visible.Select(j=>new JobRow { Job=j,Title=FriendlyTitle(j.Project),DateLabel=ProjectDate(j.Project),Status=j.Phase,StatusColor=Brush(j.Attention?(dark?"#F3C17B":"#9C4D00"):j.Active?accent:(dark?"#92C99D":"#2C7340")),Percent=j.ProgressStale||j.Progress<0?"-":j.Progress.ToString("0")+"%",PercentValue=j.Progress,Eta=EtaLabel(j),EtaValue=j.EtaSeconds??Double.MaxValue,Updated=j.UpdatedUtc==DateTime.MinValue?"-":j.UpdatedUtc.ToLocalTime().ToString("h:mm tt"),UpdatedValue=j.UpdatedUtc }).ToList();var sort=jobsGrid.Items.SortDescriptions.ToArray();jobsGrid.ItemsSource=rows;foreach(var description in sort)jobsGrid.Items.SortDescriptions.Add(description);jobsGrid.SelectedItem=rows.FirstOrDefault(r=>r.Job.Id==selectedId)??rows.FirstOrDefault();gridSignature=signature;
   }
   emptyArea.Visibility=visible.Count==0?Visibility.Visible:Visibility.Collapsed;emptyTitle.Text=searchBox.Text.Length>0?"No matching jobs":navigation.SelectedIndex==1?"No jobs in progress":navigation.SelectedIndex==3?"No jobs need attention":"No jobs to show";emptyHint.Text=searchBox.Text.Length>0?(settings.BackupMode=="Folder"?"Try another folder name.":"Try another project name."):navigation.SelectedIndex==1?(settings.BackupMode=="Folder"?"New folder backups will appear here.":"New backups and office jobs will appear here."):navigation.SelectedIndex==3?"No action is needed right now.":(settings.BackupMode=="Folder"?"Choose Back up a folder to start a backup.":"Choose Back up a project to start a footage backup.");footer.Text="Last updated "+DateTime.Now.ToString("h:mm:ss tt")+"   \u00B7   Updates automatically";if(d.UnreadableFiles>0)footer.Text+="   \u00B7   Some status files are updating";UpdateSelection();
  }
  string EtaLabel(Job job) {
   if(job.EtaSeconds.HasValue){double seconds=job.EtaSeconds.Value;if(seconds<60)return "< 1 min";if(seconds<3600)return "~ "+Math.Ceiling(seconds/60)+" min";return "~ "+(seconds/3600).ToString("0.0")+" hr";}return job.OfficeProgress&&!job.ProgressStale&&job.Active&&job.Phase!="Queued at WORKER-PC"&&job.Phase!="Waiting for download"&&job.Phase!="Awaiting replacement"?"Calculating":"-";
  }
  void UpdateSelection() {
   JobRow row=jobsGrid.SelectedItem as JobRow;if(row==null){detailArea.Visibility=Visibility.Collapsed;openProject.IsEnabled=false;openProxies.IsEnabled=false;return;}detailArea.Visibility=Visibility.Visible;Job job=row.Job;selectedTitle.Text=row.Title;selectedDetail.Text=job.Detail;selectedPath.Text=row.DateLabel+(job.Files>0?"   \u00B7   "+job.Files+" source files   \u00B7   "+(job.Bytes/1000000000.0).ToString("0.0")+" GB":"");selectedPath.ToolTip=job.ProjectPath;openProject.IsEnabled=true;openProxies.IsEnabled=!String.IsNullOrEmpty(job.ResultFolder);selectedProgress.Visibility=job.Phase=="Backing up footage"||(job.OfficeProgress&&job.Active&&!job.ProgressStale)?Visibility.Visible:Visibility.Collapsed;selectedProgress.IsIndeterminate=job.Progress<0;selectedProgress.Value=Math.Max(0,job.Progress);
  }
 }
}
