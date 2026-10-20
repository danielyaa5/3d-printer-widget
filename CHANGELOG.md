# Changelog

## 0.5.0

- Add Pause, Resume, and confirmed Stop controls to printer cards and the Mac menu bar dropdown.
- Support Bambu LAN, Moonraker, OctoPrint, PrusaLink, native K1 and SDCP v3 controls; Duet remains monitoring only.
- Verify fresh job status before commands, block duplicate clicks, correlate acknowledgements, and report uncertain outcomes without retries.
- Keep background monitoring read-only and add isolated demo controls.
- Add real-socket control integration tests, app-state regression tests, native layout renders, and an iPhone simulator UI test.

## 0.4.2

- Add a notarized Universal Mac DMG with a branded drag-to-Applications layout.
- Eject the matching installer disk after the installed direct-download app opens; leave busy disks mounted.
- Preserve App Sandbox in the widget and App Store builds.
- Add a README download button, release checksums, and a responsive GitHub Pages website with demos and an interactive menu bar preview.
- Add installer safety tests and headless website checks.

## 0.4.1

- Hide the Mac Dock icon after the last app window closes, while menu bar monitoring continues.
- Restore the Dock icon when opening the app or Preferences; the menu bar dropdown does not restore it.
- Make Keep Monitoring in Menu Bar close app windows together.
- Allow the Mac installer to update a custom installation location.
- Add native window lifecycle regression tests.

## 0.4.0

- Added a self-contained demo with printing, paused, and finished sample states.
- Added reproducible screenshots, a short video, and an animated GIF using fictional data.
- Added public setup, support, privacy, testing, and release documentation.
- Fixed certificate-pin persistence so an unsuccessful Keychain save cannot appear committed in memory.
- Included the privacy manifest in both widget extensions.
- Added continuous integration for core tests, native feature/layout tests, and an iOS build.
- Fixed Mac installation to replace complete signed bundles, avoiding stale Debug resources after installing a Release build.
- Removed reverse-DNS dependencies from loopback test fixtures so integration tests also run reliably on hosted Mac runners.

## 0.3.1

- Added OctoPrint, PrusaLink, Duet, native Creality K1, and SDCP v3 alongside Bambu and Moonraker.
- Added chamber heat, all three temperatures in compact widgets, and a setup walkthrough.
- Added an optional Mac menu bar dropdown and four mint/teal status appearances.
- Preserved cached timestamps and distinguished paused, offline, stopped, cancelled, and failed jobs.
- Improved H2D active-nozzle selection, connection deadlines, redirect handling, and numeric validation.
- Added synthetic real-socket protocol fixtures and native UI regression rendering.
