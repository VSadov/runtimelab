// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

.intel_syntax noprefix
#include "unixasmmacros.inc"

// The EE copies RhpCheckedAssignRef and RhpAssignRef as one block and runs them from the copy (see
// InitJITWriteBarrierHelpers). When the state of the GC tells what RhpAssignRef would check at run time, the GC asks
// the EE to copy a variant of RhpAssignRef over it in the copy (see GCWriteBarrierVariant and ToggleWriteBarrier).
// The variants are described in writebarrier.asm.
//
// RhpAssignRef has room for any of the variants. They have the same code ahead of their CheckedEntry, so that
// RhpCheckedAssignRef can jump to RhpCheckedEntry in the copy, whichever variant is there. It jumps to a local label,
// which the assembler resolves, because the linker could route a jump to the global symbol outside the block (e.g.
// through the PLT), and then the jump would be wrong in the copy.
// RhpCheckedAssignRef and RhpAssignRef start on cache lines, thus they do in the copy too, and the variants place
// their code as if they did.
//
// The values that the barriers use (the page map, the page byte map and the address of the barrier state) are
// patched into them (see GCWriteBarrierPatchableValue), so that they remain correct no matter where they are copied
// to. They are the imm64 operands of "mov reg, imm64" instructions, emitted manually, so that the PatchableValue_*
// labels are on the immediates. The EE patches them with single 8-byte stores, thus they must be 8-byte aligned.
// Each one is aligned by construction: it follows an alignment directive, or the start of a helper, with only
// fixed-size code in between. No jump may sit in between, since jump encodings differ between ELF and Mach-O, where
// a jump across an .alt_entry symbol is not relaxed to its short form.

// The space for RhpAssignRef and its variants
#define ASSIGN_REF_SIZE 0x200

// An alternate entry in the middle of a helper. Apple's linkers attribute unwind info to the symbol that a range
// starts at, so the range from an .alt_entry symbol has no unwind info unless an unwind region also starts there
// (see https://github.com/dotnet/runtime/pull/114982#discussion_r2083272768). This ends the current region and
// starts a new one at the entry, on Apple platforms only.
.macro ALTERNATE_ENTRY_WITH_UNWIND Name
#if defined(__APPLE__)
    .cfi_endproc
#endif
    ALTERNATE_ENTRY \Name
#if defined(__APPLE__)
    .cfi_startproc
#endif
.endm

//
//   rdi - dest address
//   rsi - object
//
        .p2align 6
LEAF_ENTRY RhpCheckedAssignRef, _TEXT
    // See if dst is in GCHeap
        NOP_6_BYTE // padding for alignment of constant
        .byte   0x48, 0xB8              // mov rax, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_CheckedAssignRef_CardBundleTable
        .quad   0xF0F0F0F0F0F0F0F0      // the page byte map
        mov     r8,  rdi
        shr     r8,  30                    // dst page index
        cmp     byte ptr [rax + r8], 0
        jne     LOCAL_LABEL(RhpCheckedEntry)   // rax - the page byte map

LOCAL_LABEL(NotInHeap):
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedAssignRefAVLocation
        mov     [rdi], rsi
        ret
LEAF_END_MARKED RhpCheckedAssignRef, _TEXT

//
//   rdi - dest address
//   rsi - object
//
        .p2align 6
LEAF_ENTRY RhpAssignRef, _TEXT
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    // check if src is in heap
        NOP_6_BYTE // padding for alignment of constant
        .byte   0x48, 0xB8              // mov rax, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_CardBundleTable
        .quad   0xF0F0F0F0F0F0F0F0      // the page byte map
LOCAL_LABEL(RhpCheckedEntry):
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedEntry
        mov     r8, rsi
        shr     r8, 30                                  //  src page index
        cmp     byte ptr [rax + r8], 0
        je      LOCAL_LABEL(JustAssign_SATORI_DYNAMIC)                 // src not in heap
#else
LOCAL_LABEL(RhpCheckedEntry):
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedEntry
#endif

    // check for escaping assignment
    // 1) check if we own the source region
        mov     rdx, rsi
        and     rdx, 0xFFFFFFFFFFE00000  // source region
#ifndef FEATURE_SATORI_EXTERNAL_OBJECTS
        jz      LOCAL_LABEL(JustAssign_SATORI_DYNAMIC)                 // assigning null
#endif
#ifdef TARGET_APPLE
        mov     rax,  gs:[0]            // thread tag
#else
        mov     rax,  fs:[0]            // thread tag
#endif
        cmp     qword ptr [rdx], rax
        jne     LOCAL_LABEL(AssignAndMarkCards_SATORI_DYNAMIC)         // not local to this thread

    // 2) check if the src and dst are from the same region
        mov     rax, rdi
        and     rax, 0xFFFFFFFFFFE00000 // target aligned to region
        cmp     rax, rdx
        jnz     LOCAL_LABEL(RecordEscape_SATORI_DYNAMIC)               // cross region assignment. definitely escaping

    // 3) check if the target is exposed
        mov     eax, edi
        and     eax, 0x1FFFFF           // offset in the region
        shr     eax, 9                  // the bitmap qword with the bit for the target (a bit per 8 bytes)
        mov     rax, qword ptr [rdx + rax * 8]
        mov     r9, rdi
        shr     r9, 3                   // bt takes the bit index modulo 64
        bt      rax, r9
        jc      LOCAL_LABEL(RecordEscape_SATORI_DYNAMIC)               // target is exposed. record an escape.

    LOCAL_LABEL(JustAssign_SATORI_DYNAMIC):
