# Print Progress

A small native app and widget for checking 3D printer progress on Mac, iPhone, and iPad.

![Print Progress app, widget and menu bar with fictional demo readings](docs/media/overview.png)

See percent complete, time remaining, the current job, layers, and nozzle, bed, and chamber temperatures. Chamber heat targets appear when the printer reports them. Add multiple printers and choose which one a widget shows. The Mac app also includes an optional menu bar view.

[iPhone screen recording](docs/media/iphone-demo.mp4) · [iPhone GIF](docs/media/iphone-demo.gif) · [Illustrated overview](docs/media/demo.mp4) · [Privacy](docs/privacy.md) · [Support](docs/support.md) · [Test report](docs/testing.md)

The iPhone recording shows the actual Release app running in Simulator, switching between its built-in Printing, Paused, and Finished demo states. The 20-second illustrated overview uses production UI components. Both use fictional readings; their state changes do not represent widget refresh frequency.

[Installed Mac demo](docs/media/screenshots/mac-demo.jpg) · [Actual iPhone demo](docs/media/screenshots/iphone-demo.png) · [iPad simulator demo](release/app-store/screenshots/ipad-13-demo.png)

## Supported connections

| Printer | Connection | What you need |
| --- | --- | --- |
| Klipper printers, including a K1 Max with Moonraker installed | Moonraker HTTP/HTTPS | The Moonraker, Fluidd, or Mainsail URL, plus an API key if required |
| Bambu Lab printers, including the H2D | Local MQTT over TLS | Printer address, serial number, and LAN access code |
| Printers already connected to OctoPrint, including many Marlin / Ender setups | OctoPrint HTTP/HTTPS | Server URL and an API key with status permission |
| Prusa printers exposing PrusaLink | PrusaLink HTTP/HTTPS, modern or legacy API | Local server URL, plus its API key or local Digest username/password |
| Duet controllers running RepRapFirmware or Duet Software Framework | Duet Web Control HTTP/HTTPS | Server URL and machine password if set |
| K1 / K1 Max / K1C firmware exposing Creality’s native status service | Native WebSocket on port 9999 | `ws://printer.local:9999`; no Moonraker installation required |
| Networked SDCP v3 printers, including compatible Elegoo Saturn / Mars models | SDCP WebSocket and unicast UDP discovery | `ws://printer.local:3030/websocket`; UDP port 3000 must also be reachable |

Compatibility depends on the printer’s exposed interface and firmware, not just its brand. Many Voron and Elegoo Neptune setups work through Moonraker; many Ender and other Marlin printers work through an existing OctoPrint host. USB-only printers need a supported network host. Proprietary Anycubic cloud services, Flashforge control protocols, Creality cloud services and non-SDCP resin interfaces are not implemented. The app does not install or change printer firmware, macros or network services.

Hardware checked: Bambu H2D and K1 Max, including both Moonraker and the native Creality interface. OctoPrint, PrusaLink, Duet and SDCP connectors have automated parser/request tests and local network fixture tests, including real HTTP Digest, WebSocket and UDP exchanges. They still need validation on physical printers; no claim is made that every model or firmware has been tested.

## Setup

1. Connect your device and printers to the same network, or a VPN that provides access to the printers.
2. Open Print Progress, select **Add printer**, and choose the local interface your printer exposes. Each choice shows its address format and credential requirements.
3. Enter the connection settings. The app verifies a live status response before saving.
4. Allow local network access when the operating system asks.

New users get a walkthrough covering connection details, Local Network access, widget setup, and Mac menu bar options. Open the question-mark button to replay it anytime.

Want to look around first? Dismiss the walkthrough and choose **Explore the demo** on the empty screen, or open **Preferences → Help → Explore the demo**. Switch the sample Workshop printer between Printing, Paused, and Finished. Demo mode makes no printer requests and does not change saved printers, credentials, or widgets.

For Klipper, an example URL is `http://printer.local:7125`. Fluidd and Mainsail reverse-proxy URLs also work. For Bambu, enter a hostname such as `printer.local`, without a URL scheme or port. Find the LAN access code and serial number in the printer’s settings.

For OctoPrint, use the server URL and a key allowed to read status. For PrusaLink, use local printer credentials, separate from a Prusa Connect cloud login: API-key mode prefers the legacy API; username/password mode uses HTTP Digest and prefers the modern API. Duet supports modern object-model queries, legacy `rr_status` and SBC-mode REST. It releases only uniquely identified sessions, preserving older shared-IP Duet Web Control sessions. Native K1 monitoring listens to status messages without sending control commands. SDCP sends a discovery request to the entered printer only and requests status with command 0; it never scans the LAN or requests camera feeds.

Sensor availability depends on the interface. Missing temperatures remain unavailable. SDCP v3 print time fields are interpreted as milliseconds per its specification; printers using incompatible variants require a dedicated adapter.

