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

### Connecting snapshot and explicit widget refresh (2026-10-22)

Build 0.5.1 (20) uses an existing permitted snapshot as a dated connecting backdrop, separately from live frames. The first live frame removes that backdrop. Disabled snapshot permissions, wrong printer IDs, replaced connection generations, and unavailable Keychain reads cannot supply a backdrop. Fresh capture requests never accept the saved picture as a new frame.

Widget refresh links identify the displayed printers and camera pictures. The app refreshes status and forces a new dated camera capture when necessary, including inside the normal 15-second background interval. Existing captures are awaited, and only frames captured after the request can satisfy it. Successful feedback requires the updated data to be saved; save failures cannot produce a checkmark. The existing icon shows an hourglass, then a checkmark or an incomplete-refresh symbol. A later timeline entry clears terminal feedback after 30 seconds without adding widget content or promising exact system redraw timing.

Twenty focused preview, snapshot, refresh, and layout tests passed, including consecutive manual captures and a simulated Keychain save failure. Both platform builds and installed signature/sandbox checks passed. The installed app's isolated native fixture captured a synthetic picture with live viewing off, displayed it with its real age during a five-second connection delay, and visibly replaced it with live video. Fixture photos stayed in memory, and the test process was closed afterward. To repeat that native check, launch the existing camera fixture mode with `--camera-connect-delay-seconds 5`, enable snapshots, wait for capture, then enable live viewing.

In the requested login session, opening the installed app's refresh deep link produced a fresh physical H2D picture in the actual transparent desktop widget; captures showed its icon changing from hourglass to checkmark. A physical pointer click on the widget is not claimed: the native control was not exposed reliably to automation. The physical camera source returned intermittent unavailable responses earlier in the check and subsequently resumed live video and fresh captures. No printer hardware controls were activated, private source values changed, or camera footage saved to reports.


### Camera-widget control regression

Use the separately identified widget QA build with its synthetic blue camera image and fictional **Widget Test** printer. Add an Extra Large widget so the wide image exercises the crop above the controls. Verify Pause changes the widget to Resume, Resume changes it back to Pause, and Stop opens the job-specific confirmation. Choose **Keep printing** and verify that no Stop command was recorded. Never use a live printer for this check.

The QA report includes command receipts and the latest action feedback. For sandboxed builds, pass `--widget-qa-report` an absolute path inside the test app's writable container with a `.noindex` directory and a `.json` filename. The fixture creates missing parent directories. Export without `--widget-qa-reset` after the clicks, preserving the receipts. Verify the report timestamp and expect exactly one Pause and one Resume receipt, with no Stop receipt after cancelling the review. Confirm the registered and running widget extension belongs to the intended build and test login before comparing results.

The camera image is decorative and does not participate in hit testing, so its aspect-fill content cannot intercept controls outside the visible crop. Stop-review failures remain visible rather than dismissing the confirmation as if the command succeeded. The focused store regression covers rejection, uncertain delivery, and pairing-required errors without retrying a command.

Build 0.5.1 (21) verification: actual Extra Large widget clicks changed the fictional job from Printing to Paused and back to Printing. Fresh QA reports recorded exactly one Pause and one Resume command. The user's widget Stop screenshot showed the job-specific confirmation; a native check of the same review link verified **Keep printing** dismisses it while retaining Printing. No real-printer command was sent by these checks. Both platform builds passed; the signed sandboxed Mac update was installed and launched in the test login with saved printer settings preserved. Physical printer actuation and iPhone widget interaction were not tested.

For a background installation in a separate login, pass `--background` as the third argument to `scripts/install-macos.sh`. It retains signature checks and bundle replacement, refreshes the app's widget extension, and relaunches the app hidden without restarting Dock or Notification Center. Verify the installed version and fresh connection report separately; a successful installation does not establish Local Network permission.

A background launch directly from an SSH session reproduced Local Network denial despite enabled permissions. Relaunching the same signed build hidden through a one-time job in the user's existing GUI bootstrap session restored fresh online readings for both configured printer kinds without changing permissions. `scripts/launch-macos-background.py` now implements that launch for `--background` installations and removes the temporary job. Fresh app and widget reports confirmed online data afterward; the visible widget redraw remains system scheduled.


### Camera gallery previews

Build 0.5.1 (22) supplies self-contained illustrative camera placeholders to gallery snapshots and placeholder entries for Large and Extra Large. Large previews one camera and XL previews two; Small and Medium remain status-only. The preview path never reads saved camera images or changes snapshot permissions. A focused test verifies preview eligibility and renders both sizes for visual inspection. Both platform builds and signed installations passed. The rendered production preview views were inspected; the native widget gallery itself was not accessible to the control tool during this check.

### Activity ordering, five-second captures, and translucent progress (build 23)

Passed 16 camera snapshot checks, including the five-second lower bound and captures continuing while status requests wait; two activity/navigation checks; and a monochrome progress layout render. Both platform builds passed. The installed Mac app visibly moved the active printer above the idle printer. The actual desktop widget in translucent appearance showed a solid 33% fraction with an outlined remainder. Both Mac installations report build 23; background diagnostics confirm sandboxed connectivity. No hardware control was exercised.

The companion-app launch scheme is community-reported, not a verified Devices-tab deep link. Mobile routing/settings compile and pure routing checks pass; actual Bambu Handy tab selection remains unverified. Timelapse was not adopted: the H2D manual describes per-layer capture, and no supported live frame retrieval route was established.

The signed iPhone build 23 installed successfully. A launch check was blocked by the device lock; actual companion-app handoff and settings interaction on the phone remain unverified.

### Adaptive snapshot cadence (build 24)

Snapshot demand is separate from visible preview demand. Captures target five seconds with a visible viewer and fifteen seconds otherwise, preserving no-overlap and explicit-refresh behavior. Sixteen snapshot tests passed, including visible/hidden transitions, release of snapshot-only connections, and a fifteen-second real timer during a delayed status request. Signed Mac and iOS builds passed; both Mac accounts received build 24. Native screen inspection was unavailable in this run. Three live bridge requests returned distinct JPEG bytes with increasing source frame counts; this verifies source delivery, not visible widget image replacement or scene movement.

### Hidden-launch monitoring repair (build 25)

A hidden Mac relaunch could leave monitoring dormant because only window/menu content started the store. Mac app store creation now starts read-only monitoring independently of view presentation; iOS retains its scene lifecycle. Both signed builds passed and build 25 was installed in both Mac accounts and the connected iPhone. A background-only Mac launch produced fresh status reports, then an actual new camera frame, saved snapshot, and widget timeline all carrying the same new capture timestamp. This proves delivery to the system widget provider; visual comparison with the companion app remains unverified because the primary desktop is not controlled.

### Five-second capture in both modes (build 26)

Restored a five-second attempt interval regardless of visible preview demand, retaining hidden-launch monitoring. All sixteen snapshot tests passed, including captures before, during, and after visible video, no early captures, and connection release when no viewer remains. The 640-pixel JPEG limit and camera URL source are unchanged. System widget redraw timing and camera-source delays remain outside the capture timer guarantee.

### Continuous capture connection and camera monitor (build 27)

Snapshot-only capture now keeps the connection available for six seconds after each request, so five-second requests reuse it instead of cold-starting video. Disabling snapshots stops the warmed connection immediately if no preview needs it. Routine captures require a frame received within the preceding two seconds; explicit refresh retains its after-request requirement. This deliberately trades additional decoding during enabled snapshots for freshness.

Nineteen focused snapshot/preview tests passed, including real JPEG and RTSPS opt-out teardown, five-second reuse, and idle expiration. Both signed platforms built successfully. The compact macOS Camera monitor was opened using its real app control and displayed the actual camera feed in the QA account; its layout was inspected after correction. It is a normal window, not a WidgetKit widget, and shares the visible-camera connection. Build 27 was installed for both Mac accounts and the phone. Background diagnostics show the physical camera continuing to deliver frames with zero visible viewers and new snapshots reaching the widget provider. Native widget redraw cadence and visual matching against the phone companion app remain outside this verification.

### Photo-age display (build 28)

Replaced relative-date wording with the system elapsed timer for camera ages in widgets, app snapshots, and connecting overlays. Fixed-width digits and identity transitions avoid width changes or number animations. The original capture timestamp remains the timer origin and accessibility timestamp; a new picture correctly resets its age. Both signed platform builds passed. The actual translucent desktop widget was inspected and showed `Photo age 0:03`. This verifies the installed appearance, not uninterrupted per-second rendering under every system scheduling condition.

### Checking actual photo replacement

The isolated QA app accepts `--widget-qa-photo-step 1` (orange with a left marker),
`--widget-qa-photo-step 2` (blue with a right marker), and `--widget-qa-photo-step 0`
(the original plain blue fixture). Launch the app through LaunchServices with the
chosen argument; quit only the QA app before relaunching it with the next step.
Keep the existing QA widget running between steps. Each step saves a new JPEG
through the shared Keychain and requests the normal timeline reload. No printer
connection or hardware command is involved. Restore step 0 and quit the QA app
afterward.

On 2026-10-23 the actual Extra Large desktop QA widget visibly changed from the
orange/left image to the blue/right image without restarting the widget host.
This exercises the same camera image view as the production Large and Extra
Large widgets. The production camera source also returned different decoded
pixels in three samples five seconds apart; the scene was paused and its current
appearance was confirmed against the companion app. No frozen bitmap was
reproduced in this check. This does not establish an exact five-second system
redraw cadence or resolve every earlier stale-image report. No production image
rendering change was made.

### Control rejection feedback (build 30)

Bambu command failures now preserve a bounded rejection reason. An authorization
verification rejection explains the supported control options and the distinction
between the video bridge and print control. Widget failures use a short **Pause
failed · Details** link in Small, Medium, Large, and Extra Large layouts; the link
opens the full error in the app. A definite rejection no longer disables both
widget controls for thirty seconds. Uncertain outcomes still block duplicate
commands, and a rendered action remains single-use.

