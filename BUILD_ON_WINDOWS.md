# Get a real AiboOS IPA on your Windows PC

This ZIP contains **iOS Xcode source**, not a precompiled IPA. It is an iOS app wrapper, **not** an iOS replacement or Android runtime. No iPhone firmware is flashed.

## Option A: GitHub Actions from Windows (requires GitHub account)

1. Create a **private repository** on GitHub for the AiboOS source (no password, token or personal data should be committed).
2. Upload the **contents of this folder**, including the hidden `.github/workflows/build-ipa.yml` file.
3. In the repository, choose **Actions → Build AiboOS IPA (for TrollStore testing) → Run workflow**.
4. Wait for a completed green run; inspect build logs for errors.
5. Download the artifact `AiboOS-TrollStore-IPA-UNSIGNED` and extract it. It contains `AiboOS_TrollStore_UNSIGNED.ipa`.
6. Transfer the IPA to your **own** jailbroken iPhone SE and attempt installation with TrollStore, following its official instructions.

> An unsigned IPA is not guaranteed to install or run. The compiled IPA has **not** been tested on the iPhone SE. If TrollStore requires signing, use its supported ldid signing workflow. Never turn off iPhone protection features or erase iOS to test this wrapper.

## Option B: Mac with Xcode

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project AiboOS.xcodeproj -scheme AiboOS -configuration Release -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
mkdir -p package/Payload
cp -R build/Build/Products/Release-iphoneos/AiboOS.app package/Payload/
(cd package && zip -qr ../AiboOS_TrollStore_UNSIGNED.ipa Payload)
```

## What works and what does not

- **Works in the browser prototype:** built-in AiboOS apps, app store's demo installs, settings, Sileo deep link UI, local APK import/library in supported browsers.
- **Needs actual device test:** iPhone WKWebView layout, persisted storage, on-device APK file picker, music/media, Sileo link activation, TrollStore installation.
- **Not supported:** executing APK files; automatically installing Sileo `.deb` packages; native iOS firmware, custom kernel, boot replacement.
- iPhone SE 2016 on iOS 15.8.8 supports an app wrapper at this minimum OS target (iOS 15.0). However, an actual native compile is required and has not been done in this container.