On multi-nozzle Bambu printers, the nozzle reading follows the active extruder reported by the printer. It does not substitute the cooler inactive nozzle or a legacy single-nozzle field. The packed temperature and active-extruder fields follow [Bambu Studio's extruder model](https://github.com/bambulab/BambuStudio/blob/master/src/slic3r/GUI/DeviceCore/DevExtruderSystem.cpp).

### Widgets

- **Mac:** Control-click the desktop, select **Edit Widgets**, and search for **Print Progress**.
- **iPhone/iPad:** Touch and hold the Home Screen, select **Edit → Add Widget**, and search for **Print Progress**.
- **iPhone Lock Screen:** Open Lock Screen customization and select a Print Progress accessory widget.
- Edit a widget to choose a printer. With automatic selection, an active printer appears first; wider widgets show multiple printers.
- Tap the refresh arrow to open the app and get a fresh reading, or tap the widget to open the app.

Home Screen and desktop widgets show nozzle, bed, and chamber temperatures together, including a chamber heat target when reported. A missing sensor shows a dash. Small widgets keep this temperature row alongside progress, remaining time, the job name, and the last reading time.

The app refreshes approximately every 15 seconds while running. Widgets prefer recent, verified readings shared by the app. If the widget host cannot reach the local network, it keeps the real reading and its timestamp; an older reading says **Refresh needed**, rather than incorrectly declaring the printer offline. The refresh arrow opens the app because widget hosts may not have the same network access as the app.

Apple controls native widget background refreshes, so widgets do not promise continuous live progress. Every widget shows when it last updated. The timeline requests a refresh after 10 minutes during an active job and after 30 minutes when idle; the operating system can delay these requests. The iPhone app stops polling in the background. There is no push server or always-on bridge.

### Mac menu bar

In **Preferences → Menu bar**, enable or disable the item and choose a progress circle, circle with percent, percent only, or time remaining. Choose a specific printer or use automatic selection to prioritize an active job. Click the item for a dropdown with full printer details, including chamber temperature.

The progress circle includes a nozzle silhouette. Every menu bar appearance, including percent and time remaining, uses the app icon’s mint and teal palette, adapting its contrast to light and dark appearances.

The dropdown shows the selected or active printer first, with complete printer cards and a scrollable list for larger fleets. It sizes to its content so the readings remain visible. Close all app windows with their red buttons or **⌘W**, or choose **Print Progress → Keep Monitoring in Menu Bar** to close them together. The Dock icon disappears while monitoring and the menu bar icon stay active. Opening the app or Settings restores the Dock icon; opening only the menu bar dropdown keeps it hidden. Choose **Quit Print Progress** to stop polling and remove the menu bar icon. A paused job shows **Paused** instead of a moving time estimate; a finished job shows **Done**.

Remaining time comes from Bambu telemetry. Klipper remaining time is estimated from elapsed printing time and reported progress, so early estimates can change substantially. Paused and offline jobs do not show a running finish time. Offline readings preserve the last known progress and its original timestamp.

Bambu reports both cancelled and failed jobs as `FAILED`. A cancellation code shows **Cancelled**; an explicit zero print-error code shows **Stopped**, since the printer has not supplied a reason. Other failures remain **Needs attention**, with the reported error code shown in the app when available. These states describe the last job, rather than diagnosing the printer’s hardware.

Moonraker chamber sensors and heaters are detected automatically. A chamber fan’s target is a cooling threshold, so it is never displayed as a heater target. Temperature readings are informational; the app does not control heating.

## Privacy and connection trust

No account, analytics, cloud service, or subscription is required. Connection settings, access codes, API keys, certificate pins, and cached snapshots stay in the device’s shared Keychain. They are available to this app and its widget after the first device unlock; they do not sync through iCloud.

Walkthrough completion and menu bar preferences are saved locally in the app’s preferences. The privacy manifest declares this use of UserDefaults.

Bambu uses device-local TLS certificates. The first successful pairing on a trusted network records the certificate fingerprint; later connections require an exact match. If a verified firmware update changes a certificate, edit the connection and enable **Trust a replacement certificate**. Never enable that option merely to dismiss an unexplained certificate change.

Moonraker uses the protocol you enter. HTTP is unencrypted; use a trusted local network, HTTPS, or a secure VPN, and do not expose Moonraker directly to the internet.

The only Bambu publication is a `pushall` telemetry request. HTTP connectors issue status and authentication GETs; credentials and session keys are never forwarded to another origin. Native Creality monitoring is passive. SDCP sends only discovery and status requests. There are no print-start, pause, stop, motion, fan, heater, firmware, or camera commands.

Protocol references: [OctoPrint](https://docs.octoprint.org/en/main/api/), [PrusaLink API specifications](https://github.com/prusa3d/Prusa-Link-Web/tree/master/spec), [RepRapFirmware HTTP API](https://github.com/Duet3D/RepRapFirmware/wiki/HTTP-requests), [Duet Software Framework REST API](https://duet3d.github.io/DuetSoftwareFramework/articles/rest-api.html), and [CBD’s SDCP v3 specification](https://github.com/cbd-tech/SDCP-Smart-Device-Control-Protocol-V3.0.0). The native K1 adapter was checked against its manufacturer-supplied local web interface and a real device.

## Build

Requires macOS 14 or iOS/iPadOS 17 or later, a recent Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). There are no third-party runtime dependencies.

```sh
xcodegen generate
open PrintProgress.xcodeproj
```

Choose the `PrintProgressMac` or `PrintProgressIOS` scheme. Set your own development team and pass a unique `PRINT_BUNDLE_PREFIX` build setting for both app and widget targets. The public default is `org.example`; no account or signing identity is embedded in the project. The app and widget must share the same `PRINT_KEYCHAIN_GROUP` and signing team.

For command-line builds:

```sh
xcodebuild -project PrintProgress.xcodeproj -scheme PrintProgressMac \
  -destination 'platform=macOS' -derivedDataPath build/Mac.noindex \
  DEVELOPMENT_TEAM=YOUR_TEAM PRINT_BUNDLE_PREFIX=your.unique.prefix build

xcodebuild -project PrintProgress.xcodeproj -scheme PrintProgressIOS \
  -destination 'generic/platform=iOS' -derivedDataPath build/iOS.noindex \
  DEVELOPMENT_TEAM=YOUR_TEAM PRINT_BUNDLE_PREFIX=your.unique.prefix build
```

Regenerate icons with `swift scripts/generate-icons.swift`.

After a signed Mac build, run `bash scripts/install-macos.sh`. It installs the app in Applications, refreshes its Dock icon and widget, removes generated app copies under the project’s `.noindex` build directory, and reopens the installed app. You can pass a different built `.app` path as the first argument and a custom installation path as the second. The installer refuses to overwrite an app with a different bundle identifier.

### Tests and live connection check

```sh
swift test --scratch-path build/Core.noindex --enable-code-coverage

xcodegen generate
xcodebuild -project PrintProgress.xcodeproj -scheme PrintProgressFeatureTests \
  -destination 'platform=macOS' -derivedDataPath build/FeatureTests.noindex \
  CODE_SIGNING_ALLOWED=NO test

swift run --scratch-path build/Core.noindex printer-probe /path/to/private-printer-settings.json
```

The core suite includes unit tests and real-socket integration tests for all seven connection families. The local fixture requires Python 3 and OpenSSL, uses only synthetic data, binds to loopback, and stops at test teardown. It exercises HTTP, Digest authentication, UDP discovery, WebSocket and TLS/MQTT, including malformed messages, certificate pinning, redirects, cancellation and deadlines. SDCP and MQTT tests report a skip if their fixed local ports are occupied; inspect skipped tests before treating a run as complete. Fixture traffic is checked for unexpected printer commands.

The native feature suite tests profile persistence, cache failures, concurrent refreshes, cancellation, late responses after editing/removing a profile, and offline recovery. It renders production SwiftUI cards, setup forms, menu bar appearances and widget layouts into `build/UIRegression.noindex`. These render checks supplement installed-app interaction tests; they do not drive the operating system's widget gallery or menu bar.

To inspect core coverage after the Swift test run:

```sh
xcrun llvm-cov report \
  build/Core.noindex/out/Products/Debug/PrintProgressCoreTests.xctest/Contents/MacOS/PrintProgressCoreTests \
  -instr-profile=build/Core.noindex/out/Products/Debug/codecov/default.profdata \
  -ignore-filename-regex='Tests/|build/'
```

The optional probe uses the same connection and parsing code as the app. Keep its settings file outside the repository and restrict its permissions; it contains credentials. Run automated tests without real printer data. Before release, also test the installed Mac and iPhone flows and physical printers: adding/editing/removing profiles, walkthrough, refresh and recovery, background behavior, menu bar, widget selection and widget-to-app links. Local fixtures cannot establish compatibility with every firmware version.

## Distribution

MIT licensed. The source is suitable for a public repository; generated builds, local signing overrides, private setup files, and generated Xcode projects are ignored. No printer details are compiled into the app.

Version 0.4.0 (11) was submitted to Apple for both iOS/iPadOS and native macOS on October 20, 2026. Both submissions were verified as **Waiting for Review**. Until Apple approves and releases them, build from source using your own signing identity. Submission is not approval or store availability.

See [release preparation](docs/releasing.md) for archive, validation, and submission steps. See [CONTRIBUTING](CONTRIBUTING.md) before reporting a firmware issue or adding a connector.
