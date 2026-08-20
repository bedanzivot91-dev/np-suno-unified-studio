using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using NPVideoStudio.App.Services;

namespace NPVideoStudio.App.ViewModels;

public sealed partial class SunoStudioViewModel : ViewModelBase
{
    private readonly SunoStudioHostService _host;

    [ObservableProperty]
    private Uri _source = new("about:blank");

    [ObservableProperty]
    private string _status = "Pokrećem Suno Studio...";

    [ObservableProperty]
    private bool _isReady;

    [ObservableProperty]
    private bool _isBusy;

    public SunoStudioViewModel(SunoStudioHostService host)
    {
        _host = host;
    }

    public Task InitializeAsync() => StartAsync();

    [RelayCommand]
    private async Task RetryAsync() => await StartAsync();

    private async Task StartAsync()
    {
        if (IsBusy)
        {
            return;
        }

        IsBusy = true;
        IsReady = false;
        Status = "Pokrećem Suno Studio...";
        try
        {
            await _host.StartAsync();
            Source = _host.BaseUri;
            IsReady = true;
            Status = "Suno Studio je spreman.";
        }
        catch (Exception ex)
        {
            Status = "Suno Studio nije mogao da se pokrene: " + ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }
}
