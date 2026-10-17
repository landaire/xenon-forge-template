//! A title that uses the standard library. It starts a thread, loads the DLL
//! that `//dll:dll` builds from the directory it was launched from, and ends.

#![no_main]

use std::ffi::CStr;
use std::thread;

use xbox360::module;
use xbox360::module::ImageFlags;
use xbox360::title;

// The kernel enters `_start` with the console calling convention, so it runs
// `main` behind the entry bridge of xbox360-sys.
xbox360::sys::bridged!(#[unsafe(no_mangle)] pub _start, main);

extern "C" fn main(_context: u32) -> u32 {
    // `game:` is the directory the title was launched from.
    // `//:title-directory` puts the DLL there under this name.
    const DLL_PATH: &CStr = c"game:\\dll.xex";

    println!("title: started");

    let worker = thread::spawn(|| (1..=10u32).sum::<u32>());
    match worker.join() {
        Ok(sum) => println!("title: worker thread returned {sum}"),
        Err(_) => println!("title: worker thread panicked"),
    }

    // SAFETY: the DLL is built from this repository, and its entry point
    // only writes to the debug output.
    match unsafe { module::load_image(DLL_PATH, ImageFlags::DLL, None) } {
        Ok(dll) => {
            println!("title: loaded {}", DLL_PATH.to_string_lossy());

            // Unloading runs the DLL's entry point again with ProcessDetach.
            if let Err(error) = dll.unload() {
                println!("title: unloading the DLL failed: {error:?}");
            }
        }
        Err(error) => println!("title: loading the DLL failed: {error:?}"),
    }

    // A title must not return from its entry point.
    title::terminate()
}
