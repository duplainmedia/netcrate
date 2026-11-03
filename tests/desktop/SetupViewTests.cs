using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using NetCrate.Setup;

class SetupViewTests
{
    static int assertions;
    static void Assert(bool value, string message) { if (!value) throw new Exception(message); assertions++; }
    [STAThread]
    static void Main()
    {
        Application app = new Application();
        SetupController controller = new SetupController(new WindowsSetupService(@"C:\No-Setup-Engine"), new MemoryStore());
        SetupView view = new SetupView(controller);
        List<RadioButton> roles = Find<RadioButton>(view);
        Assert(roles.Count == 2, "Computer choices do not expose radio selection semantics.");
        RadioButton editing = roles[0];
        Assert(!String.IsNullOrWhiteSpace(AutomationProperties.GetHelpText(editing)), "The computer choice has no accessible explanation.");
        AutomationPeer peer = UIElementAutomationPeer.CreatePeerForElement(editing);
        ISelectionItemProvider selection = peer.GetPattern(PatternInterface.SelectionItem) as ISelectionItemProvider;
        Assert(selection != null && !selection.IsSelected, "An unchosen role was not exposed as unselected.");
        selection.Select();
        Assert(controller.State.Role == ComputerRole.EditingComputer && controller.CanContinue,
            "Accessible role selection did not update setup and its Continue gate.");
        roles = Find<RadioButton>(view);
        peer = UIElementAutomationPeer.CreatePeerForElement(roles[1]);
        selection = (ISelectionItemProvider)peer.GetPattern(PatternInterface.SelectionItem);
        selection.Select();
        roles = Find<RadioButton>(view);
        Assert(controller.State.Role == ComputerRole.BackupServer && roles[1].IsChecked == true && roles[0].IsChecked == false,
            "Changing roles did not expose one selected computer choice.");
        controller.Continue();
        List<RadioButton> modes=Find<RadioButton>(view);
        Assert(modes.Count==2,"The server cannot choose folder-only capability before preparation.");
        RadioButton media=modes.Find(r=>AutomationProperties.GetName(r)=="Backups and media processing");
        Assert(media!=null,"The optional media choice is not accessible.");
        peer=UIElementAutomationPeer.CreatePeerForElement(media);
        ((ISelectionItemProvider)peer.GetPattern(PatternInterface.SelectionItem)).Select();
        Assert(controller.State.BackupMode=="Media","Clicking media capability did not change the setup request.");
        modes=Find<RadioButton>(view);
        Assert(Convert.ToString(modes.Find(r=>r.IsChecked==true).Content).StartsWith("\u25CF"),"The chosen backup mode has no explicit visible selection indicator.");
        view.Close();
        app.Shutdown();
        Console.WriteLine("PASS: " + assertions + " native role accessibility assertions.");
    }

    static List<T> Find<T>(DependencyObject root) where T : DependencyObject
    {
        List<T> result = new List<T>();
        if (root is T) result.Add((T)root);
        foreach (object child in LogicalTreeHelper.GetChildren(root))
            if (child is DependencyObject) result.AddRange(Find<T>((DependencyObject)child));
        return result;
    }

    private class MemoryStore : ISetupStore
    {
        public SetupState Load() { return null; }
        public void Save(SetupState state) { }
    }
}
