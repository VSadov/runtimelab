;; Licensed to the .NET Foundation under one or more agreements.
;; The .NET Foundation licenses this file to you under the MIT license.

include AsmConstants.inc
include AsmMacros.inc

; The EE copies RhpCheckedAssignRef and RhpAssignRef as one block and runs them from the copy (see
; InitJITWriteBarrierHelpers). When the state of the GC tells what RhpAssignRef would check at run time, the GC asks
; the EE to copy a variant of RhpAssignRef over it in the copy (see GCWriteBarrierVariant and ToggleWriteBarrier):
; - RhpAssignRef                    - the next GC is not necessarily a full GC, it reads the barrier state
;                                     (g_write_barrier_state), thus works in any state.
; - RhpAssignRef_SATORI_DYNAMIC2    - the next GC is a full GC, it reads the barrier state.
; - RhpAssignRef_SATORI             - the GC does not mark concurrently and the next GC is not necessarily a full GC.
;                                     Used only when concurrent GC is disabled.
; - RhpAssignRef_SATORI2            - the GC does not mark concurrently and the next GC is a full GC.
;                                     Used only when concurrent GC is disabled.
; - RhpAssignRef_SATORI_CONCURRENT  - while the GC marks concurrently and the next GC is not a full GC.
; - RhpAssignRef_SATORI_CONCURRENT2 - while the GC marks concurrently and the next GC is a full GC.
; They are the JIT_WriteBarrier_SATORI* barriers of the Satori VM, RhpAssignRef is JIT_WriteBarrier_SATORI_DYNAMIC.
;
; The concurrent variants do not check the barrier state, they assume that the GC marks concurrently.
; The GC switches variants only when EE is suspended anyway: to a concurrent variant at the start of
; the concurrent marking and back to a nonconcurrent one in the blocking collection that follows.
; SATORI and SATORI2 do not check the barrier state either. Without concurrent GC the barrier state changes only
; while EE is suspended. Otherwise the dynamic variants are used between GCs, since a concurrent GC switches
; the barrier state to concurrent while EE runs.
;
; RhpAssignRef has room for any of the variants. They have the same code ahead of their CheckedEntry, so that
; RhpCheckedAssignRef can jump to RhpCheckedEntry in the copy, whichever variant is there.
; RhpCheckedAssignRef and RhpAssignRef start on cache lines, thus they do in the copy too, and the variants place
; their code as if they did.
;
; The values that the barriers use (the page map, the page byte map and the address of the barrier state) are
; patched into them (see GCWriteBarrierPatchableValue), so that they remain correct no matter where they are copied
; to. They are the imm64 operands of "mov reg, imm64" instructions, emitted manually (REX.W + B8+reg + 8-byte
; immediate), so that the PatchableValue_* labels are on the immediates. The EE patches them with single 8-byte
; stores, thus they must be 8-byte aligned. The alignment is by construction: there is only fixed-size code between
; an alignment directive, or the start of a helper, and a constant.

; The space for RhpAssignRef and its variants
ASSIGN_REF_SIZE equ 200h

;
;   rcx - dest address
;   rdx - object
;
LEAF_ENTRY_ALIGN64 RhpCheckedAssignRef

    ; See if dst is in GCHeap
        NOP_6_BYTE ; padding for alignment of constant
        db      048h, 0B8h              ; mov rax, imm64
ALTERNATE_ENTRY PatchableValue_CheckedAssignRef_CardBundleTable
        dq      0F0F0F0F0F0F0F0F0h      ; the page byte map
        mov     r8,  rcx
        shr     r8,  30                    ; dst page index
        cmp     byte ptr [rax + r8], 0
        jne     RhpCheckedEntry         ; rax - the page byte map

NotInHeap:
ALTERNATE_ENTRY RhpCheckedAssignRefAVLocation
        mov     [rcx], rdx
        ret
LEAF_END_MARKED_ALIGN64 RhpCheckedAssignRef

;
;   rcx - dest address
;   rdx - object
;
LEAF_ENTRY_ALIGN64 RhpAssignRef

ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    ; check if src is in heap
        NOP_6_BYTE ; padding for alignment of constant
        db      048h, 0B8h              ; mov rax, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_CardBundleTable
        dq      0F0F0F0F0F0F0F0F0h      ; the page byte map
ALTERNATE_ENTRY RhpCheckedEntry
        mov     r8,  rdx
        shr     r8,  30                    ; src page index
        cmp     byte ptr [rax + r8], 0
        je      JustAssign                 ; src not in heap
