//! A system module that uses the standard library. The system loads it into
//! the system process, where its threads keep running when titles change.

#![no_main]
// `std::os::xbox360`, for `release_tls_slots`.
#![feature(xbox360_ext)]

use std::os::xbox360::release_tls_slots;
use std::panic;
use std::panic::PanicHookInfo;
use std::thread;
use std::time::Duration;

use xbox360::sys::xboxkrnl::Boolean;
use xbox360::sys::xboxkrnl::DllEntryReason;

// The loader enters `_start` with the console calling convention, so it runs
// `module_main` behind the entry bridge of xbox360-sys.
xbox360::sys::bridged!(#[unsafe(no_mangle)] pub _start, module_main);

/// The return value of a load: false makes the load fail.
extern "C" fn module_main(_module: u32, reason: u32, _reserved: u32) -> Boolean {
    let loaded = match DllEntryReason::from_raw(reason) {
        Some(DllEntryReason::ProcessAttach) => {
            panic::set_hook(Box::new(park_on_panic));
            start_worker()
        }
        Some(DllEntryReason::ProcessDetach) => {
            println!("system-module: detached");

            // The system process never exits, so the thread-local storage
            // slots of this module's standard library go back to it here.
            // SAFETY: the worker thread has ended, and nothing of this module
            // runs after the entry point returns.
            unsafe { release_tls_slots() };
            true
        }
        // Other reasons need no work.
        _ => true,
    };

    Boolean::from(loaded)
}

/// `std = "system"` in BUCK builds this crate against the standard library of
/// system modules, which starts the thread in the system process.
fn start_worker() -> bool {
    // The default stack of 256 KB comes out of memory that every title shares.
    const STACK_SIZE: usize = 64 * 1024;

    match thread::Builder::new().stack_size(STACK_SIZE).spawn(worker) {
        Ok(_) => true,
        Err(error) => {
            println!("system-module: starting the worker thread failed: {error}");
            false
        }
    }
}

fn worker() {
    println!("system-module: worker thread started");
    thread::sleep(Duration::from_secs(1));
    println!("system-module: worker thread ended");
}

/// After a panic the standard library aborts with a trap, which in the system
/// process stops the console. Parking the thread keeps the console running.
fn park_on_panic(info: &PanicHookInfo<'_>) {
    println!("system-module: {info}");

    loop {
        thread::sleep(Duration::from_secs(3600));
    }
}
