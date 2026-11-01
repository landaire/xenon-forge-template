# Xenon Forge template development guide

## Buck2 in five minutes

Buck2 builds targets from a dependency graph and caches the results.

A few terms:

- A *target* is one thing Buck2 can build, such as a XEX or a Rust library.
- A *`BUCK` file* declares the targets of the directory it is in. A directory with a `BUCK` file is a *package*.
- A *label* names a target. `//title:title` is the target `title` in the package `title/`. When a target has the name of its directory you can shorten its label, so `//title` means `//title:title`.
- A *pattern* names many targets. `//...` is every target in this repository. `//title/...` is every target under `title/`.
- A *cell* is a separate target tree. `xbox360//` is the pinned Xenon Forge checkout, `prelude//` provides standard rules, and `toolchains//` is this repository's `toolchains/`.
- `load("@xbox360//buck:xex.bzl", "xbox360_title")` imports a rule from the Xenon Forge cell.

Buck2 uses a background daemon. Run `buck2 kill` after changing environment variables such as `PATH`.

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

   `target_compatible_with` limits the library to console builds. `visibility = ["PUBLIC"]` allows other packages to use it.

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

[Reindeer](https://github.com/facebookincubator/reindeer) converts dependencies from `third-party/rust/Cargo.toml` into Buck targets. `Cargo.lock` pins their versions and checksums.

To add [heapless](https://crates.io/crates/heapless), for example:

1. Add it to `third-party/rust/Cargo.toml`, in the table of console dependencies:

   ```toml
   [target.'cfg(target_os = "xbox360")'.dependencies]
   heapless = "0.9"
   xbox360 = "0.2"
   xbox360-sys = "0.2"
   ```

   This table resolves the crate for the console target.

2. Regenerate the Buck2 targets:

   ```sh
   reindeer buckify
   ```

   You need `cargo` and `reindeer` on your `PATH` for this. The devenv shell has both.

3. Add build-script fixups under `third-party/rust/fixups/<crate>/fixups.toml` when required, then run `reindeer buckify` again. For example:

   ```toml
   buildscript.run = true
   ```

   See the [reindeer documentation](https://github.com/facebookincubator/reindeer) for other fixups.

4. Add `//third-party/rust:heapless` to the `deps` of each target that uses it.

5. Commit `Cargo.toml`, `Cargo.lock`, `BUCK` and any fixups together.

Only direct dependencies from `third-party/rust/Cargo.toml` receive public Buck labels.

Console-only crates may break `buck2 build //...`, which also builds public crates for the host. Build the required package patterns instead.

Crates must support `target_os = "xbox360"`. After changing dependencies, run `reindeer buckify`.

## Development environment

### Bootstrap scripts

`bin/buck2` uses the DotSlash-pinned Buck2 release in `toolchains/buck2`. On first use, the bootstrap script installs DotSlash and fetches Buck2:

```sh
./bootstrap.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File bootstrap.ps1
```

The host must provide Git, Python 3.11 or later, and a C++ compiler. Windows also needs MSVC and the Windows SDK. Buck2 downloads the pinned Rust release, openxbdm tools, and crates.

### Nix devenv

`devenv shell` provides Cargo, rustc, and Reindeer. Buck2 still uses the host C++ compiler.

### GitHub Actions

CI builds on Linux, macOS, and Windows. Linux and macOS cache Buck2 results; Windows builds from scratch.

### Updating the toolchain

Update the Xenon Forge `commit_hash` in `.buckconfig`. For a local checkout, place Xenon Forge at `xenon-forge/` and disable the external cell in `.buckconfig.local`:

```ini
[external_cells]
  xbox360 = disabled
```

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
