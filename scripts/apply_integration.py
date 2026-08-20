from __future__ import annotations

import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("Usage: apply_integration.py <np-source-root>")

root = Path(sys.argv[1]).resolve()
overlay = Path(__file__).resolve().parents[1] / "overlay"


def read(rel: str) -> str:
    return (root / rel).read_text(encoding="utf-8")


def write(rel: str, text: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


# Copy only NEW integration files. Existing source files are patched below in the temporary checkout.
for src in overlay.rglob("*"):
    if src.is_file():
        rel = src.relative_to(overlay)
        dst = root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(src.read_bytes())

# 1) Avalonia WebView dependency. Keep the original NP Avalonia packages unchanged.
# 11.4.0 is the official FOSS/MIT WebView line and supports Avalonia >= 11.1.0.
rel = "src/NPVideoStudio.App/NPVideoStudio.App.csproj"
text = read(rel)
needle = '    <PackageReference Include="Avalonia.Desktop" Version="11.1.3" />\n'
if 'Avalonia.Controls.WebView' not in text:
    text = replace_once(
        text,
        needle,
        needle + '    <PackageReference Include="Avalonia.Controls.WebView" Version="11.4.0" />\n',
        rel,
    )
write(rel, text)

# 2) Give the unified product its own AppData and default project/cache folders.
rel = "src/NPVideoStudio.Domain/AppSettings.cs"
text = read(rel)
text = text.replace('Path.Combine(docs, "NP Video Studio", "Projects")', 'Path.Combine(docs, "NP Suno Unified Studio", "Projects")')
text = text.replace('Path.Combine(local, "NP Video Studio", "Cache")', 'Path.Combine(local, "NP Suno Unified Studio", "Cache")')
text = text.replace('Path.Combine(local, "NP Video Studio")', 'Path.Combine(local, "NP Suno Unified Studio")')
write(rel, text)

# 3) DI + lifecycle for the embedded Suno backend.
rel = "src/NPVideoStudio.App/App.axaml.cs"
text = read(rel)
text = replace_once(
    text,
    '    private IAutoSaveService? _autoSaveService;\n',
    '    private IAutoSaveService? _autoSaveService;\n    private SunoStudioHostService? _sunoStudioHostService;\n',
    rel + " field",
)
text = replace_once(
    text,
    '        services.AddSingleton<IFramePreviewService>(_ => new FramePreviewService(settingsService.Current.FfmpegPath));\n',
    '        services.AddSingleton<IFramePreviewService>(_ => new FramePreviewService(settingsService.Current.FfmpegPath));\n        services.AddSingleton<SunoStudioHostService>();\n',
    rel + " service",
)
text = replace_once(
    text,
    '        services.AddTransient<TemplateGalleryViewModel>();\n        services.AddSingleton<MainWindowViewModel>();\n',
    '        services.AddTransient<TemplateGalleryViewModel>();\n        services.AddTransient<SunoStudioViewModel>();\n        services.AddSingleton<MainWindowViewModel>();\n',
    rel + " viewmodel",
)
text = replace_once(
    text,
    '        _services = services.BuildServiceProvider();\n\n        ApplyTheme(settingsService.Current.Theme);\n',
    '        _services = services.BuildServiceProvider();\n        _sunoStudioHostService = _services.GetRequiredService<SunoStudioHostService>();\n\n        ApplyTheme(settingsService.Current.Theme);\n',
    rel + " provider",
)
text = replace_once(
    text,
    '                Task.Run(() => _autoSaveService.MarkCleanShutdownAsync()).GetAwaiter().GetResult();\n                _logger.Information("NP Video Studio se zatvara čisto");\n',
    '                Task.Run(() => _autoSaveService.MarkCleanShutdownAsync()).GetAwaiter().GetResult();\n                if (_sunoStudioHostService is not null)\n                {\n                    Task.Run(() => _sunoStudioHostService.StopAsync()).GetAwaiter().GetResult();\n                }\n                _logger.Information("NP + Suno Unified Studio se zatvara čisto");\n',
    rel + " shutdown",
)
text = replace_once(
    text,
    '            _ = mainWindowViewModel.InitializeAsync();\n',
    '            _ = mainWindowViewModel.InitializeAsync();\n\n'
    '            // CI-only integration smoke path. Normal users never set this environment variable.\n'
    '            // It navigates through the same command the UI button uses; SunoStudioView then opens\n'
    '            // the same NativeWebDialog as a real user click so Windows CI can prove WebView2 works.\n'
    '            if (Environment.GetEnvironmentVariable("NP_SUNO_SMOKE_AUTO_OPEN") == "1")\n'
    '            {\n'
    '                mainWindowViewModel.GoToSunoStudioCommand.Execute(null);\n'
    '            }\n',
    rel + " smoke navigation",
)
text = text.replace('"NP Video Studio se pokreće (verzija {Version})"', '"NP + Suno Unified Studio se pokreće (verzija {Version})"')
write(rel, text)

# 4) Main navigation to Suno inside the SAME application shell.
rel = "src/NPVideoStudio.App/ViewModels/MainWindowViewModel.cs"
text = read(rel)
insert_before = '    [RelayCommand]\n    private async Task GoHomeAsync() => await ShowStartScreenAsync();\n'
new_block = '''    private SunoStudioViewModel CreateSunoStudioPage()
    {
        var vm = _services.GetRequiredService<SunoStudioViewModel>();
        _ = vm.InitializeAsync();
        return vm;
    }

    [RelayCommand]
    private void GoToSunoStudio() => CurrentPage = CreateSunoStudioPage();

'''
text = replace_once(text, insert_before, new_block + insert_before, rel + " command")
write(rel, text)

# 5) MainWindow template, title and persistent Suno tab/button.
rel = "src/NPVideoStudio.App/Views/MainWindow.axaml"
text = read(rel)
text = text.replace('Title="NP Video Studio"', 'Title="NP + Suno Unified Studio"')
text = text.replace('Text="NP VIDEO STUDIO"', 'Text="NP + SUNO UNIFIED STUDIO"')
text = replace_once(
    text,
    '    <DataTemplate DataType="vm:QuickVideoViewModel">\n      <views:QuickVideoView />\n    </DataTemplate>\n',
    '    <DataTemplate DataType="vm:QuickVideoViewModel">\n      <views:QuickVideoView />\n    </DataTemplate>\n    <DataTemplate DataType="vm:SunoStudioViewModel">\n      <views:SunoStudioView />\n    </DataTemplate>\n',
    rel + " template",
)
text = replace_once(
    text,
    '          <Button Classes="ghost" Content="Početni ekran" Command="{Binding GoHomeCommand}" Margin="12,0,0,0" />\n',
    '          <Button Classes="ghost" Content="Početni ekran" Command="{Binding GoHomeCommand}" Margin="12,0,0,0" />\n          <Button Classes="ghost" Content="Suno Studio" Command="{Binding GoToSunoStudioCommand}" />\n',
    rel + " nav",
)
write(rel, text)

# 6) New product identity in installer, with a DIFFERENT AppId so it cannot upgrade/uninstall original NP.
rel = "installer/NPVideoStudio.iss"
text = read(rel)
text = text.replace('#define MyAppName "NP Video Studio"', '#define MyAppName "NP + Suno Unified Studio"')
text = text.replace('#define MyAppPublisher "NP Video Studio"', '#define MyAppPublisher "NP + Suno Unified Studio"')
text = text.replace('AppId={{7F3A9C41-2E5D-4B18-9A6C-D0E4F1B85C27}}', 'AppId={{A0C88060-C275-4677-9983-E0E76DFFCCF6}}')
text = text.replace('OutputBaseFilename=NPVideoStudio-Setup-{#MyAppVersion}', 'OutputBaseFilename=NPSunoUnifiedStudio-Setup-{#MyAppVersion}')
text = text.replace('Poveži .npvsproject fajlove sa NP Video Studio"; GroupDescription: "Registracija fajlova:"', 'Poveži .npvsproject fajlove sa NP + Suno Unified Studio"; GroupDescription: "Registracija fajlova:"; Flags: unchecked')
text = text.replace('NPVideoStudioProject', 'NPSunoUnifiedStudioProject')
text = text.replace('ValueData: "NP Video Studio projekat"', 'ValueData: "NP + Suno Unified Studio projekat"')
text = text.replace('{localappdata}\\NP Video Studio', '{localappdata}\\NP Suno Unified Studio')
text = text.replace('NP Video Studio programa', 'NP + Suno Unified Studio programa')
# Microsoft documents this exact command for offline Evergreen Standalone deployment.
# Run it before the app launch; non-elevated installs become per-user and therefore keep
# the unified installer usable without mandatory administrator rights.
run_line = 'Filename: "{app}\\{#MyAppExeName}"; Description: "Pokreni {#MyAppName}"; Flags: nowait postinstall skipifsilent\n'
webview_line = (
    'Filename: "{app}\\SunoEngine\\tools\\webview2\\MicrosoftEdgeWebView2RuntimeInstallerX64.exe"; '
    'Parameters: "/silent /install"; StatusMsg: "Instaliram Microsoft WebView2 Runtime..."; '
    'Flags: runhidden waituntilterminated\n'
)
text = replace_once(text, run_line, webview_line + run_line, rel + " WebView2 runtime install")
write(rel, text)

# 6b) The fallback self-contained installer inside the portable package must also use the NEW identity.
rel = "src/NPVideoStudio.Installer/Program.cs"
text = read(rel)
text = text.replace('private const string AppDisplayName = "NP Video Studio";', 'private const string AppDisplayName = "NP + Suno Unified Studio";')
text = text.replace(r'Uninstall\NPVideoStudio";', r'Uninstall\NPSunoUnifiedStudio";')
text = text.replace('NP Video Studio', 'NP + Suno Unified Studio')
text = text.replace(
    'Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppDisplayName);',
    'Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NP Suno Unified Studio");',
)
write(rel, text)

# 7) Stage SunoEngine into the NP publish BEFORE the original installer/portable packaging steps.
rel = "scripts/build-release.ps1"
text = read(rel)
text = text.replace("'dist\\NPVideoStudio-Portable-x64'", "'dist\\NPSunoUnifiedStudio-Portable-x64'")
text = text.replace('NPVideoStudio-Portable-x64', 'NPSunoUnifiedStudio-Portable-x64')
text = text.replace('NPVideoStudio-Setup-', 'NPSunoUnifiedStudio-Setup-')
marker = 'Write-Host "== 5/7: Pravljenje ugradjenog instalatera (NPVideoStudioSetup.exe) ==" -ForegroundColor Cyan\n'
inject = r'''# Unified build only: copy the separately staged, pinned Suno runtime into the NP publish tree.\n$unifiedSunoEngine = $env:NP_SUNO_ENGINE_STAGE\nif ([string]::IsNullOrWhiteSpace($unifiedSunoEngine) -or -not (Test-Path $unifiedSunoEngine)) {\n    throw "NP_SUNO_ENGINE_STAGE is missing; refusing to build a fake unified package without SunoEngine."\n}\n$unifiedSunoDestination = Join-Path $publishDir 'SunoEngine'\nif (Test-Path $unifiedSunoDestination) { Remove-Item $unifiedSunoDestination -Recurse -Force }\nCopy-Item -Path $unifiedSunoEngine -Destination $unifiedSunoDestination -Recurse -Force\n$requiredSuno = @(\n    'python\\pythonw.exe',\n    'app\\server.py',\n    'app\\server_core.py',\n    'app\\web\\index.html',\n    'tools\\webview2\\MicrosoftEdgeWebView2RuntimeInstallerX64.exe',\n    'plugins\\transcribe_worker.py',\n    'plugins\\stems_worker.py',\n    'plugins\\chromaprint\\fpcalc.exe'\n)\n$missingSuno = @($requiredSuno | Where-Object { -not (Test-Path (Join-Path $unifiedSunoDestination $_)) })\nif ($missingSuno.Count -gt 0) { throw "SunoEngine staging is incomplete: $($missingSuno -join ', ')" }\nWrite-Host "SunoEngine je ugrađen u unified publish." -ForegroundColor Green\n\n'''.replace('\\n','\n')
text = replace_once(text, marker, inject + marker, rel + " SunoEngine injection")
write(rel, text)

print("Integration overlay applied successfully to temporary NP checkout:", root)
