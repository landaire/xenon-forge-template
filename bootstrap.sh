#!/bin/sh
# Installs DotSlash into .tools and fetches the Buck2 release that
# toolchains/buck2 pins, for Linux and macOS. bin/buck2 runs this on first
# use. Windows uses bootstrap.ps1.
#
# Buck2 downloads everything else it builds with. The host tools it does
# not download are checked at the end and reported, not installed.
set -eu

DOTSLASH_VERSION=v0.5.9

root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tools=$root/.tools

say() {
    printf '%s\n' "$*" >&2
}

fail() {
    say "bootstrap: $*"
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

sha256_of() {
    if have sha256sum; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

install_dotslash() {
    for tool in curl tar; do
        have "$tool" || fail "$tool is required to download DotSlash"
    done

    mkdir -p "$tools/bin"
    scratch=$(mktemp -d "$tools/download.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT

    say "Downloading DotSlash $DOTSLASH_VERSION"
    curl -fsSL --retry 3 -o "$scratch/$asset" \
        "https://github.com/facebook/dotslash/releases/download/$DOTSLASH_VERSION/$asset"

    actual=$(sha256_of "$scratch/$asset")
    [ "$actual" = "$sha256" ] || fail "$asset has SHA-256 $actual, not $sha256"

    tar -xzf "$scratch/$asset" -C "$scratch" dotslash
    mv -f "$scratch/dotslash" "$tools/bin/dotslash"
    printf '%s\n' "$sha256" >"$tools/bin/dotslash.sha256"
}

missing_required() {
    if [ -z "${required_reported:-}" ]; then
        say "Missing required host tools:"
        required_reported=1
    fi

    required_missing=1
    say "  $1: $2"
}

missing_optional() {
    if [ -z "${optional_reported:-}" ]; then
        say "Optional capabilities unavailable:"
        optional_reported=1
    fi

    say "  $1: $2"
}

check_host_tools() {
    have git || missing_required git "required. Buck2 fetches external cells with git."

    # Host executables: xex-link and xbox360-asm-rewrite.
    case $(uname -s) in
    Linux)
        have c++ ||
            missing_required c++ "required to link host executables. Install GCC or Clang (for example g++ or gcc-c++)."
        ;;
    Darwin)
        xcrun --find c++ >/dev/null 2>&1 ||
            missing_required "Xcode command line tools" "required to link host executables. Run xcode-select --install."
        ;;
    esac

    clang --print-targets 2>/dev/null | grep -q '^ *ppc32 ' ||
        missing_optional clang "PPC32 C titles need clang with the PowerPC target on the PATH of the Buck2 daemon."
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null ||
        missing_required python3 "Buck build and run actions need Python 3.11 or later."

    if ! have cargo || ! have rustup; then
        missing_optional "Cargo toolchain" "Cargo builds need rustup, Cargo, Rust 1.98.0, and its rust-src component."
    elif ! rustup toolchain list 2>/dev/null | grep -q '^1\.98\.0'; then
        missing_optional "Rust 1.98.0" "Cargo builds need rustup toolchain install 1.98.0."
    elif ! rustup component list --installed --toolchain 1.98.0 2>/dev/null | grep -q '^rust-src'; then
        missing_optional rust-src "Cargo builds need rustup component add rust-src --toolchain 1.98.0."
    fi

    have reindeer ||
        missing_optional reindeer "only regenerating third-party/rust/BUCK needs it, after a change to a Cargo.toml."

    if [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ]; then
        have cc || missing_optional cc "PPC64 builds need a host C compiler."
        have ar || missing_optional ar "PPC64 builds need binutils."
        have ranlib || missing_optional ranlib "PPC64 builds need binutils."
        have unzip || missing_optional unzip "PPC64 builds need unzip."
    fi

    if [ -n "${required_missing:-}" ]; then
        fail "install the required host tools above and run bootstrap.sh again"
    fi
}

case "$(uname -s)-$(uname -m)" in
Linux-x86_64)
    asset=dotslash-linux-musl.x86_64.$DOTSLASH_VERSION.tar.gz
    sha256=4c75c6eb7890ae35993b962073f6d9bbe78b42b81a5691303ad70f63bfbf7196
    ;;
Linux-aarch64 | Linux-arm64)
    asset=dotslash-linux-musl.arm64.$DOTSLASH_VERSION.tar.gz
    sha256=e58374446dacd4a228388cd275d974bbd8f946916b513cf0eb86bdff5d9d675e
    ;;
Darwin-x86_64 | Darwin-arm64)
    asset=dotslash-macos.$DOTSLASH_VERSION.tar.gz
    sha256=67963df97f5ce512f900a85950add6e883722c3460ee5d752a6e62665fd2f986
    ;;
*)
    fail "no DotSlash release for $(uname -s) $(uname -m)"
    ;;
esac

installed=$(cat "$tools/bin/dotslash.sha256" 2>/dev/null || true)
if [ ! -x "$tools/bin/dotslash" ] || [ "$installed" != "$sha256" ]; then
    install_dotslash
fi

say "Fetching Buck2"
"$root/bin/buck2" --version >&2

check_host_tools
say "Run bin/buck2 in place of buck2, or add $root/bin to PATH."
