//! A DLL that a title loads with `XexLoadImage`. The loader calls its entry
//! point when the title loads it and again when the title unloads it.

#![no_std]
#![no_main]

use core::panic::PanicInfo;

use xbox360::dbg_println;
use xbox360::sys::xboxkrnl::Boolean;
use xbox360::sys::xboxkrnl::DllEntryReason;
use xbox360::title;

// The loader enters `_start` with the console calling convention, so it runs
// `dll_main` behind the entry bridge of xbox360-sys.
xbox360::sys::bridged!(#[unsafe(no_mangle)] pub _start, dll_main);

/// The return value of a load: false makes the load fail.
extern "C" fn dll_main(_module: u32, reason: u32, _reserved: u32) -> Boolean {
    match DllEntryReason::from_raw(reason) {
        Some(DllEntryReason::ProcessAttach) => dbg_println!("dll: attached"),
        Some(DllEntryReason::ProcessDetach) => dbg_println!("dll: detached"),
        // Other reasons need no work.
        _ => {}
    }

    Boolean::from(true)
}

/// The DLL runs in the title's process, so a panic ends the title.
#[panic_handler]
fn panic(info: &PanicInfo<'_>) -> ! {
    dbg_println!("dll: {info}");
    title::terminate()
}
