.text
.p2align 2

.globl _AMProjV44ReleaseNativeActivityFallbackEnabled
_AMProjV44ReleaseNativeActivityFallbackEnabled:
    mov w0, #0
    ret

.p2align 2
.globl _AMProjV44IsDirectProjectPackageOption
_AMProjV44IsDirectProjectPackageOption:
    cmp w0, #7
    cset w0, eq
    ret
