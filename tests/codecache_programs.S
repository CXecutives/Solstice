// The code-cache eviction stress (test_codecache.c): about 1.4 MB of guest code in
// 89 pages, far more translated code than the small code cache the test gives it,
// so its segments are condemned and freed over and over while CPUs run.
//
// Each round: a TLBI of everything (on the JIT only: x20 = 1), then 64 "cold"
// pages run once, with the 24 "hot" pages run after every 16th of them (four times
// a round: their blocks are dropped and wanted again soon, so they are tenured, and
// there are more of them than the tenured share holds). Every cell is a block of
// its own and mixes x0 (x0 = 3 x0 + k): one skipped, run twice or run as the wrong
// code shows in x0. On the way: same-page chains, conditional exits, exits to the
// next page (chained across pages), indirect branches (the branch cache), loops
// (their back edges check for exit requests), calls to another page and returns
// (return predictions), and TLBIs by VA from every CPU.
//
// In: x0 a seed, x20 1 under the JIT (0 natively: no TLBIs at EL0), x21 rounds.
#include "harness.h"

// x0 = 3 x0 + k
.macro MIX k
    add x0, x0, x0, lsl #1
    add x0, x0, #\k
.endm

.macro CELL_B k
    MIX \k
    b 1f
1:
.endm

.macro CELL_COND k
    MIX \k
    tbnz x0, #3, 2f
    eor x0, x0, #0xff
2:  b 1f
1:
.endm

.macro CELL_BR k
    MIX \k
    adr x9, 3f
    br x9
3:  eor x0, x0, x0, lsr #7
    b 1f
1:
.endm

.macro CELL_LOOP k
    MIX \k
    mov x3, #3
4:  add x0, x0, x3
    subs x3, x3, #1
    b.ne 4b
    b 1f
1:
.endm

.macro CELL_CALL k
    MIX \k
    bl ccs_fn
    b 1f
1:
.endm

.macro CELL_TLBI k
    MIX \k
    cbz x20, 5f
    tlbi vae1is, x25
5:  b 1f
1:
.endm

// 16 cells; v picks the fifth: 0 plain, 1 indirect, 2 loop, 3 call, 4 TLBI.
.macro GROUP k, v
    CELL_B \k
    CELL_COND \k
    CELL_B \k
    CELL_B \k
    .if \v == 0
    CELL_B \k
    .endif
    .if \v == 1
    CELL_BR \k
    .endif
    .if \v == 2
    CELL_LOOP \k
    .endif
    .if \v == 3
    CELL_CALL \k
    .endif
    .if \v == 4
    CELL_TLBI \k
    .endif
    CELL_B \k
    CELL_B \k
    CELL_B \k
    CELL_COND \k
    CELL_B \k
    CELL_B \k
    CELL_B \k
    CELL_B \k
    CELL_B \k
    CELL_B \k
    CELL_B \k
.endm

// 1152 cells, about 3840 instructions: one 16 KB page.
.macro PAGEBODY k
    .rept 9
    GROUP \k, 0
    GROUP \k, 1
    GROUP \k, 0
    GROUP \k, 2
    GROUP \k, 0
    GROUP \k, 3
    GROUP \k, 0
    GROUP \k, 4
    .endr
.endm

// A cold page, then the next one (hot: by way of the hot pages, x24 = where to go on).
.macro CPAGE n, next, hot
    .p2align 14
ccs_c\n:
    PAGEBODY (\n*8+1)
    .if \hot
    adr x24, ccs_c\next
    b ccs_h0
    .else
    b ccs_c\next
    .endif
.endm

.macro HPAGE n, next
    .p2align 14
ccs_h\n:
    PAGEBODY (\n*8+801)
    b ccs_h\next
.endm

    .text
    .p2align 14
    .globl _codecache_programs_begin
    .globl _codecache_programs_finish
_codecache_programs_begin:

PROGRAM ccstress
    adr x25, ccs_fn
    lsr x25, x25, #12  // TLBI VAE1IS's operand: the called function's page
0:  cbz x20, 1f
    tlbi vmalle1is
    dsb ish
1:  isb
    adr x23, 2f
    b ccs_c0
2:  subs x21, x21, #1
    b.ne 0b
END ccstress

    .p2align 14
ccs_fn:
    eor x0, x0, x0, lsl #3
    add x0, x0, #7
    ret

    CPAGE 0, 1, 0
    CPAGE 1, 2, 0
    CPAGE 2, 3, 0
    CPAGE 3, 4, 0
    CPAGE 4, 5, 0
    CPAGE 5, 6, 0
    CPAGE 6, 7, 0
    CPAGE 7, 8, 0
    CPAGE 8, 9, 0
    CPAGE 9, 10, 0
    CPAGE 10, 11, 0
    CPAGE 11, 12, 0
    CPAGE 12, 13, 0
    CPAGE 13, 14, 0
    CPAGE 14, 15, 0
    CPAGE 15, 16, 1
    CPAGE 16, 17, 0
    CPAGE 17, 18, 0
    CPAGE 18, 19, 0
    CPAGE 19, 20, 0
    CPAGE 20, 21, 0
    CPAGE 21, 22, 0
    CPAGE 22, 23, 0
    CPAGE 23, 24, 0
    CPAGE 24, 25, 0
    CPAGE 25, 26, 0
    CPAGE 26, 27, 0
    CPAGE 27, 28, 0
    CPAGE 28, 29, 0
    CPAGE 29, 30, 0
    CPAGE 30, 31, 0
    CPAGE 31, 32, 1
    CPAGE 32, 33, 0
    CPAGE 33, 34, 0
    CPAGE 34, 35, 0
    CPAGE 35, 36, 0
    CPAGE 36, 37, 0
    CPAGE 37, 38, 0
    CPAGE 38, 39, 0
    CPAGE 39, 40, 0
    CPAGE 40, 41, 0
    CPAGE 41, 42, 0
    CPAGE 42, 43, 0
    CPAGE 43, 44, 0
    CPAGE 44, 45, 0
    CPAGE 45, 46, 0
    CPAGE 46, 47, 0
    CPAGE 47, 48, 1
    CPAGE 48, 49, 0
    CPAGE 49, 50, 0
    CPAGE 50, 51, 0
    CPAGE 51, 52, 0
    CPAGE 52, 53, 0
    CPAGE 53, 54, 0
    CPAGE 54, 55, 0
    CPAGE 55, 56, 0
    CPAGE 56, 57, 0
    CPAGE 57, 58, 0
    CPAGE 58, 59, 0
    CPAGE 59, 60, 0
    CPAGE 60, 61, 0
    CPAGE 61, 62, 0
    CPAGE 62, 63, 0
    CPAGE 63, end, 1
ccs_cend:
    br x23

    HPAGE 0, 1
    HPAGE 1, 2
    HPAGE 2, 3
    HPAGE 3, 4
    HPAGE 4, 5
    HPAGE 5, 6
    HPAGE 6, 7
    HPAGE 7, 8
    HPAGE 8, 9
    HPAGE 9, 10
    HPAGE 10, 11
    HPAGE 11, 12
    HPAGE 12, 13
    HPAGE 13, 14
    HPAGE 14, 15
    HPAGE 15, 16
    HPAGE 16, 17
    HPAGE 17, 18
    HPAGE 18, 19
    HPAGE 19, 20
    HPAGE 20, 21
    HPAGE 21, 22
    HPAGE 22, 23
    HPAGE 23, ret
ccs_hret:
    br x24

    .p2align 14
_codecache_programs_finish:
