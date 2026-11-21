using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AiboOS.LinuxBootAssistant;

internal static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new SetupWindow());
    }
}

/// <summary>
/// Hands-off, READ-ONLY USB and Windows readiness monitoring. Not an iOS installer.
/// Does not change drivers, issue iPhone USB control requests, reboot, invoke
/// checkm8, alter Windows boot configuration or write to any disk.
/// </summary>
internal sealed class SetupWindow : Form
{
    private static readonly Color Background = Color.FromArgb(26, 19, 38);
    private static readonly Color Surface = Color.FromArgb(40, 30, 56);
    private static readonly Color Pink = Color.FromArgb(247, 130, 184);
    private static readonly Color Purple = Color.FromArgb(149, 94, 217);
    private static readonly Color Light = Color.FromArgb(252, 244, 255);
    private static readonly Color Muted = Color.FromArgb(202, 182, 215);
    private static readonly Color Okay = Color.FromArgb(144, 231, 179);

    private const string UsbPowerShell = @"
$ErrorActionPreference = 'Stop'
Get-CimInstance -ClassName Win32_PnPEntity |
  Where-Object { $_.PNPDeviceID -match 'VID_05AC&PID_[0-9A-F]{4}' } |
  ForEach-Object {
    if ($_.PNPDeviceID -match 'VID_05AC&PID_([0-9A-F]{4})') { $Matches[1] }
  } | Sort-Object -Unique
";
    private readonly Label mainStatus = new();
    private readonly Label details = new();
    private readonly Label outcome = new();
    private readonly Label deviceStatus = new();
    private readonly ComboBox modelChoice = new();
    private readonly ComboBox iosChoice = new();
    private readonly TextBox report = new();
    private readonly Button scanNow = new();
    private readonly Button copyReport = new();
    private readonly System.Windows.Forms.Timer refreshTimer = new() { Interval = 20000 };
    private bool scanning;
    private string lastMode = "Not checked";
    private string lastReport = "Not checked";

