using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace NetCrate.Setup
{
    public sealed partial class SetupView : Window
    {
        private readonly SetupController controller;
        private readonly IRestoreService restoreService;
        private readonly Grid shell = new Grid();
        private readonly Dictionary<string, Control> controls = new Dictionary<string, Control>();
        private bool checkingSoftware;
        private CancellationTokenSource checkCancellation;
        private readonly BitmapSource logo;
        public bool SetupCompleted { get; private set; }
        private CancellationToken CheckToken { get { return checkCancellation == null ? CancellationToken.None : checkCancellation.Token; } }

        public SetupView(SetupController controller, IRestoreService restoreService = null, INetworkPairingService networkService = null, IRecoveryTransferService recoveryService = null)
        {
            this.controller = controller;
            localAddress = controller.State.NetworkAddress ?? "";
            this.networkService = networkService ?? new WindowsNetworkPairingService(InstallDirectory, SetupDirectory);
            this.recoveryService = recoveryService;
            this.restoreService = restoreService ?? new WindowsSetupService(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "install"));
            Title = "Set up NetCrate";
            Width = 1060;
            Height = 760;
            MinWidth = 800;
            MinHeight = 600;
            Background = Theme.Brush(Theme.Background);
            Foreground = Theme.Brush(Theme.Text);
            FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
            string logoPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "NetCrate.png");
            if (File.Exists(logoPath))
            {
                BitmapImage image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.UriSource = new Uri(logoPath);
                image.EndInit();
                image.Freeze();
                logo = image;
                Icon = logo;
            }
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Content = shell;
            shell.Background = Theme.Brush(Theme.Background);
            InstallStyles();
            controller.Changed += OnChanged;
            Closed += delegate { controller.Changed -= OnChanged; this.networkService.Dispose(); if (clipboard != null) clipboard.Dispose(); };
            Closing += OnClosing;
            SourceInitialized += delegate
            {
                clipboard = new RecoveryClipboardLifetime(new WindowsRecoveryClipboard(new System.Windows.Interop.WindowInteropHelper(this).Handle), new DispatcherRecoveryExpiryScheduler());
                try
                {
                    int enabled = 1;
                    NativeTheme.SetDarkTitleBar(new System.Windows.Interop.WindowInteropHelper(this).Handle, 20, ref enabled, 4);
                }
                catch (DllNotFoundException) { }
                catch (EntryPointNotFoundException) { }
            };
            Loaded += async delegate
            {
                await EnterStepAsync();
                FocusFirst();
            };
            Render();
        }

        private void OnChanged(object sender, EventArgs args)
        {
            if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(new Action(Render)); return; }
            Render();
        }

        private void InstallStyles()
        {
            string style = "<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'>" +
                "<Setter Property='Foreground' Value='" + Theme.Text + "'/><Setter Property='Background' Value='" + Theme.Raised + "'/>" +
                "<Setter Property='BorderBrush' Value='" + Theme.Border + "'/><Setter Property='BorderThickness' Value='1'/>" +
                "<Setter Property='FontSize' Value='14'/><Setter Property='Padding' Value='18,12'/><Setter Property='MinHeight' Value='44'/>" +
                "<Setter Property='Cursor' Value='Hand'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'>" +
                "<Border xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' x:Name='body' Background='{TemplateBinding Background}' " +
                "BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='7'>" +
                "<ContentPresenter Margin='{TemplateBinding Padding}' RecognizesAccessKey='True' HorizontalAlignment='{TemplateBinding HorizontalContentAlignment}' " +
                "VerticalAlignment='Center'/></Border><ControlTemplate.Triggers>" +
                "<Trigger Property='IsMouseOver' Value='True'><Setter TargetName='body' Property='Background' Value='" + Theme.Hover + "'/></Trigger>" +
                "<Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='body' Property='BorderBrush' Value='" + Theme.Accent + "'/>" +
                "<Setter TargetName='body' Property='BorderThickness' Value='2'/></Trigger>" +
                "<Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.45'/></Trigger>" +
                "</ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>";
            Resources.Add(typeof(Button), (Style)XamlReader.Parse(style));
            Resources.Add(typeof(RadioButton), (Style)XamlReader.Parse(style.Replace("TargetType='Button'", "TargetType='RadioButton'")));
            Resources[SystemColors.HighlightBrushKey] = Theme.Brush(Theme.Primary);
        }

        private TextBlock Text(string value, double size, string color)
        {
            return new TextBlock { Text = value, FontSize = size, Foreground = Theme.Brush(color), TextWrapping = TextWrapping.Wrap,
                LineHeight = size * 1.48 };
        }

        private Button Button(string name, Action action, bool primary)
        {
            Button button = new Button { Content = name, HorizontalContentAlignment = HorizontalAlignment.Center,
                Background = Theme.Brush(primary ? Theme.Primary : Theme.Raised), IsEnabled = !controller.Busy && !viewBusy };
            button.Tag = primary ? "Primary" : "Secondary";
            AutomationProperties.SetName(button, name.Replace("_", ""));
            controls[name.Replace("_", "")] = button;
            button.Click += delegate
            {
                try { action(); }
                catch (IOException) { ShowSaveError(); }
                catch (UnauthorizedAccessException) { ShowSaveError(); }
            };
            return button;
        }

        private void Render()
        {
            string focused = Keyboard.FocusedElement is DependencyObject ? AutomationProperties.GetName((DependencyObject)Keyboard.FocusedElement) : "";
            controls.Clear();
            shell.Children.Clear();
            shell.ColumnDefinitions.Clear();
            shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(210) });
            shell.ColumnDefinitions.Add(new ColumnDefinition());
            BuildSidebar();
            Grid main = new Grid { Margin = new Thickness(38, 30, 38, 24) };
            main.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            main.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetColumn(main, 1);
            shell.Children.Add(main);
            ScrollViewer scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
            main.Children.Add(scroll);
            StackPanel content = new StackPanel { Margin = new Thickness(0, 0, 12, 20) };
            scroll.Content = content;
            switch (controller.State.Step)
            {
                case SetupStep.Computer: ComputerScreen(content); break;
                case SetupStep.Folders: FolderScreen(content); break;
                case SetupStep.Prepare: if (recoveryPage) RecoveryScreen(content); else PrepareScreen(content); break;
                case SetupStep.Connect: ConnectScreen(content); break;
                case SetupStep.Check: CheckScreen(content); break;
                case SetupStep.Complete: CompleteScreen(content); break;
            }
            if (controller.Busy || viewBusy || !String.IsNullOrEmpty(controller.LastResult.Message))
            {
                Border status = new Border { Background = Theme.Brush(Theme.Raised), BorderBrush = Theme.Brush(Theme.Border),
                    BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(7), Padding = new Thickness(15), Margin = new Thickness(0, 22, 0, 0) };
                StackPanel lines = new StackPanel();
                status.Child = lines;
                lines.Children.Add(Text(viewBusy ? "Completing this action. Keep setup open until it finishes." : controller.Busy ? controller.ProgressMessage : controller.LastResult.Message, 13,
                    controller.Busy || viewBusy || controller.LastResult.Succeeded ? Theme.Muted : Theme.Warning));
                if (controller.Busy || viewBusy) lines.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 3, Foreground = Theme.Brush(Theme.Accent),
                    Background = Theme.Brush(Theme.Border), Margin = new Thickness(0, 12, 0, 0) });
                content.Children.Add(status);
            }
            if (!String.IsNullOrEmpty(viewMessage)) { var message=Text(viewMessage,13,Theme.Warning); message.Margin=new Thickness(0,18,0,0);content.Children.Add(message); }
            BuildFooter(main);
            Control restore;
            if (!String.IsNullOrEmpty(focused) && controls.TryGetValue(focused, out restore) && restore.IsEnabled) restore.Focus();
        }

        private void BuildSidebar()
        {
            Border sidebar = new Border { Background = Theme.Brush(Theme.Surface), BorderBrush = Theme.Brush(Theme.Border), BorderThickness = new Thickness(0, 0, 1, 0), Padding = new Thickness(23, 30, 23, 24) };
            shell.Children.Add(sidebar);
            DockPanel dock = new DockPanel();
            sidebar.Child = dock;
            StackPanel brand = new StackPanel { Margin = new Thickness(0, 0, 0, 38) };
            TextBlock title = Text("NetCrate", 24, Theme.Text);
            title.FontWeight = FontWeights.SemiBold;
            StackPanel wordmark = new StackPanel { Orientation = Orientation.Horizontal };
            if (logo != null)
                wordmark.Children.Add(new Image { Source = logo, Width = 32, Height = 32, Stretch = Stretch.Uniform,
                    Margin = new Thickness(0, 0, 10, 0), IsHitTestVisible = false });
            wordmark.Children.Add(title);
            brand.Children.Add(wordmark);
            DockPanel.SetDock(brand, Dock.Top);
            dock.Children.Add(brand);
            TextBlock note = Text("Development build", 11, Theme.Muted);
            DockPanel.SetDock(note, Dock.Bottom);
            dock.Children.Add(note);
            StackPanel steps = new StackPanel();
            dock.Children.Add(steps);
            string[] names = controller.State.Role == ComputerRole.BackupServer
                ? new[] { "This computer", "Folders", "Software", "Recovery", "Connection", "Sample check" }
                : new[] { "This computer", "Folders", "Software", "Connection", "Sample check" };
            int current = (int)controller.State.Step;
            if (controller.State.Role == ComputerRole.BackupServer && current >= 3) current++;
            if (controller.State.Step == SetupStep.Prepare && recoveryPage) current=3;
            for (int index = 0; index < names.Length; index++)
            {
                bool selected = current == index;
                bool completed = index < current;
                if(controller.State.Role==ComputerRole.BackupServer&&index==names.Length-1&&!controller.State.SampleVerified){completed=false;if(controller.State.Step==SetupStep.Complete)selected=false;}
                string state = completed ? "Completed" : selected ? "Current" : "Waiting";
                Border row = new Border { Background = Theme.Brush(selected ? Theme.Selected : Theme.Surface), CornerRadius = new CornerRadius(6), Padding = new Thickness(11,10,8,10), Margin = new Thickness(-8,0,-8,6) };
                row.Child = Text((completed ? "✓  " : (index+1)+"  ") + names[index] + "\n" + state,12,selected ? Theme.Text : Theme.Muted);
                AutomationProperties.SetName(row,names[index]+": "+state);steps.Children.Add(row);
            }
        }

        private void Heading(StackPanel panel, string title, string description)
        {
            TextBlock heading = Text(title, 28, Theme.Text);
            heading.FontWeight = FontWeights.SemiBold;
            panel.Children.Add(heading);
            if (String.IsNullOrWhiteSpace(description))
            {
                heading.Margin = new Thickness(0, 0, 0, 25);
                return;
            }
            TextBlock body = Text(description, 14, Theme.Muted);
            body.Margin = new Thickness(0, 10, 0, 25);
            panel.Children.Add(body);
        }

        private void ComputerScreen(StackPanel panel)
        {
            Heading(panel, "Which computer is this?", null);
            panel.Children.Add(RoleCard(ComputerRole.EditingComputer, "Editing Computer", "Stores the files you want to back up.", "\uE770"));
            panel.Children.Add(RoleCard(ComputerRole.BackupServer, "Backup Server", "Stores backups on its connected drive.", "\uE977"));
            panel.Children.Add(Button("Recover from a recovery file",async () => await OpenIndependentRecoveryAsync(false),false));
            var paste=Button("Paste recovery details",async () => await OpenIndependentRecoveryAsync(true),false);paste.Margin=new Thickness(0,10,0,0);panel.Children.Add(paste);
            FlowDiagram(panel);
        }

        private RadioButton RoleCard(ComputerRole role, string title, string description, string glyph)
        {
            RadioButton card = new RadioButton { GroupName = "ComputerRole", IsChecked = controller.State.Role == role,
                IsEnabled = !controller.Busy && !viewBusy };
            AutomationProperties.SetName(card, title);
            AutomationProperties.SetHelpText(card, description);
            controls[title] = card;
            card.Checked += delegate
            {
                if (controller.State.Role == role) return;
                try { controller.ChooseComputer(role); }
                catch (IOException) { ShowSaveError(); }
                catch (UnauthorizedAccessException) { ShowSaveError(); }
            };
            card.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            card.Padding = new Thickness(20);
            card.Margin = new Thickness(0, 0, 0, 13);
            bool selected = controller.State.Role == role;
            card.Background = Theme.Brush(selected ? Theme.Selected : Theme.Surface);
            card.BorderBrush = Theme.Brush(selected ? Theme.Accent : Theme.Border);
            Grid layout = new Grid();
            layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
            layout.ColumnDefinitions.Add(new ColumnDefinition());
            layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
            TextBlock icon = Text(glyph, 27, Theme.Accent);
            icon.FontFamily = new FontFamily("Segoe MDL2 Assets");
            icon.VerticalAlignment = VerticalAlignment.Center;
            layout.Children.Add(icon);
            StackPanel words = new StackPanel();
            Grid.SetColumn(words, 1);
            layout.Children.Add(words);
            TextBlock heading = Text(title, 17, Theme.Text);
            heading.FontWeight = FontWeights.SemiBold;
            words.Children.Add(heading);
            TextBlock body = Text(description, 13, Theme.Muted);
            body.Margin = new Thickness(0, 5, 8, 0);
            words.Children.Add(body);
            TextBlock indicator = Text(selected ? "\u25CF" : "\u25CB", 20, selected ? Theme.Accent : Theme.Muted);
            indicator.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(indicator, 2);
            layout.Children.Add(indicator);
            card.Content = layout;
            return card;
        }

        private void FlowDiagram(StackPanel panel)
        {
            Border border = new Border { Background = Theme.Brush(Theme.Surface), CornerRadius = new CornerRadius(7), Padding = new Thickness(20), Margin = new Thickness(0, 14, 0, 0) };
            Grid flow = new Grid();
            flow.ColumnDefinitions.Add(new ColumnDefinition());
            flow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
            flow.ColumnDefinitions.Add(new ColumnDefinition());
            border.Child = flow;
            TextBlock editing = Text("Editing Computer", 12, Theme.Text);
            editing.VerticalAlignment = VerticalAlignment.Center;
            flow.Children.Add(editing);
            TextBlock arrows = Text("Files  \u2192\nPrivate backups", 12, Theme.Accent);
            arrows.TextAlignment = TextAlignment.Center;
            Grid.SetColumn(arrows, 1);
            flow.Children.Add(arrows);
            TextBlock backup = Text("Backup Server", 12, Theme.Text);
            backup.TextAlignment = TextAlignment.Right;
            backup.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(backup, 2);
            flow.Children.Add(backup);
            panel.Children.Add(border);
        }

        private void FolderScreen(StackPanel panel)
        {
            bool editing = controller.State.Role == ComputerRole.EditingComputer;
            bool media = controller.State.BackupMode == "Media";
            Heading(panel, editing ? "Which files should NetCrate back up?" : "Where should backups go?", editing
                ? (media ? "Choose the folder containing your video projects. Select one project after setup." : "Choose an ordinary local folder. After setup, back up this whole folder or any folder inside it.")
                : "Choose storage on a connected drive. Select Folder backups for an ordinary source, or Backups and media processing if the source requests proxies.");
            panel.Children.Add(ModeChoice("Folder", "Folder backups"));
            panel.Children.Add(ModeChoice("Media", "Backups and media processing"));
            Border choice = new Border { Background = Theme.Brush(Theme.Surface), BorderBrush = Theme.Brush(Theme.Border), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(22) };
            StackPanel contents = new StackPanel();
            choice.Child = contents;
            contents.Children.Add(Text(editing ? (media ? "Project folder" : "Files to back up") : "Backup storage", 13, Theme.Muted));
            TextBox path=Input("Full folder path",folderDraft ?? controller.State.Folder ?? "");
            path.Margin=new Thickness(0,9,0,12);path.TextChanged += delegate { folderDraft=path.Text; UpdateFooter(); };contents.Children.Add(path);
            contents.Children.Add(Text("Enter a full local path, or choose a folder. The selected path and its ancestors are validated before continuing.",12,Theme.Muted));
            Button pick = Button("_Choose folder", PickFolder, false);
            pick.HorizontalAlignment = HorizontalAlignment.Left;
            contents.Children.Add(pick);
            panel.Children.Add(choice);
            if (editing && media)
            {
                TextBlock hint = Text("Returned proxies go into each project's Proxies folder.", 13, Theme.Muted);
                hint.Margin = new Thickness(0, 18, 0, 0);
                panel.Children.Add(hint);
            }
        }

        private RadioButton ModeChoice(string mode, string label)
        {
            RadioButton choice = new RadioButton { Content = (controller.State.BackupMode == mode ? "\u25CF  " : "\u25CB  ") + label, GroupName = "BackupMode", IsChecked = controller.State.BackupMode == mode,
                IsEnabled = !controller.Busy, Margin = new Thickness(0, 0, 0, 12), Padding = new Thickness(8), Foreground = Theme.Brush(Theme.Text) };
            AutomationProperties.SetName(choice, label);
            choice.Checked += delegate { if (controller.State.BackupMode != mode) controller.ChooseBackupMode(mode); };
            return choice;
        }

        private async void PickFolder()
        {
            using (Forms.FolderBrowserDialog picker = new Forms.FolderBrowserDialog())
            {
                picker.Description = controller.State.Role == ComputerRole.EditingComputer ? (controller.State.BackupMode == "Media" ? "Choose the folder containing your video projects" : "Choose a folder containing your files") : "Choose backup storage";
                picker.ShowNewFolderButton = true;
                picker.RootFolder=Environment.SpecialFolder.MyComputer;picker.SelectedPath=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                if (!String.IsNullOrEmpty(controller.State.Folder)) picker.SelectedPath = controller.State.Folder;
                if (picker.ShowDialog(new WindowOwner(new System.Windows.Interop.WindowInteropHelper(this).Handle)) == Forms.DialogResult.OK)
                { folderDraft=picker.SelectedPath; await RunSafeAsync(() => controller.ChooseFolderAsync(picker.SelectedPath, CheckToken)); }
            }
        }

    }
    internal static class NativeTheme
    {
        [System.Runtime.InteropServices.DllImport("dwmapi.dll",EntryPoint="DwmSetWindowAttribute")]
        internal static extern int SetDarkTitleBar(IntPtr window,int attribute,ref int value,int size);
    }
}