else
ALTERNATE_ENTRY RhpCheckedEntry
endif

    ; check for escaping assignment
    ; 1) check if we own the source region
        mov     r8, rdx
        and     r8, 0FFFFFFFFFFE00000h  ; source region

ifndef FEATURE_SATORI_EXTERNAL_OBJECTS
        jz      JustAssign              ; assigning null
endif

        mov     rax,  gs:[30h]          ; thread tag, TEB on NT
        cmp     qword ptr [r8], rax
        jne     AssignAndMarkCards      ; not local to this thread

    ; 2) check if the src and dst are from the same region
        mov     rax, rcx
        and     rax, 0FFFFFFFFFFE00000h ; target aligned to region
        cmp     rax, r8
        jne     RecordEscape            ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        mov     eax, ecx
        and     eax, 01FFFFFh           ; offset in the region
        shr     eax, 9                  ; the bitmap qword with the bit for the target (a bit per 8 bytes)
        mov     rax, qword ptr [r8 + rax * 8]
        mov     r9, rcx
        shr     r9, 3                   ; bt takes the bit index modulo 64
        bt      rax, r9
        jc      RecordEscape            ; target is exposed. record an escape.

    JustAssign:
ALTERNATE_ENTRY RhpAssignRefAVLocationNotHeap
        mov     [rcx], rdx              ; src is external/null, or the assignment is completely threadlocal
        ret

    ; Not executed. Places the block below within one cache line where the barrier runs (the copy starts on a cache
    ; line): the block starts 3 bytes into a line, so that the 3-byte store and the 2-byte opcode end on an 8-byte boundary.
        db      ((67 - (($ - RhpAssignRef) mod 64)) mod 64) dup (0CCh)
    AssignAndMarkCards:
ALTERNATE_ENTRY RhpAssignRefAVLocation
        mov     [rcx], rdx

    ; The barrier state may become concurrent while EE runs, thus this barrier reads it.
    ; This must be done after the assignment (in program order).
        db      049h, 0BAh              ; mov r10, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_BarrierStateAddress
        dq      0F0F0F0F0F0F0F0F0h      ; the address of the barrier state (g_write_barrier_state)
        mov     r11, qword ptr [r10]

    ; if src and dst are in the same region, cards are needed only while concurrent
        xor     rdx, rcx
        shr     rdx, 21
        jnz     CrossRegion
        cmp     r11, 1h
        je      MarkCards
        ret

    CrossRegion:
    ; if state == 2 we do not set or dirty cards.
        cmp     r11, 2h
        je      Exit

    ; dst is in another region - cards are needed if src is ephemeral (gen < 2), or while concurrent
        cmp     dword ptr [r8 + 16], 2
        jl      MarkCards
        test    r11, r11
        jnz     MarkCards
    Exit:
        ret

    ; Not executed. Places the card marking below within one cache line where the barrier runs, with the constant
    ; on an 8-byte boundary: the block starts 6 bytes into a line.
        db      ((70 - (($ - RhpAssignRef) mod 64)) mod 64) dup (0CCh)
    MarkCards:
    ; fetch card location for rcx
        db      049h, 0B9h              ; mov r9, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_CardTable
        dq      0F0F0F0F0F0F0F0F0h      ; the page map
        mov     r8,  rcx
        shr     rcx, 30
        mov     rax, qword ptr [r9 + rcx * 8] ; page
        sub     r8, rax   ; offset in page
        mov     rdx,r8
        shr     r8, 9     ; card offset
        shr     rdx, 20   ; group index
        lea     rdx, [rax + rdx * 2 + 80h] ; group offset

    ; check if concurrent marking is in progress
        test    r11, r11
        jnz     DirtyCard

    ; SETTING CARD FOR RCX
     SetCard:
        cmp     byte ptr [rax + r8], 0
        je      DoSetCard
        ret
     DoSetCard:
        mov     byte ptr [rax + r8], 1
     SetGroup:
        cmp     byte ptr [rdx], 0
        jne     CardSet
        mov     byte ptr [rdx], 1
     SetPage:
        cmp     byte ptr [rax], 0
        jne     CardSet
        ; DIRTY on purpose: a racing REMEMBERED store could overwrite another thread's DIRTY.
        mov     byte ptr [rax], 4

     CardSet:
    ; check if concurrent marking is still not in progress
        cmp     qword ptr [r10], 0h     ; r10 - the address of the barrier state
        jne     DirtyCard
        ret

    ; DIRTYING CARD FOR RCX
     DirtyCard:
        mov     byte ptr [rax + r8], 4
     DirtyGroup:
        cmp     byte ptr [rdx], 4
        jne     DoDirtyGroup
        ret
     DoDirtyGroup:
        mov     byte ptr [rdx], 4
     DirtyPage:
        cmp     byte ptr [rax], 4
        je      Exit
        mov     byte ptr [rax], 4
        ret

    ; this is expected to be rare.
    RecordEscape:

        ; 4) check if the source is escaped
        lea     eax, [rdx + 8]                ; escape bit is MT + 1
        and     eax, 01FFFFFh                 ; offset in the region
        shr     eax, 9                        ; the bitmap qword with the bit (a bit per 8 bytes)
        mov     rax, qword ptr [r8 + rax * 8]
        lea     r9, [rdx + 8]
        shr     r9, 3                         ; bt takes the bit index modulo 64
        bt      rax, r9
        jc      AssignAndMarkCards            ; source is already escaped.

        ; Align rsp
        mov  r9, rsp
        and  rsp, -16

        ; save rsp, rcx, rdx, r8
        push r9
        push rcx
        push rdx
        push r8

        ; also save xmm0, in case it is used for stack clearing.
        ; Hopefully EscapeFn cannot corrupt other xmm regs, since there is no float math or vectorizable code in there.
        sub     rsp, 16
        movdqa  [rsp], xmm0

        ; shadow space
        sub  rsp, 20h

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [r8 + 8]

        add     rsp, 20h

        movdqa  xmm0, [rsp]
        add     rsp, 16

        pop     r8
        pop     rdx
        pop     rcx
        pop     rsp
        jmp     AssignAndMarkCards

    ; Not executed. The space for the variants.
        db      (ASSIGN_REF_SIZE - ($ - RhpAssignRef)) dup (0CCh)
