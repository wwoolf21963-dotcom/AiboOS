using System;

namespace AiboOS.LinuxBootAssistant;

internal static class DeviceProfiles
{
    public const string Se2016 = "iPhone SE (2016) — A9";
    public const string Se2020 = "iPhone SE (2020) — A13";
    public const string Se2022 = "iPhone SE (2022) — A15";

    // Identifies a research profile only. A successful result does NOT authorize
    // checkm8, PongoOS upload, device erasure or permanent AiboOS installation.
    public static bool TryGetLinuxRoute(string? model, string? iosText, out string result)
    {
        if (string.IsNullOrWhiteSpace(model) || model == "Choose iPhone model")
        {
            result = "Select the exact iPhone model; DFU alone does not identify it reliably.";
            return false;
        }
        if (model != Se2016)
        {
            result = "STOP: This A9 iPhone SE research profile does not apply to the selected phone.";
            return false;
        }
        if (string.IsNullOrWhiteSpace(iosText) || iosText == "Choose last-known iOS")
        {
            result = "Enter the last-known iOS version. DFU does not reveal the installed version.";
            return false;
        }
        var value = iosText.Trim();
        if (value.StartsWith("iOS ", StringComparison.OrdinalIgnoreCase))
            value = value.Substring(4).Trim();
        if (!Version.TryParse(value, out var version) || version.Major <= 0 || version.Minor < 0)
        {
            result = "Enter a numeric iOS version, for example 15.8.8.";
            return false;
        }
        if (version.Major != 15)
        {
            result = "STOP: This experimental A9/iOS 15 research profile does not match the selected iOS version.";
            return false;
        }
        result = "A9 research profile matches. RAM boot and storage replacement are NOT verified.";
        return true;
    }
}
