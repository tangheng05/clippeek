cask "clippeek" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/tangheng05/clippeek/releases/download/v#{version}/Clippeek.zip"
  name "clippeek"
  desc "Menu bar app that sends screenshots and screen recordings to your Zipline server"
  homepage "https://github.com/tangheng05/clippeek"

  depends_on macos: :tahoe

  app "Clippeek.app"
  binary "#{appdir}/Clippeek.app/Contents/MacOS/ClippeekApp", target: "clippeek"

  # The app isn't notarized; this skips the "Open Anyway" step.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "/Applications/Clippeek.app"],
        must_succeed:   false,
        writable_paths: ["Clippeek.app"],
        writable_base:  :appdir
  end

  # Puts the user's screenshot settings back; skipped if the app is already gone.
  uninstall quit:   "io.github.tangheng05.clippeek",
            script: {
              executable:   "/bin/sh",
              args:         ["-c", '[ ! -x "$0" ] || "$0" --restore-capture',
                             "#{appdir}/Clippeek.app/Contents/MacOS/ClippeekApp"],
              must_succeed: false,
            }

  zap trash: [
    "~/Library/Application Support/clippeek",
    "~/Library/Preferences/io.github.tangheng05.clippeek.plist",
  ]

  caveats <<~EOS
    If you remove Clippeek.app without Homebrew, turn off "Send screenshots" and
    "Send screen recordings" in clippeek first so your previous screenshot settings come back.
  EOS
end
