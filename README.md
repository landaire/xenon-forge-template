# Xenon Forge template

A starting point for Xbox 360 software with the [Xenon Forge](https://github.com/landaire/xenon-forge) toolchain.

## Getting started

You should start by reading the [xenon-forge README](https://github.com/landaire/xenon-forge/blob/main/README.md). It covers some important info about how the toolchain works, grabs dependencies, etc.

To reiterate a couple of key points:

1. We have a custom LLVM toolchain and Rust standard library modifications (if using Rust). These are **optional**.
2. There are some parts of the toolchain written in Rust or requires additional tooling. These will be fetched and managed automatically.
3. There are some prerequisite host tools.

You should really read that doc if you decided to skip it.

### Using the Toolchain

Build every target:

```sh
bin/buck2 build //... --show-output
```

On Windows, run `bin\buck2.cmd` in place of `bin/buck2`. You can also add `bin` to your `PATH` and run `buck2`.

The first run takes a few minutes as it sets up tools.

`--show-output` prints where each XEX was written, under `buck-out`. To copy outputs somewhere else, use `--out`:

```sh
buck2 build //:title-directory --out out/title
buck2 build //system-module:system-module --out out/system-module.xex
```

`//:title-directory` is a directory with the title as `default.xex` and the DLL next to it as `dll.xex`. That is the layout the title expects when it loads the DLL.

### Run and debug

Set the console name or IP in `.buckconfig.local`:

```ini
[xbox360]
  console_xbdm = "deanxbox"
```

Then deploy and launch a title:

```sh
bin/buck2 run //title:title -- first "second argument"
```

Arguments after `--` become the title command line. Xenon Forge downloads the [deployment tools](https://github.com/landaire/openxbdm) automatically and uses `DEVKIT:\<project-directory>\<target-name>` by default.

With kdnet enabled, use the `debug` subtarget to deploy, stop before the title entry point, and open GDB:

```sh
bin/buck2 run //title:title[debug]
```

The same debugger subtargets work for `xbox360_c_title` C and C++ targets.
The `vscode` subtarget emits a workspace with the deployment task and debugger
configuration, adding a Rust Analyzer project for Rust targets:

```sh
code "$(bin/buck2 build //title:title[vscode] --show-simple-output)"
```

See Xenon Forge's [advanced usage](https://github.com/landaire/xenon-forge#advanced-usage) for tool overrides, deployment paths, and debugger settings.

### PPC64-ILP32

The normal target uses the downloaded PPC32 Rust release. On x86_64 Linux, select the experimental PPC64-ILP32 code generation to use the custom LLVM and Rust compiler:

```sh
bin/buck2 build -m ppc64-ilp32 //title:title --show-output
```

The first PPC64 build downloads a hash-pinned LLVM and Rust toolchain. Set `ppc64_toolchain = source` under `[xbox360]` only when working on the compiler.

## The three kinds of XEX

The examples offer three different kinds of XEX setups, defined by its `module_flags` key of `xex.toml`.

| Kind          | Example                         | `module_flags`     | Loaded by                         | Runs in             | Entry point                        |
| ------------- | ------------------------------- | ------------------ | --------------------------------- | ------------------- | ---------------------------------- |
| Title         | `//title:title`                 | `["TITLE"]`        | The dashboard or another title    | Title address space | `_start(context)`, never returns   |
| DLL           | `//dll:dll`                     | `["TITLE", "DLL"]` | A title, with `XexLoadImage`      | The title process   | `_start(module, reason, reserved)` |
| System module | `//system-module:system-module` | `["DLL"]`          | The system, at boot or on request | The system process  | `_start(module, reason, reserved)` |

All three are built with the same Buck2 macro, `xbox360_title`.

### Under the Hood

`xbox360_title` compiles and links the crate, then runs `xex-link`. Entry points called by the kernel must use `xbox360::sys::bridged!`:

```rust
xbox360::sys::bridged!(#[unsafe(no_mangle)] pub _start, main);
```

This also applies to thread entry points.

### Titles

A title owns the active title process. The example uses `std`, starts a thread, loads the DLL, and terminates:

```rust
#![no_main]

use xbox360::title;

xbox360::sys::bridged!(#[unsafe(no_mangle)] pub _start, main);

extern "C" fn main(_context: u32) -> u32 {
    println!("title: started");

    let worker = std::thread::spawn(|| (1..=10u32).sum::<u32>());
    // ...

    // A title must not return from its entry point.
    title::terminate()
}
```

Its `BUCK` file:

```python
load("@xbox360//buck:xex.bzl", "xbox360_title")

xbox360_title(
    name = "title",
    srcs = glob(["src/**/*.rs"]),
    crate_root = "src/main.rs",
    edition = "2024",
    manifest = "xex.toml",
    rust_project = "Cargo.toml",
    std = True,
    rewrite = True,
    deps = ["//third-party/rust:xbox360"],
    visibility = ["PUBLIC"],
)
```

`std = True` enables the standard library. Without it, the crate is `#![no_std]`; `alloc` is available after installing a global allocator.

Its `xex.toml` needs little more than a title ID.

```toml
title_id = 0x58580001
version = "1.0.0.0"
```

The image is linked at 0x82000000, the default load address. xex-link derives the link script from `xex.toml`: code starts at 0x82010000 because the first 64 KB hold the headers. A target can set `link_script` to use its own.

### DLLs

A DLL runs inside its title's process. The example logs its load and unload events:

```rust
#![no_std]
#![no_main]

use xbox360::dbg_println;
use xbox360::sys::xboxkrnl::Boolean;
use xbox360::sys::xboxkrnl::DllEntryReason;

xbox360::sys::bridged!(#[unsafe(no_mangle)] pub _start, dll_main);

extern "C" fn dll_main(_module: u32, reason: u32, _reserved: u32) -> Boolean {
    match DllEntryReason::from_raw(reason) {
        Some(DllEntryReason::ProcessAttach) => dbg_println!("dll: attached"),
        Some(DllEntryReason::ProcessDetach) => dbg_println!("dll: detached"),
        _ => {}
    }

    // Returning false makes the load fail.
    Boolean::from(true)
}
```

The title loads it with `xbox360::module::load_image`; dropping or unloading the returned image unloads the DLL:

```rust
let result = unsafe { module::load_image(c"game:\\dll.xex", ImageFlags::DLL, None) };
```

`game:` is the directory the title was launched from.

The manifest is what makes it a DLL:

```toml
load_address = 0x88000000
module_flags = ["TITLE", "DLL"]
tls_slots = 0
```

Each DLL needs a non-overlapping address range, set by `load_address`. `tls_slots = 0` avoids reserving the title's TLS slots. DLLs cannot export functions by ordinal, but their entry point can start threads or initialize shared state.

### System modules

A system module runs in the system process and remains loaded across title changes. The example uses `std` and starts a worker thread:

```rust
#![feature(xbox360_ext)]

extern "C" fn module_main(_module: u32, reason: u32, _reserved: u32) -> Boolean {
    let loaded = match DllEntryReason::from_raw(reason) {
        Some(DllEntryReason::ProcessAttach) => thread::Builder::new().spawn(worker).is_ok(),
        Some(DllEntryReason::ProcessDetach) => {
            // SAFETY: the worker has stopped.
            unsafe { std::os::xbox360::release_tls_slots() };
            true
        }
        // ...
    };

    Boolean::from(loaded)
}
```

Set `std = "system"` so standard-library threads and sockets belong to the system process rather than the active title.

The manifest uses small pages and an address in the system-module range:

```toml
load_address = 0x91c00000
image_flags = ["SMALL_PAGES"]
module_flags = ["DLL"]
```

Choose an unused address between `0x90000000` and `0x9fffffff`. Keep it clear of `xbdm.xex` at `0x91f00000` and the system shell at `0x92000000`.

Before unloading a `std` system module, stop its threads and call `std::os::xbox360::release_tls_slots()` as its final operation. This requires `#![feature(xbox360_ext)]`. Do not wait for worker threads from the module entry point.

A title cannot load a system module. On a development kit, copy it to `DEVKIT:\DMEXT\` and load it through XBDM:

```sh
xeedee -H <console> file put system-module.xex 'DEVKIT:\DMEXT\system-module.xex'
xeedee -H <console> raw 'dbgextld name=system-module.xex'
```

Do not unload a module while its code is still running. For exports and other manifest options, see the [Xenon Forge documentation](https://github.com/landaire/xenon-forge#xex-link).

## Notes for all console code

- `no_std` crates need a panic handler. `std` aborts after a panic.
- A custom `link_script` must place `.xthunks` and `.xvars` as the derived one does (`xex-link link-script link.x --manifest xex.toml` writes it).
- `rewrite = True` optimizes register saves and restores. Its intermediate outputs are available through subtargets such as `[asm]`, `[elf]`, and `[disassembly]`.
- Builds reject unsafe reservation instructions. Use `core` atomics or `xbox360::atomic`.
- The [Xenon Forge README](https://github.com/landaire/xenon-forge#xex-link) lists all manifest keys.

## Build modes

Builds are in `dev` mode by default: console Rust compiles with `-Copt-level=0` and debug information. `release` optimizes for size and keeps debug information in the ELF; `release-no-symbols` drops it. The standard library is optimized in every mode. Select a mode with a modifier, which `PACKAGE` enables, or with a mode file:

```sh
bin/buck2 build -m release //title:title
bin/buck2 build @xbox360//mode/release //title:title
```

Enable assertions for one target with:

```python
xbox360_title(
    name = "title",
    # ...
    rustc_flags = ["-Cdebug-assertions=on"],
)
```

Use `xbox360_rustc_flags` in `toolchains/BUCK` to change every console crate. Use `-Copt-level=3` to optimize for speed, or `compress = true` in `xex.toml` to LZX-compress the XEX.

The Buck2 primer, dependency workflow, bootstrap details, and repository layout
are in [DEVELOPING.md](DEVELOPING.md).