ALTERNATE_ENTRY_WITH_UNWIND RhpAssignRefAVLocationNotHeap
        mov     [rdi], rsi              // src is external/null, or the assignment is completely threadlocal
        ret

        // Not executed. Places the block below within one cache line where the barrier runs (the copy starts on a cache
        // line): the block starts 3 bytes into a line, so that the 3-byte store and the 2-byte opcode end on an 8-byte boundary.
        .fill ((67 - ((. - C_FUNC(RhpAssignRef)) % 64)) % 64), 1, 0xCC
    LOCAL_LABEL(AssignAndMarkCards_SATORI_DYNAMIC):
ALTERNATE_ENTRY_WITH_UNWIND RhpAssignRefAVLocation
        mov     [rdi], rsi

        // The barrier state may become concurrent while EE runs, thus this barrier reads it.
        // This must be done after the assignment (in program order).
        .byte   0x48, 0xB9              // mov rcx, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_BarrierStateAddress
        .quad   0xF0F0F0F0F0F0F0F0      // the address of the barrier state (g_write_barrier_state)
        mov     r11, [rcx]

    // if src and dst are in the same region, cards are needed only while concurrent
        xor     rsi, rdi
        shr     rsi, 21
        jnz     LOCAL_LABEL(CrossRegion_SATORI_DYNAMIC)
        cmp     r11, 1
        je      LOCAL_LABEL(MarkCards_SATORI_DYNAMIC)
        ret

    LOCAL_LABEL(CrossRegion_SATORI_DYNAMIC):
    // if state == 2 we do not set or dirty cards.
        cmp     r11, 2
        je      LOCAL_LABEL(Exit_SATORI_DYNAMIC)

    // dst is in another region - cards are needed if src is ephemeral (gen < 2), or while concurrent
        cmp     dword ptr [rdx + 16], 2
        jl      LOCAL_LABEL(MarkCards_SATORI_DYNAMIC)
        test    r11, r11
        jnz     LOCAL_LABEL(MarkCards_SATORI_DYNAMIC)
    LOCAL_LABEL(Exit_SATORI_DYNAMIC):
        ret

        // Not executed. Places the card marking below within one cache line where the barrier runs, with the constant
        // on an 8-byte boundary: the block starts 6 bytes into a line.
        .fill ((70 - ((. - C_FUNC(RhpAssignRef)) % 64)) % 64), 1, 0xCC
    LOCAL_LABEL(MarkCards_SATORI_DYNAMIC):
    // fetch card location for rdi
        .byte   0x49, 0xB9              // mov r9, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_CardTable
        .quad   0xF0F0F0F0F0F0F0F0      // the page map
        mov     rdx, rdi
        shr     rdi, 30
        mov     rax, qword ptr [r9 + rdi * 8] // page
        sub     rdx, rax   // offset in page
        mov     r8,  rdx
        shr     rdx, 9     // card offset
        shr     r8,  20    // group index
        lea     r8,  [rax + r8 * 2 + 0x80] // group offset

     // check if concurrent marking is in progress
        test    r11, r11
        jnz     LOCAL_LABEL(DirtyCard_SATORI_DYNAMIC)

     // SETTING CARD
     LOCAL_LABEL(SetCard_SATORI_DYNAMIC):
        cmp     byte ptr [rax + rdx], 0
        je      LOCAL_LABEL(DoSetCard_SATORI_DYNAMIC)
        ret
     LOCAL_LABEL(DoSetCard_SATORI_DYNAMIC):
        mov     byte ptr [rax + rdx], 1
     LOCAL_LABEL(SetGroup_SATORI_DYNAMIC):
        cmp     byte ptr [r8], 0
        jne     LOCAL_LABEL(CardSet_SATORI_DYNAMIC)
        mov     byte ptr [r8], 1
     LOCAL_LABEL(SetPage_SATORI_DYNAMIC):
        cmp     byte ptr [rax], 0
        jne     LOCAL_LABEL(CardSet_SATORI_DYNAMIC)
        // DIRTY on purpose: a racing REMEMBERED store could overwrite another thread's DIRTY.
        mov     byte ptr [rax], 4

     LOCAL_LABEL(CardSet_SATORI_DYNAMIC):
     // check if concurrent marking is still not in progress
        cmp     qword ptr [rcx], 0      // rcx - the address of the barrier state
        jne     LOCAL_LABEL(DirtyCard_SATORI_DYNAMIC)
        ret

     // DIRTYING CARD
     LOCAL_LABEL(DirtyCard_SATORI_DYNAMIC):
        mov     byte ptr [rax + rdx], 4
     LOCAL_LABEL(DirtyGroup_SATORI_DYNAMIC):
        cmp     byte ptr [r8], 4
        jne     LOCAL_LABEL(DoDirtyGroup_SATORI_DYNAMIC)
        ret
     LOCAL_LABEL(DoDirtyGroup_SATORI_DYNAMIC):
        mov     byte ptr [r8], 4
     LOCAL_LABEL(DirtyPage_SATORI_DYNAMIC):
        cmp     byte ptr [rax], 4
        je      LOCAL_LABEL(Exit_SATORI_DYNAMIC)
        mov     byte ptr [rax], 4
        ret

    // this is expected to be rare.
    LOCAL_LABEL(RecordEscape_SATORI_DYNAMIC):

    // 4) check if the source is escaped
        lea     eax, [rsi + 8]                // escape bit is MT + 1
        and     eax, 0x1FFFFF                 // offset in the region
        shr     eax, 9                        // the bitmap qword with the bit (a bit per 8 bytes)
        mov     rax, qword ptr [rdx + rax * 8]
        lea     r9, [rsi + 8]
        shr     r9, 3                         // bt takes the bit index modulo 64
        bt      rax, r9
        jc      LOCAL_LABEL(AssignAndMarkCards_SATORI_DYNAMIC)         // source is already escaped.

        // Align rsp
        mov  r9, rsp
        and  rsp, -16

        // save rsp, rdi, rsi and rdx
        push r9
        push rdi
        push rsi
        push rdx

        // also save xmm0, in case it is used for stack clearing.
        // Hopefully EscapeFn cannot corrupt other xmm regs, since there is no float math or vectorizable code in there.
        sub     rsp, 16
        movdqa  [rsp], xmm0

        // void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [rdx + 8]

        movdqa  xmm0, [rsp]
        add     rsp, 16

        pop     rdx
        pop     rsi
        pop     rdi
        pop     rsp
        jmp     LOCAL_LABEL(AssignAndMarkCards_SATORI_DYNAMIC)

        // Not executed. The space for the variants.
        .fill (ASSIGN_REF_SIZE - (. - C_FUNC(RhpAssignRef))), 1, 0xCC
LEAF_END_MARKED RhpAssignRef, _TEXT

//
// The GC does not mark concurrently yet and the next GC is a full GC, thus cards are not needed until it does.
// The barrier state may become concurrent while EE runs, thus this barrier reads it. Once it is concurrent, the cards
// are dirtied for any src, since a full GC marks through objects of any generation.
//
        .balign 16
LEAF_ENTRY RhpAssignRef_SATORI_DYNAMIC2, _TEXT
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    // check if src is in heap
        NOP_6_BYTE // padding for alignment of constant
        .byte   0x48, 0xB8              // mov rax, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_SATORI_DYNAMIC2_CardBundleTable
        .quad   0xF0F0F0F0F0F0F0F0      // the page byte map
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedEntry_SATORI_DYNAMIC2
        mov     r8, rsi
        shr     r8, 30                                  //  src page index
        cmp     byte ptr [rax + r8], 0
        je      LOCAL_LABEL(JustAssign_SATORI_DYNAMIC2)                 // src not in heap
#else
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedEntry_SATORI_DYNAMIC2
#endif

    // check for escaping assignment
    // 1) check if we own the source region
        mov     rdx, rsi
        and     rdx, 0xFFFFFFFFFFE00000  // source region
#ifndef FEATURE_SATORI_EXTERNAL_OBJECTS
        jz      LOCAL_LABEL(JustAssign_SATORI_DYNAMIC2)                 // assigning null
#endif
#ifdef TARGET_APPLE
        mov     rax,  gs:[0]            // thread tag
#else
        mov     rax,  fs:[0]            // thread tag
#endif
        cmp     qword ptr [rdx], rax
        jne     LOCAL_LABEL(AssignAndMarkCards_SATORI_DYNAMIC2)         // not local to this thread

    // 2) check if the src and dst are from the same region
        mov     rax, rdi
        and     rax, 0xFFFFFFFFFFE00000 // target aligned to region
        cmp     rax, rdx
        jnz     LOCAL_LABEL(RecordEscape_SATORI_DYNAMIC2)               // cross region assignment. definitely escaping

    // 3) check if the target is exposed
        mov     eax, edi
        and     eax, 0x1FFFFF           // offset in the region
        shr     eax, 9                  // the bitmap qword with the bit for the target (a bit per 8 bytes)
        mov     rax, qword ptr [rdx + rax * 8]
        mov     r9, rdi
        shr     r9, 3                   // bt takes the bit index modulo 64
        bt      rax, r9
        jc      LOCAL_LABEL(RecordEscape_SATORI_DYNAMIC2)               // target is exposed. record an escape.

    LOCAL_LABEL(JustAssign_SATORI_DYNAMIC2):
ALTERNATE_ENTRY_WITH_UNWIND RhpAssignRefAVLocationNotHeap_SATORI_DYNAMIC2
        mov     [rdi], rsi              // src is external/null, or the assignment is completely threadlocal
        ret

        // Not executed. Places the block below within one cache line where the barrier runs (the copy starts on a cache
        // line): the block starts 3 bytes into a line, so that the 3-byte store and the 2-byte opcode end on an 8-byte boundary.
        .fill ((67 - ((. - C_FUNC(RhpAssignRef_SATORI_DYNAMIC2)) % 64)) % 64), 1, 0xCC
    LOCAL_LABEL(AssignAndMarkCards_SATORI_DYNAMIC2):
