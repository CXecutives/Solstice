// Entering and leaving translated code.
//
// hv_enter(HvCpu *cpu, void *block) saves the host's callee-saved registers,
// loads the guest registers, and jumps to the block. Blocks have no prologue:
// x0 and x1 are already guest values, so a chained block can jump straight in.
// The block leaves through cpu->exit_routine, which is hv_exit below: by then
// the block has stored guest x0, x1 and pc into the HvCpu.
//
// Host x6, x7 and x15 are free scratch: guest x6, x7 and x15 live in the HvCpu
// (they are the least used guest registers), so the translator never spills
// them and hv_exit does not save them.
//
// hv_helper_entry is how a block calls C without leaving: the block stores
// guest x0, x1 and x30, puts a HvHelperInfo pointer in x0 and does `blr` to it.
// Everything else is saved here, hv_helper(cpu, info) runs on the host stack,
// and either every guest register is reloaded and the block resumes (it then
// reloads x0 itself), or the helper asked to leave and we go out through hv_exit.

#define CPU_NZCV 0x108
#define CPU_V 0x140
#define CPU_FPCR 0x340
#define CPU_FPSR 0x348
#define CPU_HELPER_RET 0x358
#define CPU_HELPER_FROM 0x510
#define CPU_SP 0xf8
#define CPU_HOST_SP 0x410
#define CPU_PC 0x100
#define CPU_EXIT 0x110
#define CPU_EXIT_REQ 0x3c0
#define CPU_LAST_STUB 0x3c8
#define CPU_REFILL_RET 0x438
#define CPU_IJC_SALT 0x3d8
#define CPU_IJC_TAB 0x440
#define CPU_MISS_SITE 0x3e8
#define CPU_SPILL0 0x118
#define CPU_SLOW_INFO 0x518
#define CPU_TLB 0x580
#define TLB_ADJ 15
#define IJC_BITS 18
#define OP_LIGHT_BIT 8            // HV_OP_LIGHT in HvHelperInfo.op (translate.h)
#define LIGHT_LEAVE 1             // HV_LIGHT_LEAVE (light.h)

    .text
    .p2align 2
    .globl _hv_enter
    .globl _hv_exit
    .globl _hv_helper_entry
    .globl _hv_helper_thunk
    .globl _hv_slow_thunk
    .globl _hv_chain_thunk
    .globl _hv_ijc_thunk
    .globl _hv_xjump_thunk
    .globl _hv_fp_enter
    .globl _hv_fp_leave

