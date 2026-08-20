using System.Diagnostics;
using System.Net.Http.Json;
using NPVideoStudio.Domain;

namespace NPVideoStudio.App.Services;

/// <summary>
/// Starts the embedded Suno Pesme Studio HTTP backend as a private sidecar process.
/// The original Suno repository is never modified; the unified build ships a pinned copy
/// under SunoEngine/ and gives it a separate AppData root and a dedicated local port.
/// </summary>
public sealed class SunoStudioHostService : IAsyncDisposable
{
    private const int Port = 18765;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(2) };
    private readonly SemaphoreSlim _gate = new(1, 1);
    private Process? _process;

    public Uri BaseUri { get; } = new($"http://127.0.0.1:{Port}/");

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (await IsHealthyAsync(cancellationToken).ConfigureAwait(false))
            {
                return;
            }

            if (_process is { HasExited: false })
            {
                await WaitUntilHealthyAsync(cancellationToken).ConfigureAwait(false);
                return;
            }

            var engineRoot = Path.Combine(AppContext.BaseDirectory, "SunoEngine");
            var python = Path.Combine(engineRoot, "python", "pythonw.exe");
            var server = Path.Combine(engineRoot, "app", "server.py");

            if (!File.Exists(python))
            {
                throw new FileNotFoundException("Ugrađeni Suno Python runtime nije pronađen.", python);
            }
            if (!File.Exists(server))
            {
                throw new FileNotFoundException("Ugrađeni Suno server nije pronađen.", server);
            }

            var sunoDataRoot = Path.Combine(AppSettings.AppDataRoot(), "Suno");
            Directory.CreateDirectory(sunoDataRoot);

            var psi = new ProcessStartInfo
            {
                FileName = python,
                WorkingDirectory = engineRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            psi.ArgumentList.Add(server);
            psi.Environment["SUNO_AUTO_OPEN"] = "0";
            psi.Environment["SUNO_STUDIO_PORT"] = Port.ToString();
            psi.Environment["SUNO_DISABLE_AUTO_UPDATE"] = "1";
            psi.Environment["PYTHONUTF8"] = "1";
            psi.Environment["SUNO_STUDIO_USER_DIR"] = sunoDataRoot;
            psi.Environment["SUNO_STUDIO_DATA_DIR"] = Path.Combine(sunoDataRoot, "data");
            psi.Environment["SUNO_STUDIO_DOWNLOAD_DIR"] = Path.Combine(sunoDataRoot, "Preuzete_pesme");
            psi.Environment["SUNO_STUDIO_EXPORT_DIR"] = Path.Combine(sunoDataRoot, "Izvoz");
            psi.Environment["SUNO_STUDIO_PUBLISHED_DIR"] = Path.Combine(sunoDataRoot, "OBRADJENO_NA_YOUTUBE");
            psi.Environment["SUNO_STUDIO_LIBRARY_DIR"] = Path.Combine(sunoDataRoot, "Biblioteka_pesama");
            psi.Environment["SUNO_STUDIO_RECOGNITION_DIR"] = Path.Combine(sunoDataRoot, "Pronalazac_pesme");

            _process = Process.Start(psi) ?? throw new InvalidOperationException("Suno backend nije mogao da se pokrene.");
            await WaitUntilHealthyAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_process is null && !await IsHealthyAsync(cancellationToken).ConfigureAwait(false))
            {
                return;
            }

            try
            {
                using var response = await _http.PostAsJsonAsync(new Uri(BaseUri, "api/shutdown"), new { }, cancellationToken).ConfigureAwait(false);
                _ = response.IsSuccessStatusCode;
            }
            catch
            {
                // Shutdown falls back to terminating only the child process started by this unified app.
            }

            if (_process is { HasExited: false } process)
            {
                var exited = await Task.Run(() => process.WaitForExit(3000), cancellationToken).ConfigureAwait(false);
                if (!exited && !process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }

            _process?.Dispose();
            _process = null;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task WaitUntilHealthyAsync(CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < 60; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (_process is { HasExited: true })
            {
                throw new InvalidOperationException($"Suno backend se ugasio tokom pokretanja (exit code {_process.ExitCode}).");
            }
            if (await IsHealthyAsync(cancellationToken).ConfigureAwait(false))
            {
                return;
            }
            await Task.Delay(500, cancellationToken).ConfigureAwait(false);
        }
        throw new TimeoutException("Suno backend nije postao spreman u očekivanom roku.");
    }

    private async Task<bool> IsHealthyAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var response = await _http.GetAsync(new Uri(BaseUri, "api/health"), cancellationToken).ConfigureAwait(false);
            return response.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _http.Dispose();
        _gate.Dispose();
    }
}
