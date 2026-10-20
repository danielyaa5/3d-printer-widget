# Privacy policy

Effective October 20, 2026.

Print Progress connects directly to the printers and local servers you configure. It has no developer-operated server, account system, advertising, analytics SDK, or tracking.

## Data on your device

Printer names, addresses, serial numbers, access codes, API keys, passwords, certificate fingerprints, and cached status readings are stored in the device's Keychain. The app and its widget share access through their signed Keychain group. These records do not sync through iCloud. Walkthrough completion and appearance preferences are stored locally using the operating system's preferences system.

Status readings may include print filenames, progress, remaining time, layers, temperatures, and printer error codes. They are used to display the app and widgets. Removing a printer deletes its saved connection and cached reading from the app's storage. Information already displayed by the operating system can remain visible until its next widget refresh.

## Network access

The app sends authentication and read-only status requests to the printer address you enter. It does not send printer data to the developer or to an analytics service. It does not use a vendor cloud login. Your printer or server may separately use its manufacturer's services according to its own settings and privacy policy.

HTTP and ordinary WebSocket connections are unencrypted. Use them on a trusted local network or through a secure VPN. HTTPS and Bambu TLS connections use operating-system networking and security services. Bambu certificate fingerprints are pinned after the first successful pairing.

## Permissions and diagnostics

Local Network access lets the app reach your printers. No camera, microphone, contacts, photo library, or location permission is needed.

The direct-download Mac app checks mounted disk-image metadata after launch to identify its matching installer, then asks macOS to eject that disk. It does not eject the volume it is running from or force a busy disk to unmount. This local installer cleanup sends no data to the developer. The direct-download main app runs outside App Sandbox; its widget and the App Store builds remain sandboxed.

Apple may collect crash and diagnostic information according to your operating-system settings. Development builds can write local verification reports for testing; App Store release builds disable those reports. The built-in demo uses fictional readings and makes no printer connections.

## Support

If you voluntarily submit a GitHub issue, its contents are public and subject to GitHub's privacy policy. Do not include access codes, passwords, serial numbers, addresses, certificate fingerprints, or unredacted printer logs.

For questions, use the [support page](support.md).
