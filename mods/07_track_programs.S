/* Final firmware source: track programs.
 * Assembly source sections for this feature.
 */
/* memory_reservation: assembly unit 15. */
.if MOD_UNIT == 15
/* C15: cold-start reservation, entered through the SYS MZ header.
 * Runs before the ORIGINAL SYS entry (3000:0010), with interrupts disabled.
 * No allocator or audio hooks run during playback in this candidate.
 * Build-generated constants/checks are tied to the exact C14 SYS and EXE.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
/* Begin reservation_layout.inc */
.equ BOOT_SEGMENT, 0x59ac
.equ EXE_DS, 0x1f31
.equ EXE_MAIN_CS, 0x0
.equ EXE_AUX_CS, 0xfe8
.equ OLD_ARENA_SEGMENT, 0x5a00
.equ NEW_ARENA_SEGMENT, 0x6a00
.equ OWNER_END, 0x80c
.equ OWNER_RESET, 0x0
.equ DESCRIPTOR_OFFSET, 0xffc0
.equ GUARD_WORD, 0xc15a

/* End reservation_layout.inc */
.global reserve_entry, reserve_end, code_end, boot_status, old_entry_segment
.global validation_begin, validation_end, mutation_begin, mutation_end
.global reserve_descriptor, reserve_descriptor_end

reserve_entry:
    cli
    cld
    pushf
    pusha
    push ds
    push es
    mov word ptr cs:[boot_status-reserve_entry], 1
    mov ax, cs
    cmp ax, BOOT_SEGMENT
    jne failed
    mov ax, ds
    cmp ax, EXE_DS
    jne failed

    /* Permit a fresh loader or the same already-patched loader, never a
     * mixture. Checking every instruction precedes the first EXE write.
     * DS=CS is only used while comparing immutable instruction bytes.
     */
    push cs
    pop ds
    mov ax, EXE_AUX_CS
    mov es, ax
    mov bp, word ptr es:[0x982f]
    cmp bp, OLD_ARENA_SEGMENT
    je validation_begin
    cmp bp, NEW_ARENA_SEGMENT
    jne failed
validation_begin:
/* Begin reservation_checks.inc */
mov ax, 0x0
mov es, ax
cmp byte ptr es:[0x3752], 0x2d
jne failed
cmp word ptr es:[0x3753], bp
jne failed
mov ax, 0xfe8
mov es, ax
cmp byte ptr es:[0x982e], 0xb8
jne failed
cmp word ptr es:[0x982f], bp
jne failed
mov ax, 0xfe8
mov es, ax
cmp byte ptr es:[0x9c6e], 0xb8
jne failed
cmp word ptr es:[0x9c6f], bp
jne failed
mov ax, 0xfe8
mov es, ax
cmp byte ptr es:[0x9d24], 0xbb
jne failed
cmp word ptr es:[0x9d25], bp
jne failed
mov ax, 0x0
mov es, ax
mov di, 0x3755
mov si, expected_0-reserve_entry
mov cx, 8
repe cmpsb
jne failed
mov ax, 0xfe8
mov es, ax
mov di, 0x97e6
mov si, expected_1-reserve_entry
mov cx, 4
repe cmpsb
jne failed
mov ax, 0xfe8
mov es, ax
mov di, 0x9831
mov si, expected_2-reserve_entry
mov cx, 47
repe cmpsb
jne failed
mov ax, 0xfe8
mov es, ax
mov di, 0x9869
mov si, expected_3-reserve_entry
mov cx, 6
repe cmpsb
jne failed
mov ax, 0xfe8
mov es, ax
mov di, 0x9883
mov si, expected_4-reserve_entry
mov cx, 23
repe cmpsb
jne failed
mov ax, 0xfe8
mov es, ax
mov di, 0x9999
mov si, expected_5-reserve_entry
mov cx, 5
repe cmpsb
jne failed
mov ax, 0xfe8
mov es, ax
mov di, 0x9c24
mov si, expected_6-reserve_entry
mov cx, 15
repe cmpsb
jne failed
mov ax, 0xfe8
mov es, ax
mov di, 0x9c71
mov si, expected_7-reserve_entry
mov cx, 1
repe cmpsb
jne failed
mov ax, 0xfe8
mov es, ax
mov di, 0x9d27
mov si, expected_8-reserve_entry
mov cx, 14
repe cmpsb
jne failed
mov ax, 0x1f31
mov es, ax
mov di, 0x2061
mov si, expected_9-reserve_entry
mov cx, 32
repe cmpsb
jne failed

/* End reservation_checks.inc */
validation_end:
    mov word ptr cs:[boot_status-reserve_entry], 2

mutation_begin:
    mov ax, EXE_MAIN_CS
    mov es, ax
    mov word ptr es:[0x3753], NEW_ARENA_SEGMENT
    mov ax, EXE_AUX_CS
    mov es, ax
    mov word ptr es:[0x982f], NEW_ARENA_SEGMENT
    mov word ptr es:[0x9c6f], NEW_ARENA_SEGMENT
    mov word ptr es:[0x9d25], NEW_ARENA_SEGMENT
mutation_end:
    mov word ptr cs:[boot_status-reserve_entry], 3

    /* The loader initialized empty records at 5A00 BEFORE loading SYS.
     * Appended data may have overwritten those records. Recreate the 24
     * empty native records and sequence terminator at 6A00, not memcpy.
     * This is a boot entry, never an in-session migration operation.
     */
    mov ax, EXE_DS
    mov ds, ax
    .byte 0x9a
    .word 0x97e6, EXE_AUX_CS
    mov word ptr cs:[boot_status-reserve_entry], 4

    /* Keep the installed owner code; initialize the rest of the reserved
     * segment. This includes the now-consumed SYS footer, not old code.
     * The full reservation is NOT stored as 64 KiB of disk padding.
     */
    mov ax, OLD_ARENA_SEGMENT
    mov es, ax
    xor ax, ax
    mov di, OWNER_END
    mov cx, (DESCRIPTOR_OFFSET-OWNER_END)/2
    rep stosw
    push ds
    push cs
    pop ds
    mov si, reserve_descriptor-reserve_entry
    mov cx, (reserve_descriptor_end-reserve_descriptor)/2
    rep movsw
    pop ds
    mov ax, GUARD_WORD
    mov cx, 16
    rep stosw

    /* owner_reset only initializes generations and empty sidecar tables.
     * The component is installed but is not connected to any note queue.
     */
    .byte 0x9a
    .word OWNER_RESET, OLD_ARENA_SEGMENT
    mov word ptr cs:[boot_status-reserve_entry], 0x600d

    pop es
    pop ds
    popa
    popf
    /* LES SI in the loader used the new MZ entry. Recreate the original
     * ES:SI boot contract, preserving AX and all other restored registers.
     */
    push ax
    mov ax, 0x3000
    mov es, ax
    pop ax
    mov si, 0x0010
    .byte 0xea
    .word 0x0010
old_entry_segment:
    .word 0x0000 /* MZ relocation: original SYS CS becomes 3000. */

failed:
    /* Never resume with the old arena after SYS has overwritten it.
     * Do not call an unvalidated EXE/UI on an identity mismatch.
     * BP retains the detected arena base; status is visible in a RAM dump.
     * No EXE mutation or native initialization occurs on this path.
     */
    mov word ptr cs:[boot_status-reserve_entry], 0xe001
    cli
halt_failed:
    hlt
    jmp halt_failed
code_end:
.balign 2
boot_status:
    .word 0
reserve_descriptor:
    .ascii "C15RAM64"
    .word 1, OLD_ARENA_SEGMENT, NEW_ARENA_SEGMENT, 0xeff8, 0xff70
    .word BOOT_SEGMENT, boot_status-reserve_entry, OWNER_END
    .word 24, 64, 99, 32