LEAF_END_MARKED_ALIGN64 RhpAssignRef

;
; The GC does not mark concurrently yet and the next GC is a full GC, thus cards are not needed until it does.
; The barrier state may become concurrent while EE runs, thus this barrier reads it. Once it is concurrent, the cards
; are dirtied for any src, since a full GC marks through objects of any generation.
;
LEAF_ENTRY RhpAssignRef_SATORI_DYNAMIC2, _TEXT

ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    ; check if src is in heap
        NOP_6_BYTE ; padding for alignment of constant
        db      048h, 0B8h              ; mov rax, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_SATORI_DYNAMIC2_CardBundleTable
        dq      0F0F0F0F0F0F0F0F0h      ; the page byte map
ALTERNATE_ENTRY RhpCheckedEntry_SATORI_DYNAMIC2
        mov     r8,  rdx
        shr     r8,  30                    ; src page index
        cmp     byte ptr [rax + r8], 0
        je      JustAssign                 ; src not in heap
else
ALTERNATE_ENTRY RhpCheckedEntry_SATORI_DYNAMIC2
endif

    ; check for escaping assignment
    ; 1) check if we own the source region
        mov     r8, rdx
        and     r8, 0FFFFFFFFFFE00000h  ; source region

ifndef FEATURE_SATORI_EXTERNAL_OBJECTS
        jz      JustAssign              ; assigning null
endif

        mov     rax,  gs:[30h]          ; thread tag, TEB on NT
        cmp     qword ptr [r8], rax
        jne     AssignAndMarkCards      ; not local to this thread

    ; 2) check if the src and dst are from the same region
        mov     rax, rcx
        and     rax, 0FFFFFFFFFFE00000h ; target aligned to region
        cmp     rax, r8
        jne     RecordEscape            ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        mov     eax, ecx
        and     eax, 01FFFFFh           ; offset in the region
        shr     eax, 9                  ; the bitmap qword with the bit for the target (a bit per 8 bytes)
        mov     rax, qword ptr [r8 + rax * 8]
        mov     r9, rcx
        shr     r9, 3                   ; bt takes the bit index modulo 64
        bt      rax, r9
        jc      RecordEscape            ; target is exposed. record an escape.

    JustAssign:
ALTERNATE_ENTRY RhpAssignRefAVLocationNotHeap_SATORI_DYNAMIC2
        mov     [rcx], rdx              ; src is external/null, or the assignment is completely threadlocal
        ret

    ; Not executed. Places the block below within one cache line where the barrier runs (the copy starts on a cache
    ; line): the block starts 3 bytes into a line, so that the 3-byte store and the 2-byte opcode end on an 8-byte boundary.
        db      ((67 - (($ - RhpAssignRef_SATORI_DYNAMIC2) mod 64)) mod 64) dup (0CCh)
    AssignAndMarkCards:
