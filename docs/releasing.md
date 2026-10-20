# Release preparation

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
