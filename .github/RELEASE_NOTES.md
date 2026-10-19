Download the **Universal DMG** for macOS 14 or later (Apple Silicon and Intel).
Open it, drag **MonkShift.app** onto **Applications**, then eject the disk image.
Launch MonkShift from Applications and grant Automation access to System Events.

The ZIP contains the same app. Each download has an adjacent SHA-256 checksum.
The release includes Apple Shortcuts metadata. Automated checks use fake settings;
cross-compilation does not confirm live OS behavior on both architectures.

MonkShift is ad-hoc signed and **not notarized** with an Apple Developer ID.
macOS may require per-app approval in System Settings → Privacy & Security.
The DMG does not bypass Gatekeeper or grant Automation permission.

Before uninstalling, use **Restore All Changes** to restore your previous settings.

The attached `monkshift.rb` matches this release's exact ZIP checksum. The repository's
Homebrew cask requires a separate update; this workflow does not commit to branches.