Validation: all 115 core tests and 18 focused app/widget control tests passed,
including a real local TLS/MQTT fixture rejection, error-link parsing, older
feedback decoding, and preservation of the uncertain-outcome guard. Both signed
platform builds passed. The user-authorized live Pause test returned an explicit
authorization verification rejection, and the actual desktop widget displayed
the failure link and opened its full explanation. The physical print continued.
No live Stop command was sent. A separate fictional widget opened the correct
Stop confirmation; **Keep printing** dismissed it, and the final fixture report
contained no command receipts and retained Printing. The final Small-widget
layout shares the verified error-link view; its platform builds passed, but a
separate Small error-link click was not exercised. Phone installation was checked;
phone widget interaction was not exercised.

The QA app supports `--widget-qa-reject-controls` and
`--widget-qa-allow-controls` to enable and clear a fictional authorization
rejection in its isolated backend. Always clear rejection mode after testing.
Neither flag exists in production builds, and no real printer is contacted.

### Expanded control-error details (build 31)

The authorization error now explains both control options: Handy/Studio to keep
cloud access, or LAN Only plus Developer Mode for direct third-party controls,
with the loss of cloud/Handy access stated explicitly. It also explains that the
camera bridge only supplies video and that a supported authorized control
integration is not included. The exact printer rejection remains in Details;
the widget keeps its short failure link.

Both signed platform builds and all 10 focused control-integration tests passed.
In the isolated native QA widget, the Details link opened the full expanded
alert; its screenshot showed every paragraph and the dismissal button without
clipping. The initial synthetic Pause click did not produce feedback, so this
copy/layout check used `--widget-qa-control-error-preview` to populate fictional
feedback without sending a command. This flag exists only in the isolated QA
build. Test mode and feedback were cleared afterward, with zero command
receipts and Printing retained. Production builds were installed on Mac and
phone; phone dialog interaction was not exercised.

### Large camera-widget layout (build 32)

Large camera widgets place Nozzle and Bed above Chamber in the left column,
with temperature values increased from 12 to 14 points. Pause/Resume and Stop
stack in the right column. Other widget layouts retain their existing layout.
Both signed platform builds passed. The installed native Large desktop widget
was visually inspected: all temperatures, stacked controls, photo and status
footer fit without clipping. No printer commands were sent for this layout check.

### Configurable snapshot interval (build 33)

Settings offers 5, 10, 15, 30 and 60 second camera snapshot intervals, with a
five-second default. The per-device choice is saved in Keychain and updates
monitoring immediately. Widget redraw scheduling remains system controlled.
Persistence tests cover restoration, invalid values and failed saves. The real
camera fixture verifies five-second capture, changing to thirty seconds, and
changing back without restarting the store. Both platform builds passed. The
installed Mac picker was changed to thirty seconds and restored to five seconds.
Phone installation was checked; phone settings interaction was not exercised.

Build 34 adds three seconds as the minimum interval while preserving the
five-second default. Four focused tests passed, including persistence of the
three-second choice and a camera-fixture check that capture waits until three
seconds, then uses the new interval without restarting. Both signed platform
builds passed and the installed Mac settings menu showed the new option.

### Full-width camera setup placeholder (build 36)

A single-printer Large widget uses the full-width camera layout even when
widget snapshots are off. The empty camera area is a Set up camera link; Large
and XL use the same link when a picture is unavailable. The link opens camera
setup for the displayed printer rather than the normal companion-app tap route.
The placeholder uses semantic colors to remain readable in vibrant appearance.

All six focused navigation/layout tests passed, including URL validation and
Large/XL renders with no camera. Both signed platform builds passed. Native
Mom QA verified the actual XL widget's setup tap opened Camera for Widget Test,
and the final transparent appearance was visually checked. Large empty-camera
geometry was checked in rendered fixtures; the production Large widget was
observed with a real picture. Temporary Mom snapshot settings and QA camera
mode were restored, and the fictional report retained Printing with no command
receipts. Build 36 was installed in both Mac accounts and on the phone. Phone
widget interaction was not exercised.

The isolated QA app accepts --widget-qa-camera-off / --widget-qa-camera-on to
exercise the no-camera transition without modifying production printer profiles.

### Default Moonraker camera origin (build 37)

Relative camera stream URLs now use the same printer's advertised snapshot
origin when both endpoints share their path and scheme. This supports frontends
on a separate port without guessing a camera address. Absolute stream URLs keep
their own origin, and a different-port camera never receives the printer API key.

All 116 core tests and six focused native navigation/setup/layout tests passed.
Both signed platform builds passed. The installed Mac's Direct local camera
option discovered the physical Moonraker camera, returned Picture received, saved
successfully, and produced a live preview plus fresh widget captures. Reopening
setup retained Direct local camera. No printer commands were part of this check.
Build 37 was installed for both Mac accounts and on the phone; phone UI testing
was not performed.
