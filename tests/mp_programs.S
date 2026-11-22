// Guest programs for test_mp: several CPU threads at once, through the JIT at EL1 with the MMU off. Every program
// ends at _mp_done (the test's stop PC); x17 = 0xbad there means an unexpected exception (ESR in x19, ELR in x18).
    .arch armv8.4-a
    .text
    .p2align 14
    .globl _mp_programs_begin
    .globl _mp_programs_finish
    .globl _mp_vectors
    .globl _mp_done
    .globl _mp_svc
    .globl _mp_timer_spin
    .globl _mp_timer_wfi
    .globl _mp_idle
    .globl _mp_spin
_mp_programs_begin:

    .p2align 11
_mp_vectors:
    .rept 4                         // current EL with SP_EL0: not used
    .p2align 7
    b mp_bad
    .endr
    .p2align 7                      // 0x200 synchronous: an SVC is counted in x20, anything else fails
    mrs x19, esr_el1
    lsr x19, x19, #26
    cmp x19, #0x15
    b.ne mp_bad
    add x20, x20, #1
    eret
    .p2align 7                      // 0x280 IRQ: the timer; when in x10, count in x21; the timer goes off (its line drops)
    mrs x10, cntvct_el0
    add x21, x21, #1
    msr cntv_ctl_el0, xzr
    eret
    .rept 10                        // FIQ, SError, lower ELs
    .p2align 7
    b mp_bad
    .endr

mp_bad:
    mrs x19, esr_el1
    mrs x18, elr_el1
    mov x17, #0xbad
    b _mp_done

.macro SETUP
    adr x16, _mp_vectors
    msr vbar_el1, x16
    mov x17, #0
.endm

// x0 SVCs, each counted by the vector (x20).
_mp_svc:
    SETUP
    mov x20, #0
1:  svc #0
    subs x0, x0, #1
    b.ne 1b
    b _mp_done

// x0 timer interrupts, each x1 ticks after it is set, waited for in a loop that never leaves by itself: only a kick at
// the deadline gets the CPU to the dispatcher, which takes the interrupt. Lateness (deadline to handler) summed in x22,
// the largest in x23; interrupts in x21.
_mp_timer_spin:
    SETUP
    mov x21, #0
    mov x22, #0
    mov x23, #0
    msr daifclr, #2
1:  mrs x11, cntvct_el0
    add x12, x11, x1
    msr cntv_cval_el0, x12
    mov x13, #1
    msr cntv_ctl_el0, x13
    mov x14, x21
2:  cmp x21, x14
    b.eq 2b
    sub x15, x10, x12
    add x22, x22, x15
    cmp x15, x23
    csel x23, x15, x23, hi
    subs x0, x0, #1
    b.ne 1b
    msr daifset, #2
    b _mp_done

// The same, waiting in WFI: the CPU sleeps until its deadline.
_mp_timer_wfi:
    SETUP
    mov x21, #0
    mov x22, #0
    mov x23, #0
    msr daifclr, #2
1:  mrs x11, cntvct_el0
    add x12, x11, x1
    msr cntv_cval_el0, x12
    mov x13, #1
    msr cntv_ctl_el0, x13
    mov x14, x21
2:  wfi
    cmp x21, x14
    b.eq 2b
    sub x15, x10, x12
    add x22, x22, x15
    cmp x15, x23
    csel x23, x15, x23, hi
    subs x0, x0, #1
    b.ne 1b
    msr daifset, #2
    b _mp_done

// Idle in WFI until the word at x9 is set (the test then wakes the CPU).
_mp_idle:
    SETUP
1:  wfi
    ldar w2, [x9]
    cbz w2, 1b
    b _mp_done

// Busy until the word at x9 is set: a loop that never leaves by itself.
_mp_spin:
    SETUP
1:  ldar w2, [x9]
    cbz w2, 1b
    b _mp_done

_mp_done:
    b _mp_done

    .p2align 14
_mp_programs_finish:
