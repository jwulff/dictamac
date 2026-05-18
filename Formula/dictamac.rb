# Sample Homebrew formula for dictamac.
#
# This file is a REFERENCE COPY that ships in the dictamac repo so the
# formula can be code-reviewed alongside the code it builds. The canonical,
# brew-installable copy lives in https://github.com/jwulff/homebrew-tap at
# `Formula/dictamac.rb` and is installed via:
#
#   brew install jwulff/tap/dictamac
#
# When releasing a new dictamac version, update the `url`, `sha256`, and
# (if needed) the macOS version gate here AND in the tap repo. See
# `changes/NNNN-homebrew-formula-prep.md` for the release procedure.
class Dictamac < Formula
  desc "macOS CLI for on-device transcription via SpeechAnalyzer"
  homepage "https://github.com/jwulff/dictamac"
  url "https://github.com/jwulff/dictamac/archive/refs/tags/v0.1.0.tar.gz"
  # Replace with the value of:
  #   curl -sL https://github.com/jwulff/dictamac/archive/refs/tags/v0.1.0.tar.gz \
  #     | shasum -a 256
  # immediately after pushing the v0.1.0 tag. See the release procedure in
  # `changes/` for the full sequence.
  sha256 "PLACEHOLDER_REPLACE_WITH_REAL_SHA256_AFTER_TAGGING_v0.1.0"
  license "MIT"
  head "https://github.com/jwulff/dictamac.git", branch: "main"

  # dictamac uses macOS 26 (Tahoe) SpeechAnalyzer APIs. `:tahoe` is the
  # Homebrew macro for macOS 26.0+; brew will refuse to install on older
  # systems. If running against an older Homebrew that does not know about
  # `:tahoe` yet, fall back to a manual `MacOS.version` check below.
  depends_on macos: :tahoe

  # Swift 6.x toolchain is required to build. On most contributor machines
  # this comes from Xcode 16+ Command Line Tools; `:build` tells Homebrew
  # we only need it at install time, not runtime.
  depends_on xcode: ["16.0", :build]

  def install
    # The Makefile already honors PREFIX. `prefix` is the standard
    # Homebrew variable for the keg root; bin/etc/share land under it.
    system "make", "build"
    system "make", "install", "PREFIX=#{prefix}"
  end

  test do
    # Smoke check: the binary loads and reports its version. We do NOT
    # run a transcription here because that requires Speech Recognition
    # TCC permission, which is unavailable in `brew test`'s sandbox.
    assert_match(/\d+\.\d+\.\d+/, shell_output("#{bin}/dictamac --version"))
  end
end
