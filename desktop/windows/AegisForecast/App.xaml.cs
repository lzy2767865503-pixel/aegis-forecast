using Microsoft.UI.Xaml;

namespace AegisForecast;

public partial class App : Application
{
    public static Window? MainWindow { get; private set; }

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, args) =>
        {
            System.Diagnostics.Debug.WriteLine(args.Exception);
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        MainWindow = new MainWindow();
        MainWindow.Activate();
    }
}
