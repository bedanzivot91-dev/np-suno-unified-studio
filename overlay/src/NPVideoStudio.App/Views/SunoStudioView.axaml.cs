using Avalonia.Controls;
using Avalonia.Interactivity;
using NPVideoStudio.App.ViewModels;

namespace NPVideoStudio.App.Views;

public partial class SunoStudioView : UserControl
{
    private NativeWebDialog? _dialog;

    public SunoStudioView()
    {
        InitializeComponent();
    }

    private void OpenSunoStudio_Click(object? sender, RoutedEventArgs e)
    {
        if (DataContext is not SunoStudioViewModel vm || !vm.IsReady)
        {
            return;
        }

        if (_dialog is not null)
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
}
