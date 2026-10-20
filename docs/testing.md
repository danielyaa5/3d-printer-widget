# Test report

Release candidate: **0.4.0 (11)**. Checked October 20, 2026.

## Automated results

**107 tests passed, zero failures, zero skips.**

| Suite | Tests | Coverage |
| --- | ---: | --- |
| Core unit and request tests | 72 | Seven protocol parsers, validation, state mapping, temperatures, progress, time estimates, numeric limits and MQTT framing |
| Real-socket integration tests | 14 | HTTP, HTTP Digest, WebSocket, UDP and TLS/MQTT; pinning, credentials, redirects, cancellation, deadlines, malformed responses and read-only requests |
| Application feature tests | 16 | Persistence failures, refresh races, cancellation, offline recovery, demo isolation and certificate-pin save failure |
| Native SwiftUI layout tests | 5 | Printer forms, states, large text, menu bar modes and popup sizing, widget sizes and missing sensors |

Core executable-line coverage is **95.61% (1,306 / 1,366)**, function coverage 94.17%, and region coverage 83.09%. This measures `PrintProgressCore`, not the entire app. Native tests render 29 production-UI images for inspection; they are layout assertions, not pixel-baseline screenshot comparisons.

Both Mac and iOS Release archives build with their WidgetKit extensions. Reproduction commands are in the [README](../README.md#tests-and-live-connection-check).

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

## Limits

OctoPrint, PrusaLink, Duet and SDCP still need physical-hardware validation across firmware versions. Fixture success alone does not establish universal model compatibility.

The actual Mac menu bar popup click could not be driven reliably by the screen-control service. Its production view, content height, empty state and display modes passed native tests, but those tests do not replace that system interaction.

Some long iPhone setup screens could not be scrolled reliably through mirroring. Alternate widget sizes and Lock Screen accessory widgets were rendered but not interactively tested on the phone. No iPad, VoiceOver traversal, OS-upgrade migration, first-unlock/reboot behavior or long-duration network soak test was completed.

Connection cancellation is covered by unit and real-network tests; a live UI cancellation was not captured before the request completed. Widget background scheduling remains controlled by the operating system.
