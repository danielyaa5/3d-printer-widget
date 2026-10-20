# Test report

Local Mac update: **0.4.1 (12)**. Checked October 20, 2026.

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
