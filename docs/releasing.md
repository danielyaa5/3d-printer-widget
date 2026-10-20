# Release preparation

## Direct Mac download and website

Use a Universal Release archive (`arm64` and `x86_64`) for direct distribution. Pass these settings to the Mac scheme only, in addition to your own signing team and bundle prefix:

```sh
PRINT_MAC_APP_SANDBOX=NO \
PRINT_MAC_APP_ENTITLEMENTS=Configuration/macOS-direct.entitlements \
'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PRINT_PROGRESS_DIRECT'
```

Do not override `ENABLE_APP_SANDBOX` or `CODE_SIGN_ENTITLEMENTS` globally: the embedded widget must retain its sandbox and Keychain group. App Store builds use the defaults and do not enable `PRINT_PROGRESS_DIRECT`.

Export the archive with Xcode's Developer ID distribution method, automatic signing, and the upload destination. This signs and submits the app for notarization using the Xcode account. After Apple accepts it, use `xcodebuild -exportNotarizedApp -archivePath YOUR_ARCHIVE -exportPath YOUR_EXPORT`. Verify the exported app with `codesign --verify --deep --strict`, `spctl --assess --type execute`, and `xcrun stapler validate`. Keep account-specific export options and all signing material outside source control.

Build the DMG with the pinned packaging tool in an isolated environment:

```sh
python3 -m venv build/DMGTools.noindex
build/DMGTools.noindex/bin/pip install -r release/requirements-dmg.txt
bash scripts/package-dmg.sh '/path/to/notarized/Print Progress.app'
```

The script refuses an unnotarized app, creates the branded Finder layout and Applications shortcut, verifies the disk image, and writes `SHA256SUMS.txt`. The app's stapled notarization ticket travels inside the disk image. The DMG contains a hidden release marker; the copied app ejects only a read-only disk image with a matching marker and matching app bundle ID, version, and build. It never ejects its own running volume or uses force unmount. Users must copy the app to Applications before opening it.

Mount and test the actual DMG, copy the app, launch it, and confirm the installer volume disappears. Test a disk with a mismatched marker and confirm it remains mounted. Publish `Print-Progress.dmg` and `SHA256SUMS.txt` as assets on a GitHub release, keeping the DMG filename stable for the README and website links. Verify the downloaded asset's hash and Gatekeeper assessment before announcing it.

The website source is in `site/`; `bash scripts/build-site.sh` assembles the static output. `.github/workflows/pages.yml` deploys to GitHub Pages. See [website documentation](../site/README.md). Website browser checks run with Playwright installed and `node scripts/test-site.cjs`; they use a separate headless browser. Set `PRINT_SITE_URL` to test the deployed site and `PRINT_TEST_BROWSER` to choose a Playwright browser channel (default `chrome`).

## App Store

Version **0.4.0 (11)** was submitted for iOS/iPadOS and macOS on October 20, 2026. Both submissions showed **Waiting for Review** after submission. Privacy disclosures were published as **Data Not Collected**. This records the submission state, not an approval or a live store listing.

1. Run the core and feature suites in the README. Inspect failures and skips.
2. Test the installed app on Mac and iPhone, including a physical printer. Check demo isolation, onboarding, settings, stale data, and widget-to-app navigation.
3. Update the version and build number in `project.yml`, then run XcodeGen.
4. Archive `PrintProgressMac` and `PrintProgressIOS` in Release using your own development team and bundle prefix. App and widget signing must share the configured Keychain group.
5. Validate and export using Xcode's App Store Connect distribution method. Keep archives, provisioning profiles, export options containing account identifiers, and upload logs outside source control.
6. Create the store records for your exact bundle IDs. Upload builds, wait for processing, and select the corresponding build for each platform.
7. Complete screenshots, description, category, age ratings, support/privacy URLs, App Privacy, availability, and review information. Use the built-in demo to let reviewers explore without owning a printer.
8. Submit for review and verify the resulting status. An uploaded or processed build is not a submitted app.
9. Install and launch the current local build, unregister stale copies, and check Spotlight.

The app uses Apple's operating-system encryption for TLS, hashing, and Keychain storage. `ITSAppUsesNonExemptEncryption` is false for this implementation. Reassess this declaration if encryption dependencies or behavior change.

The generated demo video is a project demonstration, not an App Store app preview. Store screenshots and previews must meet Apple's current dimensions and content requirements. Public demo media uses fictional data; actual hardware testing must be recorded separately.

For actual simulator screenshots and recordings, install a **signed** Release simulator build so shared Keychain access works. Complete the walkthrough and open **Explore the demo** before capturing. Use `xcrun simctl list devices booted` to identify your test device, then:

```sh
xcrun simctl io YOUR_SIMULATOR_ID screenshot demo.png
xcrun simctl io YOUR_SIMULATOR_ID recordVideo --codec=h264 demo.mp4
```

Stop recording with Control-C. Inspect every screenshot and video before publishing, and use the correct device class for each store slot. Never replace an iPad screenshot with a resized phone image.

App Store metadata and review guidance are in `release/app-store/`. Keep reviewer contact details and account compliance information private.
