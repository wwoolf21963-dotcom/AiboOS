using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AiboOS.LinuxBootAssistant;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new SetupWindow());
    }
}

/// <summary>
/// Read-only Windows DFU readiness monitor for AiboOS A9 operating-system research.
/// It never executes checkm8, transfers boot images, changes USB drivers,
/// erases iOS, writes to the phone, or pretends to install AiboOS.
/// </summary>
internal sealed class SetupWindow : Form
{
    private static readonly Color Background = Color.FromArgb(26, 19, 39);
    private static readonly Color Surface = Color.FromArgb(44, 33, 61);
    private static readonly Color Pink = Color.FromArgb(252, 143, 194);
    private static readonly Color White = Color.FromArgb(251, 245, 255);
    private static readonly Color Muted = Color.FromArgb(209, 196, 221);
    private static readonly Color Green = Color.FromArgb(151, 240, 183);
    private static readonly Color Amber = Color.FromArgb(255, 203, 128);
    private const string UsbQuery = @"
$ErrorActionPreference = 'Stop'
Get-CimInstance -ClassName Win32_PnPEntity |
  Where-Object { $_.PNPDeviceID -match 'VID_05AC&PID_[0-9A-F]{4}' } |
  ForEach-Object {
    if ($_.PNPDeviceID -match 'VID_05AC&PID_([0-9A-F]{4})') {
      $detectedId = $Matches[1].ToUpperInvariant()
      $driverService = ([string]$_.Service) -replace '[^a-zA-Z0-9_-]', ''
      Write-Output ""$detectedId|$driverService""
    }
  } | Sort-Object -Unique
";
    private readonly Label connectionStatus = new();
    private readonly Label connectionDetails = new();
    private readonly Label profileStatus = new();
    private readonly Label safetyStatus = new();
    private readonly ComboBox modelChoice = new();
    private readonly ComboBox iosChoice = new();
    private readonly Button rescan = new();
    private readonly Button copyReport = new();
    private readonly System.Windows.Forms.Timer refresh = new() { Interval = 20000 };
    private readonly string profileFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "AiboOS", "setup-profile.json");
    private bool scanning;
    private List<(string Id, string Driver)> usbDevices = new();
    private string diagnostic = "No USB scan completed.";

    public SetupWindow()
    {
        Text = "AiboOS — Windows DFU / Native OS Readiness";
        ClientSize = new Size(990, 720);
        MinimumSize = new Size(990, 759);
        MaximumSize = new Size(990, 759);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Background;
        ForeColor = White;
        Font = new Font("Segoe UI", 10);
        AutoScaleMode = AutoScaleMode.Dpi;

        var header = new Panel { Bounds = new Rectangle(0, 0, 990, 128) };
        header.Paint += (_, e) =>
        {
            using var background = new LinearGradientBrush(
                header.ClientRectangle, Color.FromArgb(99, 54, 149),
                Color.FromArgb(221, 104, 158), LinearGradientMode.Horizontal);
            e.Graphics.FillRectangle(background, header.ClientRectangle);
        };
        Controls.Add(header);
        AddText(header, "♡ AiboOS", new Rectangle(30, 16, 800, 63), 28, White, true);
        AddText(header, "NATIVE OS PROJECT  •  WINDOWS DFU CHECK  •  NO USB STICK",
            new Rectangle(34, 85, 920, 27), 11, White, true);

        var connection = AddPanel(new Rectangle(22, 145, 946, 154));
        AddText(connection, "1  DETECT CONNECTED IPHONE", new Rectangle(22, 12, 890, 26), 12, Pink, true);
        connectionStatus = AddText(connection, "Checking DFU automatically…",
            new Rectangle(23, 48, 895, 43), 20, White, true);
        connectionDetails = AddText(connection, "Read-only scan, using Windows device information.",
            new Rectangle(24, 98, 902, 49), 10, Muted);

        var selection = AddPanel(new Rectangle(22, 316, 946, 155));
        AddText(selection, "2  IDENTIFY DEVICE (MANUAL FALLBACK)",
            new Rectangle(22, 9, 896, 26), 12, Pink, true);
        AddText(selection, "DFU reveals USB mode, not the installed iOS version or A9 silicon vendor.",
            new Rectangle(22, 36, 896, 25), 10, Muted);
        modelChoice.SetBounds(22, 75, 440, 40);
        modelChoice.DropDownStyle = ComboBoxStyle.DropDownList;
        modelChoice.Font = new Font("Segoe UI", 11);
        modelChoice.Items.AddRange(new object[]
        {
            "Choose iPhone model", DeviceProfiles.Se2016, DeviceProfiles.Se2020,
            DeviceProfiles.Se2022, "Other / not listed"
        });
        modelChoice.SelectedIndex = 0;
        iosChoice.SetBounds(478, 75, 445, 40);
        iosChoice.Font = new Font("Segoe UI", 11);
        iosChoice.Items.AddRange(new object[]
        {
            "Choose last-known iOS", "15.8.8", "15.8.7", "15.8.6", "15.8.5",
            "15.8.4", "15.8.3", "15.8.2", "15.8.1", "15.8", "15.7", "15.6", "15.0"
        });
        iosChoice.Text = "Choose last-known iOS";
        selection.Controls.Add(modelChoice);
        selection.Controls.Add(iosChoice);
        profileStatus = AddText(selection, "Select your model and last-known iOS.",
            new Rectangle(23, 122, 898, 30), 9, Muted);

        var readiness = AddPanel(new Rectangle(22, 488, 946, 159));
        AddText(readiness, "3  NATIVE OS INSTALLATION STATUS",
            new Rectangle(22, 9, 898, 26), 12, Pink, true);
        safetyStatus = AddText(readiness, "",
            new Rectangle(23, 41, 900, 108), 10, White);
        safetyStatus.Text =
            "DFU detection: checking…\n" +
            "A9 RAM-only boot: not verified on this phone\n" +
            "A9 internal-storage installation: NOT AVAILABLE\n" +
            "No flash, driver changes or iOS erasure will be attempted.";

        rescan.SetBounds(22, 663, 192, 44);
        copyReport.SetBounds(224, 663, 190, 44);
        StyleButton(rescan, "SCAN DFU NOW", Pink, Background);
        StyleButton(copyReport, "COPY DIAGNOSTIC", Surface, White);
        rescan.Click += async (_, _) => await ScanAsync();
        copyReport.Click += (_, _) => Clipboard.SetText(diagnostic);
        Controls.Add(rescan);
        Controls.Add(copyReport);
        AddText(this, "Lightning cable only  •  No Rufus  •  No external USB drive",
            new Rectangle(432, 665, 550, 40), 10, Muted);

        modelChoice.SelectedIndexChanged += (_, _) => UpdateProfile();
        iosChoice.TextChanged += (_, _) => UpdateProfile();
        RestoreProfile();
        UpdateProfile();

        Shown += async (_, _) =>
        {
            await ScanAsync();
            refresh.Start();
        };
        refresh.Tick += async (_, _) => await ScanAsync();
        FormClosed += (_, _) => refresh.Dispose();
    }

    private Panel AddPanel(Rectangle bounds)
    {
        var panel = new Panel { Bounds = bounds, BackColor = Surface };
        Controls.Add(panel);
        return panel;
    }

    private static Label AddText(Control parent, string text, Rectangle bounds,
        float size, Color color, bool bold = false)
    {
        var label = new Label
        {
            Text = text,
            Bounds = bounds,
            ForeColor = color,
            BackColor = parent.BackColor,
            Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular)
        };
        parent.Controls.Add(label);
        return label;
    }

    private static void StyleButton(Button button, string title, Color background, Color foreground)
    {
        button.Text = title;
        button.BackColor = background;
        button.ForeColor = foreground;
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.Font = new Font("Segoe UI", 10, FontStyle.Bold);
        button.Cursor = Cursors.Hand;
    }

    private void UpdateProfile()
    {
        bool researchMatch = DeviceProfiles.TryGetLinuxRoute(
            modelChoice.SelectedItem?.ToString(), iosChoice.Text, out var note);
        profileStatus.ForeColor = researchMatch ? Green : Amber;
        profileStatus.Text = researchMatch
            ? "A9/iOS 15 research profile selected; real silicon board (Samsung/TSMC) still unknown."
            : note;
        if (researchMatch && modelChoice.SelectedIndex > 0)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(profileFile)!);
                File.WriteAllText(profileFile, JsonSerializer.Serialize(
                    new SavedProfile(modelChoice.SelectedItem!.ToString()!, iosChoice.Text)));
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        UpdateSafetyStatus();
    }

    private void RestoreProfile()
    {
        try
        {
            if (!File.Exists(profileFile)) return;
            var prior = JsonSerializer.Deserialize<SavedProfile>(File.ReadAllText(profileFile));
            if (prior == null) return;
            int index = modelChoice.Items.IndexOf(prior.Model);
            if (index > 0) modelChoice.SelectedIndex = index;
            if (!string.IsNullOrWhiteSpace(prior.Ios)) iosChoice.Text = prior.Ios;
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (JsonException) { }
    }

    private void UpdateSafetyStatus()
    {
        bool dfu = UsbModes.IsDfu(usbDevices.Select(x => x.Id));
        bool pongo = UsbModes.IsPongo(usbDevices.Select(x => x.Id));
        bool profileMatch = DeviceProfiles.TryGetLinuxRoute(
            modelChoice.SelectedItem?.ToString(), iosChoice.Text, out _);
        safetyStatus.Text =
            "Windows transport: " + (dfu ? "DFU USB ID 05AC:1227 detected" :
                pongo ? "Pongo USB ID reported; not verified as a booted OS" :
                "DFU not yet detected") + "\n" +
            "A9 profile: " + (profileMatch ? "Selected manually; silicon board NOT verified" :
                "Not confirmed / incompatible choice") + "\n" +
            "A9 Linux RAM boot: NOT PHONE-VERIFIED; Windows payload transfer unverified\n" +
            "Permanent iOS replacement: BLOCKED — no verified A9 storage installer.";
    }

    private async Task ScanAsync()
    {
        if (scanning || IsDisposed) return;
        scanning = true;
        rescan.Enabled = false;
        connectionStatus.ForeColor = White;
        connectionStatus.Text = "Scanning Windows USB devices…";
        connectionDetails.Text = "Read-only scan. No DFU commands, drivers or exploits.";
        try
        {
            usbDevices = await ReadAppleUsbDevices();
            var ids = usbDevices.Select(x => x.Id).ToArray();
            connectionStatus.Text = UsbModes.Describe(ids);
            connectionStatus.ForeColor = UsbModes.IsDfu(ids) ? Green : White;
            string driverList = usbDevices.Count == 0
                ? "none"
                : string.Join(", ", usbDevices.Select(x =>
                    "05AC:" + x.Id + " (service " + (x.Driver.Length == 0 ? "unknown" : x.Driver) + ")"));
            connectionDetails.Text =
                "Windows Apple USB matches: " + driverList + "\n" +
                "Last scan: " + DateTime.Now.ToString("HH:mm:ss") +
                " • Auto-refresh every 20 seconds";
            diagnostic = "AiboOS DFU research readiness — READ ONLY\n" +
                "Time: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\n" +
                "Windows architecture: " + RuntimeInformation.OSArchitecture + "\n" +
                "USB status: " + UsbModes.Describe(ids) + "\n" +
                "VID:PID and driver service only: " + driverList + "\n" +
                "Selected model (manual): " + (modelChoice.SelectedItem?.ToString() ?? "unknown") + "\n" +
                "Last-known iOS (manual): " + iosChoice.Text + "\n" +
                "No serials, ECIDs or IMEIs captured.\n" +
                "No iOS replacement, exploit, data erase, payload upload or USB driver change performed.";
        }
        catch (Exception ex)
        {
            usbDevices.Clear();
            connectionStatus.Text = "Windows DFU scan unavailable";
            connectionStatus.ForeColor = Amber;
            connectionDetails.Text = "Nothing was changed. " + ex.Message;
            diagnostic = "AiboOS DFU readiness: Windows scan failed. " + ex.Message;
        }
        finally
        {
            UpdateSafetyStatus();
            scanning = false;
            if (!IsDisposed) rescan.Enabled = true;
        }
    }

    private static async Task<List<(string Id, string Driver)>> ReadAppleUsbDevices()
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            throw new PlatformNotSupportedException("This utility requires Windows.");
        var start = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        start.ArgumentList.Add("-NoProfile");
        start.ArgumentList.Add("-NonInteractive");
        start.ArgumentList.Add("-Command");
        start.ArgumentList.Add(UsbQuery);
        using var proc = Process.Start(start) ??
            throw new IOException("Unable to start Windows PowerShell.");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        try
        {
            Task<string> output = proc.StandardOutput.ReadToEndAsync(timeout.Token);
            Task<string> errors = proc.StandardError.ReadToEndAsync(timeout.Token);
            await proc.WaitForExitAsync(timeout.Token);
            string stdout = await output;
            string stderr = await errors;
            if (proc.ExitCode != 0)
                throw new IOException("Windows device lookup failed: " + stderr.Trim());
            var found = new List<(string Id, string Driver)>();
            foreach (string line in stdout.Split('\n'))
            {
                string[] fields = line.Trim().Split('|');
                if (fields.Length != 2) continue;
                string id = fields[0].Trim().ToUpperInvariant();
                string driver = fields[1].Trim();
                if (id.Length == 4 && id.All(Uri.IsHexDigit)
                    && driver.All(c => char.IsAsciiLetterOrDigit(c) || c == '_' || c == '-'))
                    found.Add((id, driver));
            }
            return found.Distinct().ToList();
        }
        catch (OperationCanceledException)
        {
            if (!proc.HasExited) proc.Kill(entireProcessTree: true);
            throw new TimeoutException("Windows USB check timed out after 15 seconds.");
        }
    }

    private sealed record SavedProfile(string Model, string Ios);
}
