# Distribution through GitHub Releases and Homebrew

MonkShift is distributed outside the App Store. Release bundles are Universal
(`arm64` and `x86_64`) for macOS 14 or later and use a local ad-hoc signature.
There is no Apple Developer ID or notarization in this workflow.

## Prepare an archive

Run from the project root on a Mac with full Xcode selected (or set
`DEVELOPER_DIR` to Xcode's `Contents/Developer` directory). The release requires
`appintentsmetadataprocessor`, which is absent from standalone Command Line Tools:

```sh
bash scripts/check.sh
bash scripts/render-previews.sh --readme
bash scripts/package-release.sh
```

Packaging builds both architectures, generates the ICNS and Apple Shortcuts
metadata, signs the complete app
ad-hoc, verifies the signature, and creates these files for the version in
`Resources/Info.plist`:

- `dist/MonkShift-<version>-universal.zip`: contains `MonkShift.app` at the root.
- `dist/MonkShift-<version>-universal.zip.sha256`: checksum for that exact ZIP.
- `dist/release.json`: version, URL, architectures, checksum and signature status.
- `Casks/monkshift.rb`: the custom-tap cask pinned to that exact archive checksum.

The repository defaults to the confirmed `gslava/MonkShift`. For a fork, set
`MONKSHIFT_REPOSITORY=OWNER/REPO` when running the packaging script. Inputs are
validated before a build starts. No script uploads files, creates tags/releases,
launches MonkShift or changes the Mac's security configuration.

Verify an existing package independently:

```sh
bash scripts/verify-release.sh
```

Verification checks the ZIP checksum before extracting into a temporary build
directory, then checks both executable slices, app metadata, ICNS, license,
ad-hoc signature, Apple Shortcuts metadata and matching cask version/checksum. It
does not execute the app. A development build using `--without-app-shortcuts`
cannot pass release verification.

## Publish the prepared files

1. Review the source, screenshots, cask and verification results. Record the OS
   versions and architectures actually tested. Cross-compiling Intel does not
   demonstrate Intel runtime behavior.
2. Commit the source and generated cask together, using the repository's required
   Git identity. Keep `dist/` and `build/` untracked.
3. Create a GitHub release in `gslava/MonkShift` using tag `v<version>` and attach
   the exact ZIP and `.sha256` files produced above. Optionally attach
   `release.json`. Do not rebuild or replace that ZIP without regenerating the
   cask/checksum; a matching version alone does not identify identical bytes.
4. Verify the public URL and checksum, then test download/install on a separate
   Mac. Publication and downloaded-app Gatekeeper behavior are manual steps.

Version `0.1.0`, for example, uses:
`https://github.com/gslava/MonkShift/releases/download/v0.1.0/MonkShift-0.1.0-universal.zip`.
This is the planned URL; generating the package does not make it publicly available.

## Homebrew custom tap

The application repository also contains its cask in `Casks/`. Once the cask is
committed and the matching GitHub release exists, users can install with:

```sh
brew tap gslava/monkshift https://github.com/gslava/MonkShift.git
brew install --cask gslava/monkshift/monkshift
```

The explicit repository URL is required: the usual shorthand otherwise looks
for a separate repository called `homebrew-monkshift`. Updates use:

```sh
brew update
brew upgrade --cask gslava/monkshift/monkshift
```

This is a custom tap, not a submission to the official `homebrew/cask`
repository. [Official cask policy](https://docs.brew.sh/Acceptable-Casks) requires
Gatekeeper compatibility. The custom cask pins SHA-256, preserves quarantine,
installs the app and displays the signing/permission caveats. It does not launch
the app. Neither the cask nor the packaging scripts remove quarantine or disable
Gatekeeper. Homebrew installation does not confer Apple notarization.

## First launch and updates

For a manual installation, extract the ZIP and move `MonkShift.app` to
`/Applications` before granting Automation permission. Homebrew installs it there
by default. Launch it intentionally, then grant System Events access through
onboarding.

Because the downloaded app is not notarized, macOS can block first launch. If
you trust the download and have verified its source/checksum, follow Apple's
[per-app approval steps](https://support.apple.com/en-us/102445) in System Settings
under Privacy & Security. A custom tap cannot guarantee a prompt-free first
launch. Managed Macs may prevent approval.

An ad-hoc signed update may require regranting Automation permission. Install
the final bundle at a stable path before granting it. If an operation is in
progress, wait for it to finish before updating or quitting.

Before uninstalling, use **Restore All Changes** if you want the original system
settings restored. Quitting/uninstalling keeps current settings by design. The
cask retains `~/Library/Application Support/MonkShift` so failed or pending
restoration records are not silently deleted.