ALTERNATE_ENTRY RhpAssignRefAVLocation_SATORI_DYNAMIC2
        mov     [rcx], rdx

    ; The barrier state may become concurrent while EE runs, thus this barrier reads it.
    ; This must be done after the assignment (in program order).
        db      049h, 0BAh              ; mov r10, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_SATORI_DYNAMIC2_BarrierStateAddress
        dq      0F0F0F0F0F0F0F0F0h      ; the address of the barrier state (g_write_barrier_state)

    ; if state == 2 we do not set or dirty cards.
        cmp     qword ptr [r10], 2h
        jne     MarkCards
        ret

    ; Not executed. Aligns the constant below: the padding and the 2-byte opcode end on an 8-byte boundary.
        align   8
        NOP_6_BYTE
    MarkCards:
    ; fetch card location for rcx
        db      049h, 0B9h              ; mov r9, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_SATORI_DYNAMIC2_CardTable
        dq      0F0F0F0F0F0F0F0F0h      ; the page map
        mov     r8,  rcx
        shr     rcx, 30
        mov     rax, qword ptr [r9 + rcx * 8] ; page
        sub     r8, rax   ; offset in page
        mov     rdx,r8
        shr     r8, 9     ; card offset
        shr     rdx, 20   ; group index
        lea     rdx, [rax + rdx * 2 + 80h] ; group offset

    ; DIRTYING CARD FOR RCX
     DirtyCard:
        mov     byte ptr [rax + r8], 4
     DirtyGroup:
        cmp     byte ptr [rdx], 4
        jne     DoDirtyGroup
        ret
     DoDirtyGroup:
        mov     byte ptr [rdx], 4
     DirtyPage:
        cmp     byte ptr [rax], 4
        je      Exit
        mov     byte ptr [rax], 4
     Exit:
        ret

    ; this is expected to be rare.
    RecordEscape:

        ; 4) check if the source is escaped
        lea     eax, [rdx + 8]                ; escape bit is MT + 1
        and     eax, 01FFFFFh                 ; offset in the region
        shr     eax, 9                        ; the bitmap qword with the bit (a bit per 8 bytes)
        mov     rax, qword ptr [r8 + rax * 8]
        lea     r9, [rdx + 8]
        shr     r9, 3                         ; bt takes the bit index modulo 64
        bt      rax, r9
        jc      AssignAndMarkCards            ; source is already escaped.

        ; Align rsp
        mov  r9, rsp
        and  rsp, -16

        ; save rsp, rcx, rdx, r8
        push r9
        push rcx
        push rdx
        push r8

        ; also save xmm0, in case it is used for stack clearing.
        ; Hopefully EscapeFn cannot corrupt other xmm regs, since there is no float math or vectorizable code in there.
        sub     rsp, 16
        movdqa  [rsp], xmm0

        ; shadow space
        sub  rsp, 20h

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [r8 + 8]

        add     rsp, 20h

        movdqa  xmm0, [rsp]
        add     rsp, 16

        pop     r8
        pop     rdx
        pop     rcx
        pop     rsp
        jmp     AssignAndMarkCards
LEAF_END_MARKED RhpAssignRef_SATORI_DYNAMIC2, _TEXT

;
; The GC does not mark concurrently and the next GC is not necessarily a full GC, thus cards are needed.
; Used only when concurrent GC is disabled. Then the barrier state changes only while EE is suspended, when the GC
; also switches the barrier, thus this barrier does not check the state.
;
LEAF_ENTRY RhpAssignRef_SATORI, _TEXT

ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    ; check if src is in heap
        NOP_6_BYTE ; padding for alignment of constant
        db      048h, 0B8h              ; mov rax, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_SATORI_CardBundleTable
        dq      0F0F0F0F0F0F0F0F0h      ; the page byte map
ALTERNATE_ENTRY RhpCheckedEntry_SATORI
        mov     r8,  rdx
        shr     r8,  30                    ; src page index
        cmp     byte ptr [rax + r8], 0
        je      JustAssign                 ; src not in heap
else
ALTERNATE_ENTRY RhpCheckedEntry_SATORI
endif

    ; check for escaping assignment
    ; 1) check if we own the source region
        mov     r8, rdx
        and     r8, 0FFFFFFFFFFE00000h  ; source region

ifndef FEATURE_SATORI_EXTERNAL_OBJECTS
        jz      JustAssign              ; assigning null