reserve_descriptor_end:
/* Begin reservation_expected.inc */
expected_0:
.byte 0xc1,0xe8,0x06,0x2b,0xd2,0xcd,0x2b,0x3a
expected_1:
.byte 0xe8,0x45,0x00,0xcb
expected_2:
.byte 0x8e,0xc0,0x2b,0xff,0xb3,0x00,0xbe,0x61,0x20,0xb9,0x10,0x00,0xf3,0xa5,0xfe,0xc3,0x80,0xfb,0x18,0x75,0xf1,0x2b,0xc0,0x26,0x89,0x05,0xbf,0x32,0x05,0xbe,0x63,0x20,0x8c,0xd8,0x8e,0xc0,0xb9,0x10,0x00,0xf3,0xa4,0xc6,0x06,0x48,0x05,0x00,0xc3
expected_3:
.byte 0xb0,0x18,0xe8,0xb6,0x04,0xc3
expected_4:
.byte 0x60,0xe8,0xe2,0xff,0x26,0x8b,0x0e,0x00,0x00,0x0b,0xc9,0x74,0x08,0x8c,0xc3,0x03,0xd9,0x8e,0xc3,0xeb,0xef,0x61,0xc3
expected_5:
.byte 0xbf,0x70,0xff,0x2b,0xfa
expected_6:
.byte 0xe8,0x5c,0xfc,0x8c,0xc3,0xb8,0xf8,0xef,0x2b,0xc3,0x73,0x02,0x2b,0xc0,0xc3
expected_7:
.byte 0xc3
expected_8:
.byte 0x8e,0xc3,0x2c,0x01,0x73,0x01,0xc3,0x26,0x03,0x1e,0x00,0x00,0xeb,0xf2
expected_9:
.byte 0x02,0x00,0x28,0x55,0x6e,0x75,0x73,0x65,0x64,0x29,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x2e,0x50,0x52,0x47,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00

/* End reservation_expected.inc */
.balign 4
reserve_end:

.endif /* memory_reservation */
/* voice_ownership: assembly unit 16. */
.if MOD_UNIT == 16
/* First component of the Classic per-track program engine. NOT installed.
 * 80186, independent CS, no firmware addresses, no allocation, no I/O.
 * Entry points are FAR. See README_PL.md for the adapter/lifetime contract.
 *
 * An owner is AX=program slot (1..24), CX=source identity, DX=generation.
 * Source identity includes sequence AND track; zero is never a valid owner.
 * Do not use a movable program far pointer as the identity.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
module_start:
.global module_start, code_end, state_start, module_end
.global owner_reset, owner_make, owner_validate, owner_retire
.global sampler_put, sampler_take, duration_put, duration_get, duration_copy
.global voice_put, voice_get, voice_same_source, voice_same_program
.global generations, sampler_owners, duration_owners, voice_owners

/* Cold initialization ONLY: caller has stopped every voice/queue/producer.
 * Never reset generations during a normal queue flush or transport stop.
 * All registers and flags preserved, including caller's DF and IF.
 */
owner_reset:
    pushf
    cli
    pusha
    push es
    push cs
    pop es
    cld
    xor ax, ax
    mov di, state_start-module_start
    mov cx, (module_end-state_start)/2
    rep stosw
    mov ax, 1
    mov di, generations-module_start
    mov cx, 24
    rep stosw
    pop es
    popa
    popf
    retf

/* Near helper; AX slot -> BX word offset; other registers unchanged. */
.Lslot_index:
    cmp ax, 1
    jb .Lbad_index
    cmp ax, 24
    ja .Lbad_index
    mov bx, ax
    dec bx
    shl bx, 1
    clc
    ret
.Lbad_index:
    stc
    ret

/* AX slot + CX nonzero source -> DX generation. On error returns an empty
 * token and CF=1. Adapter must also check that the program slot is loaded.
 * BX preserved. Other flags (including IF) preserved except CF.
 */
owner_make:
    pushf
    cli
    push bx
    call .Lslot_index
    jc .Lmake_bad
    test cx, cx
    jz .Lmake_bad
    mov dx, word ptr cs:[bx+generations-module_start]
    test dx, dx
    jz .Lmake_bad
    pop bx
    popf
    clc
    retf
.Lmake_bad:
    xor ax, ax
    xor cx, cx
    xor dx, dx
    pop bx
    popf
    stc
    retf

/* Near check of a token against the current slot lifetime. Changes BX/CF.
 * No fallback to the current UI program on a missing or stale owner.
 */
.Lvalidate:
    call .Lslot_index
    jc .Linvalid
    test cx, cx
    jz .Linvalid
    test dx, dx
    jz .Linvalid
    cmp dx, word ptr cs:[bx+generations-module_start]
    jne .Linvalid
    clc
    ret
.Linvalid:
    stc
    ret

/* Input token preserved, CF=0 only if current. */
owner_validate:
    pushf
    cli
    push bx
    call .Lvalidate
    jc .Lvalidate_bad
    pop bx
    popf
    clc
    retf
.Lvalidate_bad:
    pop bx
    popf
    stc
    retf

/* Advance a slot lifetime AFTER stopping its voices and BEFORE replacing
 * or deleting its program. Old queued tokens then fail validation.
 * At FFFF->0000 quarantine the slot until cold initialization, not wrap
 * to a previously valid generation. CF=1 signals quarantine/invalid slot.
 * Caller must keep native program mutation in the same critical section.
 * All registers preserved.
 */
owner_retire:
    pushf
    cli
    push bx
    call .Lslot_index
    jc .Lretire_bad
    cmp word ptr cs:[bx+generations-module_start], 0
    je .Lretire_bad
    inc word ptr cs:[bx+generations-module_start]
    jz .Lretire_bad
    pop bx
    popf
    clc
    retf
.Lretire_bad:
    pop bx
    popf
    stc
    retf

/* Native queues use byte offsets in four-byte records. Our records have
 * six bytes. Reject malformed indices instead of masking them into a
 * valid slot. Voice APIs accept the native voice NUMBER (0..31).
 */
.macro table_index table, limit, voice=0
    cmp bx, \limit
    ja .Lbad_\@
    .if \voice
        mov si, bx
        shl bx, 1
        add bx, si
        shl bx, 1
    .else
        test bx, 3
        jnz .Lbad_\@
        mov si, bx
        shr si, 1
        add bx, si
    .endif
    add bx, \table-module_start
    jmp .Lindex_ok_\@
.Lbad_\@:
    pop si
    pop bx
    popf
    stc
    retf
.Lindex_ok_\@:
.endm

/* Writers accept raw tokens, including zero to clear or stale tokens
 * from an in-flight queue copy. They check indices, not slot lifetime.
 * Preserve all registers. CF=1 means no write occurred.
 */
.macro put name, table, limit, voice=0
\name:
    pushf
    cli
    push bx
    push si
    table_index \table, \limit, \voice
    mov word ptr cs:[bx], ax
    mov word ptr cs:[bx+2], cx
    mov word ptr cs:[bx+4], dx
    pop si
    pop bx
    popf
    clc
    retf
.endm
put sampler_put, sampler_owners, 0xfc
put duration_put, duration_owners, 0x1fc
put voice_put, voice_owners, 31, 1

/* Readers return RAW AX/CX/DX: caller must owner_validate before dispatch.
 * CF=1 means bad index, outputs zero. BX/SI and other flags preserved.
 * Sampler consumption clears that sidecar entry after taking its token.
 */
.macro get name, table, limit, voice=0, take=0
\name:
    pushf
    cli
    push bx
    push si
    xor ax, ax
    xor cx, cx
    xor dx, dx
    table_index \table, \limit, \voice
    mov ax, word ptr cs:[bx]
    mov cx, word ptr cs:[bx+2]
    mov dx, word ptr cs:[bx+4]
    .if \take
        mov word ptr cs:[bx], 0
        mov word ptr cs:[bx+2], 0
        mov word ptr cs:[bx+4], 0
    .endif
    pop si
    pop bx
    popf
    clc
    retf
.endm
get sampler_take, sampler_owners, 0xfc, 0, 1
get duration_get, duration_owners, 0x1fc
get voice_get, voice_owners, 31, 1

/* Native duration compaction: SI source and DI destination, both original
 * byte offsets (0..1FC, aligned to 4), BEFORE either native index advances.
 * Copy raw owner and return it in AX/CX/DX for the expiry path. SI==DI is
 * valid; do not clear the source (in-place compaction can alias it).
 * Invalid index: CF=1, zero token, no write. BX/SI/DI preserved.
 */
