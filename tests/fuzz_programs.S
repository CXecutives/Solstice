// test_fuzz.c writes its programs at run time. What it keeps here is the assembler's
// word for one instance of every form its encoders make, in the order check_encoders()
// builds them, so a wrong field in an encoder fails at once instead of fuzzing nothing.
#include "harness.h"

    .arch armv8.4-a
    .text
    .p2align 2
    .globl _fuzz_ref
    .globl _fuzz_ref_end
_fuzz_ref:
    ldr x1, [x2, #16]
    strb w3, [x4, #5]
    ldrsh x5, [x6, #2]
    ldrsw x7, [x8, #4]
    ldrsb w9, [x10, #1]
    ldr q1, [x2, #32]
    str h3, [x4, #6]
    ldur x1, [x2, #-3]
    str w1, [x2, #-4]!
    ldr x3, [x4], #24
    stur q5, [sp, #-17]
    ldr x1, [x2, x3, lsl #3]
    ldrh w1, [x2, w3, uxtw]
    str x1, [x2, w3, sxtw #3]
    ldr d5, [x6, x7, sxtx]
    ldr q5, [x6, x7, lsl #4]
    ldp x1, x2, [x3, #16]
    stp w1, w2, [x3, #-8]!
    ldpsw x1, x2, [x3], #8
    ldp q1, q2, [x3, #32]
    stp d1, d2, [x3], #-16
    stp x29, x30, [sp, #-32]!
    ld1 {v1.16b}, [x2]
    ld1 {v1.4s, v2.4s}, [x2], #32
    st1 {v3.8b, v4.8b, v5.8b}, [x6], x7
    ld4 {v0.4s, v1.4s, v2.4s, v3.4s}, [x1], #64
    ld2 {v1.8h, v2.8h}, [x3]
    st1 {v1.1d, v2.1d, v3.1d, v4.1d}, [x2]
    ld1r {v1.4s}, [x2]
    ld1 {v1.s}[3], [x2]
    st1 {v2.s}[1], [x3]
    ldxr x1, [x2]
    stxr w3, x1, [x2]
    ldaxr w1, [x2]
    stlxr w3, w1, [x2]
    ldxrb w1, [x2]
    stxrh w3, w1, [x2]
    ldxp x1, x2, [x3]
    stxp w4, x1, x2, [x3]
    ldar x1, [x2]
    stlr w1, [x2]
    cas x1, x2, [x3]
    casal w1, w2, [x3]
    casp x0, x1, x2, x3, [x4]
    ldaprb w1, [x2]
    ldadd x1, x2, [x3]
    ldsetal w1, w2, [x3]
    swpb w1, w2, [x3]
    ldclrl x1, x2, [x3]
    ldumaxah w1, w2, [x3]
    dc zva, x1
Lr51: ldr x1, Lr53
Lr52: ldr q1, Lr56
Lr53: ldrsw x2, Lr52
    add x1, x2, #0x123
    sub x1, x2, #5, lsl #12
Lr56: adds x1, x2, x3
    cmp x1, x2
    eor x1, x2, x3
    cset x1, ne
    movz x1, #0x1234, lsl #16
Lr61: movk x1, #0x5678, lsl #32
    movn x1, #3
Lr63: b.ne Lr65
Lr64: cbnz w1, Lr61
Lr65: bl Lr69
Lr66: adr x1, Lr68
    br x1
Lr68: blr x2
Lr69: ret
    ret x3
    ldp q0, q1, [x28, #320]
    msr fpcr, x0
    msr fpsr, x0
    mov sp, x0
    msr nzcv, x0
    mrs x2, nzcv
    mrs x2, fpcr
    mrs x2, fpsr
    mov x2, sp
    add sp, sp, #32
    sub sp, sp, #48
    subs x23, x23, #1
    add w1, w1, #1
Lr84: b Lr87
Lr85: cbz x5, Lr87
Lr86: tbnz w3, #5, Lr88
Lr87: ldr x28, [x28, #224]
Lr88: stp q30, q31, [x0, #800]
    ldp x2, x3, [sp], #16
    str x30, [x0, #240]
_fuzz_ref_end:
