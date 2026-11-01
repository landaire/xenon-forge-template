# Xenon Forge template development guide

## Buck2 in five minutes

[Buck2](https://buck2.build) is the build system. It decides what to rebuild from the files and commands it knows about, so it never runs a stale step and can share results between machines.

A few terms:

- A *target* is one thing Buck2 can build, such as a XEX or a Rust library.
- A *`BUCK` file* declares the targets of the directory it is in. A directory with a `BUCK` file is a *package*.
- A *label* names a target. `//title:title` is the target `title` in the package `title/`. When a target has the name of its directory you can shorten its label, so `//title` means `//title:title`.
- A *pattern* names many targets. `//...` is every target in this repository. `//title/...` is every target under `title/`.
- A *cell* is a separate tree of `BUCK` files with its own name. `xbox360//` is the Xenon Forge repository at the commit in `.buckconfig`, which Buck2 fetches with git. `prelude//` holds the standard rules such as `rust_library`, and `toolchains//` is `toolchains/` in this repository.
- `load("@xbox360//buck:xex.bzl", "xbox360_title")` imports a rule from a `.bzl` file, in this case from the xbox360 cell.

Buck2 runs a background process, the daemon, that keeps the build graph in memory. `buck2 kill` stops it. Run that if the build ever behaves as if it missed a change to your environment, for example after you change `PATH`.

Useful commands:

| Command | What it does |
| --- | --- |
| `buck2 build //...` | Builds every target. |
| `buck2 build //dll:dll --show-output` | Builds one target and prints the path of its output. |
| `buck2 targets //...` | Lists the targets. |
| `buck2 cquery "deps(//title:title, 1)"` | Lists the direct dependencies of a target, configured as they are built. |
| `buck2 clean` | Deletes `buck-out`. |

## Adding a target

Say you want a second title, `hello`, and a library `greeting` that both titles can use.

1. Make a directory for the library with a `BUCK` file and a source file.

   `greeting/BUCK`:

   ```python
   rust_library(
       name = "greeting",
       srcs = glob(["src/**/*.rs"]),
       crate_root = "src/lib.rs",
       edition = "2024",
       deps = ["//third-party/rust:xbox360"],
       target_compatible_with = ["xbox360//platforms:xbox360"],
       visibility = ["PUBLIC"],
   )
   ```

   `greeting/src/lib.rs`:

   ```rust
   #![no_std]

   pub fn greet(name: &str) {
       xbox360::dbg_println!("hello, {name}");
   }
   ```

   `rust_library` is a standard rule, so it needs no `load`. `target_compatible_with` tells Buck2 that the library only builds for the console. `buck2 build //...` then skips it on its own and builds it as part of each title that uses it. `visibility = ["PUBLIC"]` lets targets in other packages depend on it.

2. Copy `title/` to `hello/`. In `hello/BUCK`, rename the target and add the library to `deps`:

   ```python
   xbox360_title(
       name = "hello",
       # ...
       deps = [
           "//greeting:greeting",
           "//third-party/rust:xbox360",
       ],
   )
   ```

   Give `hello/xex.toml` a title ID of its own.

3. Call the library from `hello/src/main.rs`. The crate name is the target name, with `-` replaced by `_`:

   ```rust
   greeting::greet("console");
   ```

4. Build it:

   ```sh
   buck2 build //hello:hello --show-output
   ```

To build the library on its own, tell Buck2 to configure it for the console:

```sh
buck2 build //greeting:greeting --target-platforms xbox360//platforms:xbox360-core
```

A new DLL or system module works the same way. Copy `dll/` or `system-module/`, and give it its own name and load address.

## Adding a crates.io dependency

Buck2 does not read `Cargo.toml`. [Reindeer](https://github.com/facebookincubator/reindeer) bridges the two. It asks Cargo to resolve the dependencies in `third-party/rust/Cargo.toml` and writes a Buck2 target for each crate to `third-party/rust/BUCK`. Cargo records the exact versions and checksums in `third-party/rust/Cargo.lock`. Buck2 downloads each crate from crates.io when it first needs it and checks it against that checksum.

To add [heapless](https://crates.io/crates/heapless), for example:

1. Add it to `third-party/rust/Cargo.toml`, in the table of console dependencies:

   ```toml
   [target.'cfg(target_os = "xbox360")'.dependencies]
   heapless = "0.9"
   xbox360 = "0.2"
   xbox360-sys = "0.2"
   ```

   The table makes Cargo and reindeer resolve the crate's features and `cfg` dependencies for the console rather than for the host.

2. Regenerate the Buck2 targets:

   ```sh
   reindeer buckify
   ```

   You need `cargo` and `reindeer` on your `PATH` for this. The devenv shell has both.

3. If reindeer warns that the crate has a build script, tell it what to do with it in `third-party/rust/fixups/<crate>/fixups.toml`. Most build scripts only inspect the target and are safe to run:

   ```toml
   buildscript.run = true
   ```

   Run `reindeer buckify` again afterwards. The [reindeer documentation](https://github.com/facebookincubator/reindeer) describes the other fixups, such as for crates that compile C code.

4. Add `//third-party/rust:heapless` to the `deps` of each target that uses it.

5. Commit `Cargo.toml`, `Cargo.lock`, `BUCK` and any fixups together.

Only the crates listed in `third-party/rust/Cargo.toml` get a public label. Their own dependencies are built too, but you cannot depend on them directly. Buck2 builds each crate with every feature that `Cargo.toml` enables for it.

`buck2 build //...` also builds the public crates for the host. A crate that compiles only for the console breaks that command. Build the packages you need instead, for example `buck2 build //title/... //dll/... //system-module/...`, and use the same patterns in `.github/workflows/ci.yml`.

The crate has to support the console. Crates that are `no_std` or that use only the parts of the standard library this target has usually work. Crates with code for each operating system often do not, because they do not know `target_os = "xbox360"`. `third-party/rust/PACKAGE` makes reindeer's `cfg` evaluation for console builds match the console, so dependencies limited to Linux or Windows are left out.

To update a dependency, change its version in `Cargo.toml` or run `cargo update --manifest-path third-party/rust/Cargo.toml`, and then run `reindeer buckify`.

## Development environment

### Bootstrap scripts

`bin/buck2` runs the Buck2 release that `toolchains/buck2` pins. That file is a DotSlash file. It lists the URL, size and digest of the Buck2 build for each host. On its first run `bin/buck2` runs `bootstrap.sh` (`bootstrap.ps1` on Windows). The script downloads DotSlash into `.tools`, checks its SHA-256, fetches Buck2, and lists any host tools it could not find. You can run it yourself:

```sh
./bootstrap.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File bootstrap.ps1
```

The host must provide Git, Python 3.11 or later, and a C++ compiler; Windows
uses MSVC and the Windows SDK. The scripts check those requirements and fail
with the missing component. Buck2 downloads the pinned Rust release,
hash-pinned openxbdm host tools, and Rust crates. Python is not downloaded:
the build and run actions use the host interpreter.

### Nix devenv

If you use [Nix](https://nixos.org), `devenv shell` gives you a shell with `bin` on `PATH`, and with `cargo`, `rustc` and `reindeer` for `reindeer buckify`. It does not provide a C++ compiler. Buck2 uses the one your system has, so the host tools link against your system's C library.

### GitHub Actions

`.github/workflows/ci.yml` builds every target on Linux, macOS and Windows for each push to `main` and each pull request. The Linux job also checks that `third-party/rust/BUCK` matches `Cargo.toml`, and uploads the XEX files as an artifact named `xex`.

Building the standard library takes a few minutes, so the Linux and macOS jobs keep Buck2's results between runs. `ci/start-action-cache.sh` starts a local [bazel-remote](https://github.com/buchgr/bazel-remote) cache that `actions/cache` saves after each run on `main`. Pull requests read the latest one. Windows has no cache and builds from scratch.

### Updating the toolchain

The toolchain is the Xenon Forge repository at the commit in
`[external_cell_xbox360]` of `.buckconfig`. To update it, set `commit_hash`
to a newer Xenon Forge commit.

To build against your own Xenon Forge checkout, put it at `xenon-forge/`
in this repository and add this to `.buckconfig.local`:

```ini
[external_cells]
  xbox360 = disabled
```

The checkout must be a real directory, not a symbolic link, because Buck2 does not follow links out of the repository. Git ignores both files.

To move to another Buck2 release, replace `toolchains/buck2` with the `buck2` DotSlash file of that release:

```sh
curl -fsSL -o toolchains/buck2 https://github.com/facebook/buck2/releases/download/<tag>/buck2
```

To move to another DotSlash release, change the version and SHA-256 values in both bootstrap scripts.

## Repository layout

| Path | Contents |
| --- | --- |
| `title/`, `dll/`, `system-module/` | The examples. |
| `BUCK` | `//:title-directory`, the title with its DLL. |
| `third-party/rust/` | crates.io dependencies: `Cargo.toml`, `Cargo.lock`, and the generated `BUCK`. |
| `reindeer.toml` | Settings for `reindeer buckify`. |
| `toolchains/` | The Rust and C++ toolchains, from the xbox360 cell, and the pinned Buck2. |
| `platforms/` | The execution platform that CI uses with its action cache. |
| `bin/`, `bootstrap.sh`, `bootstrap.ps1` | Buck2 through DotSlash. |
| `ci/` | Scripts for the GitHub Actions workflow. |
| `devenv.nix`, `devenv.yaml`, `devenv.lock` | The Nix development shell. |