endif

        mov     rax,  gs:[30h]          ; thread tag, TEB on NT
        cmp     qword ptr [r8], rax
        jne     AssignAndMarkCards      ; not local to this thread

    ; 2) check if the src and dst are from the same region
        mov     rax, rcx
        and     rax, 0FFFFFFFFFFE00000h ; target aligned to region
        cmp     rax, r8
        jne     RecordEscape            ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        mov     eax, ecx
        and     eax, 01FFFFFh           ; offset in the region
        shr     eax, 9                  ; the bitmap qword with the bit for the target (a bit per 8 bytes)
        mov     rax, qword ptr [r8 + rax * 8]
        mov     r9, rcx
        shr     r9, 3                   ; bt takes the bit index modulo 64
        bt      rax, r9
        jc      RecordEscape            ; target is exposed. record an escape.

    JustAssign:
ALTERNATE_ENTRY RhpAssignRefAVLocationNotHeap_SATORI
        mov     [rcx], rdx              ; src is external/null, or the assignment is completely threadlocal
        ret

    ; Not executed. Places the block below within one cache line where the barrier runs (the copy starts on a cache line).
        db      ((64 - (($ - RhpAssignRef_SATORI) mod 64)) mod 64) dup (0CCh)
    AssignAndMarkCards:
ALTERNATE_ENTRY RhpAssignRefAVLocation_SATORI
        mov     [rcx], rdx

    ; if src and dst are in the same region, cards are not needed
        xor     rdx, rcx
        shr     rdx, 21
        jnz     CrossRegion
        ret

    CrossRegion:
    ; dst is in another region - cards are needed if src is ephemeral (gen < 2)
        cmp     dword ptr [r8 + 16], 2
        jl      MarkCards
    Exit:
        ret

    ; Not executed. Places the card marking below within one cache line where the barrier runs, with the constant
    ; on an 8-byte boundary: the block starts 6 bytes into a line.
        db      ((70 - (($ - RhpAssignRef_SATORI) mod 64)) mod 64) dup (0CCh)
    MarkCards:
        db      049h, 0B9h              ; mov r9, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_SATORI_CardTable
        dq      0F0F0F0F0F0F0F0F0h      ; the page map

    ; fetch card location for rcx
        mov     r8,  rcx
        shr     rcx, 30
        mov     rax, qword ptr [r9 + rcx * 8] ; page
        sub     r8, rax   ; offset in page
        mov     rdx,r8
        shr     r8, 9     ; card offset
        shr     rdx, 20   ; group index
        lea     rdx, [rax + rdx * 2 + 80h] ; group offset

    ; SETTING CARD FOR RCX
     SetCard:
        cmp     byte ptr [rax + r8], 0
        je      DoSetCard
        ret
     DoSetCard:
        mov     byte ptr [rax + r8], 1
     SetGroup:
        cmp     byte ptr [rdx], 0
        jne     Exit
        mov     byte ptr [rdx], 1
     SetPage:
        cmp     byte ptr [rax], 0
        jne     Exit
        ; DIRTY on purpose: a racing REMEMBERED store could overwrite another thread's DIRTY. That is possible
        ; without concurrent GC too, cards are also dirtied regardless of it (see SatoriGC::PublishObject).
        mov     byte ptr [rax], 4
        ret

    ; this is expected to be rare.
    RecordEscape:

        ; 4) check if the source is escaped
        lea     eax, [rdx + 8]                ; escape bit is MT + 1
        and     eax, 01FFFFFh                 ; offset in the region
        shr     eax, 9                        ; the bitmap qword with the bit (a bit per 8 bytes)
        mov     rax, qword ptr [r8 + rax * 8]
        lea     r9, [rdx + 8]
        shr     r9, 3                         ; bt takes the bit index modulo 64
        bt      rax, r9
        jc      AssignAndMarkCards            ; source is already escaped.

        ; Align rsp
        mov  r9, rsp
        and  rsp, -16

        ; save rsp, rcx, rdx, r8
        push r9
        push rcx
        push rdx
        push r8

        ; also save xmm0, in case it is used for stack clearing.
        ; Hopefully EscapeFn cannot corrupt other xmm regs, since there is no float math or vectorizable code in there.
        sub     rsp, 16
        movdqa  [rsp], xmm0

        ; shadow space
        sub  rsp, 20h

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [r8 + 8]

        add     rsp, 20h

        movdqa  xmm0, [rsp]
        add     rsp, 16

        pop     r8
        pop     rdx
        pop     rcx
        pop     rsp
        jmp     AssignAndMarkCards
LEAF_END_MARKED RhpAssignRef_SATORI, _TEXT

