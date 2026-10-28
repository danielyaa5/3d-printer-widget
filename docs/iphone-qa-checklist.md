# Physical iPhone QA checklist

Use this alongside the results in [testing.md](testing.md). Record the installed
version and build before testing; a successful Mac build does not establish the
version installed on a phone. Record appearance and device class. Keep real
printer identifiers, addresses, credentials, jobs and camera images out of the
repository and public test attachments.

## Read-only production checks

1. Open the app normally. Check card layout, progress, temperature labels and
   timestamps. Refresh once and distinguish current readings from offline caches.
2. Open Preferences, scroll through the form and dismiss it. Open all setup
   walkthrough pages and finish the walkthrough without adding a printer.
3. Open Add Printer with empty fields and tap Connect. The missing-field error
   should be immediately visible without searching below the fold. Cancel and
   verify no profile was added.
4. Open camera setup. Discover cameras; a listed option must not imply a
   successful connection. Test a permitted source and check that Save remains
   disabled until the selected source produces a picture.
5. In an unsaved custom-camera form, test `rtsp://camera.invalid/live`. Expect
   an unsupported-format error and disabled Save. Cancel; preserve the saved
   source and snapshot preference.
6. Record the original camera switches. On a reachable printer, temporarily
   enable live preview and widget snapshots. Verify a real picture, the Camera
   settings label and a fresh photo age. Return Home, reopen the app, and verify
   that the dated reconnecting image is replaced by live video and a fresh capture.
7. Restore both switches and verify the preview and capture state. If testing an
   actual Home Screen widget, check its selected printer, dated image and real tap
   route separately. App snapshot generation alone is not a widget rendering pass.

## Controls: built-in demo only

Open Preferences → Explore the demo. Confirm the visible “Fictional printers.
No network connection.” banner. Never perform these checks on production cards.

1. Pause Workshop; expect Paused and Resume, with demo-only feedback.
2. Resume; expect Printing and Pause.
3. Stop → Keep printing; expect the job to remain Printing.
4. Stop → Stop print; expect Cancelled and no Pause/Resume controls.
5. Select Finished; expect 100%, completion text and no active-print controls.
6. Dismiss the demo and verify the real profiles remain intact.

The existing automated counterpart is
`PrintControlsUITests.testPauseResumeAndConfirmedStopInTheActualApp`, which
launches the isolated demo with `--ui-testing-demo`. Do not substitute a real
printer endpoint for that fixture.

If mirroring disconnects, record it separately from app failures. Reconnect
through its normal UI and inspect the restored screen before attributing a crash.
Finish with no temporary forms open, original preferences restored, and explicit
limitations for untested widgets, device sizes, appearances or software builds.

## Regression automation

`PrintControlsUITests.testEmptyConnectionShowsVisibleErrorWithoutScrolling`
opens Add Printer with an isolated demo store and submits empty fields twice.
It requires the validation alert and its dismissal button to be visible without
scrolling. The `--ui-testing-add-printer` launch argument is Debug-only and uses
no saved production profiles or printer connections.

For camera recurrences, record printer/status reachability, relay frame count
and capture time, saved app capture time, and the actual widget's date separately.
Do not restart the relay before saving the failure evidence. A dated cached image
with Offline status is different from an old image incorrectly presented as live.

## Actual Home Screen and Lock Screen widgets

1. Record the existing widget's size, selected printer and surrounding icon layout.
   Keep a private reference capture before temporarily resizing it.
2. On a reachable printer, enable snapshots temporarily and use a large widget.
   Inspect the actual photo and its capture age. Tap Refresh, observe the app's
   dated reconnecting picture become live, then return Home and verify the widget
   receives the newer capture. A running camera alone does not pass this check.
3. Select a specific printer. Tap the widget body and verify its configured
   companion-app handoff. Start the companion on a different tab first and verify
   the resulting tab and device identity. Repeat after dismissing the companion
   from the app switcher to test a fresh launch. App launch alone does not prove routing
   to a specific device or that the companion's printer connection succeeds. Never tap production Pause, Resume or Stop.
4. Inspect small-widget control labels for wrapping. Automated synthetic coverage
   is `NativeLayoutTests.testSmallWidgetControlLabelsInPrintingPausedAndOfflineStates`.
5. Edit Widget and choose Automatic. Verify the widget loads the automatically
   selected printer again. `PrinterSelectionTests` covers resolving Automatic and
   restoring fleet ordering after an explicit printer selection.
6. Restore the original size, automatic/explicit selection, surrounding icon
   layout and camera switches. Inspect the result after any update installation.
7. Test Lock Screen rendering and its tap on the physical Lock Screen separately.
   Mirroring, a wallpaper-editor preview or a Home Screen pass does not establish
   this result. If physical access is unavailable, record the step as untested.
