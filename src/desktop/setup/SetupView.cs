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
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace NetCrate.Setup
{
    public sealed class SetupView : Window
    {
        private readonly SetupController controller;
        private readonly Grid shell = new Grid();
        private readonly Dictionary<string, Control> controls = new Dictionary<string, Control>();
        private bool checkingSoftware;
        private CancellationTokenSource checkCancellation;
        private bool closeAfterCheck;
        private CancellationToken CheckToken { get { return checkCancellation == null ? CancellationToken.None : checkCancellation.Token; } }

        public SetupView(SetupController controller)
        {
            this.controller = controller;
            Title = "Set up NetCrate";
            Width = 1060;
            Height = 760;
            MinWidth = 800;
            MinHeight = 600;
            Background = Theme.Brush(Theme.Background);
            Foreground = Theme.Brush(Theme.Text);
            FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Content = shell;
            shell.Background = Theme.Brush(Theme.Background);
            InstallStyles();
            controller.Changed += OnChanged;
            Closed += delegate { controller.Changed -= OnChanged; };
            Closing += delegate(object sender, System.ComponentModel.CancelEventArgs args)
            {
                if (controller.Busy)
                {
                    args.Cancel = true;
                    if (!controller.IsInstalling && checkCancellation != null)
                    {
                        closeAfterCheck = true;
                        checkCancellation.Cancel();
                    }
                }
            };
            SourceInitialized += delegate
            {
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
                if (controller.State.Step == SetupStep.Prepare) await InspectAsync();
                FocusFirst();
            };
            Render();
        }

        private void OnChanged(object sender, EventArgs args)
        {
            if (closeAfterCheck && !controller.Busy) { Dispatcher.BeginInvoke(new Action(Close)); return; }
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
                Background = Theme.Brush(primary ? Theme.Primary : Theme.Raised), IsEnabled = !controller.Busy };
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
            TextBlock label = Text("SET UP NETCRATE", 11, Theme.Accent);
            label.FontWeight = FontWeights.SemiBold;
            label.Margin = new Thickness(0, 0, 0, 13);
            content.Children.Add(label);
            switch (controller.State.Step)
            {
                case SetupStep.Computer: ComputerScreen(content); break;
                case SetupStep.Folders: FolderScreen(content); break;
                case SetupStep.Prepare: PrepareScreen(content); break;
                case SetupStep.Connect: ConnectScreen(content); break;
                case SetupStep.Check: CheckScreen(content); break;
                case SetupStep.Complete: CompleteScreen(content); break;
            }
            if (controller.Busy || !String.IsNullOrEmpty(controller.LastResult.Message))
            {
                Border status = new Border { Background = Theme.Brush(Theme.Raised), BorderBrush = Theme.Brush(Theme.Border),
                    BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(7), Padding = new Thickness(15), Margin = new Thickness(0, 22, 0, 0) };
                StackPanel lines = new StackPanel();
                status.Child = lines;
                lines.Children.Add(Text(controller.Busy ? controller.ProgressMessage : controller.LastResult.Message, 13,
                    controller.Busy || controller.LastResult.Succeeded ? Theme.Muted : Theme.Warning));
                if (controller.Busy) lines.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 3, Foreground = Theme.Brush(Theme.Accent),
                    Background = Theme.Brush(Theme.Border), Margin = new Thickness(0, 12, 0, 0) });
                content.Children.Add(status);
            }
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
            brand.Children.Add(title);
            brand.Children.Add(Text("Your footage.\nYour computers.", 12, Theme.Muted));
            DockPanel.SetDock(brand, Dock.Top);
            dock.Children.Add(brand);
            TextBlock note = Text("Development build\nPairing and round-trip checks are still in development.", 11, Theme.Muted);
            DockPanel.SetDock(note, Dock.Bottom);
            dock.Children.Add(note);
            StackPanel steps = new StackPanel();
            dock.Children.Add(steps);
            string[] names = { "This computer", "Folders", "Preparation", "Connection", "Sample check" };
            for (int index = 0; index < names.Length; index++)
            {
                bool selected = Math.Min(4, (int)controller.State.Step) == index;
                Border row = new Border { Background = Theme.Brush(selected ? Theme.Selected : Theme.Surface), CornerRadius = new CornerRadius(6),
                    Padding = new Thickness(11, 12, 8, 12), Margin = new Thickness(-8, 0, -8, 8) };
                row.Child = Text((index + 1) + "   " + names[index], 13, selected ? Theme.Text : Theme.Muted);
                steps.Children.Add(row);
            }
        }

        private void Heading(StackPanel panel, string title, string description)
        {
            TextBlock heading = Text(title, 28, Theme.Text);
            heading.FontWeight = FontWeights.SemiBold;
            panel.Children.Add(heading);
            TextBlock body = Text(description, 14, Theme.Muted);
            body.Margin = new Thickness(0, 10, 0, 25);
            panel.Children.Add(body);
        }

        private void ComputerScreen(StackPanel panel)
        {
            Heading(panel, "Which computer is this?", "Install NetCrate on both computers. Choose the job for the one you are using now.");
            panel.Children.Add(RoleCard(ComputerRole.EditingComputer, "Editing Computer", "The computer where you keep your projects and edit. Proxies come back here.", "\uE770"));
            panel.Children.Add(RoleCard(ComputerRole.BackupServer, "Backup Server", "The other computer. It stores your backups and creates proxies while you keep working.", "\uE977"));
            FlowDiagram(panel);
        }

        private RadioButton RoleCard(ComputerRole role, string title, string description, string glyph)
        {
            RadioButton card = new RadioButton { GroupName = "ComputerRole", IsChecked = controller.State.Role == role,
                IsEnabled = !controller.Busy };
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
            TextBlock arrows = Text("Footage  \u2192\n\u2190  Proxies", 12, Theme.Accent);
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
            Heading(panel, editing ? "Where are your projects?" : "Where should backups go?", editing
                ? "Choose the folder that contains your project folders. You will choose a project to back up after setup."
                : "Choose a folder on the drive you want to use for backups. Give your footage room to grow.");
            Border choice = new Border { Background = Theme.Brush(Theme.Surface), BorderBrush = Theme.Brush(Theme.Border), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(22) };
            StackPanel contents = new StackPanel();
            choice.Child = contents;
            contents.Children.Add(Text(editing ? "Project folder" : "Backup storage", 13, Theme.Muted));
            TextBlock path = Text(String.IsNullOrEmpty(controller.State.Folder) ? "No folder selected" : controller.State.Folder, 17, Theme.Text);
            path.Margin = new Thickness(0, 9, 0, 18);
            contents.Children.Add(path);
            Button pick = Button("_Choose folder", PickFolder, false);
            pick.HorizontalAlignment = HorizontalAlignment.Left;
            contents.Children.Add(pick);
            panel.Children.Add(choice);
            TextBlock hint = Text(editing ? "Returned proxies go into each project's Proxies folder automatically." : "Selecting a folder does not format the drive or start a backup.", 13, Theme.Muted);
            hint.Margin = new Thickness(0, 18, 0, 0);
            panel.Children.Add(hint);
        }

        private async void PickFolder()
        {
            using (Forms.FolderBrowserDialog picker = new Forms.FolderBrowserDialog())
            {
                picker.Description = controller.State.Role == ComputerRole.EditingComputer ? "Choose the folder containing your video projects" : "Choose backup storage";
                picker.ShowNewFolderButton = true;
                if (!String.IsNullOrEmpty(controller.State.Folder)) picker.SelectedPath = controller.State.Folder;
                if (picker.ShowDialog(new WindowOwner(new System.Windows.Interop.WindowInteropHelper(this).Handle)) == Forms.DialogResult.OK)
                    await RunSafeAsync(() => controller.ChooseFolderAsync(picker.SelectedPath, CheckToken));
            }
        }

        private void PrepareScreen(StackPanel panel)
        {
            Heading(panel, "Prepare this computer", "NetCrate checks the software it needs and installs missing supported tools. Windows may ask for your approval.");
            foreach (SoftwareCheck check in controller.LastResult.Software)
            {
                Border row = new Border { Background = Theme.Brush(Theme.Surface), BorderBrush = Theme.Brush(Theme.Border), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6), Padding = new Thickness(15, 12, 15, 12), Margin = new Thickness(0, 0, 0, 8) };
                StackPanel words = new StackPanel();
                row.Child = words;
                words.Children.Add(Text(check.Name + (check.Available ? "  \u00B7  Found" : "  \u00B7  Needed"), 14, Theme.Text));
                words.Children.Add(Text(check.Purpose, 12, Theme.Muted));
                panel.Children.Add(row);
            }
            bool retryCheck = controller.LastResult.Code == "probe-timeout" || controller.LastResult.Code == "cancelled" ||
                controller.LastResult.Code == "operation-failed" || controller.LastResult.Code == "installer-missing";
            Button prepare = Button(retryCheck ? "Try again" : controller.State.Prepared ? "Check again" : "_Prepare this computer",
                async () => await RunSafeAsync(() => retryCheck ? controller.InspectAsync(CheckToken) : controller.PrepareAsync(CheckToken)), true);
            prepare.HorizontalAlignment = HorizontalAlignment.Left;
            prepare.Margin = new Thickness(0, 12, 0, 0);
            panel.Children.Add(prepare);
            Expander details = new Expander { Header = "Software details", Foreground = Theme.Brush(Theme.Muted), Margin = new Thickness(0, 16, 0, 0),
                Content = Text("PowerShell runs tasks. Restic encrypts backups. The Backup Server also needs FFmpeg, Python and Pillow for proxies and contact sheets. Installation uses pinned Windows Package Manager entries with installer hash checks. Read THIRD-PARTY.md for license information. This development build does not yet install the worker's Python runtime automatically.", 12, Theme.Muted) };
            panel.Children.Add(details);
            if (controller.State.Role == ComputerRole.BackupServer && controller.State.Prepared)
            {
                TextBlock recovery = Text("Save recovery details somewhere separate from your backup drive. You will need them if this computer fails.", 13, Theme.Muted);
                recovery.Margin = new Thickness(0, 20, 0, 12);
                panel.Children.Add(recovery);
                panel.Children.Add(Button("Save recovery details", SaveRecovery, false));
                CheckBox confirm = new CheckBox { Content = "I saved a separate copy of my recovery details", IsChecked = controller.State.RecoveryConfirmed,
                    IsEnabled = controller.State.RecoveryExported && !controller.Busy, Foreground = Theme.Brush(Theme.Text), Margin = new Thickness(0, 14, 0, 0) };
                confirm.Checked += delegate { try { controller.SetRecoveryConfirmed(true); } catch (IOException) { ShowSaveError(); } catch (UnauthorizedAccessException) { ShowSaveError(); } };
                confirm.Unchecked += delegate { try { controller.SetRecoveryConfirmed(false); } catch (IOException) { ShowSaveError(); } catch (UnauthorizedAccessException) { ShowSaveError(); } };
                panel.Children.Add(confirm);
            }
        }

        private async Task InspectAsync()
        {
            if (checkingSoftware) return;
            checkingSoftware = true;
            try { await RunSafeAsync(() => controller.InspectAsync(CheckToken)); }
            finally { checkingSoftware = false; }
        }

        private async void SaveRecovery()
        {
            SaveFileDialog picker = new SaveFileDialog { Title = "Save recovery details", FileName = "NetCrate recovery", DefaultExt = ".netcrate", Filter = "NetCrate recovery|*.netcrate" };
            if (picker.ShowDialog(this) == true)
                await RunSafeAsync(() => controller.SaveRecoveryAsync(picker.FileName, CheckToken));
        }

        private void ConnectScreen(StackPanel panel)
        {
            Heading(panel, "Connect your computers", "Both computers need to be on the same private network. Open NetCrate on your other computer and choose its role there too.");
            FlowDiagram(panel);
            Button guide = Button("Open private network guide", () => Process.Start(new ProcessStartInfo("https://docs.netbird.io/get-started/install/windows") { UseShellExecute = true }), false);
            guide.Margin = new Thickness(0, 20, 0, 10);
            panel.Children.Add(guide);
            panel.Children.Add(Text("Computer pairing is still being built. This development version can check software, but cannot connect a backup repository yet.", 14, Theme.Warning));
            Button check = Button("Check connection", async () => await RunSafeAsync(() => controller.CheckConnectionAsync(CheckToken)), true);
            check.HorizontalAlignment = HorizontalAlignment.Left;
            check.Margin = new Thickness(0, 20, 0, 0);
            panel.Children.Add(check);
        }

        private void CheckScreen(StackPanel panel)
        {
            Heading(panel, "Check the round trip", controller.State.Role == ComputerRole.EditingComputer
                ? "A short generated sample will travel to the Backup Server. Its returned proxy must pass local verification."
                : "The Editing Computer starts the sample check. Keep this computer on while it runs.");
            panel.Children.Add(Button("Run sample check", async () => await RunSafeAsync(() => controller.CheckSampleAsync(CheckToken)), true));
        }

        private void CompleteScreen(StackPanel panel)
        {
            Heading(panel, "Your computers are ready", "The sample proxy returned and passed verification. You can now choose a project to back up.");
        }

        private void BuildFooter(Grid main)
        {
            Grid footer = new Grid { Margin = new Thickness(0, 16, 0, 0) };
            footer.ColumnDefinitions.Add(new ColumnDefinition());
            footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetRow(footer, 1);
            main.Children.Add(footer);
            Button back = Button("_Back", async () => await RunSafeAsync(async () =>
            {
                controller.Back();
                if (controller.State.Step == SetupStep.Prepare) await InspectAsync();
                FocusFirst();
            }), false);
            back.HorizontalAlignment = HorizontalAlignment.Left;
            back.Visibility = controller.State.Step == SetupStep.Computer ? Visibility.Hidden : Visibility.Visible;
            footer.Children.Add(back);
            if (controller.Busy && !controller.IsInstalling)
            {
                back.Visibility = Visibility.Collapsed;
                Button cancel = Button("Cancel check", () => { if (checkCancellation != null) checkCancellation.Cancel(); }, false);
                cancel.IsEnabled = true;
                cancel.HorizontalAlignment = HorizontalAlignment.Left;
                footer.Children.Add(cancel);
            }
            Button next = Button("_Continue", async () => await RunSafeAsync(async () =>
            {
                controller.Continue();
                if (controller.State.Step == SetupStep.Prepare) await InspectAsync();
                FocusFirst();
            }), true);
            next.IsEnabled = controller.CanContinue;
            next.MinWidth = 128;
            next.IsDefault = controller.State.Step != SetupStep.Computer;
            Grid.SetColumn(next, 1);
            footer.Children.Add(next);
        }

        private async Task RunSafeAsync(Func<Task> action)
        {
            CancellationTokenSource previous = checkCancellation;
            CancellationTokenSource current = new CancellationTokenSource();
            checkCancellation = current;
            try { await action(); }
            catch (IOException) { MessageBox.Show(this, "Your setup choices could not be saved. Check the free space and permissions in your Windows user folder, then reopen NetCrate.", "NetCrate", MessageBoxButton.OK, MessageBoxImage.Information); }
            catch (UnauthorizedAccessException) { MessageBox.Show(this, "NetCrate cannot save setup choices in your Windows user folder. Check the folder permissions, then reopen NetCrate.", "NetCrate", MessageBoxButton.OK, MessageBoxImage.Information); }
            finally
            {
                if (checkCancellation == current) checkCancellation = previous;
                current.Dispose();
            }
        }

        private void ShowSaveError()
        {
            MessageBox.Show(this, "Your setup choices could not be saved. Check the free space and permissions in your Windows user folder, then reopen NetCrate.", "NetCrate", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private void FocusFirst()
        {
            string name = controller.State.Step == SetupStep.Computer ? "Editing Computer"
                : controller.State.Step == SetupStep.Folders ? "Choose folder" : "Continue";
            Control control;
            if (controls.TryGetValue(name, out control) && control.IsEnabled) control.Focus();
        }

        private sealed class WindowOwner : Forms.IWin32Window
        {
            public IntPtr Handle { get; private set; }
            public WindowOwner(IntPtr handle) { Handle = handle; }
        }
    }

    internal static class NativeTheme
    {
        [System.Runtime.InteropServices.DllImport("dwmapi.dll", EntryPoint = "DwmSetWindowAttribute")]
        internal static extern int SetDarkTitleBar(IntPtr window, int attribute, ref int value, int size);
    }
}