;
; The GC does not mark concurrently and the next GC is a full GC, thus cards are not needed.
; Used only when concurrent GC is disabled. Then the barrier state changes only while EE is suspended, when the GC
; also switches the barrier, thus this barrier does not check the state.
;
LEAF_ENTRY RhpAssignRef_SATORI2, _TEXT

ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    ; check if src is in heap
        NOP_6_BYTE ; padding for alignment of constant
        db      048h, 0B8h              ; mov rax, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_SATORI2_CardBundleTable
        dq      0F0F0F0F0F0F0F0F0h      ; the page byte map
ALTERNATE_ENTRY RhpCheckedEntry_SATORI2
        mov     r8,  rdx
        shr     r8,  30                    ; src page index
        cmp     byte ptr [rax + r8], 0
        je      JustAssign                 ; src not in heap
else
ALTERNATE_ENTRY RhpCheckedEntry_SATORI2
endif

    ; check for escaping assignment
    ; 1) check if we own the source region
        mov     r8, rdx
        and     r8, 0FFFFFFFFFFE00000h  ; source region

ifndef FEATURE_SATORI_EXTERNAL_OBJECTS
        jz      JustAssign              ; assigning null
endif

        mov     rax,  gs:[30h]          ; thread tag, TEB on NT
        cmp     qword ptr [r8], rax
        jne     JustAssign              ; not local to this thread, no cards needed

    ; 2) check if the src and dst are from the same region
        mov     rax, rcx
        and     rax, 0FFFFFFFFFFE00000h ; target aligned to region
        cmp     rax, r8
        jne     RecordEscape            ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        mov     eax, ecx
        and     eax, 01FFFFFh           ; offset in the region
        shr     eax, 9                  ; the bitmap qword with the bit for the target (a bit per 8 bytes)
        mov     rax, qword ptr [r8 + rax * 8]
        mov     r9, rcx
        shr     r9, 3                   ; bt takes the bit index modulo 64
        bt      rax, r9
        jc      RecordEscape            ; target is exposed. record an escape.

    JustAssign:
ALTERNATE_ENTRY RhpAssignRefAVLocationNotHeap_SATORI2
        mov     [rcx], rdx              ; src is external/null, or the assignment does not need cards
        ret

    ; this is expected to be rare.
    RecordEscape:

        ; 4) check if the source is escaped
        lea     eax, [rdx + 8]                ; escape bit is MT + 1
        and     eax, 01FFFFFh                 ; offset in the region
        shr     eax, 9                        ; the bitmap qword with the bit (a bit per 8 bytes)
        mov     rax, qword ptr [r8 + rax * 8]
        lea     r9, [rdx + 8]
        shr     r9, 3                         ; bt takes the bit index modulo 64
        bt      rax, r9
        jc      JustAssign            ; source is already escaped.

        ; Align rsp
        mov  r9, rsp
        and  rsp, -16

        ; save rsp, rcx, rdx, r8
        push r9
        push rcx
        push rdx
        push r8

        ; also save xmm0, in case it is used for stack clearing.
        ; Hopefully EscapeFn cannot corrupt other xmm regs, since there is no float math or vectorizable code in there.
        sub     rsp, 16
        movdqa  [rsp], xmm0

        ; shadow space
        sub  rsp, 20h

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [r8 + 8]

        add     rsp, 20h

        movdqa  xmm0, [rsp]
        add     rsp, 16

        pop     r8
        pop     rdx
        pop     rcx
        pop     rsp
        jmp     JustAssign
LEAF_END_MARKED RhpAssignRef_SATORI2, _TEXT

;
; The GC marks concurrently and the next GC is not a full GC.
; The cards are dirtied, but only if src is ephemeral (gen < 2). A gen1 GC does not mark through tenured
; objects and references to them do not need to be remembered.
;
LEAF_ENTRY RhpAssignRef_SATORI_CONCURRENT, _TEXT

ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    ; check if src is in heap
        NOP_6_BYTE ; padding for alignment of constant
        db      048h, 0B8h              ; mov rax, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_SATORI_CONCURRENT_CardBundleTable
        dq      0F0F0F0F0F0F0F0F0h      ; the page byte map
ALTERNATE_ENTRY RhpCheckedEntry_SATORI_CONCURRENT
        mov     r8,  rdx
        shr     r8,  30                    ; src page index
        cmp     byte ptr [rax + r8], 0
        je      JustAssign                 ; src not in heap
else
ALTERNATE_ENTRY RhpCheckedEntry_SATORI_CONCURRENT
endif

    ; check for escaping assignment
    ; 1) check if we own the source region
        mov     r8, rdx
        and     r8, 0FFFFFFFFFFE00000h  ; source region

