# Test report

Local Mac update: **0.5.1 (15)**. Checked October 20, 2026.

## 0.5.1 widget controls

**151 automated tests passed:** 102 core tests, 48 native feature/layout tests and one iPhone simulator UI test. The simulator test exercises app Pause, Resume, Keep printing and confirmed Stop; it does not exercise the physical iPhone Home Screen widget. New coverage verifies widget job/connection validation, expired and offline readings, single-use action claims, duplicate dispatch, uncertain outcomes without retries, credential-free action payloads, and Stop confirmation binding. Small, medium and large production widgets render with controls and all three temperatures in light and dark appearances. Additional boundary renders check 100% in the widget/app rings and 0/9/99/100 in the menu bar circle; bounded percentage labels keep the text inside the ring.

The actual installed macOS desktop widget was tested using a separately signed, separately identified **Print Progress QA** app and its **Widget Test** printer. Its backend has no network control client, uses an isolated Keychain namespace, and refuses production bundle identifiers. Native clicks on Pause and Resume changed the displayed state and produced exactly one fictional receipt each. The containing app stayed closed. A native click on Stop opened the correct job confirmation. Cancelling sent no command; confirming in the review produced one fictional Stop receipt. Cold app launch and reopening the review with all app windows closed also passed. **No physical printer-control commands were sent.**

This end-to-end test caught a runtime action identifier that differed from Xcode's extracted metadata: the button rendered but macOS could not resolve it. The fix uses the extracted default identifier. A reusable metadata check now runs in CI for the app and extension, alongside the actual-click regression scripts.

[Small widget with controls](media/widget-controls-small.png) · [Two active printers](media/widget-controls-medium.png) · [Finished at 100%](media/widget-100.png)

These images are native production-view renders using fictional readings, not desktop captures. The real desktop interaction tests used Accessibility inspection and explicitly authorized native clicks because the normal screen-control service was unavailable.

Both release app/widget builds passed. The Universal Mac release was notarized, signature-checked, and packaged as a verified DMG. The installed app retained live printer profiles; read-only status showed the H2D's finished job. Finished and idle jobs intentionally omit Pause/Resume/Stop. The corrected iPhone release was installed on the test phone, but a locked device prevented its launch during this pass; physical iPhone widget controls are not claimed as verified. Lock Screen accessory widgets remain informational. Apple controls all widget refresh scheduling.

### Repeating widget QA

Build a **Debug-only** isolated app using `PRINT_BUNDLE_PREFIX=org.example.printprogresswidgetqa`, `PRINT_APP_PRODUCT_NAME=Print Progress QA`, `PRODUCT_MODULE_NAME=$(TARGET_NAME)`, `PRINT_URL_SCHEME=printprogresswidgetqa`, and `SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG PRINT_PROGRESS_WIDGET_QA`. Supply your own development signing team and matching app/widget Keychain entitlements. Keep private signing settings in an ignored `.xcconfig`. Install this alongside the normal app and add its small **Print Progress QA** desktop widget.

```sh
swiftc scripts/widget-qa-click.swift -o build/WidgetClick.noindex/widget-qa-click
# Requires explicit approval for native mouse input; only the fictional QA widget is accepted.
python3 scripts/test-widget-actions-macos.py \
  --app '/Applications/Print Progress QA.app' \
  --helper build/WidgetClick.noindex/widget-qa-click --allow-native-click
python3 scripts/test-widget-stop-macos.py --app '/Applications/Print Progress QA.app'
python3 scripts/check-widget-intent-metadata.py '/Applications/Print Progress QA.app'
```

Accessibility access is required. The click helper verifies the widget title, fictional printer, expected state, enabled control and hit target before sending input; it refuses obscured controls. Reports and receipts are written only under ignored `.noindex` folders. Remove the QA widget and app after testing. Do not point the QA build at real hardware or use these scripts against the production app.

## 0.5.0 print controls

