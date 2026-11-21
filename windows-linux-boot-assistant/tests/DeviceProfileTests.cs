using System;
using AiboOS.LinuxBootAssistant;

int checks = 0;
void Expect(bool actual, bool expected, string name)
{
    if (actual != expected) throw new Exception($"Failed {name}, expected {expected}.");
    checks++;
}
void Profile(string? model, string ios, bool expected) =>
    Expect(DeviceProfiles.TryGetLinuxRoute(model, ios, out _), expected, $"profile {model}/{ios}");

Profile(DeviceProfiles.Se2016, "15.8.8", true);
Profile(DeviceProfiles.Se2016, "iOS 15.8.8", true);
Profile(DeviceProfiles.Se2016, "15.0", true);
Profile(DeviceProfiles.Se2016, "14.8.1", false);
Profile(DeviceProfiles.Se2016, "16.0", false);
Profile(DeviceProfiles.Se2020, "15.8.8", false);
Profile(DeviceProfiles.Se2022, "15.8.8", false);
Profile(null, "15.8.8", false);
Profile("Choose iPhone model", "15.8.8", false);
Profile(DeviceProfiles.Se2016, "Choose last-known iOS", false);
Profile(DeviceProfiles.Se2016, "", false);
Profile(DeviceProfiles.Se2016, "abc", false);
Expect(UsbModes.IsDfu(new[] { "1227" }), true, "DFU PID");
Expect(UsbModes.IsDfu(new[] { "1281" }), false, "recovery not DFU");
Expect(UsbModes.IsPongo(new[] { "4141" }), true, "Pongo PID");
Expect(UsbModes.Describe(new[] { "1281" }).Contains("Recovery"), true, "recovery description");
Expect(UsbModes.Describe(new[] { "1227" }).Contains("DFU"), true, "DFU description");
Expect(UsbModes.Describe(Array.Empty<string>()).Contains("No Apple"), true, "not connected");
Console.WriteLine($"PASS: {checks} read-only DFU routing/USB mode tests.");
