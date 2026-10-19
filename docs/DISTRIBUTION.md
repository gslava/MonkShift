# Distribution through GitHub Releases and Homebrew

MonkShift is distributed outside the App Store. Release bundles are Universal
(`arm64` and `x86_64`) for macOS 14 or later and use a local ad-hoc signature.
There is no Apple Developer ID or notarization in this workflow.

## Prepare downloads locally

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

- `dist/MonkShift-<version>-universal.dmg`: contains `MonkShift.app`, an Applications
  link for drag-and-drop installation, and a short installation guide.
- `dist/MonkShift-<version>-universal.zip`: the same app at the archive root.
- Adjacent `.sha256` files for the exact DMG and ZIP bytes.
- `dist/release.json`: version, download URLs, architectures, both checksums and
  signing status. Existing top-level archive fields still describe the ZIP;
  the `dmg` object describes the disk image.
- `Casks/monkshift.rb` and `dist/monkshift.rb`: casks pinned to that exact ZIP.

The repository defaults to the confirmed `gslava/MonkShift`. For a fork, set
`MONKSHIFT_REPOSITORY=OWNER/REPO` when running the packaging script. Inputs are
validated before a build starts. These local packaging scripts do not upload
files, create tags/releases, launch MonkShift or change security settings. The
GitHub Actions workflow described below publishes after a tag push.

Verify an existing package independently:

```sh
bash scripts/verify-release.sh
```

Verification checks both SHA-256 files and the DMG's internal checksum. It extracts
the ZIP, mounts the DMG read-only without opening Finder, and checks the
Applications link, executable slices, metadata, ICNS, license, ad-hoc signatures
and Apple Shortcuts metadata. Both copies of the app must have identical contents.
It also checks release JSON and the adjacent generated cask (falling back to
`Casks/monkshift.rb`) against the actual files, then ejects the DMG. It does not
execute the app. A build using `--without-app-shortcuts` cannot pass release
verification. Custom paths are accepted as `[archive.zip] [image.dmg]`.

## Automatic GitHub Releases

`.github/workflows/release.yml` runs on pushes of `v*` tags. The selected behavior
is automatic publication after verification, without a manual approval step.

1. Set `CFBundleShortVersionString` in `Resources/Info.plist` to the release's
   numeric `major.minor.patch` version, and advance `CFBundleVersion` for an update.
   Commit and push the intended source, including the workflow. Keep generated
   `build/` and `dist/` files untracked.
2. Check `bash scripts/check-release-tag.sh v<version>`. The tag must match the
   plist exactly; prerelease suffixes are not supported by this workflow.
3. Create and push a new tag on that commit, replacing `<version>` below:

   ```sh
   git tag v<version>
   git push origin v<version>
   ```

4. The macOS 15 build job uses full Xcode 16.4, runs the offline suite, builds both
   executable slices including Shortcuts metadata, creates DMG/ZIP, and verifies
   their contents and checksums. Failure prevents publication. Verified files are
   retained as an Actions artifact for 14 days.
5. A separate Ubuntu job rechecks the transferred SHA-256 files and uses GitHub
   CLI to publish the Release with DMG, ZIP, both checksum files, `release.json`
   and the matching `monkshift.rb`. Notes combine `.github/RELEASE_NOTES.md` with
   GitHub's generated change notes.

Only the publishing job has `contents: write`. It uses the repository's built-in
`GITHUB_TOKEN`; no personal token or Apple signing credentials are required.
GitHub Actions must be enabled and repository/organization policy must allow
the requested token permission. Tag and repository values are passed through
environment variables, not interpolated into shell code. Official actions are
pinned to commit SHAs.

`--verify-tag` prevents GitHub CLI from creating a missing tag. Existing releases
are not overwritten: a rerun that finds one fails. GitHub CLI uploads assets
before publishing; a failed upload can leave an unpublished draft. Inspect the
failed run and any draft before retrying. Do not move a published tag or rebuild
its downloads; fix the issue and publish a new version. A version string alone
does not identify the exact bytes pinned by Homebrew.

Record OS/architecture combinations actually tested. Building both slices and
using fake settings in checks does not demonstrate live behavior on both Macs.
After publication, verify the public download and checksum and test installation
on a separate Mac. Shortcuts registration and Gatekeeper first-launch behavior
remain live verification steps.

For version `0.1.0`, download names are `MonkShift-0.1.0-universal.dmg` and
`MonkShift-0.1.0-universal.zip`, under
`https://github.com/gslava/MonkShift/releases/download/v0.1.0/` once published.

## Homebrew custom tap

The application repository also contains its cask in `Casks/`. The release
workflow attaches a generated `monkshift.rb`, but does not commit to branches.
After a successful release, copy that attached file into `Casks/monkshift.rb` and
commit/push it to update the tap. Use the published cask, rather than rebuilding
the same version locally, so its checksum matches the published ZIP. Once the
cask is updated and the matching GitHub release exists, users can install with:

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

For manual installation, open the DMG, drag `MonkShift.app` onto Applications and
eject the disk image; alternatively extract the ZIP and move the app to
`/Applications`. Install there before granting Automation permission. Homebrew
installs it there by default. Launch intentionally and grant System Events access
through onboarding. Changing the container to DMG does not notarize the app or
bypass macOS's first-launch checks.

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
