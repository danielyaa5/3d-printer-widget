# Optional Bambu Studio camera bridge

Print Progress can consume an HTTP or HTTPS MJPEG stream from a separately configured source. This optional Mac relay uses the official camera helper and a source issued by a genuine, signed-in Bambu Studio session. It does not change printer LAN settings or implement Bambu Cloud authentication. Studio issues the source during setup. Whether it must remain open depends on the issued connection type; the relay host must remain available.

This setup is useful when a printer's local-camera setting has a cloud/Handy warning you do not want to accept. Simultaneous Handy camera access must be checked on the actual printer and firmware; it is not guaranteed by choosing a bridge.

## Start the source

1. Install Bambu Studio and its official networking plugin from Bambu Lab. Sign in yourself.
2. Under **Device**, select the printer and start its camera. Confirm that it shows live video.
3. Open the camera settings and enable **Go Live**, installing Bambu's official camera tools if requested.
4. Studio should configure its official camera tools and source file. Files existing alone do not prove that video is flowing. Never copy or publish Studio's issued source URL.

## Start the relay on the same Mac

Install FFmpeg separately from a trusted package source, such as Homebrew. From this repository, run:

```sh
python3 scripts/camera-bridge.py
```

The relay binds only to `127.0.0.1`, on port 8898 by default. Its lightweight HTTP listener stays ready, but no video helper or decoder starts until a viewer or snapshot request arrives. The default mode pipes the official Studio helper directly into a native FFmpeg decoder, avoiding an extra encoder/RTP hop. It shares this one pipeline between local viewers, serves up to two frames per second, and keeps just the latest JPEG in memory. It records no images.

The decoder keeps the first H.264 keyframe and minimizes initial stream analysis. Discarding that first keyframe can otherwise leave a new viewer waiting for the next complete frame. Actual startup still depends on the source connection; a cold start is not guaranteed to be instantaneous.

After the last request disconnects, the relay stops both video processes after a two-second grace period and clears its in-memory picture. A later request starts a fresh pipeline. A visible live preview holds its connection; widget-only capture briefly connects, receives a picture, and disconnects. A missing or empty Studio source file returns unavailable without starting a video process. This prevents the helper’s setup placeholder from being saved as a fresh camera picture. A slow or failed source returns unavailable rather than serving an old picture as fresh. The relay retries while a viewer is waiting and restarts on a changed source file.

In Print Progress, select **Set up camera → Bridge or custom URL**, enter `http://127.0.0.1:8898/camera.mjpg`, and choose **Test camera**. Save only after a picture appears. Widget snapshots can be enabled independently. The app remains sandboxed; it only makes an outgoing connection to the relay.

The health endpoint is `http://127.0.0.1:8898/health`. HTTP 200 means recent decoded frames are available; HTTP 503 means they are not, including a normal idle state. Health checks never start video processing. Its JSON reports idle/starting/streaming state, connected clients, video-process count, frame counts, dates, source category, and the loopback-only flag. It does not include credentials or images. `/snapshot.jpg` waits for one fresh JPEG and releases its request; `/camera.mjpg` stays connected for live viewing.

If health stays unavailable while clients are waiting, reopen Studio's Device view and start the actual camera. Verify that the relay's frame count and latestCapture begin advancing; an old source file or a running decoder alone does not establish a working connection. Studio may be needed again to issue a replacement source. The relay does not reopen or sign in to Studio for you.

On a Mac whose FFmpeg lists `videotoolbox` in `ffmpeg -hwaccels`, add `--hwaccel videotoolbox` to use hardware video decoding. Test a real picture after enabling it. The portable default remains software decoding.

Use `--port` for another local port, `--studio-tools` for another official camera-tools directory, and `--idle-seconds` for a grace period from zero to ten seconds. Advanced `--sdp` mode receives an independently managed RTP/SDP source: the decoder still stops when idle, but the relay cannot stop an external producer it does not own. Do not run a separate continuous export supervisor alongside the default managed-source mode. A localhost URL works only on the relay's Mac. Other devices need a separately secured network relay or tunnel; this script deliberately does not expose a LAN listener.

For a persistent setup, run the same command as a user LaunchAgent on the host and in the account with the authenticated Studio camera session. A relay installed in another macOS account may be unavailable when that account is logged out. Install the official camera tools and enable Go Live in the active account; do not copy session credentials between accounts. Keep log output free of source URLs or credentials. The relay itself does not install a LaunchAgent, start Studio, or change login settings. Stop it with Control-C or unload the agent you configured.

When updating an older installation that used `studio-camera-export.py`, unload that separate export LaunchAgent and keep its configuration as a rollback backup. Only the on-demand relay listener should remain enabled. Studio itself may also be playing or exporting video independently; the relay manages only its own helper and decoder and does not close Studio or change its UI.

## Running with Studio closed

The official helper runs as the relay’s child process, independently of the
Studio application. In the verified TUTK setup, quitting Studio left its issued
source available. A complete relay restart while Studio remained closed
reconnected to the physical camera and updated both the app and desktop
widget. Studio does not need to stay open for that setup. Keep its installed
camera tools and networking plugin available to the relay.

This is connection-specific. [Bambu Studio’s camera implementation](https://github.com/bambulab/BambuStudio/blob/master/src/slic3r/GUI/MediaPlayCtrl.cpp)
starts a Studio-hosted refresh service for Agora exports and warns that those
streams may stop after Studio closes. Do not assume that the successful TUTK
check proves the same behavior for an Agora source. The relay does not renew
cloud authorization itself; this check covered a fresh connection and several
minutes of video, not indefinite authorization lifetime or a printer reboot.

## If Go Live creates the SDP file but no video

Verify that Studio's `bambu_source` and encoder processes actually start. Some Mac camera-tool packages have a missing `libBambuSource.dylib` search-path problem, reported in [Bambu Studio issue 7945](https://github.com/bambulab/BambuStudio/issues/7945). Some packages also contain an Intel-only encoder that cannot launch on an Apple Silicon Mac without translation support.

Use the current official camera-tool package first. An administrator diagnosing an affected local installation can link the already-installed official plugin library into the helper's expected directory and use an existing native FFmpeg executable, preserving any original file for rollback. These are host-specific repairs, not software installed or distributed by the Print Progress app. Recheck startup and real frames after any repair; a checked Go Live switch is not sufficient evidence.

## Repeatable checks

```sh
python3 scripts/test-camera-bridge.py
```

These checks generate blue video without contacting a printer. They exercise multiple live viewers sharing one decoder, a snapshot alongside live viewing, concurrent snapshots, idle shutdown, health checks that do not wake video, cold-start capture, empty-source rejection and recovery, unknown paths, and an official-helper-shaped H.264 fixture whose source and decoder both stop when idle. That fixture deliberately spaces keyframes ten seconds apart and checks that both video and snapshot startup retain the first one. The legacy supervisor shutdown check is retained. Do not use a generated test image as evidence of a working physical camera.