duration_copy:
    pushf
    cli
    push bx
    push si
    push di
    cmp si, 0x1fc
    ja .Lcopy_bad
    cmp di, 0x1fc
    ja .Lcopy_bad
    test si, 3
    jnz .Lcopy_bad
    test di, 3
    jnz .Lcopy_bad
    mov bx, si
    shr si, 1
    add bx, si
    mov ax, word ptr cs:[bx+duration_owners-module_start]
    mov cx, word ptr cs:[bx+duration_owners-module_start+2]
    mov dx, word ptr cs:[bx+duration_owners-module_start+4]
    mov bx, di
    shr di, 1
    add bx, di
    mov word ptr cs:[bx+duration_owners-module_start], ax
    mov word ptr cs:[bx+duration_owners-module_start+2], cx
    mov word ptr cs:[bx+duration_owners-module_start+4], dx
    pop di
    pop si
    pop bx
    popf
    clc
    retf
.Lcopy_bad:
    xor ax, ax
    xor cx, cx
    xor dx, dx
    pop di
    pop si
    pop bx
    popf
    stc
    retf

/* Compare input owner with voice BX (0..31), checking the slot lifetime.
 * CF=0 match; CF=1 stale, empty, invalid, or mismatch. Registers preserved.
 * Note Off: source comparison AND native note match.
 * Mute Groups / same-note overlap: program comparison AND native criteria.
 */
.macro match name, source
\name:
    pushf
    cli
    push bx
    push si
    mov si, bx
    call .Lvalidate
    jc .Lmatch_bad_\@
    cmp si, 31
    ja .Lmatch_bad_\@
    mov bx, si
    shl bx, 1
    add bx, si
    shl bx, 1
    cmp ax, word ptr cs:[bx+voice_owners-module_start]
    jne .Lmatch_bad_\@
    cmp dx, word ptr cs:[bx+voice_owners-module_start+4]
    jne .Lmatch_bad_\@
    .if \source
        cmp cx, word ptr cs:[bx+voice_owners-module_start+2]
        jne .Lmatch_bad_\@
    .endif
    pop si
    pop bx
    popf
    clc
    retf
.Lmatch_bad_\@:
    pop si
    pop bx
    popf
    stc
    retf
.endm
match voice_same_source, 1
match voice_same_program, 0
code_end:
.balign 2
state_start:
generations:     .space 24*2
sampler_owners:  .space 64*6
duration_owners: .space 128*6
voice_owners:    .space 32*6
module_end:

.endif /* voice_ownership */
/* track_engine: assembly unit 18. */
.if MOD_UNIT == 18
/* C17 integration. 80186, fixed reserved CS=5B00, stock EXE remains on disk.
 * Runtime detours are validated before installation. No allocation in audio.
 * Every queue entry carries a captured six-byte owner, never a UI-global ID.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
/* Begin layout.inc */
.equ HOOK_COUNT, 25
.equ OWNER_fake, 0x0
.equ OWNER_module_start, 0x0
.equ OWNER_code_end, 0x29c
.equ OWNER_state_start, 0x29c
.equ OWNER_module_end, 0x80c
.equ OWNER_reset, 0x0
.equ OWNER_make, 0x33
.equ OWNER_validate, 0x6e
.equ OWNER_retire, 0x7e
.equ OWNER_sampler_put, 0x9d
.equ OWNER_sampler_take, 0x12b
.equ OWNER_duration_put, 0xce
.equ OWNER_duration_get, 0x173
.equ OWNER_duration_copy, 0x1dc
.equ OWNER_voice_put, 0xff
.equ OWNER_voice_get, 0x1aa
.equ OWNER_voice_same_source, 0x235
.equ OWNER_voice_same_program, 0x26c
.equ OWNER_generations, 0x29c
.equ OWNER_sampler_owners, 0x2cc
.equ OWNER_duration_owners, 0x44c
.equ OWNER_voice_owners, 0x74c

/* End layout.inc */
.global module_start, module_end, code_end, install, install_status
.global seq_tail, seq_event, duration_move, duration_expire
.global enqueue_default, consume, direct_dispatch
.global note_pointer_ax, note_pointer_ax_sub, note_pointer_bx, mixer_pointer
.global note_off, overlap_stop, voice_capture, mute_groups, pitch_context
.global program_mutation, route_up, route_down, route_label, sync_track, sync_draw
.global note_on_entry, note_on_original, pad_owners
.global active_owner, active_root, voice_roots, dispatched, dropped
.global limit_admit, limit_release, limit_priority, limit_pending
.global limit_pending_total, limit_priority_drops, limit_voice_drops

.macro farcall seg, ip
    .byte 0x9a
    .word \ip, \seg
.endm
.macro farjump seg, ip
    .byte 0xea
    .word \ip, \seg
.endm
.macro own name
    farcall 0x5a00, OWNER_\name
.endm
.macro maincall ip
    push cs
    push offset .Lreturn_\@-module_start
    push 0x046b
    push 0x0000
    push \ip
    retf
.Lreturn_\@:
.endm
.macro auxcall ip
    push cs
    push offset .Lreturn_\@-module_start
    push 0x97e5
    push 0x0fe8
    push \ip
    retf
.Lreturn_\@:
.endm

module_start:
install:
    pushf
    cli
    pusha
    push ds
    push es
    push cs
    pop ds
    cld
    mov word ptr cs:[install_status-module_start], 1
    mov bx, offset hook_table-module_start
    mov bp, HOOK_COUNT
.Lcheck:
    mov es, word ptr [bx]
    mov di, word ptr [bx+2]
    mov cx, word ptr [bx+4]
    mov si, word ptr [bx+6]
    repe cmpsb
    jne .Lbad_install
    add bx, 10
    dec bp
    jnz .Lcheck
    mov bx, offset hook_table-module_start
    mov bp, HOOK_COUNT
.Linstall:
    mov es, word ptr [bx]
    mov di, word ptr [bx+2]
    mov cx, word ptr [bx+4]
    mov si, word ptr [bx+8]
    rep movsb
    add bx, 10
    dec bp
    jnz .Linstall
    mov word ptr cs:[install_status-module_start], 0x600d
    pop es
    pop ds
    popa
    popf
    farjump 0x3000, 0x0010
.Lbad_install:
    mov word ptr cs:[install_status-module_start], 0xe017
    cli
.Lhalt:
    hlt
    jmp .Lhalt

/* AX=slot1..24 -> loaded check; preserves AX/BX/DS/ES, CF failure. */
loaded:
    push bx
    push ds
    push es
    cmp ax, 1
    jb .Lloaded_bad
    cmp ax, 24
    ja .Lloaded_bad
    mov bx, 0x491a
    mov ds, bx
    mov bx, ax
    dec bx
    shl bx, 2
    les bx, dword ptr [bx+0x9cb2]
    mov dx, es
    cmp dx, 0x6a00
    jb .Lloaded_bad
    cmp word ptr es:[bx], 2
    jbe .Lloaded_bad
    pop es
    pop ds
    pop bx
    clc
    ret
.Lloaded_bad:
    pop es
    pop ds
    pop bx
    stc
    ret

/* EXE DS, BX=track -> AX/CX/DX token. Flags bits3..7 contain slot;
 * low flags are preserved. A missing explicit slot fails closed.
 */
resolve_track:
    push bx
    push es
    and bx, 63
    mov es, word ptr [0x1d0a]
    xor ax, ax
    mov al, byte ptr es:[0x13]
    cmp ax, 1
    jb .Luse_ui_seq
    cmp ax, 99
    jbe .Lseq_id
.Luse_ui_seq:
    mov al, byte ptr [0x0b20]
    inc ax
.Lseq_id:
    shl ax, 6
    or ax, bx
    mov cx, ax
    xor ax, ax
    test byte ptr es:[bx+0x430], 0x40
    jz .Lglobal_track
    mov al, byte ptr es:[bx+0x4f0]
    shr al, 3
    test al, al
    jnz .Lresolve_slot
