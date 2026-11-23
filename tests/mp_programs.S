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
    .globl _mp_pv_probe
    .globl _mp_pv_pingpong
    .globl _mp_lock
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

// xnu's hvg_is_hcall_available for WFK and KICK, as lck_init_pv runs it (osfmk/arm64/arm64_hypercall.c): x20 = 1 if
// both are there. Also REVISION's w0, w1 in x25, x26, and FEATURES for a call that is not there (GET_MABS_OFFSET) must
// be negative.
_mp_pv_probe:
    SETUP
    mov x20, #0
    movz x0, #0xc100, lsl #16
    movk x0, #0x00f0                // VMAPPLE_PAC_NOP: a host from before these calls answers 0xffffffff or < 0
    hvc #0
    mov x1, #0xffffffff
    cmp x0, x1
    b.eq 9f
    tbnz x0, #63, 9f
    movz w0, #0x8300, lsl #16
    movk w0, #0xff01                // HVC32 OEM UID
    mov w1, #0
    mov w2, #0
    mov w3, #0
    hvc #0
    movz w4, #0x9cbb, lsl #16
    movk w4, #0x6ebb
    cmp w0, w4
    b.ne 9f
    movz w4, #0x9dc9, lsl #16
    movk w4, #0xd679
    cmp w1, w4
    b.ne 9f
    movz w4, #0xaa62, lsl #16
    movk w4, #0x4e1f
    cmp w2, w4
    b.ne 9f
    movz w4, #0x3b87, lsl #16
    movk w4, #0x8185
    cmp w3, w4
    b.ne 9f
    movz w0, #0x8300, lsl #16
    movk w0, #0xff03                // HVC32 OEM REVISION
    mov w1, #0
    hvc #0
    mov w25, w0
    mov w26, w1
    movz w0, #0x8300, lsl #16
    movk w0, #0xfeff                // HVC32 OEM FEATURES: WFK
    movz w1, #0xc300, lsl #16
    movk w1, #0x0005
    hvc #0
    tbnz w0, #31, 9f
    movz w0, #0x8300, lsl #16
    movk w0, #0xfeff                // KICK
    movz w1, #0xc300, lsl #16
    movk w1, #0x0006
    hvc #0
    tbnz w0, #31, 9f
    movz w0, #0x8300, lsl #16
    movk w0, #0xfeff                // GET_MABS_OFFSET: not there
    movz w1, #0xc300, lsl #16
    movk w1, #0x0003
    hvc #0
    tbz w0, #31, 9f
    mov x20, #1
9:  b _mp_done

// A paravirtual ticket lock's two sides, as xnu's (lock_ticket_pv.c): x9 = &token (32 bits), x10 = this CPU's number
// (0 or 1), x11 = the other's MPIDR (its phys_id), x15 = hand-overs. Not this CPU's token: interrupts off, one more
// look, then wait for a kick (WFK); its own: hand it over, kick the other (KICK). Waits in x21, the longest in ticks
// in x23; a call that failed fails the test.
_mp_pv_pingpong:
    SETUP
    mov x21, #0
    mov x23, #0
1:  ldar w2, [x9]
    cmp w2, w10
    b.eq 3f
    msr daifset, #3
    ldar w2, [x9]
    cmp w2, w10
    b.eq 1b
    mrs x12, cntvct_el0
    movz x0, #0xc300, lsl #16
    movk x0, #0x0005                // VMAPPLE_VCPU_WFK
    mov x1, #0
    hvc #0
    tbnz x0, #63, mp_bad
    mrs x13, cntvct_el0
    sub x13, x13, x12
    cmp x13, x23
    csel x23, x13, x23, hi
    add x21, x21, #1
    b 1b
3:  eor w2, w10, #1
    stlr w2, [x9]
    movz x0, #0xc300, lsl #16
    movk x0, #0x0006                // VMAPPLE_VCPU_KICK
    mov x1, x11
    hvc #0
    tbnz x0, #63, mp_bad
    subs x15, x15, #1
    b.ne 1b
    b _mp_done

// x0 times: take the spinlock at x9 (LDAXR/STXR; held, wait in WFE for the holder's release), add one to the count at
// x9 + 8 with a plain load and store, release it (STLR, SEV), as xnu's hw_lock does. On two CPUs at once the count
// comes out exact only if the lock excludes.
_mp_lock:
    SETUP
    mov w10, #1
1:  ldaxr w2, [x9]
    cbnz w2, 4f
    stxr w3, w10, [x9]
    cbnz w3, 1b
    ldr x4, [x9, #8]
    add x4, x4, #1
    str x4, [x9, #8]
    stlr wzr, [x9]
    sev
    subs x0, x0, #1
    b.ne 1b
    b _mp_done
4:  wfe
    b 1b

_mp_done:
    b _mp_done

    .p2align 14
_mp_programs_finish:
