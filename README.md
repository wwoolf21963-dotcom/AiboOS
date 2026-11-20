# AiboOS SE v1.8 – app-wrapper source

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

## Managed internet messaging (v1.8)

AiboOS Messages is preconfigured to use
`https://aibomesgsystem.wwoolf21963.workers.dev` over Wi-Fi or mobile data.
The server URL cannot be edited or disconnected in the AiboOS UI.
If it cannot connect, Messages displays **Service Offline** and retries.
The relay must actually have the repository's Cloudflare Worker messaging code
deployed, with a bound D1 database called `DB` and schema applied.
A default Hello World Worker is not a messaging server.
A deployed HTTPS address alone does not prove end-to-end messaging is working.

The `aiboos-se-v1.8` release is created by a successful GitHub Actions IPA build.
The `aiboos-se-latest` release URL remains the download entry point for future versions.
The resulting IPA is unsigned and intended for compatible TrollStore testing,
not a replacement for iOS. This version does not provide end-to-end encryption.
