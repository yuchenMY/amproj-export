.text
.p2align 2
.globl _AMProjCallNativePackageImportBody
_AMProjCallNativePackageImportBody:
    .cfi_startproc
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    mov x29, sp

    mov x10, x0
    // The C adapter has one leading function pointer, so shift the first seven
    // native arguments down one register. The eighth native argument is the
    // adapter's ninth C argument and therefore arrives on the caller's stack.
    ldr x11, [x29, #16]
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    mov x4, x5
    mov x5, x6
    mov x6, x7
    mov x7, x11
    blr x10

    ldp x29, x30, [sp], #16
    .cfi_restore x29
    .cfi_restore x30
    .cfi_def_cfa_offset 0
    ret
    .cfi_endproc

.subsections_via_symbols
