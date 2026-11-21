using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
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

internal sealed class SetupWindow : Form
{
    private const string LinuxName = "palen1x-v3.0.0-beta.4-x86_64.iso";
    private const string LinuxUrl = "https://github.com/palera1n/palen1x/releases/download/v3.0.0-beta.4/palen1x-v3.0.0-beta.4-x86_64.iso";
    private const string LinuxSha = "9f47c7d4a8d8824e210a6795cc5cdb22964a0de26298800e8ba7b55953a743f3";
    private const string RufusName = "rufus-4.16.exe";
    private const string RufusUrl = "https://github.com/pbatard/rufus/releases/download/v4.16/rufus-4.16.exe";
    private const string RufusSha = "8351a56c134aa6dd26a930d702cc3fd57f11ef90b17e55a8de960d5a73d46cfc";

    private static readonly Color Bg = Color.FromArgb(24, 19, 35);
    private static readonly Color Surface = Color.FromArgb(35, 28, 50);
    private static readonly Color Muted = Color.FromArgb(195, 179, 208);
    private static readonly Color Pink = Color.FromArgb(245, 121, 181);
    private static readonly Color Purple = Color.FromArgb(149, 94, 217);
    private static readonly Color White = Color.FromArgb(252, 246, 255);
    private readonly string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "AiboOS-Linux-Boot");
    private readonly HttpClient client = new() { Timeout = TimeSpan.FromMinutes(7) };
    private readonly string[] steps = { "Welcome", "Check Windows", "Download Linux + Rufus", "Create bootable USB", "Boot Linux", "iPhone SE DFU guide", "Progress / next steps" };
    private readonly Button[] stepButtons = new Button[7];
    private readonly Label headline = new(), subtitle = new(), status = new();
    private readonly RichTextBox body = new();
    private readonly ProgressBar progress = new();
    private readonly Button primary = new(), secondary = new(), back = new(), next = new();
    private int currentStep;
    private bool busy;
    private string lastReport = "Not tested yet.";

    public SetupWindow()
    {
        Text = "AiboOS Setup Studio — Windows → Linux iPhone SE Lab";
        Width = 1080; Height = 750;
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(980, 700);
        MaximizeBox = false;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        BackColor = Bg;
        ForeColor = White;
        Font = new Font("Segoe UI", 10);
        AutoScaleMode = AutoScaleMode.Dpi;

        var hero = new Panel { Bounds = new Rectangle(0, 0, 1080, 142) };
        hero.Paint += (_, e) => DrawHero(e.Graphics, hero.ClientRectangle);
        Controls.Add(hero);
        hero.Controls.Add(new Label
        {
            Text = "AiboOS  /  Setup Studio",
            Font = new Font("Segoe UI", 25, FontStyle.Bold),
            ForeColor = Color.White,
            BackColor = Color.Transparent,
            Bounds = new Rectangle(140, 22, 750, 55)
        });
        hero.Controls.Add(new Label
        {
            Text = "Your Windows PC → bootable Linux → experimental iPhone SE development",
            Font = new Font("Segoe UI", 10.5f),
            ForeColor = Color.FromArgb(249, 227, 248),
            BackColor = Color.Transparent,
            Bounds = new Rectangle(144, 84, 820, 35)
        });

        var nav = new Panel { Bounds = new Rectangle(22, 162, 270, 490), BackColor = Surface };
        Controls.Add(nav);
        nav.Controls.Add(new Label { Text = "YOUR STEPS", ForeColor = Pink, Font = new Font("Segoe UI", 11, FontStyle.Bold), Location = new Point(20, 21), AutoSize = true });
        for (var i = 0; i < steps.Length; i++)
        {
            var index = i;
            var b = new Button
            {
                Text = $"{i + 1:00}   {steps[i]}",
                TextAlign = ContentAlignment.MiddleLeft,
                Bounds = new Rectangle(12, 62 + i * 56, 244, 46),
                FlatStyle = FlatStyle.Flat,
                ForeColor = White,
                BackColor = Surface,
                Font = new Font("Segoe UI", 10, FontStyle.Regular),
                Cursor = Cursors.Hand
            };
            b.FlatAppearance.BorderSize = 0;
            b.Click += (_, _) => { if (!busy) { currentStep = index; RefreshStep(); } };
            nav.Controls.Add(b);
            stepButtons[i] = b;
        }

        var card = new Panel { Bounds = new Rectangle(308, 162, 745, 490), BackColor = Surface };
        Controls.Add(card);
        headline.Location = new Point(28, 26); headline.Size = new Size(680, 55);
        headline.Font = new Font("Segoe UI", 20, FontStyle.Bold); headline.ForeColor = White;
        card.Controls.Add(headline);
        subtitle.Location = new Point(29, 85); subtitle.Size = new Size(680, 36);
        subtitle.ForeColor = Muted;
        card.Controls.Add(subtitle);
        body.Location = new Point(30, 137); body.Size = new Size(684, 215);
        body.BorderStyle = BorderStyle.None; body.ReadOnly = true; body.DetectUrls = false;
        body.BackColor = Surface; body.ForeColor = White;
        body.Font = new Font("Segoe UI", 11); body.ScrollBars = RichTextBoxScrollBars.Vertical;
        card.Controls.Add(body);
        progress.Location = new Point(30, 365); progress.Size = new Size(684, 15);
        progress.Style = ProgressBarStyle.Continuous;
        card.Controls.Add(progress);
        primary.Bounds = new Rectangle(30, 396, 322, 52);
        secondary.Bounds = new Rectangle(368, 396, 346, 52);
        StyleButton(primary, Pink, Bg);
        StyleButton(secondary, Color.FromArgb(65, 51, 87), White);
        primary.Click += async (_, _) => await HandlePrimaryAsync();
        secondary.Click += (_, _) => HandleSecondary();
        card.Controls.Add(primary); card.Controls.Add(secondary);

        back.Bounds = new Rectangle(308, 666, 130, 38);
        next.Bounds = new Rectangle(922, 666, 130, 38);
        StyleButton(back, Surface, White); StyleButton(next, Purple, White);
        back.Text = "← Previous"; next.Text = "Next →";
        back.Click += (_, _) => { if (!busy && currentStep > 0) { currentStep--; RefreshStep(); } };
        next.Click += (_, _) => { if (!busy && currentStep < steps.Length - 1) { currentStep++; RefreshStep(); } };
        Controls.Add(back); Controls.Add(next);

        status.Bounds = new Rectangle(455, 664, 454, 44);
        status.ForeColor = Muted;
        status.TextAlign = ContentAlignment.MiddleCenter;
        Controls.Add(status);

        client.DefaultRequestHeaders.UserAgent.ParseAdd("AiboOS-LinuxBootSetup/0.1");
        status.Text = "Not an iOS replacement • No automatic disk erasure";
        RefreshStep();
    }

    private static void StyleButton(Button button, Color color, Color text)
    {
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.BackColor = color; button.ForeColor = text;
        button.Font = new Font("Segoe UI", 10, FontStyle.Bold);
        button.Cursor = Cursors.Hand;
        button.UseVisualStyleBackColor = false;
    }

    private static void DrawHero(Graphics g, Rectangle r)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var grad = new LinearGradientBrush(r, Color.FromArgb(106, 51, 125),
            Color.FromArgb(208, 94, 153), 0f);
        g.FillRectangle(grad, r);
        using var pink = new SolidBrush(Color.FromArgb(252, 174, 208));
        using var dark = new SolidBrush(Color.FromArgb(63, 30, 78));
        using var shine = new SolidBrush(Color.White);
        g.FillEllipse(pink, 32, 18, 86, 94);
        g.FillEllipse(pink, 28, 15, 26, 31);
        g.FillEllipse(pink, 96, 15, 26, 31);
        g.FillEllipse(dark, 54, 56, 10, 17);
        g.FillEllipse(dark, 87, 56, 10, 17);
        g.FillEllipse(shine, 57, 59, 4, 6);
        g.FillEllipse(shine, 90, 59, 4, 6);
        using var pen = new Pen(dark, 3);
        g.DrawArc(pen, 64, 75, 23, 14, 3, 172);
    }

    private void RefreshStep()
    {
        var contents = new (string title, string subtitle, string text, string action, string other)[]
        {
            ("AiboOS Linux boot preparation", "Built for your iPhone SE (2016) + Windows 11",
             "We'll prepare a proper Linux boot environment on your Windows PC, without WSL or a virtual machine.\n\n• Prepare verified palen1x Linux ISO and Rufus.\n• You approve any USB erase and PC restart.\n• Follow guided DFU and Linux steps.\n\nIMPORTANT: palen1x is an upstream jailbreak/boot research environment. It does NOT replace iOS or install a native AiboOS image.", "PREPARE EVERYTHING", "What do I need?"),
            ("Check your Windows PC", "First check: can this PC boot a Linux USB?",
             "This assistant runs on Windows x64. It checks your PC architecture and looks for removable drives.\n\nYou need a spare bootable USB drive (the official palera1n download page recommends 32 GB), or another supported boot medium. It will be erased in Rufus only after you approve.\n\nNo USB drive? You can still download everything now, but you cannot complete the boot step until you have suitable removable media.", "CHECK THIS PC", "Get the tools"),
            ("Download Linux + Rufus", "Pinned official downloads with SHA-256 verification",
             "This one button downloads:\n\n• palera1n palen1x v3.0.0-beta.4 x86_64 Linux ISO\n• Rufus 4.16 Windows USB writer\n\nBoth are fetched from the projects' official GitHub releases and checked against published SHA-256 digests.\n\nThe files go to Downloads\\AiboOS-Linux-Boot. Downloading them does not change any disk or iPhone.", "DOWNLOAD + VERIFY BOTH", "OPEN DOWNLOAD FOLDER"),
            ("Create the bootable Linux USB", "Manual approval required because Rufus erases the selected drive",
             "1. Insert a spare USB drive (official site recommends 32 GB).\n2. Click OPEN RUFUS below.\n3. In Rufus, carefully SELECT THE SPARE USB DRIVE, never your Windows disk.\n4. Click SELECT and choose the downloaded palen1x .iso.\n5. Click START. Choose DD IMAGE MODE if Rufus offers ISO or DD.\n6. Review Rufus's erase warning before you confirm.\n\nThis app never writes a USB disk automatically.", "OPEN RUFUS", "OFFICIAL USB GUIDE"),
            ("Boot your PC into Linux", "This step can't be automated inside Windows",
             "1. Save your work in Windows.\n2. Leave the prepared Linux USB connected.\n3. Restart your PC and open its boot menu (often F12, F9, Esc, or another manufacturer-specific key).\n4. Select the removable USB, then boot palen1x.\n5. Some PCs require changing Secure Boot settings. Do NOT change Secure Boot unless necessary; on BitLocker-protected PCs, changes can trigger a recovery-key prompt.\n\nReturning to Windows: restart the PC normally and remove the Linux USB.", "OPEN BOOT GUIDE", "OPEN ISO FOLDER"),
            ("iPhone SE: DFU + Linux", "Follow the official Linux environment's steps",
             "Your phone is a first-generation iPhone SE with Apple A9. You previously reached DFU in Windows, but Windows checkm8/USB serial reading failed.\n\nIn Linux, use the palen1x/palera1n on-screen instructions and DFU prompts. Do not press Restore in Apple Devices.\n\nIMPORTANT: palera1n is for jailbreaking iOS. A successful palen1x run is NOT proof that our separate AiboOS Linux kernel will boot, nor does it permanently replace iOS. Don't flash the experimental AiboOS kernel to storage.", "OFFICIAL PALEN1X GUIDE", "AIBOOS PROJECT"),
            ("Progress and next steps", "What we've proved—and what still needs hardware validation",
             "Windows: the iPhone DFU mode was detected; the experimental native loader failed to read a USB identity descriptor.\n\nLinux USB: needs a physical boot test. This app can prepare the media, but cannot reboot your PC into Linux itself.\n\niPhone OS replacement: NOT READY. Our experimental A9 Linux payload hasn't been phone-boot tested. We will not offer a permanent flash command until that is validated.", "COPY TEST SUMMARY", "OPEN DOWNLOAD FOLDER")
        };
        var step = contents[currentStep];
        headline.Text = step.title;
        subtitle.Text = step.subtitle;
        body.Text = step.text;
        primary.Text = step.action; secondary.Text = step.other;
        back.Enabled = currentStep > 0 && !busy;
        next.Enabled = currentStep < steps.Length - 1 && !busy;
        primary.Enabled = secondary.Enabled = !busy;
        for (var i = 0; i < stepButtons.Length; i++)
        {
            stepButtons[i].BackColor = i == currentStep ? Color.FromArgb(92, 55, 111) : Surface;
            stepButtons[i].ForeColor = i == currentStep ? Pink : White;
        }
    }

    private void SetStatus(string text)
    {
        status.Text = text.Length > 80 ? text[..77] + "..." : text;
    }

    private async Task HandlePrimaryAsync()
    {
        switch (currentStep)
        {
            case 0: case 2: await DownloadAllAsync(); break;
            case 1: CheckPc(); break;
            case 3: await LaunchRufusAsync(); break;
            case 4: OpenOfficial("https://docs.palera.in/using-palen1x/"); break;
            case 5: OpenOfficial("https://docs.palera.in/using-palen1x/"); break;
            case 6:
                Clipboard.SetText(lastReport + Environment.NewLine +
                   "Linux boot has not been validated; AiboOS has not replaced iOS.");
                SetStatus("Progress summary copied to clipboard."); break;
        }
    }

    private void HandleSecondary()
    {
        switch (currentStep)
        {
            case 0: currentStep = 1; RefreshStep(); break;
            case 1: currentStep = 2; RefreshStep(); break;
            case 2: case 4: case 6: OpenFolder(); break;
            case 3: OpenOfficial("https://docs.palera.in/using-palen1x/"); break;
            case 5: OpenOfficial("https://github.com/wwoolf21963-dotcom/AiboOS"); break;
        }
    }

    private void CheckPc()
    {
        var arch = RuntimeInformation.OSArchitecture.ToString();
        var removable = DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Removable)
            .Select(d => d.Name).ToArray();
        lastReport = $"Windows: {Environment.OSVersion}; Architecture: {arch}; Removable drives: " +
                     (removable.Length == 0 ? "none detected" : string.Join(", ", removable));
        var msg = $"PC architecture: {arch}\n" +
          $"Windows version: {Environment.OSVersion}\n" +
          $"Removable drives seen: {(removable.Length == 0 ? "none" : string.Join(", ", removable))}\n\n" +
          "Some USB SSDs are not reported as removable, so Rufus must be checked separately.\n\n" +
          (RuntimeInformation.OSArchitecture == Architecture.X64 ?
          "PASS: This installer includes the correct x86_64 Linux ISO." :
          "WARNING: This build targets a Windows x64 PC. Do not use its ISO on an ARM PC.");
        MessageBox.Show(msg, "AiboOS Windows Check", MessageBoxButtons.OK,
            RuntimeInformation.OSArchitecture == Architecture.X64 ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
        SetStatus(RuntimeInformation.OSArchitecture == Architecture.X64 ?
          "Windows PC check complete." : "Architecture warning: see dialog.");
    }

    private async Task DownloadAllAsync()
    {
        busy = true;
        RefreshStep();
        try
        {
            Directory.CreateDirectory(folder);
            await DownloadVerifiedAsync(LinuxName, LinuxUrl, LinuxSha);
            await DownloadVerifiedAsync(RufusName, RufusUrl, RufusSha);
            lastReport = "Both official downloads verified by SHA-256; Linux boot has not yet been tested.";
            progress.Value = 100;
            SetStatus("Linux ISO + Rufus VERIFIED. Ready for USB preparation.");
            MessageBox.Show("Both official downloads passed SHA-256 verification.\n\nNext: create a bootable Linux USB using Rufus.\n\nNo disk was erased and your iPhone was not modified.",
                "AiboOS files prepared", MessageBoxButtons.OK, MessageBoxIcon.Information);
            currentStep = 3;
        }
        catch (Exception ex)
        {
            progress.Value = 0;
            SetStatus("Download or checksum verification failed. No USB was written.");
            MessageBox.Show(ex.Message, "AiboOS download failed safely", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            busy = false;
            RefreshStep();
        }
    }

    private async Task DownloadVerifiedAsync(string name, string url, string expectedSha)
    {
        var target = Path.Combine(folder, name);
        if (File.Exists(target))
        {
            if (await VerifyShaAsync(target, expectedSha))
            {
                SetStatus($"{name}: already SHA-256 verified.");
                return;
            }
            throw new InvalidDataException($"{name} exists but its checksum is WRONG. Delete or rename it before retrying. Nothing has been executed.");
        }

        if (!url.StartsWith("https://github.com/", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Refusing an unofficial download URL.");

        var partial = target + ".part";
        if (File.Exists(partial)) File.Delete(partial);
        try
        {
            SetStatus($"Downloading {name} from official GitHub...");
            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();
            var total = response.Content.Headers.ContentLength ?? 0;
            await using (var input = await response.Content.ReadAsStreamAsync())
            await using (var output = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                var buffer = new byte[65536];
                long done = 0;
                int read;
                while ((read = await input.ReadAsync(buffer)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, read));
                    done += read;
                    if (total > 0)
                        progress.Value = Math.Clamp((int)(done * 100 / total), 0, 100);
                    SetStatus($"Downloading {name}: {(total > 0 ? (done * 100 / total).ToString() + "%" : $"{done / 1024 / 1024} MB")}");
                }
            }
            SetStatus($"Verifying {name} with SHA-256...");
            if (!await VerifyShaAsync(partial, expectedSha))
                throw new InvalidDataException($"{name} failed its SHA-256 integrity check. It will NOT be used.");
            File.Move(partial, target, true);
            SetStatus($"Verified {name}.");
        }
        finally
        {
            if (File.Exists(partial)) File.Delete(partial);
        }
    }

    private static async Task<bool> VerifyShaAsync(string path, string expected)
    {
        await using var file = File.OpenRead(path);
        var actual = Convert.ToHexString(await SHA256.HashDataAsync(file)).ToLowerInvariant();
        return actual.Equals(expected, StringComparison.OrdinalIgnoreCase);
    }

    private async Task LaunchRufusAsync()
    {
        var path = Path.Combine(folder, RufusName);
        var iso = Path.Combine(folder, LinuxName);
        if (!File.Exists(path) || !File.Exists(iso))
        {
            MessageBox.Show("Linux ISO and Rufus are missing. Use 'Download + verify both' first.",
                "Files not prepared", MessageBoxButtons.OK, MessageBoxIcon.Information);
            currentStep = 2; RefreshStep(); return;
        }
        if (!await VerifyShaAsync(path, RufusSha) ||
            !await VerifyShaAsync(iso, LinuxSha))
        {
            MessageBox.Show("One downloaded file failed its SHA-256 check. Rufus will not start.",
                "Integrity check failed", MessageBoxButtons.OK, MessageBoxIcon.Error); return;
        }
        var answer = MessageBox.Show(
            "Rufus can COMPLETELY ERASE the USB drive you select.\n\nChoose only a SPARE removable USB drive, NEVER your Windows system disk.\n" +
            "In Rufus, SELECT the palen1x ISO and choose DD MODE if prompted.\n\nOpen Rufus now?",
            "Confirm safe USB preparation", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
        if (answer != DialogResult.OK) return;
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true, WorkingDirectory = folder });
        Process.Start(new ProcessStartInfo(folder) { UseShellExecute = true });
        SetStatus("Rufus opened. You must select and approve the USB drive.");
    }

    private void OpenFolder()
    {
        Directory.CreateDirectory(folder);
        Process.Start(new ProcessStartInfo(folder) { UseShellExecute = true });
    }

    private static void OpenOfficial(string url)
    {
        if (!url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) return;
        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        client.Dispose();
        base.OnFormClosed(e);
    }
}