.Lglobal_track:
    push ds
    mov ax, 0x491a
    mov ds, ax
    xor ax, ax
    mov al, byte ptr [0x9d70]
    inc ax
    pop ds
.Lresolve_slot:
    call loaded
    jc .Lempty_owner
    own make
    jmp .Lresolve_done
.Lempty_owner:
    xor ax, ax
    xor cx, cx
    xor dx, dx
.Lresolve_done:
    pop es
    pop bx
    ret

/* Default native producers capture the selected editor program NOW.
 * Pads and MIDI have separate source spaces from sequencer events.
 */
resolve_default:
    push bx
    push es
    mov bx, 0x491a
    mov es, bx
    xor ax, ax
    mov al, byte ptr es:[0x9d70]
    inc ax
    call loaded
    jc .Ldefault_empty
    own make
    jmp .Ldefault_done
.Ldefault_empty:
    xor ax, ax
    xor cx, cx
    xor dx, dx
.Ldefault_done:
    pop es
    pop bx
    ret

/* Event AX,CX,DX plus SS:SI owner. Keeps all registers/flags.
 * Packet + metadata + write-index publication form one CLI transaction.
 */
enqueue:
    pushf
    cli
    pusha
    cmp ah, 0xa0
    je .Lenqueue_done
    cmp ah, 0xd0
    jae .Lenqueue_done
    cmp ah, 0x80
    jae .Lstatus
    shl ah, 4
.Lstatus:
    mov bl, byte ptr [0x0d51]
    mov bh, bl
    sub bh, byte ptr [0x0d50]
    cmp bh, 0xc0
    jb .Lspace
    mov byte ptr [0x0d50], bl
.Lspace:
    or ah, dh
    cmp ch, 0
    je .Lsource_bit
    or ah, 8
.Lsource_bit:
    mov ch, dl
    xor bh, bh
    mov word ptr [bx+0xced8], ax
    mov word ptr [bx+0xceda], cx
    mov ax, word ptr ss:[si]
    mov cx, word ptr ss:[si+2]
    mov dx, word ptr ss:[si+4]
    own sampler_put
    add byte ptr [0x0d51], 4
.Lenqueue_done:
    popa
    popf
    ret

/* Native near entry, returns through original RET at AUX:5F80. */
enqueue_default:
    push bp
    mov bp, sp
    sub sp, 6
    pusha
    /* Program is captured on key-down and reused on key-up. */
    mov di, ax
    and di, 0x7f
    xor bx, bx
    mov bl, ch
    test bl, bl
    jz .Ldefault_key
    and bl, 31
    inc bx
    shl bx, 7
    add di, bx
.Ldefault_key:
    imul di, di, 6
    cmp ah, 0x80
    je .Ldefault_release
    cmp ah, 0x90
    jne .Ldefault_new
    test cl, cl
    jz .Ldefault_release
.Ldefault_new:
    push ax
    push cx
    mov bx, cx
    test bh, bh
    jnz .Ldefault_midi
    /* Track identity is captured when the pad goes down. */
    push es
    mov es, word ptr [0x1d0a]
    xor cx, cx
    mov cl, byte ptr es:[0x13]
    shl cx, 6
    mov bl, byte ptr [0x0b21]
    and bx, 63
    or cx, bx
    or cx, 0x4000
    pop es
    jmp .Ldefault_identity
.Ldefault_midi:
    mov cx, 0x8000
    mov cl, bh
    and cl, 31
.Ldefault_identity:
    call resolve_default
    mov word ptr [bp-6], ax
    mov word ptr [bp-4], cx
    mov word ptr [bp-2], dx
    pop bx
    pop bx
    cmp bh, 0x90
    jne .Ldefault_token
    mov word ptr cs:[di+pad_owners-module_start], ax
    mov word ptr cs:[di+pad_owners-module_start+2], cx
    mov word ptr cs:[di+pad_owners-module_start+4], dx
    jmp .Ldefault_token
.Ldefault_release:
    mov ax, word ptr cs:[di+pad_owners-module_start]
    mov cx, word ptr cs:[di+pad_owners-module_start+2]
    mov dx, word ptr cs:[di+pad_owners-module_start+4]
.Ldefault_token:
    mov word ptr [bp-6], ax
    mov word ptr [bp-4], cx
    mov word ptr [bp-2], dx
    popa
    push si
    lea si, [bp-6]
    call enqueue
    pop si
    mov sp, bp
    pop bp
    farjump 0x0fe8, 0x5f80

/* Explicit owned route; SS:SI owner. Internal enqueue consumes its own
 * metadata before external MIDI can STI; no global producer context.
 */
route_owned:
    pushf
    pusha
    test ch, 0x80
    jz .Lroute_done
    test ch, 0x40
    jz .Lexternal
    call enqueue
.Lexternal:
    and ch, 0xbf
    farcall 0x0fe8, 0x5a94
.Lroute_done:
    popa
    popf
    ret

/* Native sequenced note tail. Capture once for Note On AND duration.
 * BP entering here is duration, AL note, CH native routing, BL track.
 */
seq_tail:
    push bp
    mov bp, sp
    sub sp, 6
    pushf
    cli
    pusha
    call resolve_track
    mov word ptr [bp-6], ax
    mov word ptr [bp-4], cx
    mov word ptr [bp-2], dx
    popa
    push si
    lea si, [bp-6]
    cmp byte ptr [0x1d94], 0
    jne .Lduration
    call route_owned
.Lduration:
    /* Native may enable interrupts while sending external MIDI. */
    cli
    push ax
    push cx
    push dx
    push di
    mov bx, word ptr [0x2046]
    mov ax, word ptr [bp]
    test ax, ax
    jnz .Lduration_nonzero
    inc ax
.Lduration_nonzero:
    mov word ptr [bx+0x1e46], ax
    /* Original event AX and routing CX are still in this frame. */
    mov di, sp
    mov ax, word ptr ss:[di+6]
    mov ah, ch
    mov word ptr [bx+0x1e48], ax
    mov ax, word ptr [bp-6]
    mov cx, word ptr [bp-4]
    mov dx, word ptr [bp-2]
    own duration_put
    add bx, 4
    and bx, 0x1ff
    mov word ptr [0x2046], bx
    pop di
    pop dx
    pop cx
    pop ax
    pop si
    popf
    mov sp, bp
    pop bp
    farjump 0x0fe8, 0x9021

/* Other sequenced MIDI events (including explicit Note Off). */
seq_event:
    push bp
    mov bp, sp
    sub sp, 6
    pusha
    xor bx, bx
    mov bl, byte ptr es:[si]
    and bl, 63
    call resolve_track
    mov word ptr [bp-6], ax
    mov word ptr [bp-4], cx
    mov word ptr [bp-2], dx
    popa
    push si
    lea si, [bp-6]
    call route_owned
    pop si
    mov sp, bp
    pop bp
    retf

duration_move:
    pushf
    pusha
    sub si, 2
    sub di, 2
    own duration_copy
    popa
    popf
    mov ax, word ptr [bx+si]
    mov word ptr [bx+di], ax
    inc si
    inc si
    retf

duration_expire:
    push bp
    mov bp, sp
    sub sp, 6
    pusha
    mov bx, di
    own duration_get
    mov word ptr [bp-6], ax
    mov word ptr [bp-4], cx
    mov word ptr [bp-2], dx
    popa
    push si
    lea si, [bp-6]
    call route_owned
    pop si
    mov sp, bp
    pop bp
    retf

/* Sampler ring consumer, native loop budget stays below our frame. */
consume:
    push ax
    push bp
    mov bp, sp
    sub sp, 10
    pushf
    cli
    xor bh, bh
    mov ax, word ptr [bx+0xced8]
    mov cx, word ptr [bx+0xceda]
    mov word ptr [bp-10], ax
    mov word ptr [bp-8], cx
    own sampler_take
    mov word ptr [bp-6], ax
    mov word ptr [bp-4], cx
    mov word ptr [bp-2], dx
    add byte ptr [0x0d50], 4
    popf
    mov ax, word ptr [bp-10]
    mov cx, word ptr [bp-8]
    mov dh, ah
    and ah, 0xf0
    mov dl, ch
    mov ch, dh
    and dh, 3
    and ch, 8
    shr ch, 3
    cmp ah, 0x80
    jae .Ldecoded
    shr ah, 4
