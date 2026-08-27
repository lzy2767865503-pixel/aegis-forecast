using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.Web.WebView2.Core;
using Windows.ApplicationModel;
using Windows.Storage;

namespace AegisForecast;

public sealed partial class MainWindow : Window
{
    private const string ProductName = "Quant Scenario Studio by LAI ZEYU";
    private const string AuthorCredit = "LAI ZEYU（来泽宇）";
    private const string PrivacyBoundary = "local-only-no-telemetry";
    private const string DemoBoundary = "deterministic-synthetic-2026-08-26";
    private Process? _backend;
    private string? _sessionToken;
    private Uri? _backendUri;
    private bool _apiHealthValidated;
    private bool _coreDataValidated;
    private bool _uiReady;
    private readonly TaskCompletionSource<Uri> _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public MainWindow()
    {
        InitializeComponent();
        Closed += (_, _) => StopBackend();
        Root.Loaded += async (_, _) => await StartAsync();
    }

    private async Task StartAsync()
    {
        try
        {
            Uri backendUri = await StartBackendAsync();
            _backendUri = backendUri;
            await ValidateBackendApisAsync(backendUri);
            StatusText.Text = "正在初始化 Microsoft Edge WebView2…";
            await Browser.EnsureCoreWebView2Async();
            ConfigureWebView(backendUri);
            Browser.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
            Browser.Source = backendUri;
        }
        catch (Exception error)
        {
            ShowFailure($"启动失败：{error.Message}\n\n请确认 WebView2 Runtime 已安装，并运行 Windows 验证脚本。");
        }
    }

    private async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        if (_uiReady)
        {
            return;
        }
        if (!args.IsSuccess)
        {
            ShowFailure($"WebView2 导航失败：{args.WebErrorStatus}");
            return;
        }

