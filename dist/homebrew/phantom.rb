class Phantom < Formula
  desc "Zero-config secure remote terminal access via QUIC"
  homepage "https://github.com/user/phantom"
  license "MIT"
  version "0.1.0"

  # For local development: install from source
  # In a real tap, this would point to a release tarball:
  # url "https://github.com/user/phantom/archive/refs/tags/v#{version}.tar.gz"
  # sha256 "..."
  head "https://github.com/user/phantom.git", branch: "main"

  depends_on "rust" => :build

  def install
    cd "daemon" do
      system "cargo", "build", "--release"
      bin.install "target/release/phantom"
    end
  end

  service do
    run [opt_bin/"phantom"]
    keep_alive true
    log_path var/"log/phantom.log"
    error_log_path var/"log/phantom.log"
    working_dir var/"phantom"
  end

  def post_install
    (var/"phantom").mkpath
  end

  test do
    assert_match "phantom", shell_output("#{bin}/phantom --help")
  end
end