// Not x6, x7, x15: guest x6, x7 and x15 live in the HvCpu, the host registers are scratch.
// x2-x17: what C may clobber besides x0 and x1; x19-x29: what it keeps.
.macro SAVE_X2_X17
    stp x2, x3, [x28, #16]
    stp x4, x5, [x28, #32]
    stp x8, x9, [x28, #64]
    stp x10, x11, [x28, #80]
    stp x12, x13, [x28, #96]
    str x14, [x28, #112]
    stp x16, x17, [x28, #128]
.endm

.macro SAVE_X19_X29
    stp x19, x20, [x28, #152]
    stp x21, x22, [x28, #168]
    stp x23, x24, [x28, #184]
    stp x25, x26, [x28, #200]
    str x27, [x28, #216]
    str x29, [x28, #232]
.endm

.macro SAVE_X2_X29
    SAVE_X2_X17
    SAVE_X19_X29
.endm

.macro SAVE_FP
    stp q0, q1, [x28, #320]
    stp q2, q3, [x28, #352]
    stp q4, q5, [x28, #384]
    stp q6, q7, [x28, #416]
    stp q8, q9, [x28, #448]
    stp q10, q11, [x28, #480]
    stp q12, q13, [x28, #512]
    stp q14, q15, [x28, #544]
    stp q16, q17, [x28, #576]
    stp q18, q19, [x28, #608]
    stp q20, q21, [x28, #640]
    stp q22, q23, [x28, #672]
    stp q24, q25, [x28, #704]
    stp q26, q27, [x28, #736]
    stp q28, q29, [x28, #768]
    stp q30, q31, [x28, #800]
.endm

// Uses x0 as a temporary, so x0 must already be saved.
.macro SAVE_FLAGS_FP
    mrs x0, nzcv
    str x0, [x28, #CPU_NZCV]
    SAVE_FP
.endm

// Uses x0 and x1 as temporaries. FPCR and FPSR are not here: reading or writing
// them stalls the pipeline, so the guest's values simply stay in the host
// registers for as long as hv_run runs (see hv_fp_enter/hv_fp_leave).
.macro LOAD_FLAGS_FP
    ldp q0, q1, [x28, #320]
    ldp q2, q3, [x28, #352]
    ldp q4, q5, [x28, #384]
    ldp q6, q7, [x28, #416]
    ldp q8, q9, [x28, #448]
    ldp q10, q11, [x28, #480]
    ldp q12, q13, [x28, #512]
    ldp q14, q15, [x28, #544]
    ldp q16, q17, [x28, #576]
    ldp q18, q19, [x28, #608]
    ldp q20, q21, [x28, #640]
    ldp q22, q23, [x28, #672]
    ldp q24, q25, [x28, #704]
    ldp q26, q27, [x28, #736]
    ldp q28, q29, [x28, #768]
    ldp q30, q31, [x28, #800]
    ldr x0, [x28, #CPU_NZCV]
    msr nzcv, x0
.endm

.macro LOAD_X2_X17
    ldp x2, x3, [x28, #16]
    ldp x4, x5, [x28, #32]
    ldp x8, x9, [x28, #64]
    ldp x10, x11, [x28, #80]
    ldp x12, x13, [x28, #96]
    ldr x14, [x28, #112]
    ldp x16, x17, [x28, #128]
.endm

.macro LOAD_X1_X30
    ldr x1, [x28, #8]
    LOAD_X2_X17
    ldp x19, x20, [x28, #152]
    ldp x21, x22, [x28, #168]
    ldp x23, x24, [x28, #184]
    ldp x25, x26, [x28, #200]
    ldr x27, [x28, #216]
    ldp x29, x30, [x28, #232]
.endm

_hv_enter:
    stp x29, x30, [sp, #-176]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    str x1, [sp, #160]

    mov x28, x0
    LOAD_FLAGS_FP
    LOAD_X1_X30
    ldr x15, [sp, #160]
    // From here the SP register holds the guest's SP (a guest address: nothing
    // may push onto it). The host's is kept in the HvCpu until the block leaves.
    mov x0, sp
    str x0, [x28, #CPU_HOST_SP]
    ldr x0, [x28, #CPU_SP]
    mov sp, x0
    ldr x0, [x28, #0]
    // Another CPU may have just written the block: its writes and cache
    // invalidation are done, but this core must not run what it fetched before.
    isb
    br x15

_hv_exit:
    // x0, x1 and pc are already in the HvCpu. Back to the host's stack first.
    mov x0, sp
    str x0, [x28, #CPU_SP]
    ldr x0, [x28, #CPU_HOST_SP]
    mov sp, x0
    SAVE_X2_X29
    str x30, [x28, #240]
    SAVE_FLAGS_FP
Lrestore_host:
    ldp d14, d15, [sp, #144]
    ldp d12, d13, [sp, #128]
    ldp d10, d11, [sp, #112]
    ldp d8, d9, [sp, #96]
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #176
    ret

_hv_helper_entry:
    // Guest x0, x1 and x30 are saved; x0 = HvHelperInfo *, x30 = resume address.
    str x30, [x28, #CPU_HELPER_RET]
    str x30, [x28, #CPU_HELPER_FROM]
    mov x1, x0
    SAVE_X2_X29
    // The guest's SP into the HvCpu (C reads and changes it: exceptions, SPSel), the host's stack back.
    mov x2, sp
    str x2, [x28, #CPU_SP]
    ldr x2, [x28, #CPU_HOST_SP]
    mov sp, x2
    SAVE_FLAGS_FP
    mov x0, x28
    bl _hv_helper
    cbnz w0, Lrestore_host
    ldr x15, [x28, #CPU_HELPER_RET]
    ldr x0, [x28, #CPU_HELPER_FROM]
    eor x15, x15, x0
    LOAD_FLAGS_FP
    LOAD_X1_X30
    ldr x0, [x28, #CPU_SP]
    mov sp, x0
    // Back into the block, or (after an exception or ERET) to the start of the next
    // one, which wants guest x0 live as well; host x15 is scratch. A next block from
    // this CPU's branch cache needs no ISB: hv_helper then set helper_came_from to it
    // as well (see hv_resume).
    cbnz x15, 1f
    ldr x15, [x28, #CPU_HELPER_RET]
    ldr x0, [x28]
    ret x15
1:  ldr x15, [x28, #CPU_HELPER_RET]
    ldr x0, [x28]
    isb                           // the next block may be one another CPU just wrote (see hv_enter)
    ret x15

// Shared tails of translated code, so each call site is a few words (the
// stub's data follows its blr; blocks reach these through HvCpu, not BL, since
// the JIT region may be further away than a BL goes).
//
// hv_helper_thunk: a helper call. The site did `str x30, [x28, #x30]`, `adr x6, info`
// and `blr`; x6 is its HvHelperInfo, x30 where the block resumes (`ldr x0, [x28]` there
// reloads guest x0). Everything that goes back to the block goes by RET, popping what
// the BLR pushed on the CPU's own stack of return addresses. SVC, ERET and WFE (op bit
// HV_OP_LIGHT) take the light path first.
_hv_helper_thunk:
    stp x0, x1, [x28]
    ldr w15, [x6, #12]            // the op
    tbnz w15, #OP_LIGHT_BIT, Llight
    mov x0, x6
    b _hv_helper_entry

// The light path: hv_light(cpu, info, where the block goes on) with only what C may clobber
// saved (x2-x17 here, x0 and x1 above, NZCV, SP), as hv_ijc_thunk does, so the guest's
// q0-q31 stay in their registers and nothing hv_light reaches may use SIMD or libc
// (core/light.c, tools/simd_gate.py). It returns the code to go on at (bit 0 set: after an
// ISB); LIGHT_LEAVE: the state changed but the next block is not cached, so out to the
// dispatcher with every register saved, as hv_exit does; or 0: it did nothing, and the full
// helper does it all.
Llight:
    SAVE_X2_X17
    stp x6, x30, [x28, #CPU_SPILL0 + 16] // spill[2..3]: free at the block's end, where these are
    mrs x15, nzcv
    str x15, [x28, #CPU_NZCV]
    mov x15, sp
    str x15, [x28, #CPU_SP]
    ldr x15, [x28, #CPU_HOST_SP]
    mov sp, x15
    mov x0, x28
    mov x1, x6
    mov x2, x30
    bl _hv_light
    cmp x0, #LIGHT_LEAVE
    b.ls 2f
    mov x15, x0
    ldr x0, [x28, #CPU_SP]        // an exception or ERET may have switched SP and NZCV
    mov sp, x0
    ldr x0, [x28, #CPU_NZCV]
    msr nzcv, x0
    LOAD_X2_X17
    ldr x1, [x28, #8]
    ldr x30, [x28, #240]
    ldr x0, [x28]
    tbnz x15, #0, 1f
    ret x15
1:  sub x15, x15, #1
    isb                           // a block found only now may be one another CPU just wrote (see hv_enter)
    ret x15
2:  cbz x0, 3f
    SAVE_X19_X29                  // leave: pc, SP and NZCV are in the HvCpu already
    SAVE_FP
    b Lrestore_host
3:  ldr x0, [x28, #CPU_NZCV]      // the full helper, with every register as the block left it
    msr nzcv, x0
    LOAD_X2_X17
    ldp x6, x30, [x28, #CPU_SPILL0 + 16]
    ldr x0, [x28, #CPU_SP]
    mov sp, x0
    mov x0, x6
    b _hv_helper_entry

// hv_slow_thunk: the out-of-line side of a load or store, of a group of them, of IC IVAU,
// DC ZVA and an EL0 counter read. The block's cold part did `str x30, [x28, #x30]` and
// `bl` to its chunk's trampoline, which came here through x15: x30 = the record after the
// BL (translate.c, put_slow_record); every register but x15 is as it was at the miss.
//   - The exact check of an access in its page's last 15 bytes, which the fast one refuses:
//     if it passes, back into the fast path (resume) with every register as it was.
//   - The light TLB refill (hv_tlb_refill): filled, the access again from its start (retry).
//   - Else hv_helper on {pc, insn, op}, which comes back after the access (join); for a
//     group of accesses, the group's plain copy instead.
// The registers the access borrowed (A, T, U, unless x6, x7 or x15) are in cpu->spill in
// that order: on the ways out to retry, the helper and the copy they get the guest's values
// back. Works on an image of x0-x30 on the host stack. Calls C with the guest's q0-q31
// live, as hv_helper_thunk did (tools/simd_gate.py).
.macro SLOW_UNSPILL shift          // x2: the next spill slot's offset
    ubfx w0, w21, #\shift, #5
    lsr w1, w3, w0
    tbnz w1, #0, 9f                // x6, x7, x15: free scratch, never spilled
    ldr x1, [x28, x2]
    str x1, [sp, x0, lsl #3]
    add x2, x2, #8
9:
.endm

.macro SLOW_GUEST_VALUES
    mov w3, #0x80c0                // x6, x7, x15
    mov x2, #CPU_SPILL0
    SLOW_UNSPILL 5
    SLOW_UNSPILL 10
    SLOW_UNSPILL 15
.endm

.macro SLOW_LOAD_X2_X29            // all but x0, x1, x15 and x30
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldr x14, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x19, x20, [sp, #152]
    ldp x21, x22, [sp, #168]
    ldp x23, x24, [sp, #184]
    ldp x25, x26, [sp, #200]
    ldr x27, [sp, #216]
    ldr x29, [sp, #232]
.endm

_hv_slow_thunk:
    mov x15, sp
    str x15, [x28, #CPU_SP]
    ldr x15, [x28, #CPU_HOST_SP]
    sub sp, x15, #256              // the image: x(n) at sp + 8n
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]       // x15: nothing
    stp x16, x17, [sp, #128]
    stp x19, x20, [sp, #152]
    stp x21, x22, [sp, #168]
    stp x23, x24, [sp, #184]
    stp x25, x26, [sp, #200]
    str x27, [sp, #216]
    str x29, [sp, #232]
    ldr x0, [x28, #240]
    str x0, [sp, #240]             // x30 as the block had it
    mov x19, x30                   // the record (x19-x22 outlive the C call)
    ldr w20, [x19, #12]            // meta
    ldr w21, [x19, #16]            // registers and distances
    and w0, w21, #31
    ldr x22, [sp, x0, lsl #3]      // the address
    tbz w20, #5, 1f
    // The exact check, touching no flags (NZCV is still the guest's).
    ubfx w0, w21, #10, #5
    ldr x0, [sp, x0, lsl #3]       // T: the TLB entry the fast check read
    ubfx w1, w20, #7, #4
    add x0, x0, x1, lsl #3
    ldr x0, [x0, #CPU_TLB]         // the tag it read
    sub x0, x22, x0
    ubfx w1, w20, #11, #13         // bytes - 1
    add x0, x0, x1
    sub x0, x0, #TLB_ADJ
    lsr x0, x0, #14
    cbnz x0, 1f
    ldrsw x0, [x19, #20]
    add x15, x19, x0, lsl #2       // resume (x15 is free there: never A or T)
    b 5f
1:  mrs x0, nzcv
    str x0, [x28, #CPU_NZCV]
    tbz w20, #1, 3f                // no refill
    ubfx w1, w20, #11, #13         // bytes - 1
    tbz w20, #6, 2f
    tst x22, x1                    // must be aligned and is not: the helper (which faults)
    b.ne 3f
2:  and x0, x22, #0x3fff
    add x0, x0, x1
    lsr x0, x0, #14
    cbnz x0, 3f                    // runs into the next page
    mov w2, #63
    cmp w1, #63
    csel w2, w1, w2, lo
    lsl w2, w2, #3                 // hv_tlb_refill's flags: bytes - 1 (at most 63), the table, write
    ubfx w3, w20, #2, #3
    orr w2, w2, w3
    mov x0, x28
    mov x1, x22
    bl _hv_tlb_refill
    cbnz w0, 3f
    ldrsw x0, [x19, #20]
    ubfx w1, w21, #20, #6
    sub x0, x0, x1
    add x15, x19, x0, lsl #2       // retry
    b 4f
3:  tbnz w20, #0, 6f               // a group: its plain copy
    // The helper: {pc, insn, op} where it finds them, guest values in every register.
    ldr x0, [x19]
    str x0, [x28, #CPU_SLOW_INFO]
    ldr w0, [x19, #8]
    str w0, [x28, #CPU_SLOW_INFO + 8]
    ubfx w0, w20, #24, #4
    str w0, [x28, #CPU_SLOW_INFO + 12]
    ldrsw x0, [x19, #20]
    ubfx w1, w21, #26, #6
    add x0, x0, x1
    add x15, x19, x0, lsl #2       // join
    SLOW_GUEST_VALUES
    ldp x0, x1, [sp]
    stp x0, x1, [x28]
    ldr x0, [sp, #240]
    str x0, [x28, #240]
    ldr x0, [x28, #CPU_NZCV]
    msr nzcv, x0
    SLOW_LOAD_X2_X29
    mov x30, x15
    ldr x0, [x28, #CPU_SP]
    mov sp, x0
    add x0, x28, #CPU_SLOW_INFO
    b _hv_helper_entry
6:  ldrsw x0, [x19, #8]
    add x15, x19, x0, lsl #2       // the plain copy
4:  SLOW_GUEST_VALUES
    ldr x0, [x28, #CPU_NZCV]
    msr nzcv, x0
5:  SLOW_LOAD_X2_X29               // x15: where to
    ldr x30, [sp, #240]
    ldr x1, [sp, #8]
    ldr x0, [x28, #CPU_SP]
    mov sp, x0
    ldr x0, [x28, #CPU_HOST_SP]
    ldur x0, [x0, #-256]
    ret x15

// hv_chain_thunk: a chainable exit's slow side. The site did `str x30, [x28, #x30]`
// and `blr`; x30 points at the slot's address (unaligned), and the slot (HV_SLOT) holds
// {chained block, target VA}. Follows the slot when chained beyond the stub's B (out of
// range), else leaves for the dispatcher, naming the slot (last_stub) unless an exit
// was asked for.
_hv_chain_thunk:
    mov x7, x30
    ldr x30, [x28, #240]
    ldr x6, [x7]
    ldr w15, [x28, #CPU_EXIT_REQ]
    cbnz w15, 1f
    ldr x15, [x6]
    cbz x15, 2f
    ret x15
2:  str x6, [x28, #CPU_LAST_STUB]
1:  stp x0, x1, [x28]
    ldr x0, [x6, #8]              // the target, from the slot
    str x0, [x28, #CPU_PC]
    ldr x1, [x28, #CPU_EXIT]
    br x1

// hv_ijc_thunk: an indirect-branch cache miss, before the dispatcher. x7 = the
// target VA, x30 = the site's flags word (guest x30 already saved). Jumps to
// the target block if hv_ijc_resolve found it; else returns after the word,
// with x7 still the VA. Saves only what C may clobber, as the refill does.
_hv_ijc_thunk:
    str x30, [x28, #CPU_REFILL_RET]
    stp x0, x1, [x28, #0]
    stp x2, x3, [x28, #16]
    stp x4, x5, [x28, #32]
    stp x8, x9, [x28, #64]
    stp x10, x11, [x28, #80]
    stp x12, x13, [x28, #96]
    str x14, [x28, #112]
    stp x16, x17, [x28, #128]
    str x7, [x28, #0x130]   // spill[3]: free at a block's end, where these lookups are
    mrs x15, nzcv
    str x15, [x28, #CPU_NZCV]
    mov x15, sp
    str x15, [x28, #CPU_SP]
    ldr x15, [x28, #CPU_HOST_SP]
    mov sp, x15
    mov x0, x28
    mov x1, x7
    ldr w2, [x30]
    bl _hv_ijc_resolve
    mov x6, x0
    ldr x0, [x28, #CPU_SP]
    mov sp, x0
    ldr x0, [x28, #CPU_NZCV]
    msr nzcv, x0
    ldp x0, x1, [x28, #0]
    ldp x2, x3, [x28, #16]
    ldp x4, x5, [x28, #32]
    ldp x8, x9, [x28, #64]
    ldp x10, x11, [x28, #80]
    ldp x12, x13, [x28, #96]
    ldr x14, [x28, #112]
    ldp x16, x17, [x28, #128]
    ldr x7, [x28, #0x130]
    ldr x30, [x28, #240]
    cbz x6, 1f
    isb                           // a block found in the hash may be one another CPU just wrote
    ret x6
1:  ldr x15, [x28, #CPU_REFILL_RET]
    add x15, x15, #4
    ret x15

// hv_xjump_thunk: a direct branch to another page that is not chained, looked
// up in the indirect-branch cache here instead of in the block (one copy of the
// lookup for all of them). x7 = the site's data: .word flags (bit 31: check
// exit_req first), .word 0, .quad the target VA. x30 is still the guest's. A
// cache miss tries hv_ijc_resolve, then leaves for the dispatcher.
_hv_xjump_thunk:
    ldr w15, [x7]
    tbz w15, #31, 2f
    ldr w6, [x28, #CPU_EXIT_REQ]
    cbnz w6, 3f
2:  str x7, [x28, #CPU_REFILL_RET]
    and x6, x15, #1
    add x6, x28, x6, lsl #3
    ldr x6, [x6, #CPU_IJC_SALT]
    and x15, x15, #15
    add x15, x28, x15, lsl #3
    ldr x15, [x15, #CPU_IJC_TAB]  // this flags value's table
    ldr x7, [x7, #8]
    eor x7, x7, x6                // the tag
    eor x6, x7, x7, lsr #16
    eor x6, x6, x7, lsr #46
    ubfx x6, x6, #2, #(IJC_BITS - 1)
    add x6, x15, x6, lsl #5       // the set: two entries
    ldr x15, [x6]
    eor x15, x15, x7
    cbnz x15, 6f
    ldr x6, [x6, #8]
    br x6
6:  ldr x15, [x6, #16]
    eor x15, x15, x7
    cbnz x15, 1f
    ldr x6, [x6, #24]
    br x6
1:  // a miss: as hv_ijc_thunk, then leave if the block is not made yet
    ldr x7, [x28, #CPU_REFILL_RET]
    str x30, [x28, #240]
    stp x0, x1, [x28, #0]
    stp x2, x3, [x28, #16]
    stp x4, x5, [x28, #32]
    stp x8, x9, [x28, #64]
    stp x10, x11, [x28, #80]
    stp x12, x13, [x28, #96]
    str x14, [x28, #112]
    stp x16, x17, [x28, #128]
    mrs x15, nzcv
    str x15, [x28, #CPU_NZCV]
    mov x15, sp
    str x15, [x28, #CPU_SP]
    ldr x15, [x28, #CPU_HOST_SP]
    mov sp, x15
    mov x0, x28
    ldr x1, [x7, #8]
    ldr w2, [x7]
    and w2, w2, #0x7fffffff
    bl _hv_ijc_resolve
    mov x6, x0
    ldr x0, [x28, #CPU_SP]
    mov sp, x0
    ldr x0, [x28, #CPU_NZCV]
    msr nzcv, x0
    ldp x0, x1, [x28, #0]
    ldp x2, x3, [x28, #16]
    ldp x4, x5, [x28, #32]
    ldp x8, x9, [x28, #64]
    ldp x10, x11, [x28, #80]
    ldp x12, x13, [x28, #96]
    ldr x14, [x28, #112]
    ldp x16, x17, [x28, #128]
    ldr x30, [x28, #240]
    ldr x7, [x28, #CPU_REFILL_RET]
    cbz x6, 3f
    isb                           // as in hv_ijc_thunk
    br x6
3:  stp x0, x1, [x28]             // leave with pc = the target (and the guest's x30: hv_exit saves it)
    ldr x0, [x7, #8]
    str x0, [x28, #CPU_PC]
    str xzr, [x28, #CPU_MISS_SITE]
    ldr x1, [x28, #CPU_EXIT]
    br x1

// hv_fp_enter(cpu): the guest's FPCR and FPSR into the host registers.
_hv_fp_enter:
    ldr x1, [x0, #CPU_FPCR]
    msr fpcr, x1
    ldr x1, [x0, #CPU_FPSR]
    msr fpsr, x1
    ret

// hv_fp_leave(cpu): and back into the HvCpu.
_hv_fp_leave:
    mrs x1, fpcr
    str x1, [x0, #CPU_FPCR]
    mrs x1, fpsr
    str x1, [x0, #CPU_FPSR]
    ret
