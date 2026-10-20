# Project instructions

- Build the shared native app and WidgetKit extensions from `project.yml` using XcodeGen.
- Keep connection and telemetry logic in `Sources/PrintProgressCore`; UI code belongs in `App`, `Widgets`, or `Shared`.
- Run `swift test --scratch-path build/Core.noindex` for connection or telemetry changes. Build both platform schemes for shared UI changes.
- Background status monitoring is read-only. Pause, resume, and cancel commands must be explicit user actions on a freshly verified job; cancelling requires confirmation. Do not start jobs or add arbitrary motion, heater, or G-code controls.
- Keep all real printer addresses, serial numbers, access codes, API keys, certificate pins, device identifiers, signing accounts, and private fixtures out of source, documentation, test results, and commits.
- Store credentials and shared widget settings in Keychain. Do not fall back to plaintext when Keychain is unavailable.
- Public examples use fictional hostnames and credentials. Tests must not contain private printer captures.
- Preserve real timestamps on cached readings and keep offline/paused status distinct from live progress.
- Native widget updates are system scheduled. Do not claim continuous refresh or invent progress between actual printer reports.
- Keep generated app bundles in ignored `.noindex` build directories. Install the current Mac build in Applications and remove stale build copies after verification.
- Install signed Mac builds with `bash scripts/install-macos.sh`. It refreshes the bundle modification date and Dock icon cache, reloads the widget, removes generated bundle copies, and reopens the installed app.