ALTERNATE_ENTRY_WITH_UNWIND RhpAssignRefAVLocation_SATORI_DYNAMIC2
        mov     [rdi], rsi

        // The barrier state may become concurrent while EE runs, thus this barrier reads it.
        // This must be done after the assignment (in program order).
        .byte   0x48, 0xB9              // mov rcx, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_SATORI_DYNAMIC2_BarrierStateAddress
        .quad   0xF0F0F0F0F0F0F0F0      // the address of the barrier state (g_write_barrier_state)

    // if state == 2 we do not set or dirty cards.
        cmp     qword ptr [rcx], 2
        jne     LOCAL_LABEL(MarkCards_SATORI_DYNAMIC2)
        ret

        // Not executed. Aligns the constant below: the padding and the 2-byte opcode end on an 8-byte boundary.
        .p2align 3
        NOP_6_BYTE
    LOCAL_LABEL(MarkCards_SATORI_DYNAMIC2):
    // fetch card location for rdi
        .byte   0x49, 0xB9              // mov r9, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_SATORI_DYNAMIC2_CardTable
        .quad   0xF0F0F0F0F0F0F0F0      // the page map
        mov     rdx, rdi
        shr     rdi, 30
        mov     rax, qword ptr [r9 + rdi * 8] // page
        sub     rdx, rax   // offset in page
        mov     r8,  rdx
        shr     rdx, 9     // card offset
        shr     r8,  20    // group index
        lea     r8,  [rax + r8 * 2 + 0x80] // group offset

     // DIRTYING CARD
     LOCAL_LABEL(DirtyCard_SATORI_DYNAMIC2):
        mov     byte ptr [rax + rdx], 4
     LOCAL_LABEL(DirtyGroup_SATORI_DYNAMIC2):
        cmp     byte ptr [r8], 4
        jne     LOCAL_LABEL(DoDirtyGroup_SATORI_DYNAMIC2)
        ret
     LOCAL_LABEL(DoDirtyGroup_SATORI_DYNAMIC2):
        mov     byte ptr [r8], 4
     LOCAL_LABEL(DirtyPage_SATORI_DYNAMIC2):
        cmp     byte ptr [rax], 4
        je      LOCAL_LABEL(Exit_SATORI_DYNAMIC2)
        mov     byte ptr [rax], 4
     LOCAL_LABEL(Exit_SATORI_DYNAMIC2):
        ret

    // this is expected to be rare.
    LOCAL_LABEL(RecordEscape_SATORI_DYNAMIC2):

    // 4) check if the source is escaped
        lea     eax, [rsi + 8]                // escape bit is MT + 1
        and     eax, 0x1FFFFF                 // offset in the region
        shr     eax, 9                        // the bitmap qword with the bit (a bit per 8 bytes)
        mov     rax, qword ptr [rdx + rax * 8]
        lea     r9, [rsi + 8]
        shr     r9, 3                         // bt takes the bit index modulo 64
        bt      rax, r9
        jc      LOCAL_LABEL(AssignAndMarkCards_SATORI_DYNAMIC2)         // source is already escaped.

        // Align rsp
        mov  r9, rsp
        and  rsp, -16

        // save rsp, rdi, rsi and rdx
        push r9
        push rdi
        push rsi
        push rdx

        // also save xmm0, in case it is used for stack clearing.
        // Hopefully EscapeFn cannot corrupt other xmm regs, since there is no float math or vectorizable code in there.
        sub     rsp, 16
        movdqa  [rsp], xmm0

        // void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [rdx + 8]

        movdqa  xmm0, [rsp]
        add     rsp, 16

        pop     rdx
        pop     rsi
        pop     rdi
        pop     rsp
        jmp     LOCAL_LABEL(AssignAndMarkCards_SATORI_DYNAMIC2)
LEAF_END_MARKED RhpAssignRef_SATORI_DYNAMIC2, _TEXT

//
// The GC does not mark concurrently and the next GC is not necessarily a full GC, thus cards are needed.
// Used only when concurrent GC is disabled. Then the barrier state changes only while EE is suspended, when the GC
// also switches the barrier, thus this barrier does not check the state.
//
        .balign 16
LEAF_ENTRY RhpAssignRef_SATORI, _TEXT
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    // check if src is in heap
        NOP_6_BYTE // padding for alignment of constant
        .byte   0x48, 0xB8              // mov rax, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_SATORI_CardBundleTable
        .quad   0xF0F0F0F0F0F0F0F0      // the page byte map
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedEntry_SATORI
        mov     r8, rsi
        shr     r8, 30                                  //  src page index
        cmp     byte ptr [rax + r8], 0
        je      LOCAL_LABEL(JustAssign_SATORI)                 // src not in heap
#else
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedEntry_SATORI
#endif

    // check for escaping assignment
    // 1) check if we own the source region
        mov     rdx, rsi
        and     rdx, 0xFFFFFFFFFFE00000  // source region
#ifndef FEATURE_SATORI_EXTERNAL_OBJECTS
        jz      LOCAL_LABEL(JustAssign_SATORI)                 // assigning null
#endif
#ifdef TARGET_APPLE
        mov     rax,  gs:[0]            // thread tag
#else
        mov     rax,  fs:[0]            // thread tag
#endif
        cmp     qword ptr [rdx], rax
        jne     LOCAL_LABEL(AssignAndMarkCards_SATORI)         // not local to this thread

    // 2) check if the src and dst are from the same region
        mov     rax, rdi
        and     rax, 0xFFFFFFFFFFE00000 // target aligned to region
        cmp     rax, rdx
        jnz     LOCAL_LABEL(RecordEscape_SATORI)               // cross region assignment. definitely escaping

    // 3) check if the target is exposed
        mov     eax, edi
        and     eax, 0x1FFFFF           // offset in the region
        shr     eax, 9                  // the bitmap qword with the bit for the target (a bit per 8 bytes)
        mov     rax, qword ptr [rdx + rax * 8]
        mov     r9, rdi
        shr     r9, 3                   // bt takes the bit index modulo 64
        bt      rax, r9
        jc      LOCAL_LABEL(RecordEscape_SATORI)               // target is exposed. record an escape.

    LOCAL_LABEL(JustAssign_SATORI):
ALTERNATE_ENTRY_WITH_UNWIND RhpAssignRefAVLocationNotHeap_SATORI
        mov     [rdi], rsi              // src is external/null, or the assignment is completely threadlocal
        ret

        // Not executed. Places the block below within one cache line where the barrier runs (the copy starts on a cache line).
        .fill ((64 - ((. - C_FUNC(RhpAssignRef_SATORI)) % 64)) % 64), 1, 0xCC
    LOCAL_LABEL(AssignAndMarkCards_SATORI):
ALTERNATE_ENTRY_WITH_UNWIND RhpAssignRefAVLocation_SATORI
        mov     [rdi], rsi

    // if src and dst are in the same region, cards are not needed
        xor     rsi, rdi
        shr     rsi, 21
        jnz     LOCAL_LABEL(CrossRegion_SATORI)
        ret

    LOCAL_LABEL(CrossRegion_SATORI):
    // dst is in another region - cards are needed if src is ephemeral (gen < 2)
        cmp     dword ptr [rdx + 16], 2
        jl      LOCAL_LABEL(MarkCards_SATORI)
    LOCAL_LABEL(Exit_SATORI):
        ret

        // Not executed. Places the card marking below within one cache line where the barrier runs, with the constant
        // on an 8-byte boundary: the block starts 6 bytes into a line.
        .fill ((70 - ((. - C_FUNC(RhpAssignRef_SATORI)) % 64)) % 64), 1, 0xCC
    LOCAL_LABEL(MarkCards_SATORI):
        .byte   0x49, 0xB9              // mov r9, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_SATORI_CardTable
        .quad   0xF0F0F0F0F0F0F0F0      // the page map

    // fetch card location for rdi
        mov     rdx, rdi
        shr     rdi, 30
        mov     rax, qword ptr [r9 + rdi * 8] // page
        sub     rdx, rax   // offset in page
        mov     r8,  rdx
        shr     rdx, 9     // card offset
        shr     r8,  20    // group index
        lea     r8,  [rax + r8 * 2 + 0x80] // group offset

     // SETTING CARD
     LOCAL_LABEL(SetCard_SATORI):
        cmp     byte ptr [rax + rdx], 0
        je      LOCAL_LABEL(DoSetCard_SATORI)
        ret
     LOCAL_LABEL(DoSetCard_SATORI):
        mov     byte ptr [rax + rdx], 1
     LOCAL_LABEL(SetGroup_SATORI):
        cmp     byte ptr [r8], 0
        jne     LOCAL_LABEL(Exit_SATORI)
        mov     byte ptr [r8], 1
     LOCAL_LABEL(SetPage_SATORI):
        cmp     byte ptr [rax], 0
        jne     LOCAL_LABEL(Exit_SATORI)
        // DIRTY on purpose: a racing REMEMBERED store could overwrite another thread's DIRTY. That is possible
        // without concurrent GC too, cards are also dirtied regardless of it (see SatoriGC::PublishObject).
        mov     byte ptr [rax], 4
        ret

    // this is expected to be rare.
    LOCAL_LABEL(RecordEscape_SATORI):

    // 4) check if the source is escaped
        lea     eax, [rsi + 8]                // escape bit is MT + 1
        and     eax, 0x1FFFFF                 // offset in the region
        shr     eax, 9                        // the bitmap qword with the bit (a bit per 8 bytes)
        mov     rax, qword ptr [rdx + rax * 8]
        lea     r9, [rsi + 8]
        shr     r9, 3                         // bt takes the bit index modulo 64
        bt      rax, r9
        jc      LOCAL_LABEL(AssignAndMarkCards_SATORI)         // source is already escaped.

        // Align rsp
        mov  r9, rsp
        and  rsp, -16

        // save rsp, rdi, rsi and rdx
        push r9
        push rdi
        push rsi
        push rdx

        // also save xmm0, in case it is used for stack clearing.
        // Hopefully EscapeFn cannot corrupt other xmm regs, since there is no float math or vectorizable code in there.
        sub     rsp, 16
        movdqa  [rsp], xmm0

        // void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [rdx + 8]

        movdqa  xmm0, [rsp]
        add     rsp, 16

        pop     rdx
        pop     rsi
        pop     rdi
        pop     rsp
        jmp     LOCAL_LABEL(AssignAndMarkCards_SATORI)
LEAF_END_MARKED RhpAssignRef_SATORI, _TEXT

//
// The GC does not mark concurrently and the next GC is a full GC, thus cards are not needed.
// Used only when concurrent GC is disabled. Then the barrier state changes only while EE is suspended, when the GC
// also switches the barrier, thus this barrier does not check the state.
//
        .balign 16
