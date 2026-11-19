# AiboOS SE v0.7 – app-wrapper source

AiboOS here is a **self-contained iPhone app** intended for eventual TrollStore installation on the first-generation iPhone SE (2016). It wraps the real AiboOS web prototype in an offline `WKWebView` (iOS 15+).

This is **not** a standalone operating system. It does not replace iOS, install Android apps, or make checkm8 optional.

Features:

- Existing interactive home screen, setup, themes, offline features and demo app store.
- AiboAppStore's **Sileo** section uses iOS's `sileo://` URL handler to hand off package management to Sileo; Sileo must already be installed.
- APK library validates APK ZIP structure, inspects DEX and CPU-ABI metadata, stores/imports/exports files if browser storage permits; **it does not execute APKs**.
- Browser asset files are bundled with the app; no AI/cloud server required for the included basic offline functions. This does **not** bundle a 1.75 GB neural model.

## Build

See `BUILD_ON_WINDOWS.md` for a GitHub Actions build from Windows or Xcode commands on a Mac. Before claiming a working IPA, build and test on the real iPhone SE.

## Security

No OS flashing, untrusted repository auto-adds, or automatic APT changes. Review every repo in Sileo and only use trusted packages. Back up your phone and keep jailbreak and iOS versions unchanged.
