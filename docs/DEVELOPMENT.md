# Development

[README](../README.md) · [Testing](TESTING.md) · [Architecture](ARCHITECTURE.md)

## Build options

Requires full Xcode for Apple Shortcuts metadata. Point `DEVELOPER_DIR` at its
`Contents/Developer` directory if Command Line Tools are selected. From the project directory:

```sh
bash scripts/check.sh
bash scripts/build-app.sh
open build/MonkShift.app
```

The build produces an ad-hoc signed **Universal app for Apple Silicon and Intel**,
including metadata for Apple Shortcuts. Use `bash scripts/build-app.sh --native`
for a faster local-only development build. Move the final app to `/Applications`
**before granting permission** to keep its path stable. To edit in Xcode, open
`Package.swift`; use the build script to produce an app bundle with privacy and
Shortcuts metadata and the generated ICNS.

With Command Line Tools alone, checks and previews still work. Build a local app
without Apple Shortcuts actions using
`bash scripts/build-app.sh --native --without-app-shortcuts`. Global keyboard
shortcuts still work in this build. The standard build fails early when the
metadata tool is unavailable, preserving the previous app bundle.

`bash scripts/package-release.sh` prepares Universal DMG and ZIP files, SHA-256
checksums, release metadata and a matching Homebrew cask.
`bash scripts/verify-release.sh` verifies both downloads, mounts the DMG read-only
without opening Finder, compares the apps and ejects it without launching the app.
These local commands do not publish anything. The tag-triggered GitHub Actions
workflow publishes the verified files automatically. See
[DISTRIBUTION.md](DISTRIBUTION.md) for release and custom-tap instructions.
Developer ID, notarization and App Store distribution are outside this workflow.

## Project layout

- `Sources/MonkShiftCore/`: feature models, restoration storage and settings orchestration through `SettingsBackend`.
- `Sources/MonkShift/`: app lifecycle, permissions, shortcuts, views and macOS adapters in `System/`.
- `Tests/`: custom Foundation check runners and fake clients.
- `Resources/`: app metadata, icon and entitlements.
- `scripts/`: build, check, preview and packaging commands.

Generated files belong in ignored `.build/`, `build/` and `dist/` directories.
Automated checks use custom Foundation runners rather than `swift test`.
See [Testing](TESTING.md) for coverage, fixture generation and live acceptance checks.