LEAF_ENTRY RhpAssignRef_SATORI2, _TEXT
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    // check if src is in heap
        NOP_6_BYTE // padding for alignment of constant
        .byte   0x48, 0xB8              // mov rax, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_SATORI2_CardBundleTable
        .quad   0xF0F0F0F0F0F0F0F0      // the page byte map
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedEntry_SATORI2
        mov     r8, rsi
        shr     r8, 30                                  //  src page index
        cmp     byte ptr [rax + r8], 0
        je      LOCAL_LABEL(JustAssign_SATORI2)                 // src not in heap
#else
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedEntry_SATORI2
#endif

    // check for escaping assignment
    // 1) check if we own the source region
        mov     rdx, rsi
        and     rdx, 0xFFFFFFFFFFE00000  // source region
#ifndef FEATURE_SATORI_EXTERNAL_OBJECTS
        jz      LOCAL_LABEL(JustAssign_SATORI2)                 // assigning null
#endif
#ifdef TARGET_APPLE
        mov     rax,  gs:[0]            // thread tag
#else
        mov     rax,  fs:[0]            // thread tag
#endif
        cmp     qword ptr [rdx], rax
        jne     LOCAL_LABEL(JustAssign_SATORI2)         // not local to this thread, no cards needed

    // 2) check if the src and dst are from the same region
        mov     rax, rdi
        and     rax, 0xFFFFFFFFFFE00000 // target aligned to region
        cmp     rax, rdx
        jnz     LOCAL_LABEL(RecordEscape_SATORI2)               // cross region assignment. definitely escaping

    // 3) check if the target is exposed
        mov     eax, edi
        and     eax, 0x1FFFFF           // offset in the region
        shr     eax, 9                  // the bitmap qword with the bit for the target (a bit per 8 bytes)
        mov     rax, qword ptr [rdx + rax * 8]
        mov     r9, rdi
        shr     r9, 3                   // bt takes the bit index modulo 64
        bt      rax, r9
        jc      LOCAL_LABEL(RecordEscape_SATORI2)               // target is exposed. record an escape.

    LOCAL_LABEL(JustAssign_SATORI2):
ALTERNATE_ENTRY_WITH_UNWIND RhpAssignRefAVLocationNotHeap_SATORI2
        mov     [rdi], rsi              // src is external/null, or the assignment does not need cards
        ret

    // this is expected to be rare.
    LOCAL_LABEL(RecordEscape_SATORI2):

    // 4) check if the source is escaped
        lea     eax, [rsi + 8]                // escape bit is MT + 1
        and     eax, 0x1FFFFF                 // offset in the region
        shr     eax, 9                        // the bitmap qword with the bit (a bit per 8 bytes)
        mov     rax, qword ptr [rdx + rax * 8]
        lea     r9, [rsi + 8]
        shr     r9, 3                         // bt takes the bit index modulo 64
        bt      rax, r9
        jc      LOCAL_LABEL(JustAssign_SATORI2)         // source is already escaped.

        // Align rsp
        mov  r9, rsp
        and  rsp, -16

        // save rsp, rdi, rsi and rdx
        push r9
        push rdi
        push rsi
        push rdx

        // also save xmm0, in case it is used for stack clearing.
        // Hopefully EscapeFn cannot corrupt other xmm regs, since there is no float math or vectorizable code in there.
        sub     rsp, 16
        movdqa  [rsp], xmm0

        // void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [rdx + 8]

        movdqa  xmm0, [rsp]
        add     rsp, 16

        pop     rdx
        pop     rsi
        pop     rdi
        pop     rsp
        jmp     LOCAL_LABEL(JustAssign_SATORI2)
LEAF_END_MARKED RhpAssignRef_SATORI2, _TEXT

//
// The GC marks concurrently and the next GC is not a full GC.
// The cards are dirtied, but only if src is ephemeral (gen < 2). A gen1 GC does not mark through tenured
// objects and references to them do not need to be remembered.
//
        .balign 16
LEAF_ENTRY RhpAssignRef_SATORI_CONCURRENT, _TEXT
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    // check if src is in heap
        NOP_6_BYTE // padding for alignment of constant
        .byte   0x48, 0xB8              // mov rax, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_SATORI_CONCURRENT_CardBundleTable
        .quad   0xF0F0F0F0F0F0F0F0      // the page byte map
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedEntry_SATORI_CONCURRENT
        mov     r8, rsi
        shr     r8, 30                                  //  src page index
        cmp     byte ptr [rax + r8], 0
        je      LOCAL_LABEL(JustAssign_SATORI_CONCURRENT)                 // src not in heap
#else
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedEntry_SATORI_CONCURRENT
#endif

    // check for escaping assignment
    // 1) check if we own the source region
        mov     rdx, rsi
        and     rdx, 0xFFFFFFFFFFE00000  // source region
#ifndef FEATURE_SATORI_EXTERNAL_OBJECTS
        jz      LOCAL_LABEL(JustAssign_SATORI_CONCURRENT)                 // assigning null
#endif
#ifdef TARGET_APPLE
        mov     rax,  gs:[0]            // thread tag
#else
        mov     rax,  fs:[0]            // thread tag
