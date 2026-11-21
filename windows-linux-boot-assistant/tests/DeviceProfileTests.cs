using System;
using AiboOS.LinuxBootAssistant;

int checks = 0;
void Expect(bool actual, bool expected, string name)
{
    if (actual != expected) throw new Exception($"Failed {name}, expected {expected}.");
    checks++;
}
void Research(string? model, string version, bool expected) =>
    Expect(DeviceProfiles.TryGetLinuxRoute(model, version, out _), expected, $"research {model}/{version}");
void Phone(string? model, string version, bool expected) =>
    Expect(DeviceProfiles.TryGetPhoneAppRoute(model, version, out _), expected, $"app {model}/{version}");

Research(DeviceProfiles.Se2016, "15.8.8", true);
Research(DeviceProfiles.Se2016, "15.0", true);
Research(DeviceProfiles.Se2016, "14.8.1", false);
Research(DeviceProfiles.Se2016, "16.0", false);
Research(DeviceProfiles.Se2020, "15.8.8", false);
Research(null, "15.8.8", false);
Phone(DeviceProfiles.Se2016, "15.8.8", true);
Phone(DeviceProfiles.Se2016, "iOS 15.8.8", true);
Phone(DeviceProfiles.Se2016, "15.0", true);
Phone(DeviceProfiles.Se2016, "14.8.1", false);
Phone(DeviceProfiles.Se2016, "16.0", false);
Phone(DeviceProfiles.Se2020, "15.8.8", false);
Phone(DeviceProfiles.Se2022, "15.8.8", false);
Phone("Choose your iPhone", "15.8.8", false);
Phone(DeviceProfiles.Se2016, "Choose your iOS version", false);
Phone(DeviceProfiles.Se2016, "", false);
Phone(DeviceProfiles.Se2016, "bad", false);
Console.WriteLine($"PASS: {checks} cable-free device/version routing tests.");