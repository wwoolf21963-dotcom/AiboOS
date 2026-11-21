using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;

namespace AiboOS.ImageSetup;

internal static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--selftest")
        {
            string folder = Path.Combine(Path.GetTempPath(), "AiboOS-test-" + Guid.NewGuid().ToString("N"));
            try
            {
                string path = ImageWriter.Create(folder, null);
                var devices = UsbMonitor.Parse("1227|WinUSB\n1227|WinUSB\n4141|libusbK\ninvalid");
                bool usbPass = devices.Count(UsbMonitor.Dfu) == 2 && devices.Count(UsbMonitor.Pongo) == 1
                    && UsbMonitor.KnownDriver(devices[0]) && !UsbMonitor.KnownDriver(new UsbDevice("1227", "Apple"));
                using var native = ZipFile.OpenRead(Path.Combine(folder, "AiboOS-Native-Linux.zip"));
                bool nativePass = new[] { "Image.gz", "apple-dtbs/s8000-n69u.dtb", "apple-dtbs/s8003-n69.dtb",
                    "source/aiboos-fb.c", "source/aiboos-usb-serial.sh", "source/aiboos-install.sh", "source/aiboos-root-start.sh", "kernel.config", "HARDWARE-REPORT.txt", "vm-test/result.txt", "PROVENANCE.txt" }.All(name => native.GetEntry(name)?.Length > 0);
                return File.Exists(path) && new FileInfo(path).Length == ImageWriter.ImageSize && usbPass && nativePass ? 0 : 1;
            }
            catch { return 1; }
            finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new Setup());
        return 0;
    }
}

internal static class ImageWriter
{
    internal const long ImageSize = 256L * 1024 * 1024;
    static Stream Resource(string name) => Assembly.GetExecutingAssembly().GetManifestResourceStream(name)
        ?? throw new InvalidDataException("Missing embedded AiboOS system image.");