**140 automated tests passed:** 102 core unit/network tests, 37 native app/layout/lifecycle tests, and one iPhone simulator UI test. The core control suite exercises real loopback HTTP with Digest authentication, TLS/MQTT, native K1 WebSocket, and SDCP WebSocket/UDP exchanges. It covers pause/resume/stop transitions, rejected commands, changed jobs, mismatched acknowledgements, unsafe redirects, timeouts without resending, malformed success responses, and stale/offline state gates. Existing monitoring tests still verify read-only background traffic. No tests were skipped.

App tests cover duplicate clicks, actual versus requested state, confirmation expiry without retries, cancelling commands when a profile changes, binding confirmations to their original connection, and demo isolation. Native production views render controls in the app cards and menu bar. The iPhone UI test launches an isolated Debug app in fictional demo mode and taps Pause, Resume, Keep printing, and confirmed Stop. It asserts the final Cancelled state and retains screenshots. This caught a confirmation popover that hid its cancel button; a two-button alert replaced it and passed the full flow.

[Mac Resume/Stop controls](media/mac-controls-paused.png) · [Actual iPhone paused controls](media/iphone-controls-paused.png) · [Actual iPhone Stop confirmation](media/iphone-controls-confirm.png)

These tests do not establish physical printer-control compatibility. No pause/resume/stop command was sent to a real printer. Bambu firmware authorization, third-party control permissions, and hardware-specific cancellation routines still require real-device validation. Mac menu bar OS-level button interaction remains unverified because the native screen-control service is unavailable; its actual production view was rendered and inspected. In 0.5.0, widgets opened the app for controls; 0.5.1 adds the authenticated widget actions described above.

## 0.4.2 direct download and website

All **30 native feature/layout/lifecycle/installer tests passed**, with zero failures. The six new installer tests cover installed versus translocated copies, the running volume, similar volume names, invalid image metadata, non-volume paths and missing release markers. Both the normal sandboxed Mac Release build and the iOS Release build succeeded. Connection and telemetry code did not change; the core suite was not rerun for this update.

The Universal direct Mac archive was signed with Developer ID, accepted by Apple's notarization service, exported with a stapled ticket, and accepted by Gatekeeper. Strict signature and stapling checks also passed for the app inside the finished DMG. A packaging check caught and removed Finder metadata that invalidated strict signature verification.

The actual read-only DMG was mounted and its app was copied to Applications using the project installer, replacing and relaunching the previous build. The installed 0.4.2 app ejected the matching installer after launch. A separate read-only disk with a mismatched release marker remained mounted and was then manually detached. This verifies copy/launch/eject behavior; dragging in Finder and the Finder window's final appearance were not visually driven because native screen control was unavailable. The background artwork and saved Finder layout were inspected separately.

Headless browser checks passed at 1440, 768, 390 and 320 pixels wide: no horizontal overflow, loaded images and demo video, four menu bar previews, expandable compatibility information, valid section anchors, correct download targets, reduced-motion behavior and no browser script or asset errors. Desktop and mobile screenshots were inspected. The website uses only local assets and no analytics, external fonts or runtime dependencies.


## 0.4.1 Dock behavior

All **24 native application feature/layout/lifecycle tests passed**, with zero failures. Three new tests use real AppKit windows to verify closing the last window, reopening a retained window, keeping the Dock visible while a second app window remains open, and excluding a status panel. Both Mac and iOS Release builds succeeded. Printer connection and telemetry code did not change; the core suite was not rerun for this update.

The signed Mac app was installed and relaunched. Strict signature verification passed, and Spotlight returned only the current installation. Installed-app visual interaction could not be completed because the screen-control service failed with a ScreenCaptureKit audio/video capture error and timed out when inspecting the Dock. The native lifecycle tests do not replace that visual check.

## 0.4.0 automated results

**107 tests passed, zero failures, zero skips.**

