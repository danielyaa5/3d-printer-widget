# Project website

Build with `bash scripts/build-site.sh`. The output is in ignored `build/Site.noindex` and needs only a static HTTP server. No framework, package install, analytics, fonts, or third-party scripts are required. All imagery is existing project artwork or fictional demo media.

GitHub Actions publishes the site to `https://danielyaa5.github.io/3d-printer-widget/` on changes to its source or assets. Enable GitHub Pages with the **GitHub Actions** source. Download links use the stable `releases/latest/download/Print-Progress.dmg` asset URL. Keep that asset name on future releases. Update the visible release version and App Store availability when publishing a new release.

For browser checks, serve the generated directory and run `node scripts/test-site.cjs` with Playwright available. The default URL is `http://127.0.0.1:8765/3d-printer-widget/`; override it with `PRINT_SITE_URL`. The script uses an isolated headless Chrome process and always closes it. Screenshots go to ignored `build/SiteQA.noindex`.