.Ldecoded:
    push si
    lea si, [bp-6]
    call dispatch
    pop si
    mov sp, bp
    pop bp
    farjump 0x0fe8, 0x0119

/* Native INT35 BL=0 fallback. Its original IRET remains at 3000:1F6E. */
direct_dispatch:
    push bp
    mov bp, sp
    sub sp, 6
    pusha
    mov cx, 0xc000
    call resolve_default
    mov word ptr [bp-6], ax
    mov word ptr [bp-4], cx
    mov word ptr [bp-2], dx
    popa
    push si
    lea si, [bp-6]
    call dispatch
    pop si
    mov sp, bp
    pop bp
    farjump 0x3000, 0x1f6e

/* Context stack: interrupts can nest, previous token/root are restored.
 * Lookups resolve this owner directly; editor program globals never swap.
 */
dispatch:
    pushf
    cli
    pusha
    push ds
    push es
    push word ptr cs:[active_owner-module_start]
    push word ptr cs:[active_owner-module_start+2]
    push word ptr cs:[active_owner-module_start+4]
    push word ptr cs:[active_root-module_start]
    mov word ptr cs:[active_root-module_start], ax
    push ax
    push cx
    push dx
    mov ax, word ptr ss:[si]
    mov cx, word ptr ss:[si+2]
    mov dx, word ptr ss:[si+4]
    own validate
    jc .Linvalid_dispatch
    call loaded
    jc .Linvalid_dispatch
    /* loaded uses DX; reload the captured generation. */
    mov dx, word ptr ss:[si+4]
    mov word ptr cs:[active_owner-module_start], ax
    mov word ptr cs:[active_owner-module_start+2], cx
    mov word ptr cs:[active_owner-module_start+4], dx
    pop dx
    pop cx
    pop ax
    inc word ptr cs:[dispatched-module_start]
    jmp .Lcallback
.Linvalid_dispatch:
    pop dx
    pop cx
    pop ax
    cmp ah, 0x80
    je .Ldrop
    cmp ah, 0x90
    je .Ldrop
    mov word ptr cs:[active_owner-module_start], 0
.Lcallback:
    push ax
    mov ax, 0x491a
    mov ds, ax
    pop ax
    xchg dl, dh
    push dx
    push cx
    xchg al, ah
    push ax
    sti
    call dword ptr [0x4ef4]
    add sp, 6
    cli
    jmp .Ldispatch_restore
.Ldrop:
    inc word ptr cs:[dropped-module_start]
.Ldispatch_restore:
    pop word ptr cs:[active_root-module_start]
    pop word ptr cs:[active_owner-module_start+4]
    pop word ptr cs:[active_owner-module_start+2]
    pop word ptr cs:[active_owner-module_start]
    pop es
    pop ds
    popa
    popf
    ret

/* Sampler DS: return ES:BX program for this dispatch, otherwise editor. */
context_program:
    mov bx, word ptr cs:[active_owner-module_start]
    test bx, bx
    jz .Leditor_program
    dec bx
    shl bx, 2
    les bx, dword ptr [bx+0x9cb2]
    ret

/* Direct PROGRAM-screen previews also own their voices. */
note_on_entry:
    push bp
    mov bp, sp
    pushf
    cli
    push ds
    push es
    push word ptr cs:[active_owner-module_start]
    push word ptr cs:[active_owner-module_start+2]
    push word ptr cs:[active_owner-module_start+4]
    push word ptr cs:[active_root-module_start]
    cmp word ptr cs:[active_owner-module_start], 0
    jne .Lnote_on_ready
    pusha
    mov cx, 0xc000
    call resolve_default
    mov word ptr cs:[active_owner-module_start], ax
    mov word ptr cs:[active_owner-module_start+2], cx
    mov word ptr cs:[active_owner-module_start+4], dx
    les bx, dword ptr [bp+6]
    xor ax, ax
    mov al, byte ptr es:[bx+1]
    mov word ptr cs:[active_root-module_start], ax
    popa
.Lnote_on_ready:
    cmp word ptr cs:[active_owner-module_start], 0
    je .Lnote_on_restore
    /* Admission is atomic with an in-flight reservation. Note Off never
     * enters this routine and is never blocked by the four-program cap. */
    call limit_admit
    jc .Lnote_on_restore
    push word ptr [bp-2]
    popf
    push word ptr [bp+8]
    push word ptr [bp+6]
    push cs
    call note_on_original
    cli
    call limit_release
.Lnote_on_restore:
    cli
    pop word ptr cs:[active_root-module_start]
    pop word ptr cs:[active_owner-module_start+4]
    pop word ptr cs:[active_owner-module_start+2]
    pop word ptr cs:[active_owner-module_start]
    pop es
    pop ds
    popf
    pop bp
    retf 4
note_on_original:
    enter 10, 0
    push di
    push si
    farjump 0x3000, 0x29fe
.Leditor_program:
    les bx, dword ptr [0x9d12]
    ret

note_pointer_ax:
    push bx
    push es
    call context_program
    add ax, bx
    mov dx, es
    pop es
    pop bx
    retf
note_pointer_ax_sub:
    push cs
    call note_pointer_ax
    sub ax, 0x3d9
    retf
note_pointer_bx:
    push ax
    mov ax, bx
    call context_program
    add bx, ax
    pop ax
    retf
mixer_pointer:
    push bx
    push es
    call context_program
    mov ax, bx
    mov dx, es
    pop es
    pop bx
    retf

pitch_context:
    push bx
    push dx
    mov es, word ptr [bp+0x10]
    mov ax, word ptr es:[si+0x0d]
    push es
    push ax
    call context_program
    mov ax, es
    or ax, bx
    xor dx, dx
    test ax, ax
    jz .Lpitch_add
    mov al, byte ptr es:[bx+0x1d]
    cmp al, 255
    je .Lminus36
    cmp al, 71
    ja .Lpitch_add
    xor ah, ah
    sub ax, 35
    imul dx, ax, 10
    jmp .Lpitch_add
.Lminus36:
    mov dx, -360
.Lpitch_add:
    pop ax
    add ax, dx
    pop es
    pop dx
    pop bx
    retf

/* Native voice record has the actual note; parallel root follows VEL SW,
 * SIMULT and stereo back to the triggering note for source-scoped Off.
 */
voice_capture:
    pushf
    pusha
    mov bx, cx
    mov ax, word ptr cs:[active_owner-module_start]
    mov cx, word ptr cs:[active_owner-module_start+2]
    mov dx, word ptr cs:[active_owner-module_start+4]
    own voice_put
    mov ax, word ptr cs:[active_root-module_start]
    mov byte ptr cs:[bx+voice_roots-module_start], al
    popa
    popf
    mov byte ptr [si+0x9a6e], al
    mov ax, word ptr [bp-0x0c]
    retf

match_program:
    mov ax, word ptr cs:[active_owner-module_start]
    mov cx, word ptr cs:[active_owner-module_start+2]
    mov dx, word ptr cs:[active_owner-module_start+4]
    own voice_same_program
    ret
match_source:
    mov ax, word ptr cs:[active_owner-module_start]
    mov cx, word ptr cs:[active_owner-module_start+2]
    mov dx, word ptr cs:[active_owner-module_start+4]
    own voice_same_source
    ret

overlap_stop:
    push bp
    mov bp, sp
    pusha
    xor si, si
    mov di, 0x9a6e
.Loverlap:
    mov al, byte ptr [di]
    xor ah, ah
    cmp ax, word ptr [bp+6]
    jne .Loverlap_next
    mov bx, si
    call match_program
    jc .Loverlap_next
    push si
    farcall 0x3b7c, 0x2810
.Loverlap_next:
    add di, 18
    inc si
    cmp si, 32
    jb .Loverlap
    popa
    pop bp
    retf 2

