using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.VisualTree;
using NPVideoStudio.App.ViewModels;

namespace NPVideoStudio.App.Views;

public partial class SunoStudioView : UserControl
{
    private NativeWebDialog? _dialog;
    private bool _smokeAutoOpenStarted;

    public SunoStudioView()
    {
        InitializeComponent();
        AttachedToVisualTree += async (_, _) => await AutoOpenForSmokeTestAsync();
    }

    private void OpenSunoStudio_Click(object? sender, RoutedEventArgs e) => OpenSunoStudio();

    private void OpenSunoStudio()
    {
        if (DataContext is not SunoStudioViewModel vm || !vm.IsReady || _dialog is not null)
        {
            return;
        }

        try
        {
            var dialog = new NativeWebDialog
            {
                Title = "NP + Suno Unified Studio — Suno Pesme Studio",
                CanUserResize = true,
                Source = vm.Source
            };

            dialog.Closing += (_, _) =>
            {
                dialog.Dispose();
                _dialog = null;
            };

            _dialog = dialog;
            if (TopLevel.GetTopLevel(this) is Window owner)
            {
                dialog.Show(owner);
            }
            else
            {
                dialog.Show();
            }
        }
        catch (Exception ex)
        {
            _dialog?.Dispose();
            _dialog = null;
            vm.Status = "Suno prozor nije mogao da se otvori: " + ex.Message;
        }
    }

    private async Task AutoOpenForSmokeTestAsync()
    {
        if (_smokeAutoOpenStarted ||
            Environment.GetEnvironmentVariable("NP_SUNO_SMOKE_AUTO_OPEN") != "1")
        {
            return;
        }

        _smokeAutoOpenStarted = true;
        for (var attempt = 0; attempt < 120; attempt++)
        {
            if (DataContext is SunoStudioViewModel vm)
            {
                if (vm.IsReady)
                {
                    OpenSunoStudio();
                    return;
                }

                if (!vm.IsBusy && vm.Status.StartsWith("Suno Studio nije mogao", StringComparison.Ordinal))
                {
                    return;
                }
            }

            await Task.Delay(250);
        }
    }
}
