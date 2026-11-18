class Mateinate < Formula
  desc "Keep the Mac awake only while on Wi-Fi and above a battery floor"
  homepage "https://github.com/4lb0/mateinate"
  url "https://github.com/4lb0/mateinate/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "12e234be7943b717e3c0bc3fa38f71bc4196efe8a27afddf622106efc06accd4"
  license "MIT"
  head "https://github.com/4lb0/mateinate.git", branch: "main"

  depends_on :macos

  def install
    bin.install "mateinate"
    pkgshare.install "tests"
  end

  def caveats
    <<~EOS
      Start it at login (one password prompt, to allow pmset without sudo):

        mateinate install

      Then check the decision it is making:

        mateinate status
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/mateinate version")
  end
end