    // Fresh ordinary file only. Never opens a device, physical drive or phone.
    internal static string Create(string directory, IProgress<int>? progress)
    {
        Directory.CreateDirectory(directory);
        string temp = Path.Combine(directory, "AiboOS-" + Guid.NewGuid().ToString("N") + ".partial");
        string final = Path.Combine(directory, "AiboOS-ARM64-rootfs.ext4");
        if (File.Exists(final)) throw new IOException("An AiboOS image already exists in this folder.");
        using var reader = new StreamReader(Resource("AiboOS.RootFS.sha256"));
        byte[] expected = Convert.FromHexString(reader.ReadToEnd().Trim());
        if (expected.Length != 32) throw new InvalidDataException("Invalid embedded image digest.");
        try
        {
            using (var compressed = Resource("AiboOS.RootFS.gz"))
            using (var gzip = new GZipStream(compressed, CompressionMode.Decompress))
            using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                byte[] buffer = new byte[1024 * 1024];
                long count = 0;
                int n;
                while ((n = gzip.Read(buffer, 0, buffer.Length)) > 0)
                {
                    count += n;
                    if (count > ImageSize) throw new InvalidDataException("Image exceeds expected size.");
                    output.Write(buffer, 0, n);
                    progress?.Report((int)(count * 85 / ImageSize));
                }
                if (count != ImageSize) throw new InvalidDataException("Incomplete system image.");
                output.Flush(true);
            }
            using (var input = File.OpenRead(temp))
            {
                if (!CryptographicOperations.FixedTimeEquals(SHA256.HashData(input), expected))
                    throw new InvalidDataException("System image failed SHA-256 verification.");
            }
            SaveNativeFiles(directory);
            File.Move(temp, final, false);
            progress?.Report(100);
            return final;
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    private static void SaveNativeFiles(string directory)
    {
        string final = Path.Combine(directory, "AiboOS-Native-Linux.zip");
        string temp = final + "." + Guid.NewGuid().ToString("N") + ".partial";
        using var reader = new StreamReader(Resource("AiboOS.NativeFiles.sha256"));
        byte[] expected = Convert.FromHexString(reader.ReadToEnd().Trim());
        if (expected.Length != 32) throw new InvalidDataException("Invalid native files digest.");
        try
        {
            using (var input = Resource("AiboOS.NativeFiles.zip"))
            using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                input.CopyTo(output);
                output.Flush(true);
            }
            using (var check = File.OpenRead(temp))
                if (!CryptographicOperations.FixedTimeEquals(SHA256.HashData(check), expected))
                    throw new InvalidDataException("Native Linux files failed SHA-256 verification.");
            using (var archive = ZipFile.OpenRead(temp))
                foreach (string name in new[] { "Image.gz", "apple-dtbs/s8000-n69u.dtb", "apple-dtbs/s8003-n69.dtb" })
                    if (archive.GetEntry(name) is not { Length: > 0 })
                        throw new InvalidDataException("Missing native Linux component: " + name);
            File.Move(temp, final, false);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}

internal sealed record UsbDevice(string Pid, string Driver);

internal static class UsbMonitor
{
    internal static bool Dfu(UsbDevice d) => d.Pid == "1227";
    internal static bool Pongo(UsbDevice d) => d.Pid == "4141";
    internal static bool KnownDriver(UsbDevice d) =>
        new[] { "WinUSB", "libusbK", "libusb0" }.Contains(d.Driver, StringComparer.OrdinalIgnoreCase);
    internal static UsbDevice[] Parse(string output) => output.Split('\n')
        .Select(s => s.Trim().Split('|'))
        .Where(a => a.Length == 2 && a[0].Length == 4 && a[0].All(Uri.IsHexDigit))
        .Select(a => new UsbDevice(a[0].ToUpperInvariant(), a[1])).ToArray();

    internal static async Task<UsbDevice[]> Scan()
    {
        const string query = @"$ErrorActionPreference = 'Stop'
Get-CimInstance Win32_PnPEntity | Where-Object {
    $_.Present -eq $true -and $_.PNPDeviceID -match '^USB\\VID_05AC&PID_[0-9A-F]{4}\\'
} | ForEach-Object {
    if ($_.PNPDeviceID -match 'VID_05AC&PID_([0-9A-F]{4})') {
        $devicePid = $Matches[1].ToUpperInvariant()
        $driver = ([string]$_.Service) -replace '[^a-zA-Z0-9_-]', ''
        Write-Output ""$devicePid|$driver""
    }
}";
        var info = new ProcessStartInfo("powershell.exe") {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        foreach (string arg in new[] { "-NoProfile", "-NonInteractive", "-Command", query })
            info.ArgumentList.Add(arg);
        using var proc = Process.Start(info) ?? throw new IOException("Unable to scan Windows USB devices.");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        var output = proc.StandardOutput.ReadToEndAsync(timeout.Token);
        var errors = proc.StandardError.ReadToEndAsync(timeout.Token);
        try { await proc.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException)
        {
            if (!proc.HasExited) proc.Kill(true);
            throw new TimeoutException("USB scan timed out.");
        }
        string stdout = await output;
        string stderr = await errors;
        if (proc.ExitCode != 0) throw new IOException("USB scan failed: " + stderr.Trim());
        return Parse(stdout);
    }
}

internal sealed class Setup : Form
{
    readonly Button build = new() { Text = "Prepare AiboOS ARM64 + native Linux files", Width = 620, Height = 48 };
    readonly Button open = new() { Text = "Open image folder", Width = 300, Height = 38, Enabled = false };
    readonly Button scan = new() { Text = "Refresh USB status", Width = 300, Height = 38 };
    readonly Button driver = new() { Text = "Prepare missing Windows USB driver", Width = 620, Height = 38, Enabled = false };
    readonly ProgressBar progress = new() { Width = 620, Height = 20 };
    readonly Label state = new() { Text = "Connect your iPhone with a Lightning data cable.", Width = 620, Height = 54 };
    readonly Label[] steps = new Label[7];
    readonly System.Windows.Forms.Timer timer = new() { Interval = 10000 };
    readonly Color green = Color.FromArgb(150, 240, 185);
    readonly Color amber = Color.FromArgb(255, 207, 143);
    string? result;
    bool scanning, busy, driverBusy, offeredDriver, driverMissing;
    internal Setup()
    {
        Text = "AiboOS™ Setup — OrchardLinux A9 development";
        ClientSize = new Size(720, 800);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(26, 19, 39);
        ForeColor = Color.White;
        Font = new Font("Segoe UI", 11);
        AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(34, 16, 34, 16), AutoScroll = true };
        panel.Controls.Add(new Label { Text = "♡ AiboOS™ Setup", Font = new Font("Segoe UI", 28, FontStyle.Bold), ForeColor = Color.HotPink, Width = 620, Height = 58 });
        panel.Controls.Add(new Label { Text = "iPhone SE (2016)  •  OrchardLinux  •  Development", Width = 620, Height = 32 });
        string[] labels = {
            "USB connection", "DFU mode", "Windows DFU driver binding",
            "PongoOS USB detection", "AiboOS system image",
            "Native AiboOS boot", "Permanent installation / restart"
        };
        for (int i = 0; i < labels.Length; i++)
        {
            var row = new Panel { Width = 620, Height = 42, BackColor = Color.FromArgb(45, 33, 62), Margin = new Padding(0, 3, 0, 3) };
            steps[i] = new Label { Text = "○  " + labels[i], ForeColor = amber, Dock = DockStyle.Fill, Padding = new Padding(12, 8, 8, 2), AutoEllipsis = true };
            row.Controls.Add(steps[i]);
            panel.Controls.Add(row);
        }
        SetStep(4, "AiboOS system image — ready to verify", false);
        SetStep(5, "Native AiboOS boot — not verified", false);
        SetStep(6, "Permanent installation — not implemented", false);
        build.BackColor = Color.FromArgb(240, 143, 194);
        build.ForeColor = Color.Black;
        build.FlatStyle = FlatStyle.Flat;
        open.ForeColor = Color.Black;
        scan.ForeColor = Color.Black;
        driver.ForeColor = Color.Black;
        panel.Controls.Add(driver);
        panel.Controls.Add(build);
        panel.Controls.Add(progress);
        panel.Controls.Add(state);
        var buttons = new FlowLayoutPanel { Width = 620, Height = 48, WrapContents = false };
        buttons.Controls.Add(scan);
        buttons.Controls.Add(open);
        panel.Controls.Add(buttons);
        Controls.Add(panel);
        Shown += async (_, _) => { await RefreshUsb(); if (!IsDisposed) timer.Start(); };
        timer.Tick += async (_, _) => await RefreshUsb();
        scan.Click += async (_, _) => await RefreshUsb();
        driver.Click += async (_, _) => await PrepareDriver();
        build.Click += async (_, _) =>
        {
            busy = true;
            driver.Enabled = false;
            build.Enabled = false;
            open.Enabled = false;
            progress.Value = 0;
            result = null;
            SetStep(4, "AiboOS system image — verifying…", false);
            state.Text = "Extracting and verifying the embedded operating system.";
            try
            {
                string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AiboOS", "Images", Guid.NewGuid().ToString("N"));
                var report = new Progress<int>(p => progress.Value = Math.Clamp(p, 0, 100));
                result = await Task.Run(() => ImageWriter.Create(folder, report));
                SetStep(4, "ARM64 system image + native files — verified", true);
                state.Text = "OrchardLinux kernel and tested ARM64 filesystem saved on PC. Phone storage unchanged.";
                open.Enabled = true;
            }
            catch (Exception ex)
            {
                SetStep(4, "AiboOS system image — verification failed", false);
                state.Text = ex.Message;
            }
            finally { busy = false; build.Enabled = true; await RefreshUsb(); }
        };
        open.Click += (_, _) =>
        {
            if (result != null)
                Process.Start(new ProcessStartInfo { FileName = Path.GetDirectoryName(result)!, UseShellExecute = true });
        };
        FormClosing += (_, e) => { if (busy || driverBusy) e.Cancel = true; };
        FormClosed += (_, _) => timer.Dispose();
    }

    private void SetStep(int index, string message, bool passed)
    {
        steps[index].Text = (passed ? "✓  " : "○  ") + message;
        steps[index].ForeColor = passed ? green : amber;
    }

    private async Task RefreshUsb()
    {
        if (scanning || driverBusy || busy || IsDisposed) return;
        scanning = true;
        driver.Enabled = false;
        scan.Enabled = false;
        driverMissing = false;
        try
        {
            var devices = await UsbMonitor.Scan();
            if (IsDisposed) return;
            var dfu = devices.Where(UsbMonitor.Dfu).ToArray();
            var pongo = devices.Where(UsbMonitor.Pongo).ToArray();
            SetStep(0, devices.Length > 0 ? "Apple USB device detected" : "USB connection — waiting for Apple device", devices.Length > 0);
            SetStep(1, dfu.Length == 1 ? "DFU mode — detected" : dfu.Length > 1 ? "DFU mode — multiple devices" : "DFU mode — not currently detected", dfu.Length == 1);
            bool binding = dfu.Length == 1 && UsbMonitor.KnownDriver(dfu[0]);
            driverMissing = dfu.Length == 1 && !binding;
            if (dfu.Length == 0) offeredDriver = false;
            SetStep(2, binding ? "DFU driver binding — " + dfu[0].Driver + " (access untested)" : "DFU driver binding — not confirmed", binding);
            SetStep(3, pongo.Length == 1 ? "PongoOS USB ID — detected (boot unverified)" : "PongoOS USB ID — not detected", pongo.Length == 1);
        }
        catch (Exception ex)
        {
            if (IsDisposed) return;
            for (int i = 0; i < 4; i++) SetStep(i, "USB check unavailable — refresh to retry", false);
            if (!busy) state.Text = ex.Message;
        }
        finally
        {
            scanning = false;
            if (!IsDisposed) { scan.Enabled = true; driver.Enabled = driverMissing && !busy; }
        }
        if (!IsDisposed && driverMissing && !offeredDriver && !busy)
        {
            offeredDriver = true;
            await PrepareDriver();
        }
    }

    private async Task PrepareDriver()
    {
        if (busy || scanning || driverBusy || !driverMissing || IsDisposed) return;
        driverBusy = true;
        timer.Stop();
        driver.Enabled = scan.Enabled = build.Enabled = false;
        try
        {
            if (MessageBox.Show(this, "A compatible Windows DFU driver is missing. Prepare it now? The helper checks the connected device and backs up the original Apple driver when required. Windows may request administrator approval. This changes a Windows driver, not phone storage.", "AiboOS USB driver", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
                return;
            string folder = AppContext.BaseDirectory;
            string script = Path.Combine(folder, "Prepare-DFU-Driver.ps1");
            if (!File.Exists(script) || !File.Exists(Path.Combine(folder, "AiboOS-DFU-Driver-Tool.exe")))
                throw new IOException("Driver files missing. Extract the entire setup ZIP.");
            state.Text = "Preparing Windows USB driver. Check the Windows approval prompt.";
            var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe")) { UseShellExecute = false, CreateNoWindow = true };
            foreach (string arg in new[] { "-NoProfile", "-File", script }) info.ArgumentList.Add(arg);
            using var proc = Process.Start(info) ?? throw new IOException("Unable to start driver preparation.");
            await proc.WaitForExitAsync();
            state.Text = proc.ExitCode == 0 ? "Driver helper completed. Rechecking Windows device binding." : "Driver preparation stopped (code " + proc.ExitCode + "). See the AiboOS driver log.";
        }
        catch (Exception ex) { state.Text = ex.Message; }
        finally
        {
            driverBusy = false;
            build.Enabled = scan.Enabled = true;
            await RefreshUsb();
            if (!IsDisposed) timer.Start();
        }
    }
}
