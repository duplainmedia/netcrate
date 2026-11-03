using System;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using NetCrate.Setup;

namespace NetCrate
{
    internal static class SetupStartup
    {
        public static bool Run()
        {
            string setupRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NetCrate", "Setup");
            string engine = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "install");
            WindowsSetupService service = new WindowsSetupService(engine, setupRoot);
            SetupController controller = new SetupController(service,
                new JsonSetupStore(Path.Combine(setupRoot, "state.json")));
            Application app = new Application();
            SetupView view = new SetupView(controller, service);
            app.Run(view);
            return view.SetupCompleted;
        }

        public static void Render(string output, bool folders, bool compact, bool connect = false)
        {
            Application app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            SetupState state = new SetupState();
            if (folders) state.Role = ComputerRole.EditingComputer;
            SetupController controller = new SetupController(new WindowsSetupService(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "install")), new PreviewStore(state));
            if (connect) { controller.State.Role = ComputerRole.EditingComputer; controller.State.Step = SetupStep.Connect; controller.State.Prepared = true; }
            SetupView view = new SetupView(controller);
            if (compact) { view.Width = view.MinWidth; view.Height = view.MinHeight; }
            view.Show();
            view.Dispatcher.Invoke(System.Windows.Threading.DispatcherPriority.Render, new Action(delegate { }));
            view.UpdateLayout();
            FrameworkElement content = (FrameworkElement)view.Content;
            RenderTargetBitmap image = new RenderTargetBitmap((int)content.ActualWidth, (int)content.ActualHeight, 96, 96, PixelFormats.Pbgra32);
            image.Render(content);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(image));
            using (FileStream file = File.Create(output)) encoder.Save(file);
            view.Close();
            app.Shutdown();
        }

        private sealed class PreviewStore : ISetupStore
        {
            private readonly SetupState state;
            public PreviewStore(SetupState state) { this.state = state; }
            public SetupState Load() { return state.Copy(); }
            public void Save(SetupState state) { }
        }
    }
}