        try
        {
            const string script = """
                (() => {
                  const root = document.querySelector('.app-shell');
                  const ready = document.getElementById('store-readiness');
                  if (!root || !ready) return JSON.stringify({ ok: false });
                  return JSON.stringify({
                    ok: true,
                    product: root.dataset.product || '',
                    author: root.dataset.author || '',
                    readOnly: root.dataset.storeReadOnly || '',
                    privacy: root.dataset.privacy || '',
                    demo: root.dataset.demo || '',
                    language: root.dataset.language || '',
                    apiHealth: ready.dataset.apiHealth || '',
                    coreData: ready.dataset.coreData || '',
                    title: document.title || '',
                    visibleText: ready.textContent || ''
                  });
                })()
                """;
            JsonElement root = default;
            bool domReady = false;
            for (int attempt = 0; attempt < 120; attempt++)
            {
                string result = await Browser.CoreWebView2.ExecuteScriptAsync(script);
                string json = JsonSerializer.Deserialize<string>(result)
                    ?? throw new InvalidOperationException("DOM 验证未返回 JSON");
                using JsonDocument probe = JsonDocument.Parse(json);
                if (probe.RootElement.TryGetProperty("ok", out JsonElement ok)
                    && ok.ValueKind == JsonValueKind.True)
                {
                    root = probe.RootElement.Clone();
                    domReady = true;
                    break;
                }
                await Task.Delay(500);
            }
            if (!domReady)
            {
                throw new InvalidOperationException("核心 API 未成功载入，DOM readiness 未出现");
            }
            RequireDom(root, "ok", expectedBoolean: true);
            RequireDom(root, "product", ProductName);
            RequireDom(root, "author", AuthorCredit);
            RequireDom(root, "readOnly", "true");
            RequireDom(root, "privacy", PrivacyBoundary);
            RequireDom(root, "demo", DemoBoundary);
            RequireDom(root, "language", "zh-CN");
            RequireDom(root, "apiHealth", "true");
            RequireDom(root, "coreData", "true");
            RequireDom(root, "title", ProductName);
            string visible = root.GetProperty("visibleText").GetString() ?? "";
            foreach (string token in new[] { ProductName, AuthorCredit, "Store 只读", "API 健康", "核心说明性数据已载入", "隐私", "2026-08-26", "合成演示" })
            {
                if (!visible.Contains(token, StringComparison.Ordinal))
                {
                    throw new InvalidOperationException($"DOM 可读识别信息缺失：{token}");
                }
            }

            await WriteReadinessMarkerAsync();
            _uiReady = true;
            Browser.Visibility = Visibility.Visible;
            StatusPanel.Visibility = Visibility.Collapsed;
        }
        catch (Exception error)
        {
            ShowFailure($"界面完整性验证失败：{error.Message}");
        }
    }

    private static void RequireDom(JsonElement root, string name, string expected)
    {
        string actual = root.TryGetProperty(name, out JsonElement value) ? value.GetString() ?? "" : "";
        if (!actual.Equals(expected, StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"DOM {name} 不匹配");
        }
    }

    private static void RequireDom(JsonElement root, string name, bool expectedBoolean)
    {
        bool actual = root.TryGetProperty(name, out JsonElement value)
            && value.ValueKind == JsonValueKind.True;
        if (actual != expectedBoolean)
        {
            throw new InvalidOperationException($"DOM {name} 不匹配");
        }
    }

    private static string SourceCommit()
    {
        string value = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion ?? "";
        int separator = value.IndexOf('+');
        string commit = separator >= 0 && separator + 1 < value.Length
            ? value[(separator + 1)..]
            : "UNSET";
        return System.Text.RegularExpressions.Regex.IsMatch(commit, "^[0-9a-fA-F]{40}$")
            ? commit.ToLowerInvariant()
            : "UNSET";
    }

    private static (string DataRoot, string Binding, string PackageFamily) RuntimeIdentity()
    {
        try
        {
            string family = Package.Current.Id.FamilyName;
            return (ApplicationData.Current.LocalFolder.Path, $"PFN:{family}", family);
        }
        catch (Exception ex) when (ex is InvalidOperationException or COMException)
        {
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrWhiteSpace(localAppData))
            {
                throw new InvalidOperationException("无法识别本机应用数据目录");
            }
            return (
                Path.Combine(localAppData, "AegisForecast", "LocalState"),
                "UNPACKAGED_WINDOWS",
                "UNPACKAGED_WINDOWS"
            );
        }
    }

    private async Task WriteReadinessMarkerAsync()
    {
        (string dataRoot, string binding, string packageFamily) = RuntimeIdentity();
        string runtime = Path.Combine(dataRoot, "runtime");
        Directory.CreateDirectory(runtime);
        string expectedPath = Path.Combine(runtime, "qa_expected.json");
        // Normal users never need a QA marker. Only an explicit, nonce-bound
        // test request may cause the app to emit process IDs and paths.
        if (!File.Exists(expectedPath))
        {
            return;
        }
        using JsonDocument expected = JsonDocument.Parse(await File.ReadAllTextAsync(expectedPath));
        JsonElement values = expected.RootElement;
        string packageSha256 = values.GetProperty("packageSha256").GetString() ?? "";
        string expectedCommit = values.GetProperty("sourceCommit").GetString() ?? "";
        string qaRound = values.GetProperty("qaRound").GetString() ?? "";
        string nonce = values.GetProperty("nonce").GetString() ?? "";
        if (!System.Text.RegularExpressions.Regex.IsMatch(packageSha256, "^[0-9a-f]{64}$")
            || !System.Text.RegularExpressions.Regex.IsMatch(expectedCommit, "^[0-9a-f]{40}$")
            || !System.Text.RegularExpressions.Regex.IsMatch(qaRound, "^[12]$")
            || !System.Text.RegularExpressions.Regex.IsMatch(nonce, "^[0-9a-f]{64}$"))
        {
            throw new InvalidOperationException("QA 期望文件格式无效");
        }
        string sourceCommit = SourceCommit();
        if (!_apiHealthValidated || !_coreDataValidated || _backend is null || _backend.HasExited)
        {
            throw new InvalidOperationException("API 健康或核心说明性数据尚未验证");
        }
        if (!sourceCommit.Equals(expectedCommit, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("编译源提交与 QA 期望不匹配");
        }
        string installLocation = Path.GetFullPath(AppContext.BaseDirectory)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string shellExecutablePath = Environment.ProcessPath is string processPath
            ? Path.GetFullPath(processPath)
            : throw new InvalidOperationException("无法识别已安装壳进程路径");
        string backendExecutablePath = Path.GetFullPath(_backend.StartInfo.FileName);

        var marker = new
        {
            product = ProductName,
            author = AuthorCredit,
            readOnly = true,
            privacy = PrivacyBoundary,
            demo = DemoBoundary,
            language = "zh-CN",
            sourceCommit,
            packageSha256,
            qaRound,
            nonce,
            packageFamily,
            dataRoot = Path.GetFullPath(dataRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            dataRootBinding = binding,
            installLocation,
            shellProcessId = Environment.ProcessId,
            backendProcessId = _backend.Id,
            shellExecutablePath,
            backendExecutablePath,
            apiHealthValidated = _apiHealthValidated,
            coreDataValidated = _coreDataValidated,
            domDataReady = true,
            navigationCompleted = true,
            capturedAt = DateTimeOffset.UtcNow.ToString("o"),
        };
        string markerPath = Path.Combine(runtime, "ui_ready.json");
        string temporary = markerPath + ".tmp";
        await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(marker));
        File.Move(temporary, markerPath, overwrite: true);
    }

    private void ShowFailure(string message)
    {
        StopBackend();
        Browser.Visibility = Visibility.Collapsed;
        StatusPanel.Visibility = Visibility.Visible;
        Progress.IsActive = false;
        StatusText.Text = message;
    }

    private async Task<Uri> StartBackendAsync()
    {
        string executable = Path.Combine(AppContext.BaseDirectory, "Backend", "AegisBackend.exe");
        if (!File.Exists(executable))
        {
            throw new FileNotFoundException("已打包的 AegisBackend.exe 不存在", executable);
        }

        _sessionToken = Base64Url(RandomNumberGenerator.GetBytes(48));
        (string dataRoot, string binding, _) = RuntimeIdentity();
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            Arguments = $"--host 127.0.0.1 --port 0 --parent-pid {Environment.ProcessId}",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = AppContext.BaseDirectory,
        };
        startInfo.Environment["AEGIS_SESSION_TOKEN"] = _sessionToken;
        startInfo.Environment["AEGIS_DATA_ROOT"] = dataRoot;
        startInfo.Environment["AEGIS_DATA_ROOT_BINDING"] = binding;
        startInfo.Environment["AEGIS_ENABLE_SIMULATION_EXECUTION"] = "0";

        _backend = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        _backend.OutputDataReceived += (_, args) =>
        {
            const string prefix = "AEGIS_READY_URL=";
            if (args.Data?.StartsWith(prefix, StringComparison.Ordinal) == true
                && Uri.TryCreate(args.Data[prefix.Length..], UriKind.Absolute, out Uri? uri)
                && IsAllowedLoopbackUri(uri))
            {
                _ready.TrySetResult(uri);
            }
        };
        _backend.ErrorDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data))
            {
                Debug.WriteLine($"[AegisBackend] {args.Data}");
            }
        };
        _backend.Exited += (_, _) =>
        {
            _ready.TrySetException(new InvalidOperationException("只读研究引擎在初始化期间退出"));
            DispatcherQueue.TryEnqueue(() =>
            {
                Browser.Visibility = Visibility.Collapsed;
                StatusPanel.Visibility = Visibility.Visible;
                Progress.IsActive = false;
                StatusText.Text = "只读研究引擎已停止。请重新启动应用；本应用不会在后台自动重启。";
            });
        };

        if (!_backend.Start())
        {
            throw new InvalidOperationException("无法启动只读研究引擎");
        }
        _backend.BeginOutputReadLine();
        _backend.BeginErrorReadLine();
        return await _ready.Task.WaitAsync(TimeSpan.FromSeconds(60));
    }

    private async Task ValidateBackendApisAsync(Uri backendUri)
    {
        if (_sessionToken is null)
        {
            throw new InvalidOperationException("本机会话令牌不存在");
        }
        using var client = new HttpClient { BaseAddress = backendUri, Timeout = TimeSpan.FromSeconds(10) };
        client.DefaultRequestHeaders.Add("X-Aegis-Session", _sessionToken);

        using JsonDocument health = await GetJsonAsync(client, "/api/health");
        JsonElement healthRoot = health.RootElement;
        _apiHealthValidated = healthRoot.GetProperty("ok").GetBoolean()
            && healthRoot.GetProperty("storeReadOnly").GetBoolean()
            && !healthRoot.GetProperty("executionEnabled").GetBoolean()
            && healthRoot.GetProperty("mode").GetString() == "DETERMINISTIC_SYNTHETIC_SCENARIO";
        if (!_apiHealthValidated)
        {
            throw new InvalidOperationException("只读 API 健康边界验证失败");
        }

        using JsonDocument status = await GetJsonAsync(client, "/api/status");
        using JsonDocument signals = await GetJsonAsync(client, "/api/signals?limit=1");
        using JsonDocument universe = await GetJsonAsync(client, "/api/universe?limit=1");
        using JsonDocument data = await GetJsonAsync(client, "/api/data");
        _coreDataValidated = status.RootElement.GetProperty("system").GetProperty("storeReadOnly").GetBoolean()
            && status.RootElement.GetProperty("system").GetProperty("dataMode").GetString() == "DETERMINISTIC_SYNTHETIC_SCENARIO"
            && signals.RootElement.GetProperty("items").GetArrayLength() > 0
            && universe.RootElement.GetProperty("items").GetArrayLength() > 0
            && data.RootElement.GetProperty("dataMode").GetString() == "DETERMINISTIC_SYNTHETIC_SCENARIO";
        if (!_coreDataValidated)
        {
            throw new InvalidOperationException("核心说明性数据 API 验证失败");
        }
    }

    private static async Task<JsonDocument> GetJsonAsync(HttpClient client, string path)
    {
        using HttpResponseMessage response = await client.GetAsync(path);
        response.EnsureSuccessStatusCode();
        string content = await response.Content.ReadAsStringAsync();
        return JsonDocument.Parse(content);
    }

    private void ConfigureWebView(Uri backendUri)
    {
        if (Browser.CoreWebView2 is null || _sessionToken is null)
        {
            throw new InvalidOperationException("WebView2 初始化不完整");
        }

        CoreWebView2Cookie cookie = Browser.CoreWebView2.CookieManager.CreateCookie(
            "aegis_session", _sessionToken, backendUri.Host, "/");
        cookie.IsHttpOnly = true;
        cookie.SameSite = CoreWebView2CookieSameSiteKind.Strict;
        Browser.CoreWebView2.CookieManager.AddOrUpdateCookie(cookie);
        Browser.CoreWebView2.Settings.AreDevToolsEnabled = false;
        Browser.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
        Browser.CoreWebView2.Settings.IsStatusBarEnabled = false;
        Browser.CoreWebView2.Settings.IsWebMessageEnabled = false;
        Browser.CoreWebView2.NewWindowRequested += (_, args) => args.Handled = true;
        Browser.CoreWebView2.DownloadStarting += (_, args) => args.Cancel = true;
        Browser.CoreWebView2.PermissionRequested += (_, args) =>
        {
            args.State = CoreWebView2PermissionState.Deny;
            args.Handled = true;
        };
        Browser.CoreWebView2.NavigationStarting += (_, args) =>
        {
            if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out Uri? target)
                || !IsSameOriginLoopbackUri(target, backendUri))
            {
                args.Cancel = true;
            }
        };
        Browser.CoreWebView2.ProcessFailed += (_, _) =>
        {
            StopBackend();
            Browser.Visibility = Visibility.Collapsed;
            StatusPanel.Visibility = Visibility.Visible;
            Progress.IsActive = false;
            StatusText.Text = "WebView2 进程异常退出，请重新启动应用。";
        };
    }

    private static bool IsAllowedLoopbackUri(Uri uri) =>
        uri.Scheme == Uri.UriSchemeHttp
        && (uri.Host == "127.0.0.1" || uri.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase));

    private static bool IsSameOriginLoopbackUri(Uri target, Uri backend) =>
        IsAllowedLoopbackUri(target)
        && target.Scheme.Equals(backend.Scheme, StringComparison.OrdinalIgnoreCase)
        && target.Host.Equals(backend.Host, StringComparison.OrdinalIgnoreCase)
        && target.Port == backend.Port;

    private static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private void StopBackend()
    {
        Process? backend = _backend;
        _backend = null;
        if (backend is null)
        {
            return;
        }
        try
        {
            if (!backend.HasExited)
            {
                backend.Kill(entireProcessTree: true);
                backend.WaitForExit(3000);
            }
        }
        catch (InvalidOperationException)
        {
            // Process already exited.
        }
        finally
        {
            backend.Dispose();
        }
    }
}
