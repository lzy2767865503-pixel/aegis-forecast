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

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(
        nint window,
        nint insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);

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

            Browser.Visibility = Visibility.Visible;
            StatusPanel.Visibility = Visibility.Collapsed;
            await WriteReadinessMarkerAsync();
            _uiReady = true;
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

        IReadOnlyList<StoreListingScreenshot> screenshots = await CaptureStoreListingScreenshotsAsync(runtime);
        StoreListingScreenshot homeScreenshot = screenshots.Single(value => value.View == "home");

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
            storeListingScreenshotFile = homeScreenshot.FileName,
            storeListingScreenshotSha256 = homeScreenshot.Sha256,
            storeListingScreenshotWidth = homeScreenshot.Width,
            storeListingScreenshotHeight = homeScreenshot.Height,
            storeListingScreenshotView = "home",
            storeListingScreenshotPrivacyValidated = true,
            storeListingScreenshotCount = screenshots.Count,
            storeListingScreenshots = screenshots.Select(screenshot => new
            {
                fileName = screenshot.FileName,
                sha256 = screenshot.Sha256,
                width = screenshot.Width,
                height = screenshot.Height,
                view = screenshot.View,
                heading = screenshot.Heading,
                privacyValidated = true,
            }).ToArray(),
            capturedAt = DateTimeOffset.UtcNow.ToString("o"),
        };
        string markerPath = Path.Combine(runtime, "ui_ready.json");
        string temporary = markerPath + ".tmp";
        await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(marker));
        File.Move(temporary, markerPath, overwrite: true);
    }

    private sealed record StoreListingScreenshot(
        string FileName,
        string Sha256,
        int Width,
        int Height,
        string View,
        string Heading);

    private async Task<IReadOnlyList<StoreListingScreenshot>> CaptureStoreListingScreenshotsAsync(string runtime)
    {
        if (Browser.CoreWebView2 is null || _sessionToken is null)
        {
            throw new InvalidOperationException("商城截图只能由已验证的 WebView2 会话生成");
        }

        nint window = WinRT.Interop.WindowNative.GetWindowHandle(this);
        const uint noMoveNoZOrderNoActivate = 0x0002 | 0x0004 | 0x0010;
        if (window == 0 || GetDpiForWindow(window) != 96
            || !SetWindowPos(window, 0, 0, 0, 1600, 900, noMoveNoZOrderNoActivate))
        {
            throw new InvalidOperationException("商城截图要求受控 Windows 桌面为 100% 缩放且窗口可调整到 1600×900");
        }
        await Task.Delay(1000);

        var specifications = new[]
        {
            new { View = "home", FileName = "store-listing-home.png", NavigationLabel = (string?)null, Heading = "Nasdaq-100 说明性合成情景", Required = new[] { "确定性合成演示", "非真实行情" } },
            new { View = "scenarios", FileName = "store-listing-scenarios.png", NavigationLabel = (string?)"情景排名", Heading = "Nasdaq-100 研究排名", Required = new[] { "所有数值均非真实行情", "2026-08-26 快照研究样本" } },
            new { View = "privacy", FileName = "store-listing-privacy.png", NavigationLabel = (string?)"隐私与数据", Heading = "隐私与本地数据", Required = new[] { "无遥测、无广告标识符", "不读取、不存储" } },
            new { View = "about", FileName = "store-listing-about.png", NavigationLabel = (string?)"关于", Heading = "关于 Quant Scenario Studio", Required = new[] { "作者与发布者", "License: MIT" } },
        };
        List<StoreListingScreenshot> screenshots = [];
        const string headingProbe = "document.querySelector('.page-heading h1')?.textContent?.trim() || ''";
        const string privacyProbe = """
            (() => {
              const text = document.body?.innerText || '';
              return JSON.stringify({
                path: location.pathname,
                title: document.title || '',
                text,
                sensitiveControls: document.querySelectorAll(
                  'input[type=password],input[type=email],input[type=tel],input[type=file]'
                ).length,
                dialogs: document.querySelectorAll('[role=dialog],dialog[open]').length
              });
            })()
            """;

        foreach (var specification in specifications)
        {
            if (specification.NavigationLabel is not null)
            {
                string labelJson = JsonSerializer.Serialize(specification.NavigationLabel);
                string navigationScript = "(() => { const label = " + labelJson
                    + "; const item = [...document.querySelectorAll('.side-nav-item')].find(value => value.textContent?.trim() === label);"
                    + " if (!item) return false; item.click(); document.querySelector('.main-content')?.scrollTo(0, 0); window.scrollTo(0, 0); return true; })()";
                string navigationResult = await Browser.CoreWebView2.ExecuteScriptAsync(navigationScript);
                if (!JsonSerializer.Deserialize<bool>(navigationResult))
                {
                    throw new InvalidOperationException($"商城截图无法导航到真实视图：{specification.View}");
                }
            }
            string observedHeading = "";
            for (int attempt = 0; attempt < 40; attempt++)
            {
                string headingResult = await Browser.CoreWebView2.ExecuteScriptAsync(headingProbe);
                observedHeading = JsonSerializer.Deserialize<string>(headingResult) ?? "";
                if (observedHeading.Equals(specification.Heading, StringComparison.Ordinal)) { break; }
                await Task.Delay(100);
            }
            if (!observedHeading.Equals(specification.Heading, StringComparison.Ordinal))
            {
                throw new InvalidOperationException($"商城截图真实视图标题不匹配：{specification.View}");
            }
            await Task.Delay(500);

            string encodedProbe = await Browser.CoreWebView2.ExecuteScriptAsync(privacyProbe);
            string probeJson = JsonSerializer.Deserialize<string>(encodedProbe)
                ?? throw new InvalidOperationException("商城截图隐私探针没有返回 JSON");
            using JsonDocument probeDocument = JsonDocument.Parse(probeJson);
            JsonElement probe = probeDocument.RootElement;
            string visibleText = probe.GetProperty("text").GetString() ?? "";
            if (probe.GetProperty("path").GetString() != "/"
                || probe.GetProperty("title").GetString() != ProductName
                || probe.GetProperty("sensitiveControls").GetInt32() != 0
                || probe.GetProperty("dialogs").GetInt32() != 0
                || !visibleText.Contains(AuthorCredit, StringComparison.Ordinal)
                || !visibleText.Contains("不含交易", StringComparison.Ordinal)
                || specification.Required.Any(token => !visibleText.Contains(token, StringComparison.Ordinal))
                || visibleText.Contains(_sessionToken, StringComparison.Ordinal)
                || System.Text.RegularExpressions.Regex.IsMatch(
                    visibleText,
                    @"(?i)(?:[a-z]:\\users\\|[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}|(?:api[_ -]?key|access[_ -]?token|password|private[_ -]?key)\s*[:=])"))
            {
                throw new InvalidOperationException($"商城截图视图不是无账户、无敏感信息的真实确定性页面：{specification.View}");
            }

            string screenshotPath = Path.Combine(runtime, specification.FileName);
            if (File.Exists(screenshotPath))
            {
                throw new InvalidOperationException("商城截图文件在本轮 QA 前已存在");
            }
            await using (FileStream stream = new(
                screenshotPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                64 * 1024,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await Browser.CoreWebView2.CapturePreviewAsync(
                    CoreWebView2CapturePreviewImageFormat.Png,
                    stream);
                await stream.FlushAsync();
            }

            FileInfo screenshotFile = new(screenshotPath);
            if (screenshotFile.Length < 10_000 || screenshotFile.Length > 20 * 1024 * 1024)
            {
                throw new InvalidOperationException("商城截图 PNG 大小不在严格边界内");
            }
            byte[] header = new byte[24];
            await using (FileStream stream = File.OpenRead(screenshotPath))
            {
                int read = await stream.ReadAsync(header);
                if (read != header.Length)
                {
                    throw new InvalidOperationException("商城截图 PNG 头被截断");
                }
            }
            byte[] expectedSignature = [137, 80, 78, 71, 13, 10, 26, 10];
            if (!header.AsSpan(0, 8).SequenceEqual(expectedSignature)
                || header[12] != (byte)'I' || header[13] != (byte)'H'
                || header[14] != (byte)'D' || header[15] != (byte)'R')
            {
                throw new InvalidOperationException("商城截图不是规范 PNG/IHDR");
            }
            int width = (header[16] << 24) | (header[17] << 16) | (header[18] << 8) | header[19];
            int height = (header[20] << 24) | (header[21] << 16) | (header[22] << 8) | header[23];
            if (width < 1366 || height < 768 || width > 4096 || height > 2160)
            {
                throw new InvalidOperationException("商城截图必须在 1366×768 到 4096×2160 的受控范围内");
            }
            string sha256;
            await using (FileStream stream = File.OpenRead(screenshotPath))
            {
                sha256 = Convert.ToHexString(await SHA256.HashDataAsync(stream)).ToLowerInvariant();
            }
            screenshots.Add(new StoreListingScreenshot(
                specification.FileName,
                sha256,
                width,
                height,
                specification.View,
                specification.Heading));
        }
        if (screenshots.Count != 4 || screenshots.Select(value => value.View).Distinct(StringComparer.Ordinal).Count() != 4
            || screenshots.Select(value => value.Sha256).Distinct(StringComparer.Ordinal).Count() != 4)
        {
            throw new InvalidOperationException("商城截图必须是四个不同真实视图的四份不同 PNG");
        }
        return screenshots;
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
