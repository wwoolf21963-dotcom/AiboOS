using System;

namespace AiboOS.LinuxBootAssistant;

internal static class DeviceProfiles
{
    public const string Se2016 = "iPhone SE (2016) — A9";
    public const string Se2020 = "iPhone SE (2020) — A13";
    public const string Se2022 = "iPhone SE (2022) — A15";

    // Legacy research classification: not a boot or installation guarantee.
    public static bool TryGetLinuxRoute(string? model, string? iosText, out string result)
    {
        if (string.IsNullOrWhiteSpace(model))
        {
            result = "Select a model.";
            return false;
        }
        if (model != Se2016)
        {
            result = "STOP: A9 research preparation does not support this iPhone model.";
            return false;
        }
        if (!TryParseIOS(iosText, out var version))
        {
            result = "Enter a numeric iOS version such as 15.8.8.";
            return false;
        }
        if (version.Major != 15)
        {
            result = "STOP: The experimental A9 iOS 15 preparation route does not support this version.";
            return false;
        }
        result = "Research route only. Linux kernel boot and iOS replacement remain unverified.";
        return true;
    }

    public static bool TryGetPhoneAppRoute(string? model, string? iosText, out string result)
    {
        if (string.IsNullOrWhiteSpace(model) ||
            model == "Choose your iPhone")
        {
            result = "Select your exact iPhone generation. No phone or version is automatically detected without a connection.";
            return false;
        }
        if (!TryParseIOS(iosText, out var version))
        {
            result = "Select or enter your installed iOS version (for example, 15.8.8).";
            return false;
        }
        if (model != Se2016)
        {
            result = "This release is prepared for the 2016 iPhone SE. Other models are not verified. Nothing will be installed.";
            return false;
        }
        if (version.Major != 15)
        {
            result = "This iPhone SE AiboOS app build targets iOS 15. Your selection is not a verified match.";
            return false;
        }
        result = "Scan the QR code with your iPhone or open the release link on it. "
               + "The AiboOS IPA requires a compatible installation method such as TrollStore. "
               + "It runs INSIDE iOS; it does not replace or remove iOS.";
        return true;
    }

    private static bool TryParseIOS(string? iosText, out Version version)
    {
        version = new Version(0, 0);
        if (string.IsNullOrWhiteSpace(iosText)) return false;
        string value = iosText.Trim();
        if (value.StartsWith("iOS ", StringComparison.OrdinalIgnoreCase))
            value = value.Substring(4).Trim();
        if (!Version.TryParse(value, out var parsed) || parsed.Major <= 0 ||
            parsed.Minor < 0 || parsed.Build < -1 || parsed.Revision < -1)
            return false;
        version = parsed;
        return true;
    }
}