ifndef FEATURE_SATORI_EXTERNAL_OBJECTS
        jz      JustAssign              ; assigning null
endif

        mov     rax,  gs:[30h]          ; thread tag, TEB on NT
        cmp     qword ptr [r8], rax
        jne     AssignAndMarkCards      ; not local to this thread

    ; 2) check if the src and dst are from the same region
        mov     rax, rcx
        and     rax, 0FFFFFFFFFFE00000h ; target aligned to region
        cmp     rax, r8
        jne     RecordEscape            ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        mov     eax, ecx
        and     eax, 01FFFFFh           ; offset in the region
        shr     eax, 9                  ; the bitmap qword with the bit for the target (a bit per 8 bytes)
        mov     rax, qword ptr [r8 + rax * 8]
        mov     r9, rcx
        shr     r9, 3                   ; bt takes the bit index modulo 64
        bt      rax, r9
        jc      RecordEscape            ; target is exposed. record an escape.

    JustAssign:
ALTERNATE_ENTRY RhpAssignRefAVLocationNotHeap_SATORI_CONCURRENT
        mov     [rcx], rdx              ; src is external/null, or the assignment is completely threadlocal
        ret

    ; Not executed. Aligns the constant below: the padding, the 3-byte store and the 2-byte opcode
    ; end on an 8-byte boundary.
        align   8
        NOP_3_BYTE
    AssignAndMarkCards:
ALTERNATE_ENTRY RhpAssignRefAVLocation_SATORI_CONCURRENT
        mov     [rcx], rdx
        db      049h, 0B9h              ; mov r9, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_SATORI_CONCURRENT_CardTable
        dq      0F0F0F0F0F0F0F0F0h      ; the page map

    ; if src is tenured (gen >= 2), cards are not needed
        cmp     dword ptr [r8 + 16], 2
        jge     Exit

    ; fetch card location for rcx
        mov     r8,  rcx
        shr     rcx, 30
        mov     rax, qword ptr [r9 + rcx * 8] ; page
        sub     r8, rax   ; offset in page
        mov     rdx,r8
        shr     r8, 9     ; card offset
        shr     rdx, 20   ; group index
        lea     rdx, [rax + rdx * 2 + 80h] ; group offset

    ; DIRTYING CARD FOR RCX
     DirtyCard:
        mov     byte ptr [rax + r8], 4
     DirtyGroup:
        cmp     byte ptr [rdx], 4
        jne     DoDirtyGroup
        ret
     DoDirtyGroup:
        mov     byte ptr [rdx], 4
     DirtyPage:
        cmp     byte ptr [rax], 4
        je      Exit
        mov     byte ptr [rax], 4
     Exit:
        ret

    ; this is expected to be rare.
    RecordEscape:

        ; 4) check if the source is escaped
        lea     eax, [rdx + 8]                ; escape bit is MT + 1
        and     eax, 01FFFFFh                 ; offset in the region
        shr     eax, 9                        ; the bitmap qword with the bit (a bit per 8 bytes)
        mov     rax, qword ptr [r8 + rax * 8]
        lea     r9, [rdx + 8]
        shr     r9, 3                         ; bt takes the bit index modulo 64
        bt      rax, r9
        jc      AssignAndMarkCards            ; source is already escaped.

        ; Align rsp
        mov  r9, rsp
        and  rsp, -16

        ; save rsp, rcx, rdx, r8
        push r9
        push rcx
        push rdx
        push r8

        ; also save xmm0, in case it is used for stack clearing.
        ; Hopefully EscapeFn cannot corrupt other xmm regs, since there is no float math or vectorizable code in there.
        sub     rsp, 16
        movdqa  [rsp], xmm0

        ; shadow space
        sub  rsp, 20h

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [r8 + 8]

        add     rsp, 20h

        movdqa  xmm0, [rsp]
        add     rsp, 16

        pop     r8
        pop     rdx
        pop     rcx
        pop     rsp
        jmp     AssignAndMarkCards
LEAF_END_MARKED RhpAssignRef_SATORI_CONCURRENT, _TEXT

;
; The GC marks concurrently and the next GC is a full GC.
; The cards are dirtied for any src, since a full GC marks through objects of any generation.
;
LEAF_ENTRY RhpAssignRef_SATORI_CONCURRENT2, _TEXT

ifdef FEATURE_SATORI_EXTERNAL_OBJECTS
    ; check if src is in heap
        NOP_6_BYTE ; padding for alignment of constant
        db      048h, 0B8h              ; mov rax, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_SATORI_CONCURRENT2_CardBundleTable
        dq      0F0F0F0F0F0F0F0F0h      ; the page byte map
