namespace AiboOS.LinuxBootAssistant;

internal static class DeviceProfiles
{
    public const string Se2016 = "iPhone SE (2016) — A9";
    public const string Se2020 = "iPhone SE (2020) — A13";
    public const string Se2022 = "iPhone SE (2022) — A15";

    // This only selects the Windows/Linux BOOT PREPARATION route.
    // It does not claim AiboOS is compatible with or can install on any phone.
    public static bool TryGetLinuxRoute(string? model, string? iosText, out string result)
    {
        if (string.IsNullOrWhiteSpace(model))
        {
            result = "First select your iPhone model. The SE generations have different chips and boot requirements.";
            return false;
        }
        if (model != Se2016)
        {
            result = model == Se2020 || model == Se2022
                ? "STOP: This iPhone SE generation uses A13/A15, not A9. The palen1x/checkm8 boot route in this setup does not support it."
                : "STOP: This AiboOS Linux boot preparation is not verified for the chosen phone. Select the precise supported model.";
            return false;
        }
        if (string.IsNullOrWhiteSpace(iosText))
        {
            result = "Enter your installed iOS version, such as 15.8.8. Do not guess or use the phone model as the version.";
            return false;
        }
        var text = iosText.Trim();
        if (text.StartsWith("iOS ", StringComparison.OrdinalIgnoreCase)) text = text.Substring(4).Trim();
        if (!Version.TryParse(text, out var version) || version.Major <= 0 || version.Minor < 0)
        {
            result = "Unrecognised iOS version. Use a numeric version such as 15.8.8 (Settings > General > About).";
            return false;
        }
        if (version.Major < 15)
        {
            result = "STOP: palera1n/palen1x is for iOS 15.0 or later. This selected iOS version requires a different route.";
            return false;
        }
        if (version.Major > 15)
        {
            result = "STOP: The 2016 iPhone SE cannot run iOS 16 or later. Check whether you selected the wrong iPhone generation or iOS version.";
            return false;
        }
        result = "SUPPORTED FOR LINUX USB PREPARATION: " + model + " on iOS " + text
                 + ". Uses the official palen1x A9/checkm8 research route; AiboOS kernel boot and any permanent iOS replacement remain UNVERIFIED.";
        return true;
    }
}
