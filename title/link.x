ENTRY(_start)

/* Image base 0x82000000, the default load_address of xex-link. The first
   64 KB hold the PE headers. Sections are 64 KB-aligned so that each page has
   uniform attributes, which the hardware requires. .xthunks is on the
   executable .text pages because the loader patches each import thunk in
   place. */
SECTIONS {
    . = 0x82010000;
    .text : {
        *(.text._start)
        *(.text .text.*)
    }
    . = ALIGN(4);
    .xthunks : { *(.xthunks .xthunks.*) }

    . = ALIGN(0x10000);
    .rodata : { *(.rodata .rodata.*) }

    . = ALIGN(0x10000);
    .data : { *(.data .data.*) *(.sdata .sdata.*) }
    . = ALIGN(4);
    .xvars : { *(.xvars .xvars.*) }

    . = ALIGN(0x10000);
    .bss : { *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) }

    /DISCARD/ : { *(.eh_frame) *(.eh_frame_hdr) *(.comment) *(.note .note.*) }
}
