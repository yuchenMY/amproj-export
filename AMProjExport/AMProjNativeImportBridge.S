.text
.p2align 2
.globl _AMProjBridgeNSURLToSwiftURL
_AMProjBridgeNSURLToSwiftURL:
    .cfi_startproc
    mov x9, x0
    mov x8, x1
    mov x0, x2
    br x9
    .cfi_endproc

.p2align 2
.globl _AMProjCallNativeLocalImportContinuation
_AMProjCallNativeLocalImportContinuation:
    .cfi_startproc
    stp x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x29, -16
    .cfi_offset x30, -8
    mov x29, sp

    mov x10, x0
    // The adapter's first argument is the target function. Shift the next
    // seven native arguments down one register, then map the three C stack
    // arguments to native x7 and the continuation's two stack arguments.
    ldr x11, [x29, #16]
    ldr x12, [x29, #24]
    ldr x13, [x29, #32]
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    mov x4, x5
    mov x5, x6
    mov x6, x7
    mov x7, x11
    stp x12, x13, [sp, #-16]!
    blr x10
    add sp, sp, #16

    ldp x29, x30, [sp], #16
    .cfi_restore x29
    .cfi_restore x30
    .cfi_def_cfa_offset 0
    ret
    .cfi_endproc

.subsections_via_symbols
