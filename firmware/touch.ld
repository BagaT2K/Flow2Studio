ENTRY(touch_packet)
SECTIONS {
 .text 0x08015000 : { *(.text*) *(.rodata*) }
 /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.comment*) }
 .data : { *(.data*) }
 .bss : { *(.bss*) *(COMMON) }
}
