;; Licensed to the .NET Foundation under one or more agreements.
;; The .NET Foundation licenses this file to you under the MIT license.

#include "ksarm64.h"
#include "asmconstants.h"
#include "asmmacros.h"
#include "../satoriconstants.h"

;; The EE copies RhpCheckedAssignRef and RhpAssignRef as one block and runs them from the copy (see
;; InitJITWriteBarrierHelpers). When the state of the GC tells what RhpAssignRef would check at run time, the GC asks
;; the EE to copy a variant of RhpAssignRef over it in the copy (see GCWriteBarrierVariant and ToggleWriteBarrier).
;; The variants are described in amd64\writebarrier.asm.
;;
;; RhpAssignRef has room for any of the variants. They have the same code ahead of their CheckedEntry, so that
;; RhpCheckedAssignRef can jump to RhpCheckedEntry in the copy, whichever variant is there.
;; RhpCheckedAssignRef and RhpAssignRef start on cache lines, thus they do in the copy too, and the variants start
;; on cache lines as well, so that the code that they align is aligned in the copy.
;;
;; The values that the barriers use (the page map, the page byte map and the address of the barrier state) are in
;; patchable literal pools (see GCWriteBarrierPatchableValue), so that they remain correct no matter where the barriers
;; are copied to. Each pool is at the end of its helper or variant and is copied with it. The pools are 8-byte aligned,
;; since the EE patches them with single 8-byte stores.

;; The space for RhpAssignRef and its variants
#define ASSIGN_REF_SIZE 0x280

    ;; The area of the helpers (see LEAF_ENTRY), with 64 byte alignment, so that they can start on cache lines
    AREA    _TEXT,ALIGN=6,CODE,READONLY

;; JIT_CheckedWriteBarrier(Object** dst, Object* src)
;;
;; Write barrier for writes to objects that may reside
;; on the managed heap.
;;
;; On entry:
;;   x14 : the destination address (LHS of the assignment).
;;         May not be a heap location (hence the checked).
;;   x15 : the object reference (RHS of the assignment).
;;
;; On exit:
;;   x12  : trashed
;;   x14  : preserved (the destination address is not modified)
;;   x15  : trashed
;;   x16  : trashed (ip0)
;;   x17  : trashed (ip1)
        ALIGN 64
    LEAF_ENTRY RhpCheckedAssignRef, _TEXT
    ;; See if dst is in GCHeap
        ldr     x16, PatchableValue_CheckedAssignRef_CardBundleTable
    ;; Native destinations may carry a top-byte tag (TBI/MTE).
    ;; Ignore the tag only for the page-map lookup; preserve x14 for the store.
        ubfx    x17, x14, #SATORI_PAGE_BITS, #SATORI_PAGE_MAP_BITS    ;; dst page index
        ldrb    w12, [x16, x17]
        cbnz    x12, RhpCheckedEntry                                   ;; x16 - the page byte map

NotInHeap
    ALTERNATE_ENTRY RhpCheckedAssignRefAVLocation
        str  x15, [x14]
        ret  lr

    ;; The patchable value, see GCWriteBarrierPatchableValue. It is not in the pool of RhpAssignRef, which the
    ;; variants replace.
        ALIGN 8
    PATCH_LABEL PatchableValue_CheckedAssignRef_CardBundleTable
        DCQ 0
    LEAF_END_MARKED RhpCheckedAssignRef

;; JIT_WriteBarrier(Object** dst, Object* src)
;;
;; Write barrier for writes to objects that are known to
;; reside on the managed heap.
;;
;; On entry:
;;   x14  : the destination address (LHS of the assignment)
;;   x15  : the object reference (RHS of the assignment)
;;
;; On exit:
;;   x12  : trashed
;;   x14  : preserved (the destination address is not modified)
;;   x15  : trashed
;;   x16  : trashed (ip0)
;;   x17  : trashed (ip1)
;;
        ALIGN 64
    LEAF_ENTRY RhpAssignRef, _TEXT
    ; check for escaping assignment
    ; 1) check if we own the source region
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
        ldr     x16, PatchableValue_AssignRef_CardBundleTable
    ALTERNATE_ENTRY RhpCheckedEntry
        lsr     x17, x15, #30                   ; src page index
        ldrb    w12, [x16, x17]
        cbz     x12, JustAssign_SATORI_DYNAMIC                 ; null or external (immutable) object
#else
    ALTERNATE_ENTRY RhpCheckedEntry
        cbz     x15, JustAssign_SATORI_DYNAMIC                 ; assigning null