#endif
        cmp     qword ptr [rdx], rax
        jne     LOCAL_LABEL(AssignAndMarkCards_SATORI_CONCURRENT)         // not local to this thread

    // 2) check if the src and dst are from the same region
        mov     rax, rdi
        and     rax, 0xFFFFFFFFFFE00000 // target aligned to region
        cmp     rax, rdx
        jnz     LOCAL_LABEL(RecordEscape_SATORI_CONCURRENT)               // cross region assignment. definitely escaping

    // 3) check if the target is exposed
        mov     eax, edi
        and     eax, 0x1FFFFF           // offset in the region
        shr     eax, 9                  // the bitmap qword with the bit for the target (a bit per 8 bytes)
        mov     rax, qword ptr [rdx + rax * 8]
        mov     r9, rdi
        shr     r9, 3                   // bt takes the bit index modulo 64
        bt      rax, r9
        jc      LOCAL_LABEL(RecordEscape_SATORI_CONCURRENT)               // target is exposed. record an escape.

    LOCAL_LABEL(JustAssign_SATORI_CONCURRENT):
ALTERNATE_ENTRY_WITH_UNWIND RhpAssignRefAVLocationNotHeap_SATORI_CONCURRENT
        mov     [rdi], rsi              // src is external/null, or the assignment is completely threadlocal
        ret

        // Not executed. Aligns the constant below: the padding, the 3-byte store and the 2-byte opcode
        // end on an 8-byte boundary.
        .p2align 3
        NOP_3_BYTE
    LOCAL_LABEL(AssignAndMarkCards_SATORI_CONCURRENT):
ALTERNATE_ENTRY_WITH_UNWIND RhpAssignRefAVLocation_SATORI_CONCURRENT
        mov     [rdi], rsi
        .byte   0x49, 0xB9              // mov r9, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_SATORI_CONCURRENT_CardTable
        .quad   0xF0F0F0F0F0F0F0F0      // the page map

    // if src is tenured (gen >= 2), cards are not needed
        cmp     dword ptr [rdx + 16], 2
        jge     LOCAL_LABEL(Exit_SATORI_CONCURRENT)

    // fetch card location for rdi
        mov     rdx, rdi
        shr     rdi, 30
        mov     rax, qword ptr [r9 + rdi * 8] // page
        sub     rdx, rax   // offset in page
        mov     r8,  rdx
        shr     rdx, 9     // card offset
        shr     r8,  20    // group index
        lea     r8,  [rax + r8 * 2 + 0x80] // group offset

     // DIRTYING CARD
     LOCAL_LABEL(DirtyCard_SATORI_CONCURRENT):
        mov     byte ptr [rax + rdx], 4
     LOCAL_LABEL(DirtyGroup_SATORI_CONCURRENT):
        cmp     byte ptr [r8], 4
        jne     LOCAL_LABEL(DoDirtyGroup_SATORI_CONCURRENT)
        ret
     LOCAL_LABEL(DoDirtyGroup_SATORI_CONCURRENT):
        mov     byte ptr [r8], 4
     LOCAL_LABEL(DirtyPage_SATORI_CONCURRENT):
        cmp     byte ptr [rax], 4
        je      LOCAL_LABEL(Exit_SATORI_CONCURRENT)
        mov     byte ptr [rax], 4
     LOCAL_LABEL(Exit_SATORI_CONCURRENT):
        ret

    // this is expected to be rare.
    LOCAL_LABEL(RecordEscape_SATORI_CONCURRENT):

    // 4) check if the source is escaped
        lea     eax, [rsi + 8]                // escape bit is MT + 1
        and     eax, 0x1FFFFF                 // offset in the region
        shr     eax, 9                        // the bitmap qword with the bit (a bit per 8 bytes)
        mov     rax, qword ptr [rdx + rax * 8]
        lea     r9, [rsi + 8]
        shr     r9, 3                         // bt takes the bit index modulo 64
        bt      rax, r9
        jc      LOCAL_LABEL(AssignAndMarkCards_SATORI_CONCURRENT)         // source is already escaped.

        // Align rsp
        mov  r9, rsp
        and  rsp, -16

        // save rsp, rdi, rsi and rdx
        push r9
        push rdi
        push rsi
        push rdx

        // also save xmm0, in case it is used for stack clearing.
        // Hopefully EscapeFn cannot corrupt other xmm regs, since there is no float math or vectorizable code in there.
        sub     rsp, 16
        movdqa  [rsp], xmm0

        // void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [rdx + 8]

        movdqa  xmm0, [rsp]
        add     rsp, 16

        pop     rdx
        pop     rsi
        pop     rdi
        pop     rsp
        jmp     LOCAL_LABEL(AssignAndMarkCards_SATORI_CONCURRENT)
LEAF_END_MARKED RhpAssignRef_SATORI_CONCURRENT, _TEXT

//
// The GC marks concurrently and the next GC is a full GC.
// The cards are dirtied for any src, since a full GC marks through objects of any generation.
//
        .balign 16
LEAF_ENTRY RhpAssignRef_SATORI_CONCURRENT2, _TEXT
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    // check if src is in heap
        NOP_6_BYTE // padding for alignment of constant
        .byte   0x48, 0xB8              // mov rax, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_SATORI_CONCURRENT2_CardBundleTable
        .quad   0xF0F0F0F0F0F0F0F0      // the page byte map
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedEntry_SATORI_CONCURRENT2
        mov     r8, rsi
        shr     r8, 30                                  //  src page index
        cmp     byte ptr [rax + r8], 0
        je      LOCAL_LABEL(JustAssign_SATORI_CONCURRENT2)                 // src not in heap
