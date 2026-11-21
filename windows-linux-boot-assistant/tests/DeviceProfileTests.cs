using System;
using AiboOS.LinuxBootAssistant;

int checks = 0;
void Expect(string? model, string version, bool expected)
{
    bool result = DeviceProfiles.TryGetLinuxRoute(model, version, out string message);
    if (result != expected) throw new Exception($"Case model={model}, iOS={version}, expected {expected}: {message}");
    checks++;
}
Expect(DeviceProfiles.Se2016, "15.8.8", true);
Expect(DeviceProfiles.Se2016, "15.0", true);
Expect(DeviceProfiles.Se2016, "15.8.7", true);
Expect(DeviceProfiles.Se2016, "iOS 15.8.8", true);
Expect(DeviceProfiles.Se2016, "14.8.1", false);
Expect(DeviceProfiles.Se2016, "16.0", false);
Expect(DeviceProfiles.Se2016, "Unknown", false);
Expect(DeviceProfiles.Se2016, "", false);
Expect(DeviceProfiles.Se2020, "15.8.8", false);
Expect(DeviceProfiles.Se2022, "15.8.8", false);
Expect("Other / not listed", "15.8.8", false);
Expect(null, "15.8.8", false);
Console.WriteLine($"PASS: {checks} offline device/version compatibility tests.");
