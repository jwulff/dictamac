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
# `changes/0058-homebrew-formula-prep.md` for the release procedure.
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
  # systems. `:tahoe` is supported on every Homebrew release that ships
  # with macOS 26, so no manual `MacOS.version` fallback is required.
  depends_on macos: :tahoe

  # Swift 6.x toolchain is required to build. On most contributor machines
  # this comes from Xcode 16+ Command Line Tools; `:build` tells Homebrew
  # we only need it at install time, not runtime. NOTE: Xcode 16 ships
  # only the macOS 15 (Sequoia) SDK; building dictamac requires the
  # macOS 26 SDK that ships with Xcode 26. The hard gate below enforces
  # that — `depends_on xcode:` is kept as a floor for Swift 6.x.
  depends_on xcode: ["16.0", :build]

  def install
    # dictamac targets `.macOS("26.0")` and imports `SpeechAnalyzer` /
    # `SpeechTranscriber`, which are only available in the macOS 26 SDK
    # that ships with Xcode 26. Homebrew may pick an older toolchain on
    # Tahoe machines that still have Xcode/CLT 16.x installed, in which
    # case the Swift build will fail late with cryptic "cannot find type
    # 'SpeechAnalyzer' in scope" errors. Fail loudly up front instead.
    odie <<~EOS unless MacOS::Xcode.version >= "26"
      dictamac requires Xcode 26 (or its Command Line Tools) to build,
      which provides the macOS 26 SDK. Detected Xcode version:
      #{MacOS::Xcode.version}.

      Install Xcode 26 from the App Store (or `xcode-select` to a newer
      developer dir) and try again.
    EOS

    # Pin the deployment target so the Swift compiler honors the macOS
    # 26 floor declared in Package.swift even if a host environment
    # overrides it.
    ENV["MACOSX_DEPLOYMENT_TARGET"] = "26.0"

    # The Makefile already honors PREFIX. `prefix` is the standard
    # Homebrew variable for the keg root; bin/etc/share land under it.
    system "make", "build"
    system "make", "install", "PREFIX=#{prefix}"
  end

  test do
    # Smoke check: the binary loads and reports its version. We do NOT
    # run a transcription here because that requires Speech Recognition
    # TCC permission, which is unavailable in `brew test`'s sandbox.
    # Asserting exit 0 (rather than regex-matching the version string)
    # keeps the test robust to pre-release version suffixes like
    # `0.0.0-dev` and to the eventual `0.1.0` tag alike.
    system "#{bin}/dictamac", "--version"
  end
end
