{ pkgs, lib, ... }:

let
  # Reindeer for `reindeer buckify`. One of its tests fails on darwin, so
  # there it is built without them. Elsewhere the unmodified package comes
  # prebuilt from the binary cache; overriding it would rebuild it from
  # source.
  reindeer =
    if pkgs.stdenv.hostPlatform.isDarwin then
      pkgs.reindeer.overrideAttrs { doCheck = false; }
    else
      pkgs.reindeer;
in
{
  # Buck2 links xex-link and the other host tools of the xbox360 cell with
  # the host's C compiler driver (cc, c++ and ar on Linux, Xcode's clang on
  # macOS), so the shell provides none: the binaries then depend on the
  # host's C library rather than on Nix store paths.
  stdenv = pkgs.stdenvNoCC;

  # Cargo and rustc resolve third-party/rust/Cargo.toml for reindeer. Buck2
  # downloads the Rust release that it builds with.
  packages = [
    pkgs.cargo
    pkgs.rustc
    reindeer
  ];

  # bin/buck2 runs the Buck2 release that toolchains/buck2 pins, through the
  # DotSlash that bootstrap.sh installs, as outside the shell. DotSlash and
  # the Linux Buck2 builds are static, so they run on NixOS.
  enterShell = ''
    export PATH="$DEVENV_ROOT/bin:$PATH"
  '';

  # bazel-remote serves the Buck2 action cache in CI. Only the Linux job runs
  # reindeer, and the darwin build of reindeer is in no public binary cache,
  # so the macOS job leaves it out rather than build it on every run.
  profiles.ci.module.packages = lib.mkForce (
    [
      pkgs.bazel-remote
      pkgs.cargo
      pkgs.rustc
    ]
    ++ lib.optional (!pkgs.stdenv.hostPlatform.isDarwin) reindeer
  );
}