    public SetupWindow()
    {
        Text = "AiboOS — Windows Auto Readiness";
        Width = 1030;
        Height = 745;
        MinimumSize = new Size(1030, 745);
        MaximumSize = new Size(1030, 745);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Background;
        ForeColor = Light;
        Font = new Font("Segoe UI", 10);
        AutoScaleMode = AutoScaleMode.Dpi;

        var header = new Panel { Bounds = new Rectangle(0, 0, 1030, 145) };
        header.Paint += (_, e) => DrawMascot(e.Graphics, header.ClientRectangle);
        Controls.Add(header);
        header.Controls.Add(new Label
        {
            Text = "AiboOS",
            BackColor = Color.Transparent,
            ForeColor = Color.White,
            Font = new Font("Segoe UI", 28, FontStyle.Bold),
            Bounds = new Rectangle(142, 18, 650, 59)
        });
        header.Controls.Add(new Label
        {
            Text = "WINDOWS AUTO READINESS  •  NO EXTRA USB STICK",
            BackColor = Color.Transparent,
            ForeColor = Color.White,
            Font = new Font("Segoe UI", 11, FontStyle.Bold),
            Bounds = new Rectangle(145, 85, 790, 28)
        });

        var card = new Panel { BackColor = Surface, Bounds = new Rectangle(25, 162, 975, 191) };
        Controls.Add(card);
        var cardTitle = AddText(card, "YOUR IPHONE CONNECTION", new Rectangle(26, 17, 900, 30), 12, Pink, true);
        mainStatus = AddText(card, "Checking automatically...", new Rectangle(26, 57, 900, 55), 22, Light, true);
        details = AddText(card, "Open this app; it scans automatically.", new Rectangle(27, 123, 910, 43), 10, Muted, false);

        var profiles = new Panel { BackColor = Surface, Bounds = new Rectangle(25, 369, 975, 114) };
        Controls.Add(profiles);
        AddText(profiles, "DEVICE VERSION  —  OPTIONAL, NEVER GUESSED", new Rectangle(22, 8, 900, 25), 10, Pink, true);
        modelChoice.Bounds = new Rectangle(22, 44, 445, 38);
        modelChoice.DropDownStyle = ComboBoxStyle.DropDownList;
        modelChoice.Font = new Font("Segoe UI", 11);
        modelChoice.Items.AddRange(new object[]
        {
            "Model unknown (auto-detection only)",
            DeviceProfiles.Se2016,
            DeviceProfiles.Se2020,
            DeviceProfiles.Se2022,
            "Other / not listed"
        });
        modelChoice.SelectedIndex = 0;
        iosChoice.Bounds = new Rectangle(484, 44, 445, 38);
        iosChoice.Font = new Font("Segoe UI", 11);
        iosChoice.DropDownStyle = ComboBoxStyle.DropDown;
        iosChoice.Items.AddRange(new object[]
        {
            "iOS version unknown", "15.8.8", "15.8.7", "15.8.6", "15.8.5", "15.8.4", "15.8.3", "15.8.2",
            "15.8.1", "15.8", "15.7", "15.6", "15.0", "14.8.1", "16.0"
        });
        iosChoice.Text = "iOS version unknown";
        modelChoice.SelectedIndexChanged += (_, _) => UpdateProfileNote();
        iosChoice.TextChanged += (_, _) => UpdateProfileNote();
        profiles.Controls.Add(modelChoice);
        profiles.Controls.Add(iosChoice);

        var bottom = new Panel { BackColor = Surface, Bounds = new Rectangle(25, 499, 975, 156) };
        Controls.Add(bottom);
        AddText(bottom, "AIBOOS INSTALLATION STATUS", new Rectangle(22, 10, 900, 25), 10, Pink, true);
        outcome = AddText(bottom,
            "NOT AVAILABLE — no tested A9 Linux boot or permanent iOS replacement image",
            new Rectangle(23, 42, 926, 59), 12, Light, true);
        deviceStatus = AddText(bottom,
            "Automatic checking does not install drivers, run a jailbreak, or flash the phone.",
            new Rectangle(23, 105, 922, 43), 10, Muted, false);

        scanNow.Bounds = new Rectangle(26, 671, 192, 42);
        copyReport.Bounds = new Rectangle(226, 671, 192, 42);
        StyleButton(scanNow, Pink, Background, "SCAN NOW");
        StyleButton(copyReport, Purple, Light, "COPY REPORT");
        scanNow.Click += async (_, _) => await ScanAsync();
        copyReport.Click += (_, _) => Clipboard.SetText(lastReport);
        Controls.Add(scanNow);
        Controls.Add(copyReport);
        AddText(this, "No WSL  •  No Rufus  •  No USB stick  •  No background installation",
            new Rectangle(433, 674, 571, 35), 10, Muted, false);

        report.Visible = false;  // Report is available through Copy Report, not uploaded.
        Controls.Add(report);

        Shown += async (_, _) =>
        {
            await ScanAsync();
            refreshTimer.Start();
        };
        refreshTimer.Tick += async (_, _) => await ScanAsync();
        FormClosed += (_, _) => refreshTimer.Dispose();
        UpdateProfileNote();
    }