note_off:
    push bp
    mov bp, sp
    pushf
    cli
    pusha
    push word ptr cs:[active_owner-module_start]
    push word ptr cs:[active_owner-module_start+2]
    push word ptr cs:[active_owner-module_start+4]
    cmp word ptr cs:[active_owner-module_start], 0
    jne .Loff_ready
    mov cx, 0xc000
    call resolve_default
    mov word ptr cs:[active_owner-module_start], ax
    mov word ptr cs:[active_owner-module_start+2], cx
    mov word ptr cs:[active_owner-module_start+4], dx
.Loff_ready:
    xor bx, bx
    mov si, 0x9a6e
    mov di, 0x570e
.Loff_loop:
    cmp word ptr [di], 0
    je .Loff_next
    mov al, byte ptr cs:[bx+voice_roots-module_start]
    xor ah, ah
    cmp ax, word ptr [bp+6]
    jne .Loff_next
    call match_source
    jc .Loff_next
    cmp byte ptr [si+1], 2
    jne .Loff_next
    cmp byte ptr [si+3], 0
    je .Lstop_voice
    cmp byte ptr [si+2], 0
    jne .Lstop_voice
    cmp word ptr [di-0x40], -1
    jne .Loff_next
    mov ax, word ptr [si+8]
    mov word ptr [di], ax
    mov word ptr [di-0x40], 1
    jmp .Loff_next
.Lstop_voice:
    push bx
    push bx
    farcall 0x3b7c, 0x2810
    pop bx
.Loff_next:
    inc bx
    add si, 18
    add di, 2
    cmp bx, 32
    jb .Loff_loop
    pop word ptr cs:[active_owner-module_start+4]
    pop word ptr cs:[active_owner-module_start+2]
    pop word ptr cs:[active_owner-module_start]
    popa
    popf
    pop bp
    retf 2

mute_groups:
    pusha
    push es
    mov dl, byte ptr es:[bx+5]
    cmp dl, 4
    jb .Lmute_done
    cmp dl, 7
    ja .Lmute_done
    xor si, si
    mov di, 0x9a6e
.Lmute_loop:
    push dx
    mov bx, si
    call match_program
    pop dx
    jc .Lmute_next
    mov al, byte ptr [di]
    cmp al, 35
    jb .Lmute_next
    cmp al, 98
    ja .Lmute_next
    xor ah, ah
    cmp ax, word ptr [bp-8]
    je .Lmute_next
    imul ax, ax, 29
    call context_program
    add bx, ax
    sub bx, 0x3d9
    cmp byte ptr es:[bx+5], dl
    jne .Lmute_next
    push si
    farcall 0x3b7c, 0x2810
.Lmute_next:
    add di, 18
    inc si
    cmp si, 32
    jb .Lmute_loop
.Lmute_done:
    pop es
    popa
    cmp byte ptr es:[bx+5], 2
    retf

/* Native program allocator operation 1 targets BL (zero based).
 * Operation 2 copies BL into CL. Invalidate destination before mutation.
 */
program_mutation:
    pushf
    cli
    pusha
    push ds
    cmp ax, 1
    je .Lretire_bl
    cmp ax, 2
    jne .Lmutation_done
    cmp bl, cl
    je .Lmutation_done
    mov bl, cl
.Lretire_bl:
    xor bh, bh
    cmp bx, 24
    jae .Lmutation_done
    mov si, bx
    inc si
    mov ax, 0x491a
    mov ds, ax
    xor di, di
.Lretire_voices:
    mov bx, di
    own voice_get
    cmp ax, si
    jne .Lretire_next
    push di
    farcall 0x3b7c, 0x2810
.Lretire_next:
    inc di
    cmp di, 32
    jb .Lretire_voices
    mov ax, si
    own retire
.Lmutation_done:
    pop ds
    popa
    popf
    /* Replay displaced CMP/JZ; continue correct original near routine. */
    cmp ax, 0
    je .Larena_base
    farjump 0x0fe8, 0x9c63
.Larena_base:
    farjump 0x0fe8, 0x9c6e

/* MAIN channel selector: OFF, loaded 1P..24P, 1A..16A,1B..16B.
 * Existing Pgm remains MIDI Program Change. Low track flags remain intact.
 */
route_value:
    mov bl, byte ptr [0x0b21]
    xor bh, bh
    mov es, word ptr [0x1d0a]
    xor ax, ax
    test byte ptr es:[bx+0x430], 0x40
    jz .Lroute_midi_value
    mov al, byte ptr es:[bx+0x4f0]
    shr al, 3
    test al, al
    jnz .Lroute_value_end
.Lroute_midi_value:
    test byte ptr es:[bx+0x430], 0x20
    jz .Lroute_off_value
    mov al, byte ptr es:[bx+0x430]
    and al, 31
    add al, 25
    ret
.Lroute_off_value:
    xor ax, ax
.Lroute_value_end:
    ret
route_up:
    mov dx, 1
    jmp route_change
route_down:
    mov dx, -1
route_change:
    pushf
    pusha
    push es
    maincall 0x1775
    jne .Lroute_change_done
    push dx
    maincall 0x6747
    pop dx
    call route_value
    mov di, dx
.Lnext_route:
    add ax, di
    cmp ax, 56
    ja .Lroute_change_done
    test ax, ax
    jz .Lstore_off
    cmp ax, 24
    ja .Lstore_midi
    push dx
    call loaded
    pop dx
    jc .Lnext_route
    mov cl, al
    shl cl, 3
    and byte ptr es:[bx+0x4f0], 7
    or byte ptr es:[bx+0x4f0], cl
    and byte ptr es:[bx+0x430], 0x80
    or byte ptr es:[bx+0x430], 0x40
    jmp .Lroute_changed
.Lstore_midi:
    sub al, 25
    mov ah, byte ptr es:[bx+0x430]
    and ah, 0x80
    or al, ah
    or al, 0x20
    mov byte ptr es:[bx+0x430], al
    and byte ptr es:[bx+0x4f0], 7
    jmp .Lroute_changed
.Lstore_off:
    and byte ptr es:[bx+0x430], 0xc0
    and byte ptr es:[bx+0x4f0], 7
.Lroute_changed:
    push cs
    call sync_track
.Lroute_change_done:
    pop es
    popa
    popf
    farjump 0x0000, 0x6af1

/* Replace MAIN channel label at 1133 through 1148; AL starts as the
 * original type XOR20. This is display only; no editor change during play.
 */
route_label:
    push ax
    mov al, byte ptr es:[bx+0x4f0]
    shr al, 3
    test byte ptr es:[bx+0x430], 0x40
    jz .Lnative_label
    cmp al, 1
    jb .Lnative_label
    cmp al, 24
    ja .Lnative_label
    pusha
    push ds
    push es
    xor ah, ah
    mov dl, 10
    div dl
    add ax, 0x3030
    mov byte ptr cs:[program_label-module_start], al
    mov byte ptr cs:[program_label-module_start+1], ah
    cmp al, '0'
    jne .Llabel_ready
    mov byte ptr cs:[program_label-module_start], ' '
.Llabel_ready:
    mov si, offset program_label-module_start
    mov dx, cs
    int 0x2b
    .byte 0x18, 0x24, 0x24, 3
    pop es
    pop ds
    popa
    pop ax
    farjump 0x0000, 0x114a
.Lnative_label:
    pop ax
    test al, 0x20
    jz .Llabel_lookup
    mov al, 0x20
.Llabel_lookup:
    mov ah, 3
    mul ah
    add ax, 0x1555
    mov si, ax
    mov dx, ds
    int 0x2b
    .byte 0x18, 0x24, 0x24, 3
    farjump 0x0000, 0x114a

/* Called when MAIN is redrawn/track selected: use native setter only
 * when the selected explicit program differs, never before every note.
 */
sync_track:
    pushf
    pusha
    push ds
    push es
    mov ax, 0x1f31
    mov ds, ax
    call route_value
    cmp ax, 1
    jb .Lsync_done
    cmp ax, 24
    ja .Lsync_done
    call loaded
    jc .Lsync_done
    dec ax
    mov dx, 0x491a
    mov ds, dx
    cmp al, byte ptr [0x9d70]
    je .Lsync_done
    push ax
    farcall 0x3b7c, 0x58a8
