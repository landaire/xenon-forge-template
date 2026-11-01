# Xenon Forge template

A starting point for Xbox 360 software written in Rust with the [Xenon Forge](https://github.com/landaire/xenon-forge) toolchain.

## tl;dr

- `bin/buck2 build //...` builds three XEX files: a title, a DLL that the title loads, and a system module.
- `bin/buck2 run //title:title` deploys and launches the title on a configured devkit.
- You don't need to install Rust or Buck2 yourself. The first build downloads everything it needs and checks each download against a pinned hash.
- Each example is a directory with a `BUCK` file, a linker script, an `xex.toml`, a Cargo manifest for editor support, and Rust sources. Copy one to start your own.
- crates.io dependencies go in `third-party/rust/Cargo.toml`. Run [`reindeer buckify`](https://github.com/facebookincubator/reindeer) after you change it.
- A Nix [devenv](https://devenv.sh) shell, bootstrap scripts for Linux, macOS and Windows, and a GitHub Actions workflow are included.

## Getting started

You need a few host tools. Everything else is downloaded by the build.

- `git`, `curl` and `tar`.
- A C++ linker driver for the host tools of the toolchain, such as `xex-link`. Use GCC or Clang on Linux, the Xcode command line tools on macOS, or Visual Studio Build Tools with the C++ workload on Windows.
- On Windows, long paths enabled. Buck2's output paths exceed 260 characters.

Build every target:

```sh
bin/buck2 build //... --show-output
```

On Windows, run `bin\buck2.cmd` in place of `bin/buck2`. You can also add `bin` to your `PATH` and run `buck2`.

The first run takes a few minutes. It downloads [DotSlash](https://dotslash-cli.com), [Buck2](https://buck2.build), a Rust release, and the toolchain, and then compiles the Rust standard library for the console. Later builds reuse all of it.

`--show-output` prints where each XEX was written, under `buck-out`. To copy outputs somewhere else, use `--out`:

```sh
buck2 build //:title-directory --out out/title
buck2 build //system-module:system-module --out out/system-module.xex
```

`//:title-directory` is a directory with the title as `default.xex` and the DLL next to it as `dll.xex`. That is the layout the title expects when it loads the DLL.

### Running

Copy the title directory to the console and launch `default.xex`. Output from `println!` and `dbg_println!` goes to the debug output, which you can read with a debug monitor client such as [xeedee](https://github.com/landaire/xeedee).

[Xenia](https://xenia.jp) runs titles too, with some gaps. Xenia does not provide `ExAllocatePoolWithTag`, which the standard library allocates with, so a title that allocates on the heap will crash. It also does not implement the `mcrf` instruction, which some of `core`'s integer formatting uses. Xenia's `--break_on_unimplemented_instructions=false` skips the instruction instead of stopping, and the results of that code are then wrong. `tools/run-xenia.sh` in the Xenon Forge repository shows how to run a XEX headless.

### Deploying and debugging

Configure the console that runs XBDM in `.buckconfig.local`:

```ini
[xbox360]
  console_xbdm = deanxbox
```

Then deploy and launch the title. Arguments after `--` become its command
line:

```sh
bin/buck2 run //title:title -- first "second argument"
```

The default remote directory is
`DEVKIT:\<project-directory>\<target-name>`. Set `deploy_directory` under
`[xbox360]` to override the base directory. Xenon Forge downloads
hash-pinned `xeedee` and `openxbdm-kd` releases for supported hosts; set
`xbdm_tool` or `kd_tool` only to override them.

With kdnet enabled, `[debug]` deploys the title, starts the kernel debugger,
holds the title before its entry point, and opens GDB:

```sh
bin/buck2 run //title:title[debug]
```

`[debug-server]` performs the same deployment and load stop but leaves the
GDB remote server at `127.0.0.1:2159`. `[vscode]` emits a VS Code workspace
with the deployment task, GDB launch configuration, and Rust Analyzer
project:

```sh
code "$(bin/buck2 build //title:title[vscode] --show-simple-output)"
```

Set `console_kd_target`, `gdb_tool`, or `gdb_listen` under `[xbox360]` to
override debugger defaults.

### PPC64-ILP32

The normal target uses the downloaded PPC32 Rust release. On x86_64 Linux,
select the experimental PPC64-ILP32 platform to build the custom LLVM and
Rust compiler, then compile the same title with it:

```sh
bin/buck2 build //title:title \
  --target-platforms xbox360//platforms:ppc64 \
  --show-output
```

The first PPC64 build compiles LLVM, clang, LLD, and rustc from source.
Later builds reuse that build tree. Standalone host tools such as
`xex-link` continue to use the downloaded host Rust release.

## The three kinds of XEX

The examples offer three different kinds of XEX setups, defined by its `module_flags` key of `xex.toml`.

| Kind | Example | `module_flags` | Loaded by | Runs in | Entry point |
| --- | --- | --- | --- | --- | --- |
| Title | `//title:title` | `["TITLE"]` | The dashboard or another title | Title address space| `_start(context)`, never returns |
| DLL | `//dll:dll` | `["TITLE", "DLL"]` | A title, with `XexLoadImage` | The title process | `_start(module, reason, reserved)` |
| System module | `//system-module:system-module` | `["DLL"]` | The system, at boot or on request | The system process | `_start(module, reason, reserved)` |

All three are built with the same Buck2 macro, `xbox360_title`.

### Under the Hood

`xbox360_title` compiles a Rust binary crate for `powerpc-unknown-xbox360`, links it with the linker script you pass, and converts the result to a XEX with `xex-link` and the metadata in your manifest.

The kernel calls every entry point with the console calling convention. Rust code for this target saves only the low half of the registers that convention preserves. So every entry point the kernel calls goes through `xbox360::sys::bridged!`, which wraps a Rust function in an entry that preserves them:

```rust
xbox360::sys::bridged!(#[unsafe(no_mangle)] pub _start, main);
```

Thread start routines and anything else the kernel calls need the same treatment.

### Titles

A title is a process which takes over main execution on the console (games, apps, whatever). `title/` is a title that uses the standard library. It starts a thread, loads the DLL, and ends:

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
    link_script = "link.x",
    manifest = "xex.toml",
    rust_project = "Cargo.toml",
    std = True,
    rewrite = True,
    deps = ["//third-party/rust:xbox360"],
    visibility = ["PUBLIC"],
)
```

`std = True` gives the crate the standard library, with `std::thread`, `std::net`, `std::fs`, allocation and `println!`. Without it the crate is `#![no_std]` and has `core`. It can use `alloc` too once it installs a `#[global_allocator]`, such as `xbox360::pool::PoolAllocator`. Use the standard library in titles when you can.

Its `xex.toml` needs little more than a title ID.

```toml
title_id = 0x58580001
version = "1.0.0.0"
```

The image is linked at 0x82000000, the default load address. `title/link.x` places the code at 0x82010000 because the first 64 KB hold the headers.

### DLLs

A DLL is code that a title loads into its own process at run time. `dll/` prints a line when it is loaded and when it is unloaded:

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

The title loads it with `xbox360::module::load_image`, and dropping or unloading the returned image unloads the DLL:

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

Each DLL needs its own address range. It must not overlap the title or any other DLL the title loads. The same address goes in `load_address` and in `link.x`. `tls_slots = 0` keeps the 64 thread-local storage slots of a title out of the DLL.

`xex-link` writes an export table only for the system modules listed under System modules below. So a DLL cannot export functions for the title to call by ordinal. It can still run code from its entry point, for example to start threads.

### System modules

A system module runs in the system process rather than in a title. It stays loaded when titles change. A debug monitor such as `xbdm.xex` is one. `system-module/` uses the standard library and starts a thread when it is loaded:

```rust
#![feature(xbox360_ext)]

extern "C" fn module_main(_module: u32, reason: u32, _reserved: u32) -> Boolean {
    let loaded = match DllEntryReason::from_raw(reason) {
        Some(DllEntryReason::ProcessAttach) => thread::Builder::new().spawn(worker).is_ok(),
        Some(DllEntryReason::ProcessDetach) => {
            // SAFETY: the worker has ended, and nothing of this module runs
            // after the entry point returns.
            unsafe { std::os::xbox360::release_tls_slots() };
            true
        }
        // ...
    };

    Boolean::from(loaded)
}
```

Its `BUCK` file sets `std = "system"` instead of `std = True`. That selects the standard library for system modules, which differs from a title's in two ways:

- `std::thread` starts threads in the system process, where they keep running when the title exits. A title's standard library starts them in the title process.
- Sockets belong to the system rather than to the running title. They can send datagrams to, open connections with, and accept connections from any host.

With `std = True`, a system module still builds and runs. Its threads then end with the title, and its sockets are the title's.

#### Working in the title's context

A module can mix the two contexts. With `std = "system"`, `std` works in the system context, and the `xbox360` crate reaches the title's. A thread from `xbox360::thread` starts in the title process, because it passes no process flag to the kernel. It ends when the title exits:

```rust
extern "C" fn title_worker(_argument: u32) -> u32 {
    0
}

xbox360::thread_entry!(TITLE_WORKER = title_worker);

let thread = xbox360::thread::spawn_entry(TITLE_WORKER, 0)?;
```

A socket of the title is a raw `xbox360::sys::xam` socket that passes `XnCaller::Title` to every call. Start the title's network stack for that caller once before the first socket:

```rust
use xbox360::sys::xam;
use xbox360::sys::xam::XnCaller;

let mut params = xam::XnetStartupParams::new();
params.flags = xam::XnetStartupFlags::BYPASS_SECURITY;
let mut data = xam::WsaData::new();

// SAFETY: `params` and `data` are live locals of the types the calls take.
let socket = unsafe {
    xam::NetDll_XNetStartup(XnCaller::Title, &params);
    xam::NetDll_WSAStartup(XnCaller::Title, xam::WinsockVersion::new(2, 2), &mut data);
    xam::NetDll_socket(XnCaller::Title, xam::AddressFamily::Inet, xam::SocketType::Datagram, xam::Protocol::Udp)
};
```

Both were tested from a system module on a development kit. The thread ran in the title process, and the datagram arrived from the console's title address.

It also works the other way round. With `std = True`, `std` works in the title's context, and `xbox360::sys` reaches the system's:

- `xbox360::sys::xboxkrnl::ExCreateThread` with `ThreadCreationFlags::SYSTEM_PROCESS` starts a thread in the system process. Its start routine must be a `bridged!` entry, as `_start` is.
- A socket with `XnCaller::SystemApp` belongs to the system. It needs SOL_SOCKET option `0x5801` set to 1 with `NetDll_setsockopt` before it can reach ordinary hosts, which is what the standard library for system modules does for each socket.

`std::thread` gives each thread a 256 KB stack. Memory in the system process is shared with every title, so set a smaller one with `std::thread::Builder::stack_size` where you can.

The manifest:

```toml
load_address = 0x91c00000
image_flags = ["SMALL_PAGES"]
module_flags = ["DLL"]
```

System modules live between 0x90000000 and 0x9fffffff on 4 KB pages. That is why the image has `SMALL_PAGES` and why `system-module/link.x` aligns sections to 4 KB instead of 64 KB. Pick an address that no other system module uses. `xbdm.xex` is at 0x91f00000 and the system shell at 0x92000000.

On a development kit, `println!`, allocation, `thread_local!`, `std::thread` with `join`, `Mutex`, `sleep`, `Instant`, `std::fs`, UDP and TCP all worked in a system module, with no `tls_slots` in the manifest. Nothing in the standard library for system modules depends on the debug monitor, but it has not been tested on a retail console.

The standard library takes thread-local storage slots of the system process, which never exits. On a development kit, 29 slots were free after a boot, and each load of the example took 5. A module that keeps its slots runs the system out of them after a few loads, and the next load stops the console with a crash dump. So the module returns them when it unloads, with `std::os::xbox360::release_tls_slots()`, as the example does. On a development kit, the example loaded and unloaded 10 times in a row, and all 29 slots were free afterwards. The function is unstable, so the crate needs `#![feature(xbox360_ext)]`. Call it last, after every thread of the module has ended, because no thread local of the module may be used after it.

Do not wait in the entry point for a thread that the module starts. On a development kit, a module that did so never finished loading, and the debug monitor stopped answering until the console restarted.

The standard library makes the image larger. The example is 53 KB with it, and 28 KB as a `#![no_std]` module that does the same with the [`xbox360`](https://crates.io/crates/xbox360) crate. For a `#![no_std]` module, use `xbox360` for threads, locks, time and debug output, and [`xbox360-sys`](https://crates.io/crates/xbox360-sys) for raw kernel and XAM calls.

A title cannot load a system module. `XexLoadImage` from a title fails with `STATUS_ACCESS_DENIED`. On a development kit, the debug monitor can load one for you. Copy the module to `DEVKIT:\DMEXT\` and send the XBDM command `dbgextld name=<file>`, for example with xeedee:

```sh
xeedee -H <console> file put system-module.xex 'DEVKIT:\DMEXT\system-module.xex'
xeedee -H <console> raw 'dbgextld name=system-module.xex'
```

The monitor holds one extension at a time. `dbgextld unload module=<handle>` unloads it, with the handle that the load printed. Do not unload a module whose threads are still running its code.

A system module can export functions. Declare each export with `xbox360::sys::export!(ORDINAL, function)` and keep the `.xexports` section in the linker script. Then name the module it replaces in the manifest, which must be `xboxkrnl.exe`, `xam.xex` or `xbdm.xex`, and give it the version of that module:

```toml
version = "2.0.21256.0"

[exports]
module = "xbdm.xex"
```

The export table records `version`, and `xex-link` rejects a version below `min_version` of `[exports]`, which is 2.0.1861.0 by default. The load address of a module with exports must be a multiple of 64 KB.

## Notes for all console code

- A `no_std` crate needs a `#[panic_handler]`. The DLL example prints the panic message and then ends the title.
- A `std` crate aborts after a panic, with a trap. In the system process that stops the console, so the system module example installs a panic hook with `std::panic::set_hook` that prints the message and parks the thread.
- Every linker script must keep `.xthunks` (import thunks) on executable pages and collect `.xvars` (data imports). Copy one of the examples.
- `rewrite = True` makes the image smaller. It replaces the register saves and restores in each function with calls to shared routines, as Microsoft's compiler does. The build fails if the relinked image differs from the one rustc links, or if a sequence the rewrite handles remains.
- With `rewrite = True` a target has subtargets for the intermediate files. For example, `buck2 build //title:title[disassembly] --show-output` prints the path of the disassembly. Others are `[asm]`, `[elf]`, `[rewrite-report]` and `[refusals]`.
- Every build fails if the image contains a reservation instruction (`lwarx`, `stwcx.`) outside the interrupt-protected form. The kernel loader reports the unprotected form. Use the atomics in `core`, which the toolchain builds in the protected form, or `xbox360::atomic`.
- The full list of manifest keys is in the [Xenon Forge README](https://github.com/landaire/xenon-forge#xex-link).

## Release builds

Every console build is already a release build. There is no separate debug configuration and no flag to pass. The toolchain compiles every console crate, the standard library included, with `-Copt-level=z` and one code generation unit, and strips the symbols from the image. `rewrite = True` adds fat LTO. rustc turns off debug assertions and overflow checks at any optimization level above 0, so they are off too. The XEX that `buck2 build` writes is the one you ship.

To turn the checks on for one target while you develop, add a rustc flag to it in its `BUCK` file:

```python
xbox360_title(
    name = "title",
    # ...
    rustc_flags = ["-Cdebug-assertions=on"],
)
```

The flag turns on overflow checks too. It applies to that crate only, not to the standard library or to the crates it depends on. To change every console crate, the standard library included, pass the flags as `xbox360_rustc_flags` to `xbox360_toolchains()` in `toolchains/BUCK`. Buck2 then rebuilds the standard library with them.

To optimize a target for speed instead of size, add `"-Copt-level=3"` to its `rustc_flags`. A later `-Copt-level` replaces the toolchain's.

To make the XEX file smaller, set `compress = true` in its `xex.toml`. `xex-link` then compresses the image with LZX.

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