#endif
        and     x16,  x15, #0xFFFFFFFFFFE00000  ; source region
        ldr     x12, [x16]                      ; region tag
        cmp     x12, x18                        ; x18 - TEB
        bne     AssignAndMarkCards_SATORI_DYNAMIC              ; not local to this thread

    ; 2) check if the src and dst are from the same region
        and     x12, x14, #0xFFFFFFFFFFE00000   ; target aligned to region
        cmp     x12, x16
        bne     RecordEscape_SATORI_DYNAMIC                    ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        ubfx        x17, x14,#9,#12             ; word index = (dst >> 9) & 0x1FFFFF
        ldr         x17, [x16, x17, lsl #3]     ; mark word = [region + index * 8]
        lsr         x12, x14, #3                ; bit = (dst >> 3) [& 63]
        lsr         x17, x17, x12
        tbnz        x17, #0, RecordEscape_SATORI_DYNAMIC       ; target is exposed. record an escape.

    ; UNORDERED! src is external/null, or the assignment is completely threadlocal
JustAssign_SATORI_DYNAMIC
    ALTERNATE_ENTRY RhpAssignRefAVLocationNotHeap
        str  x15, [x14]
        ret  lr

    ; Not executed. Places the block below within one cache line.
        ALIGN 64
AssignAndMarkCards_SATORI_DYNAMIC
    ALTERNATE_ENTRY RhpAssignRefAVLocation
        stlr    x15, [x14]

    ; The barrier state may become concurrent while EE runs, thus this barrier reads it.
    ; This must be done after the assignment (in program order).
        ldr     x17, PatchableValue_AssignRef_BarrierStateAddress            ; the address of the barrier state (g_write_barrier_state)
        ldr     x17, [x17]

    ; if src and dst are in the same region, cards are needed only while concurrent (state == 1)
        and     x12, x14, #0xFFFFFFFFFFE00000   ; target aligned to region
        cmp     x12, x16
        bne     CrossRegion_SATORI_DYNAMIC
        tbnz    x17, #0, MarkCards_SATORI_DYNAMIC
        ret     lr

CrossRegion_SATORI_DYNAMIC
    ; if state == 2 we do not set or dirty cards.
        tbnz    x17, #1, ExitNoCards_SATORI_DYNAMIC

    ; dst is in another region - cards are needed if src is ephemeral (gen < 2), or while concurrent
        ldr     w12, [x16, 16]                  ; source region + 16 -> generation
        tbz     x12, #1, MarkCards_SATORI_DYNAMIC
        cbnz    x17, MarkCards_SATORI_DYNAMIC
ExitNoCards_SATORI_DYNAMIC
        ret     lr

    ; Not executed. Places the card marking below within one cache line.
        ALIGN 64
MarkCards_SATORI_DYNAMIC
    ; only x12, x15, x16 and x17 may be trashed here, so we keep the card offset in x12,
    ; the group address in x15, the page in x16, and reuse x17 for both the loaded byte
    ; and the value being stored. That avoids needing any extra temps.

    ; fetch card location for x14
        ldr     x12, PatchableValue_AssignRef_CardTable                  ; fetch the page map
        lsr     x16, x14, #30
        ldr     x16, [x12, x16, lsl #3]              ; page
        sub     x12, x14, x16   ; offset in page
        lsr     x15, x12, #20   ; group index
        lsr     x12, x12, #9    ; card offset
        add     x15, x16, x15, lsl #1   ; group address (page + index * 2)

    ; check if concurrent marking is in progress
        cbnz    x17, DirtyCard_SATORI_DYNAMIC

    ; SETTING CARD FOR X14
SetCard_SATORI_DYNAMIC
        ldrb    w17, [x16, x12]
        cbz     w17, DoSetCard_SATORI_DYNAMIC
        ret     lr
DoSetCard_SATORI_DYNAMIC
        mov     w17, #1
        strb    w17, [x16, x12]
SetGroup_SATORI_DYNAMIC
        ldrb    w17, [x15, #0x80]
        cbnz    w17, CardSet_SATORI_DYNAMIC
        mov     w17, #1
        strb    w17, [x15, #0x80]
SetPage_SATORI_DYNAMIC
        ldrb    w17, [x16]
        cbnz    w17, CardSet_SATORI_DYNAMIC
        ; DIRTY on purpose: a racing REMEMBERED store could overwrite another thread's DIRTY.
        mov     w17, #4
        strb    w17, [x16]

CardSet_SATORI_DYNAMIC
    ; check if concurrent marking is still not in progress
    ; (uses x17 so that the card offset in x12 stays live for DirtyCard)
        ldr     x17, PatchableValue_AssignRef_BarrierStateAddress            ; the address of the barrier state
        ldr     x17, [x17]                      ; !barrier state -> !concurrent
        cbnz    x17, DirtyCard_SATORI_DYNAMIC

Exit_SATORI_DYNAMIC
        ret  lr

    ; DIRTYING CARD FOR X14
DirtyCard_SATORI_DYNAMIC
        add     x12, x16, x12   ; card address
        mov     w17, #4
        ; must be after the field write to allow concurrent clean
        stlrb   w17, [x12]
DirtyGroup_SATORI_DYNAMIC
        ldrb    w12, [x15, #0x80]
        tbz     w12, #2, DoDirtyGroup_SATORI_DYNAMIC
        ret     lr
DoDirtyGroup_SATORI_DYNAMIC
        strb    w17, [x15, #0x80]
DirtyPage_SATORI_DYNAMIC
        ldrb    w12, [x16]
        tbnz    w12, #2, Exit_SATORI_DYNAMIC
        strb    w17, [x16]
        ret  lr

    ; this is expected to be rare.
RecordEscape_SATORI_DYNAMIC

    ; 4) check if the source is escaped (x16 has source region)
        add         x12, x15, #8                   ; escape bit is MT + 1
        ubfx        x17, x12, #9,#12               ; word index = (dst >> 9) & 0x1FFFFF
        ldr         x17, [x16, x17, lsl #3]        ; mark word = [region + index * 8]
        lsr         x12, x12, #3                   ; bit = (dst >> 3) [& 63]
        lsr         x17, x17, x12
        tbnz        x17, #0, AssignAndMarkCards_SATORI_DYNAMIC    ; source is already escaped.

        ; because of the barrier call convention we need to preserve x0-x11, x13, x14, x15 and x30.
        ; x12, x16 and x17 are trashable per the barrier contract, and x12 is rewritten before
        ; being read again. x29 is callee-saved, so EscapeFn preserves it for us.
        ; also save q0, in case it is used for stack clearing.
        ; Hopefully EscapeFn cannot corrupt other vector regs, since there is no float math or vectorizable code in there.

        stp     x30, x0, [sp, -16 * 9]!
        stp     x1,  x2, [sp, 16 * 1]
        stp     x3,  x4, [sp, 16 * 2]
        stp     x5,  x6, [sp, 16 * 3]
        stp     x7,  x8, [sp, 16 * 4]
        stp     x9,  x10,[sp, 16 * 5]
        stp     x11, x13,[sp, 16 * 6]
        stp     x14, x15,[sp, 16 * 7]
        str     q0,      [sp, 16 * 8]

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        ; mov  x0, x14  EscapeFn does not use dst, it is just to avoid arg shuffle on x64
        mov  x1, x15
        mov  x2, x16                        ; source region
        ldr  x12, [x16, #8]                 ; EscapeFn address
        blr  x12

        ldr     q0,      [sp, 16 * 8]
        ldp     x14, x15,[sp, 16 * 7]
        ldp     x11, x13,[sp, 16 * 6]
        ldp     x9,  x10,[sp, 16 * 5]
        ldp     x7,  x8, [sp, 16 * 4]
        ldp     x5,  x6, [sp, 16 * 3]
        ldp     x3,  x4, [sp, 16 * 2]
        ldp     x1,  x2, [sp, 16 * 1]
        ldp     x30, x0, [sp], 16 * 9

        and     x16, x15, #0xFFFFFFFFFFE00000  ; source region
        b       AssignAndMarkCards_SATORI_DYNAMIC

    ;; The patchable values, see GCWriteBarrierPatchableValue.
        ALIGN 8
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    PATCH_LABEL PatchableValue_AssignRef_CardBundleTable
        DCQ 0
#endif
    PATCH_LABEL PatchableValue_AssignRef_BarrierStateAddress
        DCQ 0
    PATCH_LABEL PatchableValue_AssignRef_CardTable
        DCQ 0

    ;; Not executed. The space for the variants.
RhpAssignRef_Padding
        SPACE ASSIGN_REF_SIZE - (RhpAssignRef_Padding - RhpAssignRef)
    LEAF_END_MARKED RhpAssignRef

;-----------------------------------------------------------------------------
; void RhpAssignRef_SATORI_DYNAMIC2(Object** dst, Object* src)
;
; The GC does not mark concurrently yet and the next GC is a full GC, thus cards are not needed until it does.
; The barrier state may become concurrent while EE runs, thus this barrier reads it. Once it is concurrent, the cards
; are dirtied for any src, since a full GC marks through objects of any generation.
;
; On entry:
;   x14  : the destination address (LHS of the assignment)
;   x15  : the object reference (RHS of the assignment)
;
; On exit:
;   x12  : trashed
;   x14  : preserved (the destination address is not modified)
;   x15  : trashed
;   x16  : trashed (ip0)
;   x17  : trashed (ip1)
;
        ALIGN 64
    LEAF_ENTRY RhpAssignRef_SATORI_DYNAMIC2, _TEXT
    ; check for escaping assignment
    ; 1) check if we own the source region
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
        ldr     x16, PatchableValue_AssignRef_SATORI_DYNAMIC2_CardBundleTable
    ALTERNATE_ENTRY RhpCheckedEntry_SATORI_DYNAMIC2
        lsr     x17, x15, #30                   ; src page index
        ldrb    w12, [x16, x17]
        cbz     x12, JustAssign_SATORI_DYNAMIC2                 ; null or external (immutable) object
#else
    ALTERNATE_ENTRY RhpCheckedEntry_SATORI_DYNAMIC2
        cbz     x15, JustAssign_SATORI_DYNAMIC2                 ; assigning null
#endif
        and     x16,  x15, #0xFFFFFFFFFFE00000  ; source region
        ldr     x12, [x16]                      ; region tag
        cmp     x12, x18                        ; x18 - TEB
        bne     AssignAndMarkCards_SATORI_DYNAMIC2              ; not local to this thread

    ; 2) check if the src and dst are from the same region
        and     x12, x14, #0xFFFFFFFFFFE00000   ; target aligned to region
        cmp     x12, x16
        bne     RecordEscape_SATORI_DYNAMIC2                    ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        ubfx        x17, x14,#9,#12             ; word index = (dst >> 9) & 0x1FFFFF
        ldr         x17, [x16, x17, lsl #3]     ; mark word = [region + index * 8]
        lsr         x12, x14, #3                ; bit = (dst >> 3) [& 63]
        lsr         x17, x17, x12
        tbnz        x17, #0, RecordEscape_SATORI_DYNAMIC2       ; target is exposed. record an escape.

    ; UNORDERED! src is external/null, or the assignment is completely threadlocal
JustAssign_SATORI_DYNAMIC2
    ALTERNATE_ENTRY RhpAssignRefAVLocationNotHeap_SATORI_DYNAMIC2
        str  x15, [x14]
        ret  lr

AssignAndMarkCards_SATORI_DYNAMIC2
    ALTERNATE_ENTRY RhpAssignRefAVLocation_SATORI_DYNAMIC2
        stlr    x15, [x14]

    ; The barrier state may become concurrent while EE runs, thus this barrier reads it.
    ; This must be done after the assignment (in program order).
        ldr     x17, PatchableValue_AssignRef_SATORI_DYNAMIC2_BarrierStateAddress            ; the address of the barrier state (g_write_barrier_state)
        ldr     x17, [x17]

    ; if state == 2 we do not set or dirty cards.
        tbnz    x17, #1, Exit_SATORI_DYNAMIC2

    ; only x12, x15, x16 and x17 may be trashed here, so we keep the card offset in x12,
    ; the group address in x15, the page in x16, and reuse x17 for the value being stored.

    ; fetch card location for x14
        ldr     x12, PatchableValue_AssignRef_SATORI_DYNAMIC2_CardTable ; fetch the page map
        lsr     x16, x14, #30
        ldr     x16, [x12, x16, lsl #3]              ; page
        sub     x12, x14, x16   ; offset in page
        lsr     x15, x12, #20   ; group index
        lsr     x12, x12, #9    ; card offset
        add     x15, x16, x15, lsl #1   ; group address (page + index * 2)

    ; DIRTYING CARD FOR X14
DirtyCard_SATORI_DYNAMIC2
        add     x12, x16, x12   ; card address
        mov     w17, #4
        ; must be after the field write to allow concurrent clean
        stlrb   w17, [x12]
DirtyGroup_SATORI_DYNAMIC2
        ldrb    w12, [x15, #0x80]
        tbz     w12, #2, DoDirtyGroup_SATORI_DYNAMIC2
        ret     lr
DoDirtyGroup_SATORI_DYNAMIC2
        strb    w17, [x15, #0x80]
DirtyPage_SATORI_DYNAMIC2
        ldrb    w12, [x16]
        tbnz    w12, #2, Exit_SATORI_DYNAMIC2
        strb    w17, [x16]
Exit_SATORI_DYNAMIC2
        ret  lr

    ; this is expected to be rare.
RecordEscape_SATORI_DYNAMIC2

    ; 4) check if the source is escaped (x16 has source region)
        add         x12, x15, #8                   ; escape bit is MT + 1
        ubfx        x17, x12, #9,#12               ; word index = (dst >> 9) & 0x1FFFFF
        ldr         x17, [x16, x17, lsl #3]        ; mark word = [region + index * 8]
        lsr         x12, x12, #3                   ; bit = (dst >> 3) [& 63]
        lsr         x17, x17, x12
        tbnz        x17, #0, AssignAndMarkCards_SATORI_DYNAMIC2    ; source is already escaped.

        ; because of the barrier call convention we need to preserve x0-x11, x13, x14, x15 and x30.
        ; x12, x16 and x17 are trashable per the barrier contract, and x12 is rewritten before
        ; being read again. x29 is callee-saved, so EscapeFn preserves it for us.
        ; also save q0, in case it is used for stack clearing.
        ; Hopefully EscapeFn cannot corrupt other vector regs, since there is no float math or vectorizable code in there.

        stp     x30, x0, [sp, -16 * 9]!
        stp     x1,  x2, [sp, 16 * 1]
        stp     x3,  x4, [sp, 16 * 2]
        stp     x5,  x6, [sp, 16 * 3]
        stp     x7,  x8, [sp, 16 * 4]
        stp     x9,  x10,[sp, 16 * 5]
        stp     x11, x13,[sp, 16 * 6]
        stp     x14, x15,[sp, 16 * 7]
        str     q0,      [sp, 16 * 8]

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        ; mov  x0, x14  EscapeFn does not use dst, it is just to avoid arg shuffle on x64
        mov  x1, x15
        mov  x2, x16                        ; source region
        ldr  x12, [x16, #8]                 ; EscapeFn address
        blr  x12

        ldr     q0,      [sp, 16 * 8]
        ldp     x14, x15,[sp, 16 * 7]
        ldp     x11, x13,[sp, 16 * 6]
        ldp     x9,  x10,[sp, 16 * 5]
        ldp     x7,  x8, [sp, 16 * 4]
        ldp     x5,  x6, [sp, 16 * 3]
        ldp     x3,  x4, [sp, 16 * 2]
        ldp     x1,  x2, [sp, 16 * 1]
        ldp     x30, x0, [sp], 16 * 9

        and     x16, x15, #0xFFFFFFFFFFE00000  ; source region
        b       AssignAndMarkCards_SATORI_DYNAMIC2

    ;; The patchable values, see GCWriteBarrierPatchableValue.
        ALIGN 8
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    PATCH_LABEL PatchableValue_AssignRef_SATORI_DYNAMIC2_CardBundleTable
        DCQ 0
#endif
    PATCH_LABEL PatchableValue_AssignRef_SATORI_DYNAMIC2_BarrierStateAddress
        DCQ 0
    PATCH_LABEL PatchableValue_AssignRef_SATORI_DYNAMIC2_CardTable
        DCQ 0
    LEAF_END_MARKED RhpAssignRef_SATORI_DYNAMIC2

;-----------------------------------------------------------------------------
; void RhpAssignRef_SATORI(Object** dst, Object* src)
;
; The GC does not mark concurrently and the next GC is not necessarily a full GC, thus cards are needed.
; Used only when concurrent GC is disabled. Then the barrier state changes only while EE is suspended, when the GC
; also switches the barrier, thus this barrier does not check the state.
;
; On entry:
;   x14  : the destination address (LHS of the assignment)
;   x15  : the object reference (RHS of the assignment)
;
; On exit:
;   x12  : trashed
;   x14  : preserved (the destination address is not modified)
;   x15  : trashed
;   x16  : trashed (ip0)
;   x17  : trashed (ip1)
;
; It starts on a cache line boundary, as the copy does, so that the blocks aligned below are aligned in the copy.
;
        ALIGN 64
    LEAF_ENTRY RhpAssignRef_SATORI, _TEXT
    ; check for escaping assignment
    ; 1) check if we own the source region
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
        ldr     x16, PatchableValue_AssignRef_SATORI_CardBundleTable
    ALTERNATE_ENTRY RhpCheckedEntry_SATORI
        lsr     x17, x15, #30                   ; src page index
        ldrb    w12, [x16, x17]
        cbz     x12, JustAssign_SATORI    ; null or external (immutable) object
#else
    ALTERNATE_ENTRY RhpCheckedEntry_SATORI
        cbz     x15, JustAssign_SATORI    ; assigning null
#endif
        and     x16,  x15, #0xFFFFFFFFFFE00000  ; source region
        ldr     x12, [x16]                      ; region tag
        cmp     x12, x18                        ; x18 - TEB
        bne     AssignAndMarkCards_SATORI ; not local to this thread

    ; 2) check if the src and dst are from the same region
        and     x12, x14, #0xFFFFFFFFFFE00000   ; target aligned to region
        cmp     x12, x16
        bne     RecordEscape_SATORI       ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        ubfx        x17, x14,#9,#12             ; word index = (dst >> 9) & 0x1FFFFF
        ldr         x17, [x16, x17, lsl #3]     ; mark word = [region + index * 8]
        lsr         x12, x14, #3                ; bit = (dst >> 3) [& 63]
        lsr         x17, x17, x12
        tbnz        x17, #0, RecordEscape_SATORI ; target is exposed. record an escape.

    ; UNORDERED! src is external/null, or the assignment is completely threadlocal
JustAssign_SATORI
    ALTERNATE_ENTRY RhpAssignRefAVLocationNotHeap_SATORI
        str  x15, [x14]
        ret  lr

    ; Not executed. Places the block below at the start of a cache line.
        ALIGN 64
AssignAndMarkCards_SATORI
    ALTERNATE_ENTRY RhpAssignRefAVLocation_SATORI
        stlr    x15, [x14]

    ; if src and dst are in the same region, cards are not needed
        and     x12, x14, #0xFFFFFFFFFFE00000   ; target aligned to region
        cmp     x12, x16
        bne     CrossRegion_SATORI
        ret     lr

CrossRegion_SATORI
    ; dst is in another region - cards are needed if src is ephemeral (gen < 2)
        ldr     w12, [x16, 16]                  ; source region + 16 -> generation
        tbz     x12, #1, MarkCards_SATORI
Exit_SATORI
        ret     lr

    ; Not executed. Places the card marking below within one cache line.
        ALIGN 64
MarkCards_SATORI
    ; only x12, x15, x16 and x17 may be trashed here, so we keep the card offset in x12,
    ; the group address in x15, the page in x16, and reuse x17 for both the loaded byte
    ; and the value being stored. That avoids needing any extra temps.

    ; fetch card location for x14
        ldr     x12, PatchableValue_AssignRef_SATORI_CardTable     ; fetch the page map
        lsr     x16, x14, #30
        ldr     x16, [x12, x16, lsl #3]              ; page
        sub     x12, x14, x16   ; offset in page
        lsr     x15, x12, #20   ; group index
        lsr     x12, x12, #9    ; card offset
        add     x15, x16, x15, lsl #1   ; group address (page + index * 2)

    ; SETTING CARD FOR X14
SetCard_SATORI
        ldrb    w17, [x16, x12]
        cbz     w17, DoSetCard_SATORI
        ret     lr
DoSetCard_SATORI
        mov     w17, #1
        strb    w17, [x16, x12]
SetGroup_SATORI
        ldrb    w17, [x15, #0x80]
        cbnz    w17, Exit_SATORI
        mov     w17, #1
        strb    w17, [x15, #0x80]
SetPage_SATORI
        ldrb    w17, [x16]
        cbnz    w17, Exit_SATORI
        ; DIRTY on purpose: a racing REMEMBERED store could overwrite another thread's DIRTY. That is possible
        ; without concurrent GC too, cards are also dirtied regardless of it (see SatoriGC::PublishObject).
        mov     w17, #4
        strb    w17, [x16]
        ret     lr

    ; this is expected to be rare.
RecordEscape_SATORI

    ; 4) check if the source is escaped (x16 has source region)
        add         x12, x15, #8                   ; escape bit is MT + 1
        ubfx        x17, x12, #9,#12               ; word index = (dst >> 9) & 0x1FFFFF
        ldr         x17, [x16, x17, lsl #3]        ; mark word = [region + index * 8]
        lsr         x12, x12, #3                   ; bit = (dst >> 3) [& 63]
        lsr         x17, x17, x12
        tbnz        x17, #0, AssignAndMarkCards_SATORI        ; source is already escaped.

        ; because of the barrier call convention we need to preserve x0-x11, x13, x14, x15 and x30.
        ; x12, x16 and x17 are trashable per the barrier contract, and x12 is rewritten before
        ; being read again. x29 is callee-saved, so EscapeFn preserves it for us.
        ; also save q0, in case it is used for stack clearing.
        ; Hopefully EscapeFn cannot corrupt other vector regs, since there is no float math or vectorizable code in there.

        stp     x30, x0, [sp, -16 * 9]!
        stp     x1,  x2, [sp, 16 * 1]
        stp     x3,  x4, [sp, 16 * 2]
        stp     x5,  x6, [sp, 16 * 3]
        stp     x7,  x8, [sp, 16 * 4]
        stp     x9,  x10,[sp, 16 * 5]
        stp     x11, x13,[sp, 16 * 6]
        stp     x14, x15,[sp, 16 * 7]
        str     q0,      [sp, 16 * 8]

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        ; mov  x0, x14  EscapeFn does not use dst, it is just to avoid arg shuffle on x64
        mov  x1, x15
        mov  x2, x16                       ; source region
        ldr  x12, [x16, #8]                 ; EscapeFn address
        blr  x12

        ldr     q0,      [sp, 16 * 8]
        ldp     x14, x15,[sp, 16 * 7]
        ldp     x11, x13,[sp, 16 * 6]
        ldp     x9,  x10,[sp, 16 * 5]
        ldp     x7,  x8, [sp, 16 * 4]
        ldp     x5,  x6, [sp, 16 * 3]
        ldp     x3,  x4, [sp, 16 * 2]
        ldp     x1,  x2, [sp, 16 * 1]
        ldp     x30, x0, [sp], 16 * 9

        and     x16, x15, #0xFFFFFFFFFFE00000  ; source region
        b       AssignAndMarkCards_SATORI

    ;; The patchable values, see GCWriteBarrierPatchableValue.
        ALIGN 8
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    PATCH_LABEL PatchableValue_AssignRef_SATORI_CardBundleTable
        DCQ 0
#endif
    PATCH_LABEL PatchableValue_AssignRef_SATORI_CardTable
        DCQ 0
    LEAF_END_MARKED RhpAssignRef_SATORI

;-----------------------------------------------------------------------------
; void RhpAssignRef_SATORI2(Object** dst, Object* src)
;
; The GC does not mark concurrently and the next GC is a full GC, thus cards are not needed.
; Used only when concurrent GC is disabled. Then the barrier state changes only while EE is suspended, when the GC
; also switches the barrier, thus this barrier does not check the state.
;
; On entry:
;   x14  : the destination address (LHS of the assignment)
;   x15  : the object reference (RHS of the assignment)
;
; On exit:
;   x12  : trashed
;   x14  : preserved (the destination address is not modified)
;   x15  : trashed
;   x16  : trashed (ip0)
;   x17  : trashed (ip1)
;
        ALIGN 64
    LEAF_ENTRY RhpAssignRef_SATORI2, _TEXT
    ; check for escaping assignment
    ; 1) check if we own the source region
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
        ldr     x16, PatchableValue_AssignRef_SATORI2_CardBundleTable
    ALTERNATE_ENTRY RhpCheckedEntry_SATORI2
        lsr     x17, x15, #30                   ; src page index
        ldrb    w12, [x16, x17]
        cbz     x12, JustAssign_SATORI2    ; null or external (immutable) object
#else
    ALTERNATE_ENTRY RhpCheckedEntry_SATORI2
        cbz     x15, JustAssign_SATORI2    ; assigning null
#endif
        and     x16,  x15, #0xFFFFFFFFFFE00000  ; source region
        ldr     x12, [x16]                      ; region tag
        cmp     x12, x18                        ; x18 - TEB
        bne     Assign_SATORI2 ; not local to this thread, no cards needed

    ; 2) check if the src and dst are from the same region
        and     x12, x14, #0xFFFFFFFFFFE00000   ; target aligned to region
        cmp     x12, x16
        bne     RecordEscape_SATORI2       ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        ubfx        x17, x14,#9,#12             ; word index = (dst >> 9) & 0x1FFFFF
        ldr         x17, [x16, x17, lsl #3]     ; mark word = [region + index * 8]
        lsr         x12, x14, #3                ; bit = (dst >> 3) [& 63]
        lsr         x17, x17, x12
        tbnz        x17, #0, RecordEscape_SATORI2 ; target is exposed. record an escape.

    ; UNORDERED! src is external/null, or the assignment is completely threadlocal
JustAssign_SATORI2
    ALTERNATE_ENTRY RhpAssignRefAVLocationNotHeap_SATORI2
        str  x15, [x14]
        ret  lr

    ; ordered, as in the barriers that mark cards, but no cards are needed
Assign_SATORI2
        stlr    x15, [x14]
        ret  lr

    ; this is expected to be rare.
RecordEscape_SATORI2

    ; 4) check if the source is escaped (x16 has source region)
        add         x12, x15, #8                   ; escape bit is MT + 1
        ubfx        x17, x12, #9,#12               ; word index = (dst >> 9) & 0x1FFFFF
        ldr         x17, [x16, x17, lsl #3]        ; mark word = [region + index * 8]
        lsr         x12, x12, #3                   ; bit = (dst >> 3) [& 63]
        lsr         x17, x17, x12
        tbnz        x17, #0, Assign_SATORI2        ; source is already escaped.

        ; because of the barrier call convention we need to preserve x0-x11, x13, x14, x15 and x30.
        ; x12, x16 and x17 are trashable per the barrier contract, and x12 is rewritten before
        ; being read again. x29 is callee-saved, so EscapeFn preserves it for us.
        ; also save q0, in case it is used for stack clearing.
        ; Hopefully EscapeFn cannot corrupt other vector regs, since there is no float math or vectorizable code in there.

        stp     x30, x0, [sp, -16 * 9]!
        stp     x1,  x2, [sp, 16 * 1]
        stp     x3,  x4, [sp, 16 * 2]
        stp     x5,  x6, [sp, 16 * 3]
        stp     x7,  x8, [sp, 16 * 4]
        stp     x9,  x10,[sp, 16 * 5]
        stp     x11, x13,[sp, 16 * 6]
        stp     x14, x15,[sp, 16 * 7]
        str     q0,      [sp, 16 * 8]

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        ; mov  x0, x14  EscapeFn does not use dst, it is just to avoid arg shuffle on x64
        mov  x1, x15
        mov  x2, x16                       ; source region
        ldr  x12, [x16, #8]                 ; EscapeFn address
        blr  x12

        ldr     q0,      [sp, 16 * 8]
        ldp     x14, x15,[sp, 16 * 7]
        ldp     x11, x13,[sp, 16 * 6]
        ldp     x9,  x10,[sp, 16 * 5]
        ldp     x7,  x8, [sp, 16 * 4]
        ldp     x5,  x6, [sp, 16 * 3]
        ldp     x3,  x4, [sp, 16 * 2]
        ldp     x1,  x2, [sp, 16 * 1]
        ldp     x30, x0, [sp], 16 * 9

        b       Assign_SATORI2

    ;; The patchable values, see GCWriteBarrierPatchableValue.
        ALIGN 8
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    PATCH_LABEL PatchableValue_AssignRef_SATORI2_CardBundleTable
        DCQ 0
#endif
    LEAF_END_MARKED RhpAssignRef_SATORI2

;-----------------------------------------------------------------------------
; void RhpAssignRef_SATORI_CONCURRENT(Object** dst, Object* src)
;
; The GC marks concurrently and the next GC is not a full GC.
; The cards are dirtied, but only if src is ephemeral (gen < 2). A gen1 GC does not mark through tenured
; objects and references to them do not need to be remembered.
;
; On entry:
;   x14  : the destination address (LHS of the assignment)
;   x15  : the object reference (RHS of the assignment)
;
; On exit:
;   x12  : trashed
;   x14  : preserved (the destination address is not modified)
;   x15  : trashed
;   x16  : trashed (ip0)
;   x17  : trashed (ip1)
;
        ALIGN 64
    LEAF_ENTRY RhpAssignRef_SATORI_CONCURRENT, _TEXT
    ; check for escaping assignment
    ; 1) check if we own the source region
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
        ldr     x16, PatchableValue_AssignRef_SATORI_CONCURRENT_CardBundleTable
    ALTERNATE_ENTRY RhpCheckedEntry_SATORI_CONCURRENT
        lsr     x17, x15, #30                   ; src page index
        ldrb    w12, [x16, x17]
        cbz     x12, JustAssign_SATORI_CONCURRENT                 ; null or external (immutable) object
#else
    ALTERNATE_ENTRY RhpCheckedEntry_SATORI_CONCURRENT
        cbz     x15, JustAssign_SATORI_CONCURRENT                 ; assigning null
#endif
        and     x16,  x15, #0xFFFFFFFFFFE00000  ; source region
        ldr     x12, [x16]                      ; region tag
        cmp     x12, x18                        ; x18 - TEB
        bne     AssignAndMarkCards_SATORI_CONCURRENT              ; not local to this thread

    ; 2) check if the src and dst are from the same region
        and     x12, x14, #0xFFFFFFFFFFE00000   ; target aligned to region
        cmp     x12, x16
        bne     RecordEscape_SATORI_CONCURRENT                    ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        ubfx        x17, x14,#9,#12             ; word index = (dst >> 9) & 0x1FFFFF
        ldr         x17, [x16, x17, lsl #3]     ; mark word = [region + index * 8]
        lsr         x12, x14, #3                ; bit = (dst >> 3) [& 63]
        lsr         x17, x17, x12
        tbnz        x17, #0, RecordEscape_SATORI_CONCURRENT       ; target is exposed. record an escape.

    ; UNORDERED! src is external/null, or the assignment is completely threadlocal
JustAssign_SATORI_CONCURRENT
    ALTERNATE_ENTRY RhpAssignRefAVLocationNotHeap_SATORI_CONCURRENT
        str  x15, [x14]
        ret  lr

AssignAndMarkCards_SATORI_CONCURRENT
    ALTERNATE_ENTRY RhpAssignRefAVLocation_SATORI_CONCURRENT
        stlr    x15, [x14]

    ; if src is tenured (gen >= 2), cards are not needed
        ldr     w12, [x16, 16]                  ; source region + 16 -> generation
        tbnz    x12, #1, Exit_SATORI_CONCURRENT

    ; only x12, x15, x16 and x17 may be trashed here, so we keep the card offset in x12,
    ; the group address in x15, the page in x16, and reuse x17 for the value being stored.

    ; fetch card location for x14
        ldr     x12, PatchableValue_AssignRef_SATORI_CONCURRENT_CardTable ; fetch the page map
        lsr     x16, x14, #30
        ldr     x16, [x12, x16, lsl #3]              ; page
        sub     x12, x14, x16   ; offset in page
        lsr     x15, x12, #20   ; group index
        lsr     x12, x12, #9    ; card offset
        add     x15, x16, x15, lsl #1   ; group address (page + index * 2)

    ; DIRTYING CARD FOR X14
DirtyCard_SATORI_CONCURRENT
        add     x12, x16, x12   ; card address
        mov     w17, #4
        ; must be after the field write to allow concurrent clean
        stlrb   w17, [x12]
DirtyGroup_SATORI_CONCURRENT
        ldrb    w12, [x15, #0x80]
        tbz     w12, #2, DoDirtyGroup_SATORI_CONCURRENT
        ret     lr
DoDirtyGroup_SATORI_CONCURRENT
        strb    w17, [x15, #0x80]
DirtyPage_SATORI_CONCURRENT
        ldrb    w12, [x16]
        tbnz    w12, #2, Exit_SATORI_CONCURRENT
        strb    w17, [x16]
Exit_SATORI_CONCURRENT
        ret  lr

    ; this is expected to be rare.
RecordEscape_SATORI_CONCURRENT

    ; 4) check if the source is escaped (x16 has source region)
        add         x12, x15, #8                   ; escape bit is MT + 1
        ubfx        x17, x12, #9,#12               ; word index = (dst >> 9) & 0x1FFFFF
        ldr         x17, [x16, x17, lsl #3]        ; mark word = [region + index * 8]
        lsr         x12, x12, #3                   ; bit = (dst >> 3) [& 63]
        lsr         x17, x17, x12
        tbnz        x17, #0, AssignAndMarkCards_SATORI_CONCURRENT    ; source is already escaped.

        ; because of the barrier call convention we need to preserve x0-x11, x13, x14, x15 and x30.
        ; x12, x16 and x17 are trashable per the barrier contract, and x12 is rewritten before
        ; being read again. x29 is callee-saved, so EscapeFn preserves it for us.
        ; also save q0, in case it is used for stack clearing.
        ; Hopefully EscapeFn cannot corrupt other vector regs, since there is no float math or vectorizable code in there.

        stp     x30, x0, [sp, -16 * 9]!
        stp     x1,  x2, [sp, 16 * 1]
        stp     x3,  x4, [sp, 16 * 2]
        stp     x5,  x6, [sp, 16 * 3]
        stp     x7,  x8, [sp, 16 * 4]
        stp     x9,  x10,[sp, 16 * 5]
        stp     x11, x13,[sp, 16 * 6]
        stp     x14, x15,[sp, 16 * 7]
        str     q0,      [sp, 16 * 8]

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        ; mov  x0, x14  EscapeFn does not use dst, it is just to avoid arg shuffle on x64
        mov  x1, x15
        mov  x2, x16                        ; source region
        ldr  x12, [x16, #8]                 ; EscapeFn address
        blr  x12

        ldr     q0,      [sp, 16 * 8]
        ldp     x14, x15,[sp, 16 * 7]
        ldp     x11, x13,[sp, 16 * 6]
        ldp     x9,  x10,[sp, 16 * 5]
        ldp     x7,  x8, [sp, 16 * 4]
        ldp     x5,  x6, [sp, 16 * 3]
        ldp     x3,  x4, [sp, 16 * 2]
        ldp     x1,  x2, [sp, 16 * 1]
        ldp     x30, x0, [sp], 16 * 9

        and     x16, x15, #0xFFFFFFFFFFE00000  ; source region
        b       AssignAndMarkCards_SATORI_CONCURRENT

    ;; The patchable values, see GCWriteBarrierPatchableValue.
        ALIGN 8
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    PATCH_LABEL PatchableValue_AssignRef_SATORI_CONCURRENT_CardBundleTable
        DCQ 0
#endif
    PATCH_LABEL PatchableValue_AssignRef_SATORI_CONCURRENT_CardTable
        DCQ 0
    LEAF_END_MARKED RhpAssignRef_SATORI_CONCURRENT

;-----------------------------------------------------------------------------
; void RhpAssignRef_SATORI_CONCURRENT2(Object** dst, Object* src)
;
; The GC marks concurrently and the next GC is a full GC.
; The cards are dirtied for any src, since a full GC marks through objects of any generation.
;
; On entry:
;   x14  : the destination address (LHS of the assignment)
;   x15  : the object reference (RHS of the assignment)
;
; On exit:
;   x12  : trashed
;   x14  : preserved (the destination address is not modified)
;   x15  : trashed
;   x16  : trashed (ip0)
;   x17  : trashed (ip1)
;
        ALIGN 64
    LEAF_ENTRY RhpAssignRef_SATORI_CONCURRENT2, _TEXT
    ; check for escaping assignment
    ; 1) check if we own the source region
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
        ldr     x16, PatchableValue_AssignRef_SATORI_CONCURRENT2_CardBundleTable
    ALTERNATE_ENTRY RhpCheckedEntry_SATORI_CONCURRENT2
        lsr     x17, x15, #30                   ; src page index
        ldrb    w12, [x16, x17]
        cbz     x12, JustAssign_SATORI_CONCURRENT2                 ; null or external (immutable) object
#else
    ALTERNATE_ENTRY RhpCheckedEntry_SATORI_CONCURRENT2
        cbz     x15, JustAssign_SATORI_CONCURRENT2                 ; assigning null
#endif
        and     x16,  x15, #0xFFFFFFFFFFE00000  ; source region
        ldr     x12, [x16]                      ; region tag
        cmp     x12, x18                        ; x18 - TEB
        bne     AssignAndMarkCards_SATORI_CONCURRENT2              ; not local to this thread

    ; 2) check if the src and dst are from the same region
        and     x12, x14, #0xFFFFFFFFFFE00000   ; target aligned to region
        cmp     x12, x16
        bne     RecordEscape_SATORI_CONCURRENT2                    ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        ubfx        x17, x14,#9,#12             ; word index = (dst >> 9) & 0x1FFFFF
        ldr         x17, [x16, x17, lsl #3]     ; mark word = [region + index * 8]
        lsr         x12, x14, #3                ; bit = (dst >> 3) [& 63]
        lsr         x17, x17, x12
        tbnz        x17, #0, RecordEscape_SATORI_CONCURRENT2       ; target is exposed. record an escape.

    ; UNORDERED! src is external/null, or the assignment is completely threadlocal
JustAssign_SATORI_CONCURRENT2
    ALTERNATE_ENTRY RhpAssignRefAVLocationNotHeap_SATORI_CONCURRENT2
        str  x15, [x14]
        ret  lr

AssignAndMarkCards_SATORI_CONCURRENT2
    ALTERNATE_ENTRY RhpAssignRefAVLocation_SATORI_CONCURRENT2
        stlr    x15, [x14]

    ; only x12, x15, x16 and x17 may be trashed here, so we keep the card offset in x12,
    ; the group address in x15, the page in x16, and reuse x17 for the value being stored.

    ; fetch card location for x14
        ldr     x12, PatchableValue_AssignRef_SATORI_CONCURRENT2_CardTable ; fetch the page map
        lsr     x16, x14, #30
        ldr     x16, [x12, x16, lsl #3]              ; page
        sub     x12, x14, x16   ; offset in page
        lsr     x15, x12, #20   ; group index
        lsr     x12, x12, #9    ; card offset
        add     x15, x16, x15, lsl #1   ; group address (page + index * 2)

    ; DIRTYING CARD FOR X14
DirtyCard_SATORI_CONCURRENT2
        add     x12, x16, x12   ; card address
        mov     w17, #4
        ; must be after the field write to allow concurrent clean
        stlrb   w17, [x12]
DirtyGroup_SATORI_CONCURRENT2
        ldrb    w12, [x15, #0x80]
        tbz     w12, #2, DoDirtyGroup_SATORI_CONCURRENT2
        ret     lr
DoDirtyGroup_SATORI_CONCURRENT2
        strb    w17, [x15, #0x80]
DirtyPage_SATORI_CONCURRENT2
        ldrb    w12, [x16]
        tbnz    w12, #2, Exit_SATORI_CONCURRENT2
        strb    w17, [x16]
Exit_SATORI_CONCURRENT2
        ret  lr

    ; this is expected to be rare.
RecordEscape_SATORI_CONCURRENT2

    ; 4) check if the source is escaped (x16 has source region)
        add         x12, x15, #8                   ; escape bit is MT + 1
        ubfx        x17, x12, #9,#12               ; word index = (dst >> 9) & 0x1FFFFF
        ldr         x17, [x16, x17, lsl #3]        ; mark word = [region + index * 8]
        lsr         x12, x12, #3                   ; bit = (dst >> 3) [& 63]
        lsr         x17, x17, x12
        tbnz        x17, #0, AssignAndMarkCards_SATORI_CONCURRENT2    ; source is already escaped.

        ; because of the barrier call convention we need to preserve x0-x11, x13, x14, x15 and x30.
        ; x12, x16 and x17 are trashable per the barrier contract, and x12 is rewritten before
        ; being read again. x29 is callee-saved, so EscapeFn preserves it for us.
        ; also save q0, in case it is used for stack clearing.
        ; Hopefully EscapeFn cannot corrupt other vector regs, since there is no float math or vectorizable code in there.

        stp     x30, x0, [sp, -16 * 9]!
        stp     x1,  x2, [sp, 16 * 1]
        stp     x3,  x4, [sp, 16 * 2]
        stp     x5,  x6, [sp, 16 * 3]
        stp     x7,  x8, [sp, 16 * 4]
        stp     x9,  x10,[sp, 16 * 5]
        stp     x11, x13,[sp, 16 * 6]
        stp     x14, x15,[sp, 16 * 7]
        str     q0,      [sp, 16 * 8]

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        ; mov  x0, x14  EscapeFn does not use dst, it is just to avoid arg shuffle on x64
        mov  x1, x15
        mov  x2, x16                        ; source region
        ldr  x12, [x16, #8]                 ; EscapeFn address
        blr  x12

        ldr     q0,      [sp, 16 * 8]
        ldp     x14, x15,[sp, 16 * 7]
        ldp     x11, x13,[sp, 16 * 6]
        ldp     x9,  x10,[sp, 16 * 5]
        ldp     x7,  x8, [sp, 16 * 4]
        ldp     x5,  x6, [sp, 16 * 3]
        ldp     x3,  x4, [sp, 16 * 2]
        ldp     x1,  x2, [sp, 16 * 1]
        ldp     x30, x0, [sp], 16 * 9

        and     x16, x15, #0xFFFFFFFFFFE00000  ; source region
        b       AssignAndMarkCards_SATORI_CONCURRENT2

    ;; The patchable values, see GCWriteBarrierPatchableValue.
        ALIGN 8
#ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    PATCH_LABEL PatchableValue_AssignRef_SATORI_CONCURRENT2_CardBundleTable
        DCQ 0
#endif
    PATCH_LABEL PatchableValue_AssignRef_SATORI_CONCURRENT2_CardTable
        DCQ 0
    LEAF_END_MARKED RhpAssignRef_SATORI_CONCURRENT2

    end