.Lsync_done:
    pop es
    pop ds
    popa
    popf
    retf

sync_draw:
    maincall 0x1239
    push cs
    call sync_track
    mov bl, byte ptr [0x0b21]
    retf

/* C17 R1: helpers use the caller's eight-byte, zeroed SS:BP set.
 * AX is a 1-based slot; all registers are preserved, CF is the result.
 * No allocator, disk I/O, program switching or native voice stopping.
 */
limit_seen:
    cmp ax, word ptr [bp-8]
    je .Lseen
    cmp ax, word ptr [bp-6]
    je .Lseen
    cmp ax, word ptr [bp-4]
    je .Lseen
    cmp ax, word ptr [bp-2]
    je .Lseen
    stc
    ret
.Lseen:
    clc
    ret

limit_insert:
    cmp word ptr [bp-8], 0
    je .Linsert0
    cmp word ptr [bp-6], 0
    je .Linsert1
    cmp word ptr [bp-4], 0
    je .Linsert2
    cmp word ptr [bp-2], 0
    je .Linsert3
    stc
    ret
.Linsert0:
    mov word ptr [bp-8], ax
    clc
    ret
.Linsert1:
    mov word ptr [bp-6], ax
    clc
    ret
.Linsert2:
    mov word ptr [bp-4], ax
    clc
    ret
.Linsert3:
    mov word ptr [bp-2], ax
    clc
    ret

/* DI=requested slot, active_owner identifies the source. IF is clear.
 * First four distinct loaded programs on used DRUM tracks, ascending
 * track order. Muting a track does not reshuffle program priority.
 * OFF resolves to the legacy editor program. MIDI-only tracks don't count.
 * During transport, pads/preview/MIDI input share this priority; if fewer
 * than four tracks' programs exist they may use the remaining capacity.
 * At STOP, manual audition is governed only by the live-voice cap.
 */
limit_priority:
    mov ax, 0x1f31
    mov ds, ax
    mov cx, word ptr cs:[active_owner-module_start+2]
    cmp cx, 0x4000
    jb .Lpriority_sequence
    cmp byte ptr [0x1d86], 0
    je .Lpriority_yes
.Lpriority_sequence:
    mov bx, word ptr [0x1d0a]
    cmp bx, 0x6a00
    jb .Lpriority_no
    mov es, bx
    cmp word ptr es:[0], 0x53
    jb .Lpriority_no
    cmp cx, 0x4000
    jae .Lpriority_global
    /* A captured event from the preceding sequence keeps its owner. Its
     * old routing cannot be ranked against the new sequence: apply only
     * the hard live-voice cap, just as for already sounding old tails. */
    xor ax, ax
    mov al, byte ptr es:[0x13]
    cmp ax, 1
    jb .Lpriority_ui_seq
    cmp ax, 99
    jbe .Lpriority_id
.Lpriority_ui_seq:
    mov al, byte ptr [0x0b20]
    inc ax
.Lpriority_id:
    shr cx, 6
    cmp ax, cx
    jne .Lpriority_yes
.Lpriority_global:
    push ds
    mov ax, 0x491a
    mov ds, ax
    xor ax, ax
    mov al, byte ptr [0x9d70]
    inc ax
    mov si, ax
    pop ds
    xor bx, bx
.Lpriority_track:
    test byte ptr es:[bx+0x4f0], 1
    jz .Lpriority_next
    test byte ptr es:[bx+0x430], 0x40
    jz .Lpriority_next
    xor ax, ax
    mov al, byte ptr es:[bx+0x4f0]
    shr al, 3
    test al, al
    jnz .Lpriority_slot
    mov ax, si
.Lpriority_slot:
    cmp ax, di
    je .Lpriority_yes
    call limit_seen
    jnc .Lpriority_next
    call loaded
    jc .Lpriority_next
    call limit_insert
    jc .Lpriority_no
    cmp word ptr [bp-2], 0
    jne .Lpriority_no
.Lpriority_next:
    inc bx
    cmp bx, 64
    jb .Lpriority_track
    /* Fewer than four configured programs: preserve a captured legacy
     * OFF owner even if the editor program changed since enqueue. */
.Lpriority_yes:
    clc
    ret
.Lpriority_no:
    stc
    ret

/* Gate the original Note On BEFORE sample lookup, overlap/mute processing
 * or DSP allocation. At most four distinct slots may have live voices or
 * unfinished Note On callbacks. The latter closes the interrupt window
 * between admission and voice_capture. All state is in the C15 reservation.
 * Max 64 track checks + (only when nested) 24 pending slots + 32 voices.
 * Existing requested programs short-circuit both scans. No per-tick work.
 * Preserve all registers and flags except CF; caller already has IF=0.
 */
limit_admit:
    pushf
    cli
    push bp
    mov bp, sp
    sub sp, 8
    pusha
    push ds
    push es
    xor ax, ax
    mov word ptr [bp-8], ax
    mov word ptr [bp-6], ax
    mov word ptr [bp-4], ax
    mov word ptr [bp-2], ax
    mov di, word ptr cs:[active_owner-module_start]
    cmp di, 1
    jb .Llimit_bad
    cmp di, 24
    ja .Llimit_bad
    call limit_priority
    jc .Llimit_priority_reject
    xor ax, ax
    mov word ptr [bp-8], ax
    mov word ptr [bp-6], ax
    mov word ptr [bp-4], ax
    mov word ptr [bp-2], ax
    cmp word ptr cs:[limit_pending_total-module_start], 0
    je .Llimit_voices
    xor bx, bx
.Llimit_pending_loop:
    cmp word ptr cs:[bx+limit_pending-module_start], 0
    je .Llimit_pending_next
    mov ax, bx
    shr ax, 1
    inc ax
    cmp ax, di
    je .Llimit_reserve
    call limit_insert
    jc .Llimit_full
    cmp word ptr [bp-2], 0
    jne .Llimit_full
.Llimit_pending_next:
    add bx, 2
    cmp bx, 48
    jb .Llimit_pending_loop
.Llimit_voices:
    mov ax, 0x491a
    mov ds, ax
    mov ax, 0x5a00
    mov es, ax
    xor bx, bx
    xor si, si
.Llimit_voice_loop:
    cmp word ptr [si+0x570e], 0
    je .Llimit_voice_next
    mov ax, word ptr es:[bx+OWNER_voice_owners]
    cmp ax, 1
    jb .Llimit_voice_next
    cmp ax, 24
    ja .Llimit_voice_next
    cmp ax, di
    je .Llimit_reserve
    call limit_seen
    jnc .Llimit_voice_next
    call limit_insert
    jc .Llimit_full
    cmp word ptr [bp-2], 0
    jne .Llimit_full
.Llimit_voice_next:
    add bx, 6
    add si, 2
    cmp si, 64
    jb .Llimit_voice_loop
.Llimit_reserve:
    mov bx, di
    dec bx
    shl bx, 1
    cmp word ptr cs:[bx+limit_pending-module_start], -1
    je .Llimit_full
    cmp word ptr cs:[limit_pending_total-module_start], -1
    je .Llimit_full
    inc word ptr cs:[bx+limit_pending-module_start]
    inc word ptr cs:[limit_pending_total-module_start]
    pop es
    pop ds
    popa
    mov sp, bp
    pop bp
    popf
    clc
    ret
.Llimit_priority_reject:
    inc word ptr cs:[limit_priority_drops-module_start]
    jmp .Llimit_bad
.Llimit_full:
    inc word ptr cs:[limit_voice_drops-module_start]
.Llimit_bad:
    pop es
    pop ds
    popa
    mov sp, bp
    pop bp
    popf
    stc
    ret

/* Called with IF=0 after every admitted original Note On return, including
 * a note with no sample / no free voice. Nested callbacks restored owner. */
