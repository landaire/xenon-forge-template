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

The normal target uses the downloaded PPC32 Rust release. On x86_64 Linux, select the experimental PPC64-ILP32 platform to use the custom LLVM and Rust compiler:

```sh
bin/buck2 build //title:title \
  --target-platforms xbox360//platforms:ppc64 \
  --show-output
```

The first PPC64 build downloads the tested, hash-pinned LLVM and Rust toolchain archive. Set `ppc64_toolchain = source` under `[xbox360]` only when developing the compiler itself. Standalone host tools such as `xex-link` continue to use the downloaded host Rust release.

## The three kinds of XEX

The examples offer three different kinds of XEX setups, defined by its `module_flags` key of `xex.toml`.

| Kind          | Example                         | `module_flags`     | Loaded by                         | Runs in             | Entry point                        |
| ------------- | ------------------------------- | ------------------ | --------------------------------- | ------------------- | ---------------------------------- |
| Title         | `//title:title`                 | `["TITLE"]`        | The dashboard or another title    | Title address space | `_start(context)`, never returns   |
| DLL           | `//dll:dll`                     | `["TITLE", "DLL"]` | A title, with `XexLoadImage`      | The title process   | `_start(module, reason, reserved)` |
| System module | `//system-module:system-module` | `["DLL"]`          | The system, at boot or on request | The system process  | `_start(module, reason, reserved)` |

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

The Buck2 primer, dependency workflow, bootstrap details, and repository layout
are in [DEVELOPING.md](DEVELOPING.md).
