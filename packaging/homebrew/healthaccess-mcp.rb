# Homebrew formula skeleton for Health Access MCP.
#
# Lives in the tap repository `leonhardprinz/homebrew-tap` as
# Formula/healthaccess-mcp.rb once the first GitHub release exists:
#
#   brew install leonhardprinz/tap/healthaccess-mcp
#
# The release workflow (.github/workflows/release.yml) builds the universal
# macOS tarball and prints its sha256 in the release notes. Fill in the two
# TODO placeholders from that release, bump `version`, and push the tap.
class HealthaccessMcp < Formula
  desc "Apple Health workouts, vitals and a briefing for your AI, from a folder you own"
  homepage "https://github.com/leonhardprinz/healthaccess-mcp"
  version "0.6.2"
  license "MIT"

  # TODO: the universal macOS tarball attached to the v<version> GitHub release
  url "https://github.com/leonhardprinz/healthaccess-mcp/releases/download/v0.6.2/healthaccess-mcp-0.6.2-macos-universal.tar.gz" # TODO
  sha256 "TODO" # TODO: shasum -a 256 of that tarball

  depends_on :macos

  def install
    bin.install "healthaccess-mcp"
    bin.install "healthaccess"
  end

  def caveats
    <<~EOS
      Register the server with your AI. Claude Code, for example:

        claude mcp add --scope user healthaccess -- #{opt_bin}/healthaccess-mcp --dir "<your Health Access folder>"

      The folder is the one the Health Access iOS app writes into. Check it with:

        healthaccess --dir "<your Health Access folder>" doctor
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/healthaccess-mcp --version")
    assert_match version.to_s, shell_output("#{bin}/healthaccess --version")
    assert_match "next_swim_session", shell_output("#{bin}/healthaccess prompts")
  end
end