#else
ALTERNATE_ENTRY_WITH_UNWIND RhpCheckedEntry_SATORI_CONCURRENT2
#endif

    // check for escaping assignment
    // 1) check if we own the source region
        mov     rdx, rsi
        and     rdx, 0xFFFFFFFFFFE00000  // source region
#ifndef FEATURE_SATORI_EXTERNAL_OBJECTS
        jz      LOCAL_LABEL(JustAssign_SATORI_CONCURRENT2)                 // assigning null
#endif
#ifdef TARGET_APPLE
        mov     rax,  gs:[0]            // thread tag
#else
        mov     rax,  fs:[0]            // thread tag
#endif
        cmp     qword ptr [rdx], rax
        jne     LOCAL_LABEL(AssignAndMarkCards_SATORI_CONCURRENT2)         // not local to this thread

    // 2) check if the src and dst are from the same region
        mov     rax, rdi
        and     rax, 0xFFFFFFFFFFE00000 // target aligned to region
        cmp     rax, rdx
        jnz     LOCAL_LABEL(RecordEscape_SATORI_CONCURRENT2)               // cross region assignment. definitely escaping

    // 3) check if the target is exposed
        mov     eax, edi
        and     eax, 0x1FFFFF           // offset in the region
        shr     eax, 9                  // the bitmap qword with the bit for the target (a bit per 8 bytes)
        mov     rax, qword ptr [rdx + rax * 8]
        mov     r9, rdi
        shr     r9, 3                   // bt takes the bit index modulo 64
        bt      rax, r9
        jc      LOCAL_LABEL(RecordEscape_SATORI_CONCURRENT2)               // target is exposed. record an escape.

    LOCAL_LABEL(JustAssign_SATORI_CONCURRENT2):
ALTERNATE_ENTRY_WITH_UNWIND RhpAssignRefAVLocationNotHeap_SATORI_CONCURRENT2
        mov     [rdi], rsi              // src is external/null, or the assignment is completely threadlocal
        ret

        // Not executed. Aligns the constant below: the padding, the 3-byte store and the 2-byte opcode
        // end on an 8-byte boundary.
        .p2align 3
        NOP_3_BYTE
    LOCAL_LABEL(AssignAndMarkCards_SATORI_CONCURRENT2):
ALTERNATE_ENTRY_WITH_UNWIND RhpAssignRefAVLocation_SATORI_CONCURRENT2
        mov     [rdi], rsi

    // fetch card location for rdi
        .byte   0x49, 0xB9              // mov r9, imm64
ALTERNATE_ENTRY_WITH_UNWIND PatchableValue_AssignRef_SATORI_CONCURRENT2_CardTable
        .quad   0xF0F0F0F0F0F0F0F0      // the page map
        mov     rdx, rdi
        shr     rdi, 30
        mov     rax, qword ptr [r9 + rdi * 8] // page
        sub     rdx, rax   // offset in page
        mov     r8,  rdx
        shr     rdx, 9     // card offset
        shr     r8,  20    // group index
        lea     r8,  [rax + r8 * 2 + 0x80] // group offset

     // DIRTYING CARD
     LOCAL_LABEL(DirtyCard_SATORI_CONCURRENT2):
        mov     byte ptr [rax + rdx], 4
     LOCAL_LABEL(DirtyGroup_SATORI_CONCURRENT2):
        cmp     byte ptr [r8], 4
        jne     LOCAL_LABEL(DoDirtyGroup_SATORI_CONCURRENT2)
        ret
     LOCAL_LABEL(DoDirtyGroup_SATORI_CONCURRENT2):
        mov     byte ptr [r8], 4
     LOCAL_LABEL(DirtyPage_SATORI_CONCURRENT2):
        cmp     byte ptr [rax], 4
        je      LOCAL_LABEL(Exit_SATORI_CONCURRENT2)
        mov     byte ptr [rax], 4
     LOCAL_LABEL(Exit_SATORI_CONCURRENT2):
        ret

    // this is expected to be rare.
    LOCAL_LABEL(RecordEscape_SATORI_CONCURRENT2):

    // 4) check if the source is escaped
        lea     eax, [rsi + 8]                // escape bit is MT + 1
        and     eax, 0x1FFFFF                 // offset in the region
        shr     eax, 9                        // the bitmap qword with the bit (a bit per 8 bytes)
        mov     rax, qword ptr [rdx + rax * 8]
        lea     r9, [rsi + 8]
        shr     r9, 3                         // bt takes the bit index modulo 64
        bt      rax, r9
        jc      LOCAL_LABEL(AssignAndMarkCards_SATORI_CONCURRENT2)         // source is already escaped.

        // Align rsp
        mov  r9, rsp
        and  rsp, -16

        // save rsp, rdi, rsi and rdx
        push r9
        push rdi
        push rsi
        push rdx

        // also save xmm0, in case it is used for stack clearing.
        // Hopefully EscapeFn cannot corrupt other xmm regs, since there is no float math or vectorizable code in there.
        sub     rsp, 16
        movdqa  [rsp], xmm0

        // void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [rdx + 8]

        movdqa  xmm0, [rsp]
        add     rsp, 16

        pop     rdx
        pop     rsi
        pop     rdi
        pop     rsp
        jmp     LOCAL_LABEL(AssignAndMarkCards_SATORI_CONCURRENT2)
LEAF_END_MARKED RhpAssignRef_SATORI_CONCURRENT2, _TEXT
