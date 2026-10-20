# Changelog

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
