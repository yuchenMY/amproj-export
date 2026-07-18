.text
.p2align 2
.globl _AMProjCallNativePackageImport
_AMProjCallNativePackageImport:
    .cfi_startproc
    stp x29, x30, [sp, #-32]!
    .cfi_def_cfa_offset 32
    .cfi_offset x29, -32
    .cfi_offset x30, -24
    mov x29, sp
    str x20, [sp, #16]
    .cfi_offset x20, -16

    mov x9, x0
    // The verified Swift entry takes its storage reference in explicit x2 and
    // keeps the weak presentation owner in the hidden Swift x20 context. The
    // C adapter exposes that owner as its final argument (x7).
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    mov x4, x5
    mov x5, x6
    mov x20, x7
    blr x9

    ldr x20, [sp, #16]
    .cfi_restore x20
    ldp x29, x30, [sp], #32
    .cfi_restore x29
    .cfi_restore x30
    .cfi_def_cfa_offset 0
    ret
    .cfi_endproc

.subsections_via_symbols
