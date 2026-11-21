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
                return File.Exists(path) && new FileInfo(path).Length == ImageWriter.ImageSize ? 0 : 1;
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
            File.Move(temp, final, false);
            progress?.Report(100);
            return final;
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}

internal sealed class Setup : Form
{
    readonly Button build = new() { Text = "Prepare AiboOS system image", Width = 460, Height = 52 };
    readonly Button open = new() { Text = "Open image folder", Width = 460, Height = 42, Enabled = false };
    readonly ProgressBar progress = new() { Width = 460, Height = 22 };
    readonly Label state = new() { Text = "Ready to extract the embedded ARM64 operating system.", Width = 460, Height = 70 };
    string? result;
    internal Setup()
    {
        Text = "AiboOS — OS image preparation";
        ClientSize = new Size(540, 460);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(26, 19, 39);
        ForeColor = Color.White;
        Font = new Font("Segoe UI", 11);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(34, 20, 34, 20) };
        panel.Controls.Add(new Label { Text = "AiboOS", Font = new Font("Segoe UI", 30, FontStyle.Bold), ForeColor = Color.HotPink, Width = 460, Height = 65 });
        panel.Controls.Add(new Label { Text = "ARM64 system image • Development build", Width = 460, Height = 34 });
        panel.Controls.Add(new Label { Text = "Creates a verified 256 MiB Linux filesystem image on this PC. iPhone SE permanent installation is not implemented. No phone or physical disk is written.", Width = 460, Height = 85 });
        build.BackColor = Color.FromArgb(240, 143, 194);
        build.ForeColor = Color.Black;
        build.FlatStyle = FlatStyle.Flat;
        open.ForeColor = Color.Black;
        panel.Controls.Add(build);
        panel.Controls.Add(progress);
        panel.Controls.Add(state);
        panel.Controls.Add(open);
        Controls.Add(panel);
        build.Click += async (_, _) =>
        {
            build.Enabled = false;
            open.Enabled = false;
            progress.Value = 0;
            state.Text = "Extracting and verifying AiboOS...";
            try
            {
                string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AiboOS", "Images", Guid.NewGuid().ToString("N"));
                var report = new Progress<int>(p => progress.Value = Math.Clamp(p, 0, 100));
                result = await Task.Run(() => ImageWriter.Create(folder, report));
                state.Text = "Image verified and saved. Your iPhone has not been changed.";
                open.Enabled = true;
            }
            catch (Exception ex) { state.Text = "Image preparation failed: " + ex.Message; }
            finally { build.Enabled = true; }
        };
        FormClosing += (_, e) => { if (!build.Enabled) e.Cancel = true; };
        open.Click += (_, _) =>
        {
            if (result != null)
                Process.Start(new ProcessStartInfo { FileName = Path.GetDirectoryName(result)!, UseShellExecute = true });
        };
    }
}
