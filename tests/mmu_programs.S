// Several CPUs at once, through the JIT at EL1 with the MMU on (each page mapped at its own address, VA = PA, except X):
// one CPU keeps remapping a code page X while the others keep calling it, so TLBIs from the first meet the others in
// every state, translating ones included (O8). See remap_test in test_mmu.c.
    .arch armv8.4-a
    .text
    .p2align 14
    .globl _mmu_programs_begin
    .globl _mmu_programs_finish
    .globl _mmu_remap
    .globl _mmu_exec
    .globl _mmu_exec_switch
    .globl _mmu_xcode
    .globl _mmu_done
    .globl _mmu_vectors
_mmu_programs_begin:

// Any exception is a failure: ESR in x20, FAR in x19, ELR in x18 (the test prints them), then stop.
    .p2align 11
_mmu_vectors:
    .rept 16
    .p2align 7
    mrs x20, esr_el1
    mrs x19, far_el1
    mrs x18, elr_el1
    b _mmu_done
    .endr

// Copied to the start of each of the three code pages X may map: the generation it was written for (the remapper
// rewrites the movz), and the generation as it reads it when it runs.
    .p2align 2
_mmu_xcode:
    movz w0, #0
    ldar w1, [x9]
    ret

// The remapper. x9 = &gen (32 bits), x10 = X, x11 = the last generation (under 65536), x12 = &page[3] (their addresses),
// x13 = &X's page table entry, x14 = what a page's address is ored with to map it (not global: the callers run it under
// ASIDs 1 and 2). Generation k: write k into page k % 3's code, map X to it, TLBI (odd k: VMALLE1IS, which other CPUs do
// themselves and this one waits for; even k: VAE1IS for each ASID, which this one does in their TLBs), then publish k.
_mmu_remap:
    mov w1, #1
1:  mov w2, #3
    udiv w3, w1, w2
    msub w3, w3, w2, w1
    ldr x4, [x12, x3, lsl #3]
    movz w5, #0x5280, lsl #16
    orr w5, w5, w1, lsl #5          // movz w0, #k
    str w5, [x4]
    dc cvau, x4
    dsb ish
    ic ivau, x4
    dsb ish
    orr x6, x4, x14
    str x6, [x13]
    dsb ish
    tbnz w1, #0, 2f
    lsr x7, x10, #12
    orr x8, x7, #(1 << 48)
    tlbi vae1is, x8
    orr x8, x7, #(2 << 48)
    tlbi vae1is, x8
    b 3f
2:  tlbi vmalle1is
3:  dsb ish
    isb
    stlr w1, [x9]
    add w1, w1, #1
    cmp w1, w11
    b.ls 1b
    b _mmu_done

// A caller: x9 = &gen, x10 = X, x11 = the last generation. Calls X until it reads the last generation. A call that reads
// generation g ran code written for g or later if g is odd (VMALLE1IS waited for every CPU), g - 1 or later if even
// (VAE1IS leaves a CPU already running the old block to finish it). Calls in x24; calls that ran older code in x21, the
// first one's generations (code, read) in x22, x23.
_mmu_exec:
    mov x21, #0
    mov x24, #0
1:  blr x10
    add x24, x24, #1
    and w2, w1, #1
    eor w2, w2, #1
    add w3, w0, w2
    cmp w3, w1
    b.hs 2f
    cbnz x21, 3f
    mov w22, w0
    mov w23, w1
3:  add x21, x21, #1
2:  cmp w1, w11
    b.lo 1b
    b _mmu_done

// The same, switching between two address spaces (x15, x16: TTBR0 values, the same tables under two ASIDs) before
// each call: its TLB entries are put aside and brought back while the TLBIs come in (the stashes, O8b).
_mmu_exec_switch:
    mov x21, #0
    mov x24, #0
1:  tst x24, #1
    csel x17, x15, x16, eq
    msr ttbr0_el1, x17
    isb
    blr x10
    add x24, x24, #1
    and w2, w1, #1
    eor w2, w2, #1
    add w3, w0, w2
    cmp w3, w1
    b.hs 2f
    cbnz x21, 3f
    mov w22, w0
    mov w23, w1
3:  add x21, x21, #1
2:  cmp w1, w11
    b.lo 1b
    b _mmu_done

_mmu_done:
    b _mmu_done

    .p2align 14
_mmu_programs_finish:
