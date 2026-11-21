using System.Collections.Generic;
using System.Linq;

namespace AiboOS.LinuxBootAssistant;

internal static class UsbModes
{
    public static bool IsDfu(IEnumerable<string> ids) =>
        ids.Any(id => string.Equals(id, "1227", System.StringComparison.OrdinalIgnoreCase));

    public static bool IsPongo(IEnumerable<string> ids) =>
        ids.Any(id => string.Equals(id, "4141", System.StringComparison.OrdinalIgnoreCase));

    public static string Describe(IEnumerable<string> ids)
    {
        var values = ids.ToArray();
        if (IsDfu(values)) return "iPhone DFU USB mode detected";
        if (IsPongo(values)) return "Pongo USB identifier detected (unverified)";
        if (values.Contains("1281")) return "Apple Recovery mode detected (not DFU)";
        if (values.Contains("12A8")) return "Apple normal USB mode detected (not DFU)";
        if (values.Length > 0) return "Apple USB device detected (mode unverified)";
        return "No Apple DFU device found";
    }
}
