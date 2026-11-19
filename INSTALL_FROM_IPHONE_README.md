# Get AiboOS onto your iPhone SE via TrollStore

**Your device:** iPhone SE 2016 (A1723), iOS 15.8.8.  
**What this builds:** AiboOS as an **app** containing the offline web-based AiboOS prototype. It will NOT remove or replace iOS. It does NOT run APKs.

## On your Windows PC, once

1. Make or sign in to a free GitHub account.
2. Create a new **private** repository named `AiboOS-SE` (do not choose an empty custom branch).
3. Extract this ZIP on your PC. Upload **all files and folders inside the extracted directory** to your repository, including `.github/workflows/build-ipa.yml`. GitHub's browser upload may not preserve hidden folders if selected incorrectly; using Git is more reliable.
4. In your repository, open **Actions** > **Build AiboOS IPA for TrollStore** > **Run workflow**. If GitHub requests workflow approval, enable Actions for this repository.
5. When the build succeeds, tap the workflow run. Under **Artifacts**, download `AiboOS-SE-TrollStore-IPA`.
6. Unzip the download. Inside you will find `AiboOS_SE_TrollStore.ipa`.

## On your iPhone

1. Open Safari, sign in to GitHub, visit your repository > Actions and download the successful build artifact. Safari saves a ZIP to Files.
2. Open **Files** and tap that ZIP to extract `AiboOS_SE_TrollStore.ipa`.
3. In **Files**, tap or share the `.ipa` and choose **TrollStore**. Or open TrollStore > **+** > select the IPA.
4. Install and launch **AiboOS**. Keep iOS and TrollStore installed.

If TrollStore rejects the IPA, do not try to bypass restrictions or erase iOS. Capture the **exact error**, then use that error to fix signing/packaging in the build workflow.

## Want one direct IPA link on your iPhone?

After the project builds successfully, on your PC create/push a release tag such as `aibo-v0.7` to run the release workflow. It publishes `AiboOS_SE_TrollStore.ipa` in GitHub Releases, so Safari can download it directly without extracting an Actions artifact ZIP.

Git commands in your checked-out repository:

    git tag aibo-v0.7
    git push origin aibo-v0.7

*GitHub Actions requires a macOS runner to compile this native iOS wrapper. No already-built IPA is included in this ZIP.*

## Limitations

- Source code and file layout are validated, but **the native app has not been compiled or tested on an actual phone**.
- The build is unsigned. Depending on TrollStore version and package requirements, additional signing steps may be necessary.
- For iOS 15.8.8, a `WKWebView` wrapper may show minor differences from the desktop prototype.
- The original iPhone SE can be jailbroken but that does **not** mean a replacement operating system is installed.
