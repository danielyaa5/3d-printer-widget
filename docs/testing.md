# Test report

Local Mac update: **0.5.1 (15)**. Checked October 20, 2026.

## Local network access across Mac updates

Use `scripts/install-macos.sh` for signed local installations. The installer checks
both the app and widget against the installed bundle's signing requirements before
replacing either. Changing bundle ID, signing team, or incompatible certificate
requirements stops the update. A change between development and distribution
signing is an identity migration and must be handled deliberately.

The old backup and generated build copy are removed before the replacement is
registered and launched to reduce ambiguity from overlapping app copies.
This is installer hygiene, not a verified fix for OS permission bugs. A
controlled local update still lost access with compatible signing after this
change; incrementing the build number also did not restore access. System logs
reported a saved allow preference but failed application-identity lookup.
Restarting the affected user's network helper, refreshing app registration, and
relaunching the app also did not restore access. The precise OS trigger remains
unproven. Re-enabling the app's Local Network permission was the recovery actually
observed; no permanent workaround has been verified. Do not treat a four-UUID cache entry
alone as proof of duplicate app versions: an embedded widget also has executable
UUIDs. Apple's
[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
documents stable signing identities, executable UUIDs, and issues involving
multiple app copies.

Focused signing-guard tests (no installations or privacy changes):

```sh
python3 scripts/test-macos-install.py
bash -n scripts/install-macos.sh
```

For an actual update check, start with fresh readings in the installed app, build
a replacement with a different executable UUID, install it using the script, and
verify new readings for each connected printer without changing Local Network
permission. A successful command-line printer probe does not prove the app has
permission. Preserve actual cached timestamps when a connection fails.

The app records connection transitions in the `PrinterConnection` system-log
category, using only printer protocol and error category. It does not log names,
addresses, credentials, or job details. Successful builds and identity checks do
not replace the working-before/working-after update test.

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

## Camera previews (2026-10-21)

Camera checks use `Tests/Fixtures/camera_server.py`, a loopback-only HTTP MJPEG and TLS/RTSP server with generated solid-blue images. No printer footage is saved in fixtures. `CameraTests` covers old profile decoding, per-source API-key isolation, camera transforms, chunked JPEG extraction, RTSP framing, H.264 fragmentation/loss recovery, and Digest authentication. `CameraIntegrationTests` exercises actual sockets, HTTP errors and redirects, TLS certificate pairing/rejection, failed pin persistence, Digest authentication, H.264 hardware decoding, and connection shutdown.

```sh
swift test --scratch-path build/Core.noindex --filter Camera
xcodebuild -project PrintProgress.xcodeproj -scheme PrintProgressFeatureTests \
  -destination 'platform=macOS' -derivedDataPath build/CameraMac.noindex \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:PrintProgressFeatureTests/ProgressStoreTests \
  -only-testing:PrintProgressFeatureTests/CameraLayoutTests test
```

The store checks include per-printer persistence, default-off behavior, shared camera sessions, and Keychain-save failure. `CameraPreviewTests` verifies that closing one viewer preserves the shared session, closing the last viewer cancels it, and reopening starts a new session. `CameraLayoutTests` writes expanded app-card and menu layouts to `build/CameraLayout.noindex` without opening visible windows. This pass ran all 113 core tests and 20 focused native app tests successfully; the ten camera core tests were rerun after the final transport edits. Both Mac and iOS Simulator schemes built successfully with signing disabled.

For isolated native interaction checks, start the fixture with `python3 Tests/Fixtures/camera_server.py --directory build/CameraFixtures.noindex/ui-server`. Read the two ephemeral ports in its `ready.json`, then launch a Debug app with `--ui-testing-camera --camera-http-port HTTP_PORT --camera-rtsp-port RTSP_PORT`. This mode keeps synthetic profiles and certificate pins only in memory and does not read or edit saved printers. It is absent from Release builds. Quit the test app and terminate the fixture after use.

Native app-window toggles were clicked for MJPEG and RTSPS, live blue previews were inspected, and disabling MJPEG closed its socket. Physical Klipper camera discovery and stream reads succeeded outside the test app. The test app's real-LAN check was blocked by macOS Local Network access. The actual menu-bar popup could not be reached by the native UI tools; its production view was rendered separately. No physical H2D camera or signed installation was verified in this account, which has no signing identities.

## Widget camera snapshots (2026-10-21)

`WidgetCameraSnapshotTests` runs the full app capture path against the synthetic MJPEG and encrypted H.264 fixtures with live video switched off. It checks thumbnail bounds/rotation, JPEG and timestamp serialization, first-use camera pinning during widget capture, capture throttling, both sockets closing, opt-out image deletion, permission-save failure, old-image preservation on camera failure, and rejection of images belonging to a previous camera connection. Small widgets do not load image settings or bytes.

The layout tests render the production large and extra-large widget views with active/paused controls, two-hour-old image timestamps, and missing/disabled images in light and dark appearances. Outputs are under `build/WidgetCameraLayout.noindex`; their images are generated geometric fixtures, not printer footage.

```sh
xcodebuild -project PrintProgress.xcodeproj -scheme PrintProgressFeatureTests \
  -destination 'platform=macOS' -derivedDataPath build/CameraMac.noindex \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:PrintProgressFeatureTests/WidgetCameraSnapshotTests \
  -only-testing:PrintProgressFeatureTests/CameraPreviewTests \
  -only-testing:PrintProgressFeatureTests/ProgressStoreTests test
```

After the Mac was unlocked, both snapshot toggles were clicked in the isolated native app. MJPEG and encrypted H.264 captures succeeded while both live-video switches stayed off, displayed the actual capture age, and cleared that status on opt-out. All 25 focused native app tests passed. The 113-test core suite passed, with the ten camera tests rerun after the final optional settings additions. Both Mac and iOS Simulator builds passed with signing disabled.

The actual desktop widget, physical H2D snapshot, and signed installation remain unverified. No permissions were changed. Programmatic socket-to-thumbnail-to-cache checks and production-view renders are reported separately from native desktop interaction. The test app and fixture server were closed after verification.

### Signed installation follow-up

The updated Mac app and widget were subsequently built using the existing Apple Development signing identity in its owning login session. The installer verified compatibility with both installed signing identities before replacement. Strict signature verification passed after installation, the installed app relaunched with its saved printer profiles, and Spotlight returned only the current installation. Generated app bundles and the temporary signing job were removed. The installed camera/snapshot switches were observed; a physical H2D camera feed and an actual desktop-widget photo refresh are not claimed as verified by this installation check. No certificates were revoked or private keys copied.

### Native camera verification support

`scripts/camera-ui.applescript` accepts a running app bundle identifier and an explicit camera-only action. `inspect` reports switch states by ordinal, plus counts of live/captured/unavailable labels; it does not print private printer names or values. Switch actions verify the current Accessibility role and available action before pressing. Connection actions target only the camera stream field and the existing connection-check/save button. No print-control button can be selected through this helper.

```sh
osascript scripts/camera-ui.applescript your.bundle.identifier inspect
osascript scripts/camera-ui.applescript your.bundle.identifier live-on 1
```

Run this in the installed app's logged-in macOS session with Accessibility permission enabled and that desktop active/unlocked. SSH can sign in a background login session while native app windows remain unavailable there; a successful SSH login alone does not establish a usable UI test route.

Debug verification reports now include camera frame counts, viewer counts, last-frame timestamps, snapshot capture dates and enabled/failed flags. They contain no camera images or connection details. Comparing successive reports verifies ongoing frame delivery and that counts stop after the final viewer closes. The fixture capture test also checks that frame counts stop and viewer counts return to zero after a bounded snapshot capture.

### Sandboxed camera installation (2026-10-21)

The signed Mac app was rebuilt with `PRINT_MAC_APP_SANDBOX=YES`, `Configuration/macOS.entitlements`, and without `PRINT_PROGRESS_DIRECT`, then installed through `scripts/install-macos.sh`. `scripts/check-macos-sandbox.py` passed for both the built and installed app/widget. The same checker rejected the preceding unsandboxed installation. Both bundles have outgoing network access and the same resolved Keychain group, with no temporary sandbox exceptions. The running app's development report confirms an active sandbox container.

The installed sandboxed app loaded its existing Keychain profiles and showed both physical printers online. The physical Moonraker camera displayed real video using its saved Custom Camera URL. Snapshot capture succeeded with live video off and returned to zero viewers. The native connection editor rejected an unsupported custom RTSP URL before saving, then successfully saved the original MJPEG URL and reconnected. The optional field is also present when adding a printer. After relaunch, saved profiles, the custom URL, and per-printer settings remained available; snapshot opt-out removed the capture status. No private connection values or camera footage were saved to verification artifacts.

The same installed sandboxed app was subsequently launched in its isolated in-memory camera-fixture mode. Native toggles produced live MJPEG and encrypted H.264 previews. Both snapshot toggles captured while live video was off; fixture receipts recorded two opens and two closes for each transport, including both live-preview and bounded-capture connections. The fixture was stopped and the normal installed app reopened afterward. Real profiles were not modified by fixture mode.

Focused checks passed: 11 core camera tests, including custom Bambu relay precedence and credential isolation; 27 native camera, snapshot, store, and setup-layout tests; and the iOS Simulator build. Generated setup forms were visually inspected. Debug-only widget camera diagnostics now record family, timeline versus snapshot invocation, sandbox-container state, status/permission/image counts, and the latest capture date in shared Keychain; the app exports this sanitized evidence to its own cache when available.

The physical H2D camera remains unverified because its local video setting is off and the endpoint refuses connections. Preserving existing cloud/Handy access is required; the setting was left unchanged. A Bambu Studio relay was not installed or tested. Actual desktop large/XL widget images and the native menu-bar popup remain unverified because current desktop-control tooling cannot acquire those surfaces. Production widget/menu render tests and matching entitlements are not substitutes for those interactions. The app remains open with the first printer's live preview enabled and snapshot opt-ins off for both printers. No printer-control commands were sent.

### Camera setup, Studio bridge, and actual widget follow-up (2026-10-21)

The installed sandboxed app now has a per-printer **Set up camera** flow shared by the app cards and menu cards. It explains direct LAN viewing and the possible cloud/Handy warning, or a separately configured MJPEG bridge. A test must receive a picture before Save becomes available. Native interaction verified the direct/bridge choices, invalid-source rejection, successful physical H2D test picture, Save, live viewing, and independent widget snapshot opt-in. Test probes preserve existing enable settings and share an already-running preview connection when appropriate.

A separately run, loopback-only relay received real H2D frames from the official Bambu Studio Go Live helper and encoder. Studio remained responsible for authentication and issuing its source. The printer's local-camera setting was unchanged; the user confirmed Handy camera viewing still worked. Local camera-tool startup repairs used an existing vendor library and native encoder, preserving the original encoder. An optional supervisor now supports keeping that same official helper pipeline alive outside the app. The relay and supervisor were run as user services on the desktop containing the signed-in Studio session. This is a same-Mac source, not an iPhone or remote-host camera deployment.

Actual Large and XL desktop widgets were added from the system gallery. Large displayed the physical H2D picture; XL displayed both physical printer pictures with their capture ages and status controls. The first real desktop check exposed a solid pale image under the system's tinted appearance. The image now requests full-color rendering on supported OS versions; after reinstalling and drawing a fresh timeline, both actual widget photos were visually verified. Sanitized timeline evidence confirmed the sandboxed widget could read two permitted images. Turning snapshot permissions off removed both images from subsequent actual widget data and displayed **Camera snapshots off** in the XL widget. No pause or stop controls were activated. The actual menu-bar popup interaction remains unverified; the same camera controls and setup action are rendered and built for that surface.

Focused validation passed: 30 native camera/setup/store tests before the appearance fix, all nine snapshot/setup tests after it, both platform builds, strict installed signatures, App Sandbox/Keychain entitlement checks, and two relay/supervisor tests. `scripts/test-camera-bridge.py` retains generated-image HTTP, concurrent-viewer, shutdown, and child-process cleanup checks. Private camera footage and Studio's issued source URL were not saved in reports. Ignored local evidence is under `build/CameraVerification.noindex`.

To repeat the desktop portion, add one Large and one XL widget after enabling snapshots for two printers, inspect their actual photographs and capture ages, then disable snapshots and verify the system widget removes the images. Each widget's **Edit Widget → Printer** setting can select one saved printer; Automatic prioritizes active printers. Remove only widgets created for the check. The desktop host may require its full application path rather than its bundle identifier for native inspection.

### On-demand camera processing and 15-second capture (2026-10-21)

The optional managed Studio relay now starts its official source helper and JPEG decoder only for a live viewer or bounded capture. It pipes the helper directly into the decoder instead of running a separate continuous encoder/RTP export. The HTTP listener remains available while idle; health requests never start video. The two video processes stop after the last client disconnects and the short idle grace expires. An earlier separate continuous-export job must remain disabled when using this mode.

The app attempts widget captures every 15 seconds with a separate camera timer, independent of status requests. It prevents overlapping captures for each printer and reuses an existing visible preview. An unavailable bridge is retried by a later capture. A preview now checks both its window visibility and the actual camera image's position within SwiftUI's scroll view. The first installed check exposed an offscreen camera retaining its connection; the corrected geometry check was rebuilt, installed, and verified by scrolling the real H2D image away and observing zero bridge clients and zero video processes.

Focused tests passed: 13 camera-preview and snapshot tests, including an actual 15-second timer while a status request stayed pending; four preview/setup layout checks after the visibility correction; and four relay integration checks covering sharing, bounded capture, idle teardown, cold restart, and child cleanup. Both platform builds and installed sandbox/signature checks passed. The signed Mac development build is 0.5.1 (17). No printer-control buttons were activated.

On the active desktop, the real H2D source was tested through **Set up camera**, saved, and viewed in the installed app. A separate cold request returned a genuine JPEG in about 4.2 seconds. With live video off and snapshot capture enabled, complete observed request intervals were approximately 15.7 and 15.9 seconds; the initial partial interval is excluded. Captures did not overlap, and zero-video-process idle periods were observed between them. This proves app capture demand, not a guaranteed 15-second WidgetKit redraw. The operating system retains control of widget scheduling. Camera footage and private source URLs are not retained in evidence.

The native menu-popup check subsequently passed after a physical click opened the remaining-time status item. The actual H2D video was visible, with one viewer and one shared source/decoder pipeline. Dismissing the popup returned the relay to zero viewers and zero video processes after its idle grace period. Widget snapshots were then restored and the main window closed. Automated popup opening itself remains unreliable; that limitation did not prevent verification of the real open/close flow.

### Camera layout follow-up (2026-10-21)

Build 0.5.1 (18) places widget-snapshot guidance, capture age, and snapshot messages below the camera preview. The Mac dropdown is 520 points wide and its scrolling viewport can grow to 700 points, bounded by the available screen height. Both platform builds and two focused layout checks passed. The signed sandboxed app was relaunched in the requested login session; the real app-window video and text order were visually inspected there. After the user opened the status popup, its actual larger video and text placement were also visually verified in that login. The H2D relay stayed streaming throughout a 21-second observation, receiving 65 additional frames; a second native capture confirmed visible movement and fresh snapshot ages. The reported initial connecting state was not reproduced during that observation, so its cause remains unconfirmed. No widget layout or printer controls changed.

### Camera startup follow-up (2026-10-21)

The managed relay decoder now retains its initial H.264 keyframe and reduces stream analysis time. A generated source with ten-second keyframe spacing reproduced a 10.9-second startup before the change; the same check now passes a five-second bound for both initial live video and a cold snapshot. All four relay integration tests passed. Initial physical comparisons included intermittent unsuccessful starts in both configurations, so they do not establish a complete fix for every connection stall. Three further direct-helper starts succeeded in 1.5–1.9 seconds, and three cold requests to the installed relay returned valid pictures in 3.2, 4.4, and 2.7 seconds, returning to zero video processes between requests. The actual dropdown then displayed fresh H2D video in the requested login. Both camera switches were restored on. The relay was updated without changing the signed sandboxed app or its 15-second capture schedule; no footage or source credentials were retained.

Reusable native verification supports `open-camera-setup`, `setup-bridge`, `setup-url`, `setup-test`, `setup-save`, `scroll-top`, `scroll-bottom`, and `close-window` in `scripts/camera-ui.applescript`, alongside camera-only toggle actions. The setup address is entered as ordinary text and committed before testing. No action selects a printer hardware-control button. Run it in the app's actual GUI login session; shell identity alone can differ from the active desktop. Use real screenshot inspection together with bridge `/health` state, and restore temporary camera permissions afterward.

### Transparent widget photo layout (2026-10-22)

Build 0.5.1 (19) fills the Large and XL camera frames with a centered, clipped photo while preserving its proportions and full-color rendering. The previous fit layout exposed side bars that appeared pale in the system's transparent/accented style. The existing Large/XL photo layout test passed, and its light/dark generated-image renders were visually inspected. Both platform builds passed. After signed installation and widget-host refresh in the requested login session, the actual transparent Large desktop widget displayed a fresh physical camera image filling the rounded frame without side bars. The XL layout was checked through its generated render, not by adding another desktop widget. Installed app/widget sandbox and signature checks passed. No printer controls were activated or private footage retained.
