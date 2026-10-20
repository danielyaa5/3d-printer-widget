# Contributing

Start with a reproducible issue or a small pull request. Describe the printer interface and firmware involved. Use synthetic fixtures and fictional hostnames; never include a private printer capture.

Keep networking and telemetry in `Sources/PrintProgressCore`. Put platform UI in `App`, `Shared`, or `Widgets`. Monitoring must remain read-only. Preserve timestamps, distinguish unavailable sensors from zero, and do not invent progress or a running finish estimate for paused or offline jobs.

Run the core and native feature test commands in [README](README.md#tests-and-live-connection-check). Build both platform schemes after shared UI changes. Include a targeted regression test for a protocol or persistence fix. A fixture test demonstrates an interface contract; document physical hardware verification separately.

Use `bash scripts/generate-demo-media.sh` to regenerate the public demo assets. It requires Xcode, XcodeGen, and FFmpeg and renders only fictional sample readings. Never substitute real printer profiles into public media.

For a potential credential-disclosure vulnerability, avoid publishing secrets or exploit details in a public issue. GitHub's private vulnerability reporting can be used when enabled for the repository.
