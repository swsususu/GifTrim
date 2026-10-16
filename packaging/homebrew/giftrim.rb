cask "giftrim" do
  # Update both on every release. Get the checksum from the published asset:
  #   shasum -a 256 GifTrim_<version>_universal.dmg
  version "0.1.2"
  sha256 "f0be6fd2bdfff46e76450c890514d9b154e31c17c503c454a2290f7dcf01dd34"

  url "https://github.com/swsususu/GifTrim/releases/download/v#{version}/GifTrim_#{version}_universal.dmg"
  name "GifTrim"
  desc "GIF maker with screen recording, captions, CLI and MCP server for AI agents"
  homepage "https://github.com/swsususu/GifTrim"

  depends_on :macos

  app "GifTrim.app"
  binary "#{appdir}/GifTrim.app/Contents/Helpers/giftrim"

  zap trash: [
    "~/Library/Preferences/com.swsususu.giftrim.plist",
    "~/Library/Saved Application State/com.swsususu.giftrim.savedState",
  ]

  caveats <<~CAVEATS
    GifTrim is not notarised yet, so macOS will refuse to open it the first
    time. Either right-click the app and choose Open, or run:

      xattr -dr com.apple.quarantine /Applications/GifTrim.app

    Until then the `giftrim` command may also be killed on launch.

    Use it from AI assistants (MCP):

      claude mcp add giftrim -- giftrim mcp
  CAVEATS
end