    private static Label AddText(Control parent, string caption, Rectangle bounds, float size,
                                 Color color, bool bold)
    {
        var label = new Label
        {
            Text = caption,
            ForeColor = color,
            BackColor = parent.BackColor,
            Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular),
            Bounds = bounds
        };
        parent.Controls.Add(label);
        return label;
    }

    private static void StyleButton(Button b, Color fill, Color text, string caption)
    {
        b.Text = caption;
        b.BackColor = fill;
        b.ForeColor = text;
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderSize = 0;
        b.Font = new Font("Segoe UI", 10, FontStyle.Bold);
        b.Cursor = Cursors.Hand;
    }

    private static void DrawMascot(Graphics g, Rectangle rectangle)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var bg = new LinearGradientBrush(rectangle,
            Color.FromArgb(107, 57, 131), Color.FromArgb(222, 104, 159), 0f);
        g.FillRectangle(bg, rectangle);
        using var face = new SolidBrush(Color.FromArgb(255, 186, 211));
        using var ink = new SolidBrush(Color.FromArgb(66, 34, 81));
        using var shine = new SolidBrush(Color.White);
        using var outline = new Pen(Color.FromArgb(66, 34, 81), 3);
        g.FillEllipse(face, 31, 17, 91, 98);
        g.FillEllipse(face, 27, 11, 28, 37);
        g.FillEllipse(face, 102, 11, 26, 37);
        g.FillEllipse(ink, 56, 55, 12, 19);
        g.FillEllipse(ink, 88, 55, 12, 19);
        g.FillEllipse(shine, 59, 58, 4, 7);
        g.FillEllipse(shine, 91, 58, 4, 7);
        g.DrawArc(outline, 67, 78, 22, 16, 5, 165);
    }

    private void UpdateProfileNote()
    {
        if (modelChoice.SelectedItem is not string model ||
            model == "Model unknown (auto-detection only)")
        {
            deviceStatus.Text = "Exact model and iOS version cannot reliably be identified from DFU alone. No guessing or flashing.";
            return;
        }
        var ios = iosChoice.Text == "iOS version unknown" ? "" : iosChoice.Text;
        bool preparable = DeviceProfiles.TryGetLinuxRoute(model, ios, out var message);
        deviceStatus.Text = preparable
            ? "Selected A9/iOS 15 profile is for research preparation only — no supported AiboOS installation."
            : message;
    }

    private async Task ScanAsync()
    {
        if (scanning || IsDisposed) return;
        scanning = true;
        scanNow.Enabled = false;
        mainStatus.Text = "Checking Windows USB...";
        details.Text = "Read-only device enumeration. No phone changes.";
        try
        {
            var usbIds = await QueryAppleUsbModeAsync();
            string mode = usbIds.Contains("4141") ? "PongoOS USB ID reported (needs separate verification)"
                        : usbIds.Contains("1227") ? "iPhone in DFU mode"
                        : usbIds.Contains("1281") ? "iPhone in Recovery mode"
                        : usbIds.Contains("12A8") ? "iPhone connected in normal iOS mode"
                        : usbIds.Count > 0 ? "An Apple USB device is connected"
                        : "No matching Apple USB device found";
            lastMode = mode;
            mainStatus.Text = mode;
            details.Text = "Detected USB IDs: " + (usbIds.Count == 0 ? "none" : string.Join(", ", usbIds.Select(x => "05AC:" + x)))
                + "\nLast scanned: " + DateTime.Now.ToString("HH:mm:ss") + " • Auto-refresh every 20 seconds";
            outcome.Text = "iOS replacement: NOT READY. No verified AiboOS A9 boot/install package exists.";
            lastReport = "AiboOS Windows Auto Readiness"
                  + "\nLocal time: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")
                  + "\nPC architecture: " + RuntimeInformation.OSArchitecture
                  + "\nUSB mode: " + mode
                  + "\nUSB IDs (VID:PID only): " + (usbIds.Count == 0 ? "none" : string.Join(", ", usbIds.Select(x => "05AC:" + x)))
                  + "\nModel selected: " + (modelChoice.SelectedItem?.ToString() ?? "unknown")
                  + "\niOS version selected: " + iosChoice.Text
                  + "\nAiboOS iOS replacement: NOT AVAILABLE / NOT TESTED."
                  + "\nNo jailbreak, driver change, restart, storage write or flash was executed.";
        }
        catch (Exception ex)
        {
            mainStatus.Text = "USB scan unavailable";
            details.Text = "Windows diagnostic could not complete; nothing was changed. " + ex.Message;
            lastReport = "AiboOS Windows Readiness: Scan error. " + ex.Message;
        }
        finally
        {
            scanning = false;
            if (!IsDisposed) scanNow.Enabled = true;
        }
    }

    /// <summary>
    /// Prints only USB PID values (no serial number, hardware instance ID,
    /// ECID, IMEI, or other identifying data).
    /// </summary>
    private static async Task<System.Collections.Generic.HashSet<string>> QueryAppleUsbModeAsync()
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            throw new PlatformNotSupportedException("This app is for Windows 11.");

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
        start.ArgumentList.Add(UsbPowerShell);

        using var process = Process.Start(start) ??
            throw new IOException("Windows PowerShell could not start.");
        using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        try
        {
            Task<string> outputTask = process.StandardOutput.ReadToEndAsync(cancel.Token);
            Task<string> errorTask = process.StandardError.ReadToEndAsync(cancel.Token);
            await process.WaitForExitAsync(cancel.Token);
            var stdout = await outputTask;
            var stderr = await errorTask;
            if (process.ExitCode != 0)
                throw new IOException("PowerShell USB enumeration error: " + stderr.Trim());
            var pids = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var line in stdout.Split('\n'))
            {
                var id = line.Trim().ToUpperInvariant();
                if (id.Length == 4 && id.All(c => Uri.IsHexDigit(c))) pids.Add(id);
            }
            return pids;
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            throw new TimeoutException("USB check timed out after 15 seconds.");
        }
    }
}
