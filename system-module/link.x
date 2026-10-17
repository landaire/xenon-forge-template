ENTRY(_start)

/* Image base 0x91c00000 (load_address in xex.toml). The first 4 KB hold the
   PE headers. Sections are 4 KB-aligned, the page size of a SMALL_PAGES
   image. .xthunks is on the executable .text pages because the loader
   patches each import thunk in place. */
SECTIONS {
    . = 0x91c01000;
    .text : {
        *(.text._start)
        *(.text .text.*)
    }
    . = ALIGN(4);
    .xthunks : { *(.xthunks .xthunks.*) }

    . = ALIGN(0x1000);
    .rodata : { *(.rodata .rodata.*) }

    . = ALIGN(0x1000);
    .data : { *(.data .data.*) *(.sdata .sdata.*) }
    . = ALIGN(4);
    .xvars : { *(.xvars .xvars.*) }

    . = ALIGN(0x1000);
    .bss : { *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) }

    /* Export records (xbox360_sys::export!): read by xex-link, not loaded. */
    . = ALIGN(4);
    .xexports : { KEEP(*(.xexports)) }

    /DISCARD/ : { *(.eh_frame) *(.eh_frame_hdr) *(.comment) *(.note .note.*) }
}