| Suite | Tests | Coverage |
| --- | ---: | --- |
| Core unit and request tests | 72 | Seven protocol parsers, validation, state mapping, temperatures, progress, time estimates, numeric limits and MQTT framing |
| Real-socket integration tests | 14 | HTTP, HTTP Digest, WebSocket, UDP and TLS/MQTT; pinning, credentials, redirects, cancellation, deadlines, malformed responses and read-only requests |
| Application feature tests | 16 | Persistence failures, refresh races, cancellation, offline recovery, demo isolation and certificate-pin save failure |
| Native SwiftUI layout tests | 5 | Printer forms, states, large text, menu bar modes and popup sizing, widget sizes and missing sensors |

Core executable-line coverage is **95.61% (1,306 / 1,366)**, function coverage 94.17%, and region coverage 83.09%. This measures `PrintProgressCore`, not the entire app. Native tests render 29 production-UI images for inspection; they are layout assertions, not pixel-baseline screenshot comparisons.

Both Mac and iOS Release archives build with their WidgetKit extensions. Reproduction commands are in the [README](../README.md#tests-and-live-connection-check).

The [hosted macOS CI run](https://github.com/danielyaa5/3d-printer-widget/actions/runs/39432785593) also passed all test stages and the iOS app/widget build. Loopback fixture startup uses its known local hostname rather than depending on reverse DNS.

## Installed-app and hardware checks

The preceding 0.3.1 device pass covered:

- Mac setup for all seven interfaces against synthetic local servers, including invalid input, incorrect and corrected authentication, save/relaunch, editing, and removal.
- Paused, offline, finished, and idle transitions. Offline retained the last actual timestamp and progress; paused omitted a running finish time.
- Walkthrough navigation, menu bar preferences and four appearances, explicit printer selection, and continued monitoring after closing the main window.
- Live Bambu H2D and K1 Max status, including active-nozzle selection and the K1's Moonraker and native interfaces.
- Mac desktop widget temperatures and refresh navigation to the app.
- Physical iPhone setup fields, walkthrough, preferences, refresh, background/foreground behavior, widget gallery, printer selection, and widget-to-app refresh.
- 479 fixture requests with zero unexpected printer-control operations. Temporary fixture profiles were removed.

The 0.4.0 regression pass adds isolated demo states and verifies that failed certificate-pin persistence cannot leave an apparently saved pin in memory. Public demo media is generated from fictional readings, independently of live profiles.

The installed 0.4.0 Mac release and physical iPhone were opened and checked with live printer readings and the isolated demo. Clean demo screenshots were captured on both devices. Reinstalling the complete Mac Release bundle passed strict signature verification for the app and widget, then relaunched with both saved printers intact.

The signed iOS Release app was also tested in the iPhone Duo simulator, in both closed and expanded layouts. First-run walkthrough navigation, opening and cancelling a printer form, and the three demo states worked. Paused readings did not show a running finish estimate; Finished showed 100%. Closing the demo and relaunching returned to the empty app without repeating onboarding or saving fictional printers. The [screen recording](media/iphone-demo.mp4) and [GIF](media/iphone-demo.gif) capture these actual app interactions with fictional data.

On a 13-inch iPad Pro simulator, all walkthrough steps, presenting and cancelling the Bambu setup form, and Printing/Paused/Finished demo transitions were checked in portrait. Actual iPad screenshots are in `release/app-store/screenshots/`.

## Limits

OctoPrint, PrusaLink, Duet and SDCP still need physical-hardware validation across firmware versions. Fixture success alone does not establish universal model compatibility.

The actual Mac menu bar popup click could not be driven reliably by the screen-control service. Its production view, content height, empty state and display modes passed native tests, but those tests do not replace that system interaction.

Some long iPhone setup screens could not be scrolled reliably through mirroring. Alternate widget sizes and Lock Screen accessory widgets were rendered but not interactively tested on the phone. Physical iPad hardware, iPad multitasking, VoiceOver traversal, OS-upgrade migration, first-unlock/reboot behavior and long-duration network soak testing remain unverified.

Connection cancellation is covered by unit and real-network tests; a live UI cancellation was not captured before the request completed. Widget background scheduling remains controlled by the operating system.
