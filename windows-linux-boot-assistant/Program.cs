using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Text.Json;
using System.Windows.Forms;
using QRCoder;

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
/// Cable-free, no-USB-stick setup and compatibility guide for the existing
/// AiboOS iOS app. Does NOT jailbreak, flash, replace iOS or modify the phone.
/// </summary>
internal sealed class SetupWindow : Form
{
    private const string PhoneReleaseUrl =
        "https://github.com/wwoolf21963-dotcom/AiboOS/releases/tag/aiboos-se-latest";
    private static readonly Color Background = Color.FromArgb(25, 19, 36);
    private static readonly Color Surface = Color.FromArgb(45, 32, 58);
    private static readonly Color Pink = Color.FromArgb(255, 142, 191);
    private static readonly Color White = Color.FromArgb(255, 247, 252);
    private static readonly Color Muted = Color.FromArgb(209, 194, 220);
    private static readonly Color Green = Color.FromArgb(146, 239, 184);

    private readonly ComboBox model = new();
    private readonly ComboBox ios = new();
    private readonly Label routeTitle = new();
    private readonly Label routeDetails = new();
    private readonly PictureBox qr = new();
    private readonly Button releaseButton = new();
    private readonly Button copyButton = new();
    private readonly string settingsFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "AiboOS", "setup-profile.json");

    public SetupWindow()
    {
        Text = "AiboOS — Cable-Free Setup";
        ClientSize = new Size(990, 695);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Background;
        ForeColor = White;
        Font = new Font("Segoe UI", 10);

        var banner = new Panel { Bounds = new Rectangle(0, 0, 990, 128) };
        banner.Paint += (_, e) =>
        {
            using var brush = new LinearGradientBrush(
                banner.ClientRectangle, Color.FromArgb(114, 57, 150),
                Color.FromArgb(226, 103, 158), LinearGradientMode.Horizontal);
            e.Graphics.FillRectangle(brush, banner.ClientRectangle);
        };
        Controls.Add(banner);
        AddLabel(banner, "♡ AiboOS", 30, 17, 650, 60, 30, White, true);
        AddLabel(banner, "A SIMPLE, CABLE-FREE WAY TO TRY AIBOOS", 34, 83, 880, 26, 12, White, true);

        var selection = PanelAt(22, 148, 946, 170);
        AddLabel(selection, "1  YOUR IPHONE", 22, 14, 860, 27, 13, Pink, true);
        AddLabel(selection, "Choose once. We'll remember your selection on this PC.", 23, 45, 860, 25, 10, Muted);
        AddLabel(selection, "IPHONE MODEL", 23, 81, 429, 19, 9, Muted, true);
        AddLabel(selection, "INSTALLED IOS VERSION", 479, 81, 430, 19, 9, Muted, true);
        model.SetBounds(23, 105, 429, 38);
        model.DropDownStyle = ComboBoxStyle.DropDownList;
        model.Font = new Font("Segoe UI", 11);
        model.Items.AddRange(new object[]
        {
            "Choose your iPhone",
            DeviceProfiles.Se2016, DeviceProfiles.Se2020, DeviceProfiles.Se2022,
            "Other / not listed"
        });
        model.SelectedIndex = 0;
        ios.SetBounds(479, 105, 429, 38);
        ios.DropDownStyle = ComboBoxStyle.DropDown;
        ios.Font = new Font("Segoe UI", 11);
        ios.Items.AddRange(new object[]
        {
            "Choose your iOS version", "15.8.8", "15.8.7", "15.8.6",
            "15.8.5", "15.8.4", "15.8.3", "15.8.2", "15.8.1",
            "15.8", "15.7", "15.6", "15.5", "15.0"
        });
        ios.Text = "Choose your iOS version";
        selection.Controls.Add(model);
        selection.Controls.Add(ios);

        var setup = PanelAt(22, 333, 946, 205);
        AddLabel(setup, "2  CONTINUE ON YOUR IPHONE", 22, 13, 870, 29, 13, Pink, true);
        routeTitle.SetBounds(24, 52, 600, 30);
        routeTitle.ForeColor = White;
        routeTitle.BackColor = Surface;
        routeTitle.Font = new Font("Segoe UI", 14, FontStyle.Bold);
        setup.Controls.Add(routeTitle);
        routeDetails.SetBounds(24, 91, 610, 90);
        routeDetails.ForeColor = Muted;
        routeDetails.BackColor = Surface;
        routeDetails.Font = new Font("Segoe UI", 10);
        setup.Controls.Add(routeDetails);
        qr.SetBounds(716, 18, 175, 175);
        qr.SizeMode = PictureBoxSizeMode.Zoom;
        qr.BackColor = Color.White;
        setup.Controls.Add(qr);
        DrawQr();

        releaseButton.SetBounds(23, 549, 286, 49);
        copyButton.SetBounds(320, 549, 208, 49);
        StyleButton(releaseButton, Pink, Background, "OPEN AIBOOS APP RELEASE");
        StyleButton(copyButton, Surface, White, "COPY PHONE LINK");
        releaseButton.Click += (_, _) =>
        {
            Process.Start(new ProcessStartInfo(PhoneReleaseUrl) { UseShellExecute = true });
        };
        copyButton.Click += (_, _) => Clipboard.SetText(PhoneReleaseUrl);
        Controls.Add(releaseButton);
        Controls.Add(copyButton);

        var footer = PanelAt(22, 614, 946, 62);
        AddLabel(footer, "FULL IOS REPLACEMENT: NOT AVAILABLE", 19, 9, 905, 21, 11, Pink, true);
        AddLabel(footer, "No verified A9 installer exists. This app never erases, flashes, or changes your iPhone.",
            19, 32, 907, 23, 9, Muted);

        model.SelectedIndexChanged += (_, _) => UpdateRouteAndSave();
        ios.TextChanged += (_, _) => UpdateRouteAndSave();
        RestoreSelection();
        UpdateRouteAndSave();
    }

    private Panel PanelAt(int x, int y, int width, int height)
    {
        var panel = new Panel { BackColor = Surface, Bounds = new Rectangle(x, y, width, height) };
        Controls.Add(panel);
        return panel;
    }

    private static Label AddLabel(Control parent, string text, int x, int y,
        int width, int height, float size, Color color, bool bold = false)
    {
        var label = new Label
        {
            Text = text,
            Bounds = new Rectangle(x, y, width, height),
            BackColor = parent.BackColor,
            ForeColor = color,
            Font = new Font("Segoe UI", size,
                bold ? FontStyle.Bold : FontStyle.Regular)
        };
        parent.Controls.Add(label);
        return label;
    }

    private static void StyleButton(Button button, Color background, Color foreground, string text)
    {
        button.Text = text;
        button.BackColor = background;
        button.ForeColor = foreground;
        button.Font = new Font("Segoe UI", 10, FontStyle.Bold);
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.Cursor = Cursors.Hand;
    }

    private void DrawQr()
    {
        try
        {
            using var generator = new QRCodeGenerator();
            using var data = generator.CreateQrCode(PhoneReleaseUrl, QRCodeGenerator.ECCLevel.Q);
            using var code = new PngByteQRCode(data);
            var png = code.GetGraphic(5);
            using var stream = new MemoryStream(png);
            using var bitmap = new Bitmap(stream);
            qr.Image = new Bitmap(bitmap);
        }
        catch
        {
            qr.Visible = false;
            // The release button and copyable link remain available.
        }
    }

    private void UpdateRouteAndSave()
    {
        bool supported = DeviceProfiles.TryGetPhoneAppRoute(
            model.SelectedItem?.ToString(), ios.Text, out var note);
        routeTitle.ForeColor = supported ? Green : White;
        routeTitle.Text = supported
            ? "Ready for the AiboOS app preview"
            : "Check your device and iOS version";
        routeDetails.Text = note;
        qr.Visible = supported && qr.Image != null;
        releaseButton.Enabled = supported;
        copyButton.Enabled = supported;

        if (!supported || model.SelectedIndex <= 0) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(settingsFile)!);
            File.WriteAllText(settingsFile, JsonSerializer.Serialize(
                new SavedProfile(model.SelectedItem!.ToString()!, ios.Text)));
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void RestoreSelection()
    {
        try
        {
            if (!File.Exists(settingsFile)) return;
            var saved = JsonSerializer.Deserialize<SavedProfile>(
                File.ReadAllText(settingsFile));
            if (saved == null) return;
            int index = model.Items.IndexOf(saved.Model);
            if (index > 0) model.SelectedIndex = index;
            if (!string.IsNullOrWhiteSpace(saved.Ios)) ios.Text = saved.Ios;
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (JsonException) { }
    }

    private sealed record SavedProfile(string Model, string Ios);
}