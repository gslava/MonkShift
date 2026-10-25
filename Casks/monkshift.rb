cask "monkshift" do
  version "0.1.6"
  sha256 "7ecf6e2da4351258471deca2e5c0dd8c7eb1ea7747d1adb4f2de8013afb19c44"

  url "https://github.com/gslava/MonkShift/releases/download/v#{version}/MonkShift-#{version}-universal.zip"
  name "MonkShift"
  desc "Offline focus controls for Dock, Stage Manager and display settings"
  homepage "https://github.com/gslava/MonkShift"

  depends_on macos: :sonoma

  app "MonkShift.app"

  uninstall quit: "app.monkshift.MonkShift"

  caveats <<~EOS
    MonkShift is ad-hoc signed and is not notarized with an Apple Developer ID.
    macOS may require approval in System Settings > Privacy & Security on first launch.
    Grant Automation access to System Events when MonkShift asks.
    Restore All Changes before uninstalling if you want your previous settings back.
    Saved restore records are retained in ~/Library/Application Support/MonkShift.
  EOS
end