limit_release:
    pushf
    push bx
    mov bx, word ptr cs:[active_owner-module_start]
    dec bx
    shl bx, 1
    dec word ptr cs:[bx+limit_pending-module_start]
    dec word ptr cs:[limit_pending_total-module_start]
    pop bx
    popf
    ret

code_end:
.balign 2
install_status: .word 0
active_owner: .space 6
active_root: .word 0
voice_roots: .space 32
pad_owners: .space 33*128*6
dispatched: .word 0
dropped: .word 0
limit_pending: .space 24*2
limit_pending_total: .word 0
limit_priority_drops: .word 0
limit_voice_drops: .word 0
program_label: .ascii " 1P"
.balign 2
/* Begin hooks.inc */
hook_table:
.word 0xfe8, 0x8ff7, 5, expected_0-module_start, patch_0-module_start
.word 0xfe8, 0x911a, 5, expected_1-module_start, patch_1-module_start
.word 0xfe8, 0x9792, 6, expected_2-module_start, patch_2-module_start
.word 0xfe8, 0x97ac, 5, expected_3-module_start, patch_3-module_start
.word 0xfe8, 0x5f3a, 5, expected_4-module_start, patch_4-module_start
.word 0xfe8, 0xe9, 5, expected_5-module_start, patch_5-module_start
.word 0x3000, 0x1f40, 7, expected_6-module_start, patch_6-module_start
.word 0x3000, 0x29f8, 6, expected_7-module_start, patch_7-module_start
.word 0x3000, 0x2a10, 8, expected_8-module_start, patch_8-module_start
.word 0x3000, 0x2a86, 8, expected_9-module_start, patch_9-module_start
.word 0x3000, 0x2b07, 7, expected_10-module_start, patch_10-module_start
.word 0x3000, 0x2b87, 8, expected_11-module_start, patch_11-module_start
.word 0x3000, 0x2bd0, 8, expected_12-module_start, patch_12-module_start
.word 0x3b7c, 0x4092, 7, expected_13-module_start, patch_13-module_start
.word 0x3b7c, 0x40d6, 7, expected_14-module_start, patch_14-module_start
.word 0x53b0, 0x0, 5, expected_15-module_start, patch_15-module_start
.word 0x3b7c, 0x1f3c, 5, expected_16-module_start, patch_16-module_start
.word 0x3b7c, 0x259a, 5, expected_17-module_start, patch_17-module_start
.word 0x3b7c, 0x278a, 7, expected_18-module_start, patch_18-module_start
.word 0x53a0, 0x0, 5, expected_19-module_start, patch_19-module_start
.word 0xfe8, 0x9c5e, 5, expected_20-module_start, patch_20-module_start
.word 0x0, 0x6acb, 5, expected_21-module_start, patch_21-module_start
.word 0x0, 0x6b06, 5, expected_22-module_start, patch_22-module_start
.word 0x0, 0x1133, 6, expected_23-module_start, patch_23-module_start
.word 0x0, 0x10fe, 7, expected_24-module_start, patch_24-module_start
expected_0:
.byte 0x80,0x3e,0x94,0x1d,0x0
patch_0:
.byte 0xea
.word seq_tail-module_start, 0x5b00
.fill 0,1,0x90
expected_1:
.byte 0x90,0xe,0xe8,0x75,0xc9
patch_1:
.byte 0x9a
.word seq_event-module_start, 0x5b00
.fill 0,1,0x90
expected_2:
.byte 0x8b,0x0,0x89,0x1,0x46,0x46
patch_2:
.byte 0x9a
.word duration_move-module_start, 0x5b00
.fill 1,1,0x90
expected_3:
.byte 0x90,0xe,0xe8,0xe3,0xc2
patch_3:
.byte 0x9a
.word duration_expire-module_start, 0x5b00
.fill 0,1,0x90
expected_4:
.byte 0x80,0xfc,0xa0,0x74,0x41
patch_4:
.byte 0xea
.word enqueue_default-module_start, 0x5b00
.fill 0,1,0x90
expected_5:
.byte 0x50,0x2a,0xff,0x8b,0x87
patch_5:
.byte 0xea
.word consume-module_start, 0x5b00
.fill 0,1,0x90
expected_6:
.byte 0x86,0xf2,0x52,0x51,0x86,0xe0,0x50
patch_6:
.byte 0xea
.word direct_dispatch-module_start, 0x5b00
.fill 2,1,0x90
expected_7:
.byte 0xc8,0xa,0x0,0x0,0x57,0x56
patch_7:
.byte 0xea
.word note_on_entry-module_start, 0x5b00
.fill 1,1,0x90
expected_8:
.byte 0x3,0x6,0x12,0x9d,0x8b,0x16,0x14,0x9d
patch_8:
.byte 0x9a
.word note_pointer_ax-module_start, 0x5b00
.fill 3,1,0x90
expected_9:
.byte 0x8e,0x6,0x14,0x9d,0x3,0x1e,0x12,0x9d
patch_9:
.byte 0x9a
.word note_pointer_bx-module_start, 0x5b00
.fill 3,1,0x90
expected_10:
.byte 0x3,0x6,0x12,0x9d,0x2d,0xd9,0x3
patch_10:
.byte 0x9a
.word note_pointer_ax_sub-module_start, 0x5b00
.fill 2,1,0x90
expected_11:
.byte 0x3,0x6,0x12,0x9d,0x8b,0x16,0x14,0x9d
patch_11:
.byte 0x9a
.word note_pointer_ax-module_start, 0x5b00
.fill 3,1,0x90
expected_12:
.byte 0x3,0x6,0x12,0x9d,0x8b,0x16,0x14,0x9d
patch_12:
.byte 0x9a
.word note_pointer_ax-module_start, 0x5b00
.fill 3,1,0x90
expected_13:
.byte 0xa1,0x12,0x9d,0x8b,0x16,0x14,0x9d
patch_13:
.byte 0x9a
.word mixer_pointer-module_start, 0x5b00
.fill 2,1,0x90
expected_14:
.byte 0xa1,0x12,0x9d,0x8b,0x16,0x14,0x9d
patch_14:
.byte 0x9a
.word mixer_pointer-module_start, 0x5b00
.fill 2,1,0x90
expected_15:
.byte 0xe9,0xa2,0x53,0x46,0x10
patch_15:
.byte 0xea
.word pitch_context-module_start, 0x5b00
.fill 0,1,0x90
expected_16:
.byte 0xc8,0x2,0x0,0x0,0x56
patch_16:
.byte 0xea
.word note_off-module_start, 0x5b00
.fill 0,1,0x90
expected_17:
.byte 0x55,0x8b,0xec,0x57,0x56
patch_17:
.byte 0xea
.word overlap_stop-module_start, 0x5b00
.fill 0,1,0x90
expected_18:
.byte 0x88,0x84,0x6e,0x9a,0x8b,0x46,0xf4
patch_18:
.byte 0x9a
.word voice_capture-module_start, 0x5b00
.fill 2,1,0x90
expected_19:
.byte 0x60,0x6,0x26,0x8a,0x57
patch_19:
.byte 0xea
.word mute_groups-module_start, 0x5b00
.fill 0,1,0x90
expected_20:
.byte 0x3d,0x0,0x0,0x74,0xb
patch_20:
.byte 0xea
.word program_mutation-module_start, 0x5b00
.fill 0,1,0x90
expected_21:
.byte 0xe8,0xa7,0xac,0x74,0x1
patch_21:
.byte 0xea
.word route_up-module_start, 0x5b00
.fill 0,1,0x90
expected_22:
.byte 0xe8,0x6c,0xac,0x74,0x1
patch_22:
.byte 0xea
.word route_down-module_start, 0x5b00
.fill 0,1,0x90
expected_23:
.byte 0xa8,0x20,0x74,0x2,0xb0,0x20
patch_23:
.byte 0xea
.word route_label-module_start, 0x5b00
.fill 1,1,0x90
expected_24:
.byte 0xe8,0x38,0x1,0x8a,0x1e,0x21,0xb
patch_24:
.byte 0x9a
.word sync_draw-module_start, 0x5b00
.fill 2,1,0x90

/* End hooks.inc */
.balign 16
module_end:

.endif /* track_engine */
