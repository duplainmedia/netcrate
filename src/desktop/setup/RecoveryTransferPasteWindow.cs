using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using Forms = System.Windows.Forms;

namespace NetCrate.Setup
{
    public sealed class RecoveryPasteWindow : Window
    {
        readonly IRecoveryTransferService service;
        readonly Func<string> readClipboard;
        readonly TextBox repository = new TextBox { MinWidth = 300, Margin = new Thickness(0, 8, 0, 8) };
        readonly TextBlock status = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 12) };
        string contents;
        RecoveryPasteContext context;
        RecoveryPasteWindow(IRecoveryTransferService service) : this(service, delegate { return Clipboard.ContainsText() ? Clipboard.GetText() : null; }) { }
        internal RecoveryPasteWindow(IRecoveryTransferService service, Func<string> readClipboard)
        {
            this.service = service;
            this.readClipboard = readClipboard;
            Title = "Paste recovery details · NetCrate"; Width = 650; Height = 430; MinWidth = 520; MinHeight = 380;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            var panel = new StackPanel { Margin = new Thickness(24) }; Content = panel;
            panel.Children.Add(new TextBlock { Text = "Recover using your saved recovery contents", FontSize = 21, TextWrapping = TextWrapping.Wrap });
            panel.Children.Add(new TextBlock { Text = "Copy the complete NetCrate recovery document from your password manager or private document, then choose Paste recovery details. The keys stay in memory for this recovery window and are not displayed or saved.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 12) });
            panel.Children.Add(Command("Paste recovery details", Paste));
            panel.Children.Add(new TextBlock { Text = "Existing originals repository folder (contains config)", Margin = new Thickness(0, 12, 0, 0) });
            AutomationProperties.SetName(repository, "Existing originals repository folder"); panel.Children.Add(repository);
            panel.Children.Add(Command("Choose originals repository", delegate {
                using (var picker = new Forms.FolderBrowserDialog { Description = "Choose the existing originals repository folder containing config.", ShowNewFolderButton = false })
                    if (picker.ShowDialog() == Forms.DialogResult.OK) repository.Text = picker.SelectedPath;
            }));
            panel.Children.Add(status);
            panel.Children.Add(Command("Browse backups", delegate {
                try { context = service.CreatePasteContext(contents, repository.Text); contents = null; DialogResult = true; }
                catch (ArgumentException ex) { status.Text = ex.Message; }
            }));
            Closed += delegate { contents = null; };
        }
        void Paste()
        {
            try
            {
                // Explicit click is the only clipboard read; never inspect clipboard automatically on entry.
                string value = readClipboard();
                RecoveryDocument.Validate(value); contents = value;
                status.Text = "Recovery details supplied. Choose the matching originals repository folder.";
            }
            catch (ArgumentException) { contents = null; status.Text = "Copy and paste a complete NetCrate recovery document."; }
            catch (ExternalException) { status.Text = "The clipboard is busy. Try Paste recovery details again."; }
        }
        static Button Command(string label, Action action)
        {
            var button = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(12, 8, 12, 8) };
            AutomationProperties.SetName(button, label); button.Click += delegate { action(); }; return button;
        }
        public static void Open(Window owner, IRecoveryTransferService service)
        {
            var paste = new RecoveryPasteWindow(service) { Owner = owner };
            if (paste.ShowDialog() != true) return;
            RecoveryPasteContext context = paste.context; paste.context = null;
            try
            {
                var recovery = new NetCrate.RestoreView(new NetCrate.RestoreBrowser(context, new RestoreRequest())) { Owner = owner };
                recovery.Closed += delegate { context.Dispose(); };
                recovery.Show();
            }
            catch { context.Dispose(); throw; }
        }
    }
}