ALTERNATE_ENTRY RhpCheckedEntry_SATORI_CONCURRENT2
        mov     r8,  rdx
        shr     r8,  30                    ; src page index
        cmp     byte ptr [rax + r8], 0
        je      JustAssign                 ; src not in heap
else
ALTERNATE_ENTRY RhpCheckedEntry_SATORI_CONCURRENT2
endif

    ; check for escaping assignment
    ; 1) check if we own the source region
        mov     r8, rdx
        and     r8, 0FFFFFFFFFFE00000h  ; source region

ifndef FEATURE_SATORI_EXTERNAL_OBJECTS
        jz      JustAssign              ; assigning null
endif

        mov     rax,  gs:[30h]          ; thread tag, TEB on NT
        cmp     qword ptr [r8], rax
        jne     AssignAndMarkCards      ; not local to this thread

    ; 2) check if the src and dst are from the same region
        mov     rax, rcx
        and     rax, 0FFFFFFFFFFE00000h ; target aligned to region
        cmp     rax, r8
        jne     RecordEscape            ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        mov     eax, ecx
        and     eax, 01FFFFFh           ; offset in the region
        shr     eax, 9                  ; the bitmap qword with the bit for the target (a bit per 8 bytes)
        mov     rax, qword ptr [r8 + rax * 8]
        mov     r9, rcx
        shr     r9, 3                   ; bt takes the bit index modulo 64
        bt      rax, r9
        jc      RecordEscape            ; target is exposed. record an escape.

    JustAssign:
ALTERNATE_ENTRY RhpAssignRefAVLocationNotHeap_SATORI_CONCURRENT2
        mov     [rcx], rdx              ; src is external/null, or the assignment is completely threadlocal
        ret

    ; Not executed. Aligns the constant below: the padding, the 3-byte store and the 2-byte opcode
    ; end on an 8-byte boundary.
        align   8
        NOP_3_BYTE
    AssignAndMarkCards:
ALTERNATE_ENTRY RhpAssignRefAVLocation_SATORI_CONCURRENT2
        mov     [rcx], rdx

    ; fetch card location for rcx
        db      049h, 0B9h              ; mov r9, imm64
ALTERNATE_ENTRY PatchableValue_AssignRef_SATORI_CONCURRENT2_CardTable
        dq      0F0F0F0F0F0F0F0F0h      ; the page map
        mov     r8,  rcx
        shr     rcx, 30
        mov     rax, qword ptr [r9 + rcx * 8] ; page
        sub     r8, rax   ; offset in page
        mov     rdx,r8
        shr     r8, 9     ; card offset
        shr     rdx, 20   ; group index
        lea     rdx, [rax + rdx * 2 + 80h] ; group offset

    ; DIRTYING CARD FOR RCX
     DirtyCard:
        mov     byte ptr [rax + r8], 4
     DirtyGroup:
        cmp     byte ptr [rdx], 4
        jne     DoDirtyGroup
        ret
     DoDirtyGroup:
        mov     byte ptr [rdx], 4
     DirtyPage:
        cmp     byte ptr [rax], 4
        je      Exit
        mov     byte ptr [rax], 4
     Exit:
        ret

    ; this is expected to be rare.
    RecordEscape:

        ; 4) check if the source is escaped
        lea     eax, [rdx + 8]                ; escape bit is MT + 1
        and     eax, 01FFFFFh                 ; offset in the region
        shr     eax, 9                        ; the bitmap qword with the bit (a bit per 8 bytes)
        mov     rax, qword ptr [r8 + rax * 8]
        lea     r9, [rdx + 8]
        shr     r9, 3                         ; bt takes the bit index modulo 64
        bt      rax, r9
        jc      AssignAndMarkCards            ; source is already escaped.

        ; Align rsp
        mov  r9, rsp
        and  rsp, -16

        ; save rsp, rcx, rdx, r8
        push r9
        push rcx
        push rdx
        push r8

        ; also save xmm0, in case it is used for stack clearing.
        ; Hopefully EscapeFn cannot corrupt other xmm regs, since there is no float math or vectorizable code in there.
        sub     rsp, 16
        movdqa  [rsp], xmm0

        ; shadow space
        sub  rsp, 20h

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [r8 + 8]

        add     rsp, 20h

        movdqa  xmm0, [rsp]
        add     rsp, 16

        pop     r8
        pop     rdx
        pop     rcx
        pop     rsp
        jmp     AssignAndMarkCards
LEAF_END_MARKED RhpAssignRef_SATORI_CONCURRENT2, _TEXT

    end
