/* Final firmware source: regions.
 * Assembly source sections for this feature.
 */
/* region_core: assembly unit 20. */
.if MOD_UNIT == 20
/* REGIONS arithmetic and optional queue component, integrated by adapter.S.
 * 80186, own CS, FAR entries, no firmware addresses, DMA or allocation.
 * See README_PL.md for the distinction between active adapter and optional ABI.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
/* Begin abi.inc */
/* Classic REGIONS component ABI v1. All addresses/lengths count PCM words. */
.equ REGIONS_ABI, 1
.equ REGION_COUNT, 16
.equ VAR_REGIONS, 4
.equ PREFIX_REGIONS, 0x84
.equ GUARD_FRAMES, 16
.equ DSP_END_MAX_HI, 0x00ff
.equ DSP_END_MAX_LO, 0xfff0
.equ EVENT_BYTES, 20
.equ CAPTURE_BYTES, 16
.equ FIFO_CAPACITY, 64
.equ EVENT_OWNER_SLOT, 0
.equ EVENT_OWNER_SOURCE, 2
.equ EVENT_OWNER_GENERATION, 4
.equ EVENT_NOTE, 6
.equ EVENT_VELOCITY, 7
.equ EVENT_REGION, 8
.equ EVENT_PAD, 9
.equ EVENT_TRACK, 10
.equ EVENT_FLAGS, 11
.equ EVENT_BAR, 12
.equ EVENT_TICK, 14
.equ EVENT_SERIAL, 16
.equ ERR_INVALID, 1
.equ ERR_FULL, 2
.equ ERR_EMPTY, 3
.equ ERR_SERIAL_EXHAUSTED, 4
.equ ERR_NOT_INITIALIZED, 5
.equ CORE_READY, 0x5247

/* End abi.inc */
.global module_start, code_end, state_start, module_end
.global regions_split, regions_guard, regions_capture, regions_take
.global regions_reset, regions_flush, regions_encode_pair, regions_decode_prefix
.global regions_layout
.global ready, fifo_count, serial_next, fifo_records

module_start:

/* DX:AX=start, CX:BX=end (exclusive), ES:DI=17 DWORD boundaries.
 * All registers and IF/DF preserved. CF=1 => invalid input, no writes.
 * At least 16 PCM words; addresses <= 0x00FFFFFF; output cannot wrap ES.
 * q=L/16, r=L%16. Each iteration adds q and carries floor(i*r/16).
 */
regions_split:
    push bp
    mov bp, sp
    sub sp, 12
    pushf
    pusha
    cmp di, 0xffbc
    ja .Lsplit_bad
    cmp dx, 0x00ff
    ja .Lsplit_bad
    cmp cx, 0x00ff
    ja .Lsplit_bad
    mov word ptr [bp-2], ax
    mov word ptr [bp-4], dx
    sub bx, ax
    sbb cx, dx
    jc .Lsplit_bad
    test cx, cx
    jnz .Lsplit_length_ok
    cmp bx, REGION_COUNT
    jb .Lsplit_bad
.Lsplit_length_ok:
    mov ax, bx
    and ax, 15
    mov word ptr [bp-10], ax
    mov word ptr [bp-12], 0
    mov ax, bx
    mov dx, cx
    mov cx, 4
.Lsplit_divide:
    shr dx, 1
    rcr ax, 1
    loop .Lsplit_divide
    mov word ptr [bp-6], ax
    mov word ptr [bp-8], dx
    mov ax, word ptr [bp-2]
    mov dx, word ptr [bp-4]
    mov cx, REGION_COUNT
    cld
    stosw
    xchg ax, dx
    stosw
    xchg ax, dx
.Lsplit_next:
    add ax, word ptr [bp-6]
    adc dx, word ptr [bp-8]
    mov bx, word ptr [bp-12]
    add bx, word ptr [bp-10]
    cmp bx, 16
    jb .Lsplit_store
    sub bx, 16
    add ax, 1
    adc dx, 0
.Lsplit_store:
    mov word ptr [bp-12], bx
    stosw
    xchg ax, dx
    stosw
    xchg ax, dx
    loop .Lsplit_next
    popa
    popf
    leave
    clc
    retf
.Lsplit_bad:
    popa
    popf
    leave
    stc
    retf

/* DX:AX=aligned destination start, CX:BX=nonzero source length.
 * ES:DI=16-byte descriptor: start, first_zero, loop_start, dsp_end (DWORDs).
 * END must fit bits 23..4. All registers and IF/DF preserved. CF result.
 * Does not copy PCM. Every validation precedes the first output write.
 */
regions_guard:
    push bp
    mov bp, sp
    sub sp, 12
    pushf
    pusha
    cmp di, 0xfff0
    ja .Lguard_bad
    test ax, 15
    jnz .Lguard_bad
    cmp dx, DSP_END_MAX_HI
    ja .Lguard_bad
    cmp cx, DSP_END_MAX_HI
    ja .Lguard_bad
    mov word ptr [bp-2], ax
    mov word ptr [bp-4], dx
    mov si, bx
    or si, cx
    jz .Lguard_bad
    add ax, bx
    adc dx, cx
    jc .Lguard_bad
    mov word ptr [bp-6], ax
    mov word ptr [bp-8], dx
    add ax, 15
    adc dx, 0
    jc .Lguard_bad
    and ax, 0xfff0
    mov word ptr [bp-10], ax
    mov word ptr [bp-12], dx
    add ax, GUARD_FRAMES
    adc dx, 0
    jc .Lguard_bad
    cmp dx, DSP_END_MAX_HI
    ja .Lguard_bad
    jb .Lguard_write
    cmp ax, DSP_END_MAX_LO
    ja .Lguard_bad
.Lguard_write:
    mov word ptr es:[di+12], ax
    mov word ptr es:[di+14], dx
    mov ax, word ptr [bp-2]
    mov dx, word ptr [bp-4]
    mov word ptr es:[di], ax
    mov word ptr es:[di+2], dx
    mov ax, word ptr [bp-6]
    mov dx, word ptr [bp-8]
    mov word ptr es:[di+4], ax
    mov word ptr es:[di+6], dx
    mov ax, word ptr [bp-10]
    mov dx, word ptr [bp-12]
    mov word ptr es:[di+8], ax
    mov word ptr es:[di+10], dx
    popa
    popf
    leave
    clc
    retf
.Lguard_bad:
    popa
    popf
    leave
    stc
    retf

/* DX:AX=trim start, CX:BX=trim end; ES:DI=16 * 24-byte rows.
 * Row: source_start, source_end, destination_start, first_zero,
 *      loop_start, dsp_end (all DWORD PCM word offsets).
 * Returns DX:AX=one destination plane's length, CF=0. Other registers
 * preserved. CF=1: output may be partial and MUST NOT be published/used.
 * Destination plane starts at zero; its eventual PCM base must be aligned.
 * All allocation/copy operations happen AFTER this whole plan succeeds.
 */
regions_layout:
    push bp
    mov bp, sp
    sub sp, 18
    pushf
    push bx
    push cx
    push si
    push di
    cmp di, 0xfe80
    ja .Llayout_bad
    cmp dx, 0xff
    ja .Llayout_bad
    cmp cx, 0xff
    ja .Llayout_bad
    mov word ptr [bp-2], ax
    mov word ptr [bp-4], dx
    sub bx, ax
    sbb cx, dx
    jc .Llayout_bad
    test cx, cx
    jnz .Llayout_length_ok
    cmp bx, REGION_COUNT
    jb .Llayout_bad
.Llayout_length_ok:
    mov ax, bx
    and ax, 15
    mov word ptr [bp-10], ax
    mov word ptr [bp-12], 0
    mov ax, bx
    mov dx, cx
    mov cx, 4
.Llayout_divide:
    shr dx, 1
    rcr ax, 1
    loop .Llayout_divide
    mov word ptr [bp-6], ax
    mov word ptr [bp-8], dx
    mov word ptr [bp-14], 0
    mov word ptr [bp-16], 0
    mov word ptr [bp-18], REGION_COUNT
.Llayout_next:
    mov ax, word ptr [bp-2]
    mov dx, word ptr [bp-4]
    mov word ptr es:[di], ax
    mov word ptr es:[di+2], dx
    mov bx, word ptr [bp-6]
    mov cx, word ptr [bp-8]
    mov si, word ptr [bp-12]
    add si, word ptr [bp-10]
    cmp si, 16
    jb .Llayout_remainder
    sub si, 16
    add bx, 1
    adc cx, 0
.Llayout_remainder:
    mov word ptr [bp-12], si
    add ax, bx
    adc dx, cx
    mov word ptr es:[di+4], ax
    mov word ptr es:[di+6], dx
    mov word ptr [bp-2], ax
    mov word ptr [bp-4], dx
    mov ax, word ptr [bp-14]
    mov dx, word ptr [bp-16]
    add di, 8
    push cs
    call regions_guard
    jc .Llayout_bad
    mov ax, word ptr es:[di+12]
    mov dx, word ptr es:[di+14]
    mov word ptr [bp-14], ax
    mov word ptr [bp-16], dx
    add di, 16
    dec word ptr [bp-18]
    jnz .Llayout_next
    pop di
    pop si
    pop cx
    pop bx
    popf
    leave
    clc
    retf
.Llayout_bad:
    pop di
    pop si
    pop cx
    pop bx
    popf
    leave
    stc
    retf

/* Cold reset ONLY, after stopping all producers, consumers and voices.
 * A transport stop or queue flush must use regions_flush, never reset IDs.
 */
regions_reset:
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
    mov word ptr cs:[serial_next-module_start], 1
    mov word ptr cs:[ready-module_start], CORE_READY
    pop es
    popa
    popf
    retf

/* Discard queued captures, preserving serial lifetime and ready status.
 * Caller must also discard related, unpublished recorder reservations.
 */
regions_flush:
    pushf
    cli
    push ax
    xor ax, ax
    mov word ptr cs:[fifo_read-module_start], ax
    mov word ptr cs:[fifo_write-module_start], ax
    mov word ptr cs:[fifo_count-module_start], ax
    pop ax
    popf
    retf

/* DS:SI -> 16-byte captured Note On context (see abi.inc).
 * Native C17 owner validation is the adapter's responsibility; this helper
 * validates representation, never follows movable program/sample pointers.
 * Preserves registers except AX. CF/AX=0 success; CF=1/AX=error otherwise.
 * No overwrite on full FIFO; IDs never wrap into an earlier lifetime.
 */
regions_capture:
    push bp
    mov bp, sp
    pushf
    cli
    pusha
    push es
    cmp word ptr cs:[ready-module_start], CORE_READY
    jne .Lcapture_uninitialized
    call .Lvalidate_capture
    jc .Lcapture_invalid
    cmp word ptr cs:[fifo_count-module_start], FIFO_CAPACITY
    jae .Lcapture_full
    mov ax, word ptr cs:[serial_next-module_start]
    or ax, word ptr cs:[serial_next-module_start+2]
    jz .Lcapture_exhausted
    mov bx, word ptr cs:[fifo_write-module_start]
    imul di, bx, EVENT_BYTES
    add di, fifo_records-module_start
    push cs
    pop es
    mov cx, CAPTURE_BYTES/2
    cld
    rep movsw
    mov ax, word ptr cs:[serial_next-module_start]
    stosw
    mov ax, word ptr cs:[serial_next-module_start+2]
    stosw
    add word ptr cs:[serial_next-module_start], 1
    adc word ptr cs:[serial_next-module_start+2], 0
    inc bx
    and bx, FIFO_CAPACITY-1
    mov word ptr cs:[fifo_write-module_start], bx
    inc word ptr cs:[fifo_count-module_start]
    mov word ptr [bp-4], 0 /* saved AX in PUSHA frame */
    jmp .Lcapture_done
.Lcapture_uninitialized:
    mov word ptr [bp-4], ERR_NOT_INITIALIZED
    jmp .Lcapture_done
.Lcapture_invalid:
    mov word ptr [bp-4], ERR_INVALID
    jmp .Lcapture_done
.Lcapture_full:
    mov word ptr [bp-4], ERR_FULL
    jmp .Lcapture_done
.Lcapture_exhausted:
    mov word ptr [bp-4], ERR_SERIAL_EXHAUSTED
.Lcapture_done:
    pop es
    popa
    popf
    pop bp
    test ax, ax
    jz .Lcapture_ok
    stc
    retf
.Lcapture_ok:
    clc
    retf

/* ES:DI -> caller-owned 20-byte event, must not alias component state.
 * One consumer. Do not take until the recorder can retain the whole event.
 * CF/AX convention as capture. On error output and FIFO are unchanged.
 */
regions_take:
    push bp
    mov bp, sp
    pushf
    cli
    pusha
    push ds
    cmp di, 0xffec
    ja .Ltake_invalid
    cmp word ptr cs:[ready-module_start], CORE_READY
    jne .Ltake_uninitialized
    cmp word ptr cs:[fifo_count-module_start], 0
    je .Ltake_empty
    mov bx, word ptr cs:[fifo_read-module_start]
    imul si, bx, EVENT_BYTES
    add si, fifo_records-module_start
    push cs
    pop ds
    mov cx, EVENT_BYTES/2
    cld
    rep movsw
    inc bx
    and bx, FIFO_CAPACITY-1
    mov word ptr cs:[fifo_read-module_start], bx
    dec word ptr cs:[fifo_count-module_start]
    mov word ptr [bp-4], 0
    jmp .Ltake_done
.Ltake_invalid:
    mov word ptr [bp-4], ERR_INVALID
    jmp .Ltake_done
.Ltake_uninitialized:
    mov word ptr [bp-4], ERR_NOT_INITIALIZED
    jmp .Ltake_done
.Ltake_empty:
    mov word ptr [bp-4], ERR_EMPTY
.Ltake_done:
    pop ds
    popa
    popf
    pop bp
    test ax, ax
    jz .Ltake_ok
    stc
    retf
.Ltake_ok:
    clc
    retf

/* DS:SI captured context; BX=duration 1..9999 ticks; ES:DI=12-byte scratch.
 * Produces adjacent variation prefix + note. Does NOT allocate/insert into
 * native sequence memory. Adapter must reserve both records as one operation
 * and retain EVENT_SERIAL until duration/Note Off bookkeeping is committed.
 * Input/output must not alias. All registers and IF/DF preserved; CF result.
 */
regions_encode_pair:
    pushf
    pusha
    cmp di, 0xfff4
    ja .Lencode_bad
    cmp bx, 1
    jb .Lencode_bad
    cmp bx, 9999
    ja .Lencode_bad
    call .Lvalidate_capture
    jc .Lencode_bad
    mov al, byte ptr [si+EVENT_TRACK]
    or al, 0x40
    mov byte ptr es:[di], al
    mov ax, word ptr [si+EVENT_TICK]
    mov word ptr es:[di+1], ax
    mov byte ptr es:[di+3], PREFIX_REGIONS
    mov al, byte ptr [si+EVENT_NOTE]
    mov byte ptr es:[di+4], al
    mov al, byte ptr [si+EVENT_REGION]
    mov byte ptr es:[di+5], al
    mov al, byte ptr [si+EVENT_TRACK]
    mov byte ptr es:[di+6], al
    mov ax, word ptr [si+EVENT_TICK]
    mov cx, bx
    shl ch, 3
    or ah, ch
    mov word ptr es:[di+7], ax
    mov byte ptr es:[di+9], bl
    mov al, byte ptr [si+EVENT_NOTE]
    test bx, 0x2000
    jz .Lencode_note
    or al, 0x80
.Lencode_note:
    mov byte ptr es:[di+10], al
    mov al, byte ptr [si+EVENT_VELOCITY]
    mov byte ptr es:[di+11], al
    popa
    popf
    clc
    retf
.Lencode_bad:
    popa
    popf
    stc
    retf

/* DS:SI=6-byte sequence prefix. Success AX=region, BX=note, CX=track,
 * DX=tick. No latch/global UI state. The adapter must match the next note's
 * track/tick/note before applying this prefix. CF=1 leaves registers intact.
 * Accepts only canonical REGIONS, never aliases types 0..3 or 5..15.
 */
regions_decode_prefix:
    pushf
    cmp si, 0xfffa
    ja .Ldecode_bad
    cmp byte ptr [si], 0x40
    jb .Ldecode_bad
    cmp byte ptr [si], 0x7f
    ja .Ldecode_bad
    cmp byte ptr [si+3], PREFIX_REGIONS
    jne .Ldecode_bad
    cmp word ptr [si+1], 0x07ff
    ja .Ldecode_bad
    cmp byte ptr [si+4], 35
    jb .Ldecode_bad
    cmp byte ptr [si+4], 98
    ja .Ldecode_bad
    cmp byte ptr [si+5], REGION_COUNT
    jae .Ldecode_bad
    xor ax, ax
    mov al, byte ptr [si+5]
    xor bx, bx
    mov bl, byte ptr [si+4]
    xor cx, cx
    mov cl, byte ptr [si]
    and cl, 63
    mov dx, word ptr [si+1]
    popf
    clc
    retf
.Ldecode_bad:
    popf
    stc
    retf

/* Near helper. Preserves all registers; validates 16-byte input only.
 * Caller guarantees input does not alias FIFO/component storage.
 */
.Lvalidate_capture:
    cmp si, 0xfff0
    ja .Lcapture_representation_bad
    cmp word ptr [si+EVENT_OWNER_SLOT], 1
    jb .Lcapture_representation_bad
    cmp word ptr [si+EVENT_OWNER_SLOT], 24
    ja .Lcapture_representation_bad
    cmp word ptr [si+EVENT_OWNER_SOURCE], 0
    je .Lcapture_representation_bad
    cmp word ptr [si+EVENT_OWNER_GENERATION], 0
    je .Lcapture_representation_bad
    cmp byte ptr [si+EVENT_NOTE], 35
    jb .Lcapture_representation_bad
    cmp byte ptr [si+EVENT_NOTE], 98
    ja .Lcapture_representation_bad
    cmp byte ptr [si+EVENT_VELOCITY], 1
    jb .Lcapture_representation_bad
    cmp byte ptr [si+EVENT_VELOCITY], 127
    ja .Lcapture_representation_bad
    cmp byte ptr [si+EVENT_REGION], REGION_COUNT
    jae .Lcapture_representation_bad
    cmp byte ptr [si+EVENT_PAD], 16
    jae .Lcapture_representation_bad
    cmp byte ptr [si+EVENT_TRACK], 64
    jae .Lcapture_representation_bad
    cmp byte ptr [si+EVENT_FLAGS], 0
    jne .Lcapture_representation_bad
    cmp word ptr [si+EVENT_TICK], 0x07ff
    ja .Lcapture_representation_bad
    clc
    ret
.Lcapture_representation_bad:
    stc
    ret

code_end:
.balign 2
state_start:
ready: .word 0
fifo_read: .word 0
fifo_write: .word 0
fifo_count: .word 0
serial_next: .long 0
fifo_records: .fill FIFO_CAPACITY*EVENT_BYTES, 1, 0
.balign 4
module_end:

.endif /* region_core */
/* region_pcm: assembly unit 21. */
.if MOD_UNIT == 21
/* C17 R2 native PCM bindings, called by the REGIONS foreground adapter.
 * These are foreground-only operations. Caller must exclude other PCM
 * mutations/copies and retain source/allocation lifetimes for the whole call.
 * Native copies use shared DS:9F24 scratch; no call from a pad/audio IRQ.
 * Absolute FAR addresses are valid ONLY after C17 R2 byte/hash validation.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
.global module_start, code_end, module_end
.global pcm_allocate, pcm_release, pcm_resolve, pcm_copy, pcm_zero
.equ SYS_DS, 0x491a
.equ POOL_COUNT, 130
.equ POOL_BASE, 0x5184
.equ POOL_HEAD, 0x56a2

.macro native seg, ip
    .byte 0x9a
    .word \ip, \seg
.endm

module_start:

/* DX:AX=positive PCM word count -> AX=pool handle, FFFF on failure.
 * Other registers/segments and IF/DF preserved. CF indicates failure.
 * Allocation rounds up to 16 words. No sound/program record is created.
 */
pcm_allocate:
    push bp
    mov bp, sp
    pushf
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
    mov bx, ax
    or bx, dx
    jz .Lalloc_bad
    cmp dx, 0xff
    ja .Lalloc_bad
    jb .Lalloc_go
    cmp ax, 0xfff0
    ja .Lalloc_bad
.Lalloc_go:
    mov bx, SYS_DS
    mov ds, bx
    cld
    push dx
    push ax
    native 0x3000, 0x2534
    cmp ax, POOL_COUNT
    jb .Lalloc_done
.Lalloc_bad:
    mov ax, 0xffff
.Lalloc_done:
    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    popf
    pop bp
    cmp ax, 0xffff
    je .Lalloc_failed
    clc
    retf
.Lalloc_failed:
    stc
    retf

/* AX=live pool handle -> DX:AX=PCM base, CX:BX=allocation length.
 * CF=1 for absent/invalid/non-RAM handle; other registers preserved.
 * Pool index is NOT a lifetime token: caller separately validates generation.
 */
pcm_resolve:
    pushf
    push ds
    push si
    push di
    mov di, SYS_DS
    mov ds, di
    call .Lfind_handle
    jc .Lresolve_bad
    mov ax, word ptr [si+POOL_BASE]
    mov dx, word ptr [si+POOL_BASE+2]
    mov bx, word ptr [si+POOL_BASE+4]
    mov cx, word ptr [si+POOL_BASE+6]
    pop di
    pop si
    pop ds
    popf
    clc
    retf
.Lresolve_bad:
    xor ax, ax
    xor bx, bx
    xor cx, cx
    xor dx, dx
    pop di
    pop si
    pop ds
    popf
    stc
    retf

/* Foreground, AX=owned, unused-by-voices handle. Caller removes its cache
 * reference BEFORE this call. No ownership/generation inference from index.
 * CF=1 if the handle is absent/non-RAM; no release in that case.
 */
pcm_release:
    push bp
    mov bp, sp
    pushf
    pusha
    push ds
    push es
    mov dx, SYS_DS
    mov ds, dx
    call .Lfind_handle
    jc .Lrelease_bad
    cld
    push ax
    native 0x3000, 0x25ca
    pop es
    pop ds
    popa
    popf
    pop bp
    clc
    retf
.Lrelease_bad:
    pop es
    pop ds
    popa
    popf
    pop bp
    stc
    retf

/* DS:SI request, 16 bytes:
 * source_handle:u16, destination_handle:u16,
 * source_offset:u32, destination_offset:u32, count:u32.
 * Checks both live allocations and ranges BEFORE copying. Only distinct
 * handles accepted: native forward copy does not promise overlap safety.
 * Request must not alias native PCM scratch. All registers/IF/DF preserved.
 */
pcm_copy:
    push bp
    mov bp, sp
    sub sp, 16
    pushf
    pusha
    push ds
    push es
    cmp si, 0xfff0
    ja .Lcopy_bad
    mov ax, word ptr [si]
    cmp ax, word ptr [si+2]
    je .Lcopy_bad
    mov dx, word ptr [si+12]
    mov cx, word ptr [si+14]
    mov word ptr [bp-2], dx
    mov word ptr [bp-4], cx
    or dx, cx
    jz .Lcopy_bad
    /* Resolve source into AX:DX, allocation length BX:CX. */
    push cs
    call pcm_resolve
    jc .Lcopy_bad
    push ax
    push dx
    mov ax, word ptr [si+4]
    mov dx, word ptr [si+6]
    call .Lrange
    pop dx
    pop ax
    jc .Lcopy_bad
    add ax, word ptr [si+4]
    adc dx, word ptr [si+6]
    jc .Lcopy_bad
    mov word ptr [bp-6], ax
    mov word ptr [bp-8], dx
    mov ax, word ptr [si+2]
    push cs
    call pcm_resolve
    jc .Lcopy_bad
    push ax
    push dx
    mov ax, word ptr [si+8]
    mov dx, word ptr [si+10]
    call .Lrange
    pop dx
    pop ax
    jc .Lcopy_bad
    add ax, word ptr [si+8]
    adc dx, word ptr [si+10]
    jc .Lcopy_bad
    mov word ptr [bp-10], ax
    mov word ptr [bp-12], dx
    mov ax, SYS_DS
    mov ds, ax
    cld
    /* The DSP address/control ports are also used by timer-driven voices.
       Keep each native DMA transaction atomic, with an IRQ opportunity after
       at most 16 words. The panel UART receives a byte every 320 us:
       128-word read+write transactions can lose its release-status byte.
       Never mask IRQs for the whole sample. */
.Lcopy_chunk:
    mov ax, 16
    cmp word ptr [bp-4], 0
    jne .Lcopy_chunk_size
    cmp word ptr [bp-2], ax
    jae .Lcopy_chunk_size
    mov ax, word ptr [bp-2]
.Lcopy_chunk_size:
    mov word ptr [bp-14], ax
    pushf
    cli
    push word ptr [bp-8]
    push word ptr [bp-6]
    push word ptr [bp-12]
    push word ptr [bp-10]
    push 0
    push word ptr [bp-14]
    native 0x3b7c, 0x1036
    popf
    mov ax, word ptr [bp-14]
    add word ptr [bp-6], ax
    adc word ptr [bp-8], 0
    add word ptr [bp-10], ax
    adc word ptr [bp-12], 0
    sub word ptr [bp-2], ax
    sbb word ptr [bp-4], 0
    mov ax, word ptr [bp-2]
    or ax, word ptr [bp-4]
    jnz .Lcopy_chunk
    pop es
    pop ds
    popa
    popf
    leave
    clc
    retf
.Lcopy_bad:
    pop es
    pop ds
    popa
    popf
    leave
    stc
    retf

/* DS:SI request, 10 bytes: destination handle:u16, offset:u32, count:u32.
 * Zeroes PCM words using native transfer routine after bounds validation.
 * All registers/IF/DF preserved. CF=0 means native function returned;
 * this native ABI does not provide transfer-error verification.
 */
pcm_zero:
    push bp
    mov bp, sp
    sub sp, 12
    pushf
    pusha
    push ds
    push es
    cmp si, 0xfff6
    ja .Lzero_bad
    mov ax, word ptr [si+6]
    mov dx, word ptr [si+8]
    mov word ptr [bp-2], ax
    mov word ptr [bp-4], dx
    or ax, dx
    jz .Lzero_bad
    mov ax, word ptr [si]
    push cs
    call pcm_resolve
    jc .Lzero_bad
    push ax
    push dx
    mov ax, word ptr [si+2]
    mov dx, word ptr [si+4]
    call .Lrange
    pop dx
    pop ax
    jc .Lzero_bad
    add ax, word ptr [si+2]
    adc dx, word ptr [si+4]
    jc .Lzero_bad
    mov word ptr [bp-6], ax
    mov word ptr [bp-8], dx
    mov ax, SYS_DS
    mov ds, ax
    cld
 .Lzero_chunk:
    mov ax, 16
    cmp word ptr [bp-4], 0
    jne .Lzero_chunk_size
    cmp word ptr [bp-2], ax
    jae .Lzero_chunk_size
    mov ax, word ptr [bp-2]
.Lzero_chunk_size:
    mov word ptr [bp-10], ax
    pushf
    cli
    push word ptr [bp-8]
    push word ptr [bp-6]
    push 0
    push 0
    push word ptr [bp-10]
    native 0x3b7c, 0x11da
    popf
    mov ax, word ptr [bp-10]
    add word ptr [bp-6], ax
    adc word ptr [bp-8], 0
    sub word ptr [bp-2], ax
    sbb word ptr [bp-4], 0
    mov ax, word ptr [bp-2]
    or ax, word ptr [bp-4]
    jnz .Lzero_chunk
    pop es
    pop ds
    popa
    popf
    leave
    clc
    retf
.Lzero_bad:
    pop es
    pop ds
    popa
    popf
    leave
    stc
    retf

/* Near: offset DX:AX + count [BP-4]:[BP-2] <= length CX:BX.
 * Returns CF, AX/DX scratch. Does not change BX/CX or BP.
 */
.Lrange:
    add ax, word ptr [bp-2]
    adc dx, word ptr [bp-4]
    jc .Lrange_bad
    cmp dx, cx
    ja .Lrange_bad
    jb .Lrange_ok
    cmp ax, bx
    ja .Lrange_bad
.Lrange_ok:
    clc
    ret
.Lrange_bad:
    stc
    ret

/* DS=SYS_DS, AX=handle -> SI=10*handle, CF. AX preserved, BX/CX/DX/DI
 * scratch. Bounded linked-list traversal avoids following a corrupt cycle.
 */
.Lfind_handle:
    cmp ax, POOL_COUNT
    jae .Lfind_bad
    mov bx, word ptr [POOL_HEAD]
    mov cx, POOL_COUNT
.Lfind_next:
    cmp bx, POOL_COUNT
    jae .Lfind_bad
    imul si, bx, 10
    cmp bx, ax
    je .Lfind_found
    mov bx, word ptr [si+POOL_BASE+8]
    loop .Lfind_next
    jmp .Lfind_bad
.Lfind_found:
    cmp word ptr [si+POOL_BASE+2], 0xff
    ja .Lfind_bad
    mov dx, word ptr [si+POOL_BASE+6]
    cmp dx, 0xff
    ja .Lfind_bad
    mov bx, word ptr [si+POOL_BASE+4]
    mov di, bx
    or di, dx
    jz .Lfind_bad
    add bx, word ptr [si+POOL_BASE]
    adc dx, word ptr [si+POOL_BASE+2]
    jc .Lfind_bad
    cmp dx, 0x0100
    ja .Lfind_bad
    jb .Lfind_ok
    test bx, bx
    jnz .Lfind_bad
.Lfind_ok:
    clc
    ret
.Lfind_bad:
    stc
    ret

code_end:
.balign 4
module_end:

.endif /* region_pcm */
/* region_adapter: assembly unit 22. */
.if MOD_UNIT == 22
/* C17 R2 REGIONS integration. Fixed private resident segment; 80186. */
.intel_syntax noprefix
.code16
.arch i186
.text
/* Begin layout.inc */
.equ HOOK_COUNT, 41
.equ CORE_CS, 0x6214
.equ CORE_regions_split, 0x0
.equ CORE_regions_guard, 0x89
.equ CORE_regions_capture, 0x23e
.equ CORE_regions_take, 0x2cb
.equ CORE_regions_reset, 0x207
.equ CORE_regions_flush, 0x22a
.equ CORE_regions_encode_pair, 0x330
.equ CORE_regions_decode_prefix, 0x3a0
.equ CORE_regions_layout, 0x126
.equ PCM_CS, 0x62a9
.equ PCM_pcm_allocate, 0x0
.equ PCM_pcm_release, 0x77
.equ PCM_pcm_resolve, 0x45
.equ PCM_pcm_copy, 0x9d
.equ PCM_pcm_zero, 0x17f
.equ C17_voice_capture, 0x523
.equ C17_sync_draw, 0x851
.equ C17_mute_groups, 0x63e
.equ C17_overlap_stop, 0x575

/* End layout.inc */
.global module_start, module_end, code_end, install, install_status
.global menu_label, menu_type, menu_cursor, menu_enable, pad_mode, pad_release
.global record_producer, record_read, record_variation, record_commit, record_off
.global voice_start, stereo_stride, envelope_mode, voice_capture, voice_shape
.global pool_allocate, pool_free, prefix_read
.global step_draw, step_type_up, step_type_down, step_value_up, step_value_down
.global main_prepare, cache_collect
.global step_window_type, step_window_up, step_window_draw, step_window_apply
.global cache_table, cache_status, prepared, hits, misses, record_hits, record_vars
.equ CACHE_COUNT, 16
.equ CACHE_BYTES, 424
.equ C_READY, 0
.equ C_PTR, 2
.equ C_SOURCE, 6
.equ C_SOURCE_GEN, 8
.equ C_HANDLE, 12
.equ C_HANDLE_GEN, 14
.equ C_START, 18
.equ C_END, 22
.equ C_LENGTH, 26
.equ C_STEREO, 30
.equ C_COUNT, 31
.equ C_PLANE, 32
.equ C_LAYOUT, 40
.equ C_MAP_REV, 36
.macro fc seg, ip
 .byte 0x9a
 .word \ip, \seg
.endm
.macro fj seg, ip
 .byte 0xea
 .word \ip, \seg
.endm
.macro maincall ip
 push cs
 push offset .Lmain_return_\@-module_start
 push 0x046b
 push 0
 push \ip
 retf
.Lmain_return_\@:
.endm
.macro auxcall ip
 push cs
 push offset .Laux_return_\@-module_start
 push 0x97e5
 push 0x0fe8
 push \ip
 retf
.Laux_return_\@:
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
 mov word ptr [install_status-module_start], 1
 mov bx, offset hook_table-module_start
 mov bp, HOOK_COUNT
.Lverify:
 mov es, [bx]
 mov di, [bx+2]
 mov cx, [bx+4]
 mov si, [bx+6]
 repe cmpsb
 jne .Linstall_bad
 add bx, 10
 dec bp
 jnz .Lverify
 mov bx, offset hook_table-module_start
 mov bp, HOOK_COUNT
.Linstall:
 mov es, [bx]
 mov di, [bx+2]
 mov cx, [bx+4]
 mov si, [bx+8]
 rep movsb
 add bx, 10
 dec bp
 jnz .Linstall
 fc CORE_CS, CORE_regions_reset
 mov word ptr [install_status-module_start], 0x600d
 pop es
 pop ds
 popa
 popf
 fj 0x3000, 0x10
.Linstall_bad:
 mov word ptr [install_status-module_start], 0xe018
 mov word ptr [install_failed_remaining-module_start], bp
 cli
.Lhalt: hlt
 jmp .Lhalt

/* Native UI drawing uses inline INT 2B operands relative to the current CS. */
/* Capture the untouched F2 area after the native Assign 16 levels frame is
   drawn. Restore all three LCD planes, including its original lower border;
   clearing an empty soft key would leave a hole in that border. */
menu_frame_capture:
 pushf
 pusha
 push ds
 push es
 push 0x1f31
 pop ds
 push cs
 pop es
 mov si, 0xe3f5 /* DD90 + 51*32 + 5: six bytes covering F2, rows 51..59. */
 mov di, offset menu_f2_frame-module_start
 mov bx, 3
.Lframe_capture_plane:
 mov dx, 9
.Lframe_capture_row:
 mov cx, 6
 rep movsb
 add si, 26
 dec dx
 jnz .Lframe_capture_row
 add si, 0x660 /* Next 1920-byte plane, less the nine rows traversed. */
 dec bx
 jnz .Lframe_capture_plane
 pop es
 pop ds
 popa
 popf
 mov word ptr [0x0e58], 0xaa03
 retf

menu_frame_restore:
 pusha
 push ds
 push es
 push cs
 pop ds
 push 0x1f31
 pop es
 mov si, offset menu_f2_frame-module_start
 mov di, 0xe3f5
 mov bx, 3
.Lframe_restore_plane:
 mov dx, 9
.Lframe_restore_row:
 mov cx, 6
 rep movsb
 add di, 26
 dec dx
 jnz .Lframe_restore_row
 add di, 0x660
 dec bx
 jnz .Lframe_restore_plane
 pop es
 pop ds
 popa
 ret

menu_label:
 call menu_frame_restore
 int 0x65
 .word editor_open-module_start
 cmp byte ptr [0x636a], 2
 je .Lregions_label
 int 0x2b
 .byte 0x16,0x49,0x1a
 .word 0x636a,0x636c
 retf
.Lregions_label:
 int 0x2b
 .byte 0x68,2,1
 .asciz "EDIT"
 int 0x2b
 .byte 0x0e,0x49,0x1a
 .asciz "REGIONS "
 retf
menu_type:
 cmp byte ptr [0x636a], 1
 je .Ltype_native
 fj 0, 0xa938
.Ltype_native:
 fj 0, 0xa939
menu_cursor:
 cmp byte ptr [0x636a], 1
 je .Lcursor_native
 fj 0, 0xaa39
.Lcursor_native:
 fj 0, 0xaa3a
menu_enable:
 call regions_quiet
 cmp byte ptr [0x636a], 2
 jne .Lenable
 pusha
 push ds
 push es
 mov al, [0x6367]
 maincall 0xa610
 les si, es:[si]
 mov ax, es
 or ax, si
 jz .Lenable_failed
 call prepare
 jc .Lenable_failed
 pop es
 pop ds
 popa
.Lenable:
 mov byte ptr [0x0d38], 1
 fj 0, 0xa9a1
.Lenable_failed:
 pop es
 pop ds
 popa
 int 0x2b
 .byte 0x0e,0x25,0x24
 .asciz "REGIONS: unavailable     "
 fj 0, 0xa99b

/* Same immediate stop used by native TRIM. Silence before any foreground
   allocation/copy; never leave a long audition competing with preparation. */
regions_quiet:
 pushf
 pusha
 push ds
 push es
 push 0x491a
 pop ds
 xor si, si
.Lquiet_voice:
 pushf
 cli
 push si
 fc 0x3b7c, 0x27de
 popf
 inc si
 cmp si, 32
 jb .Lquiet_voice
 pop es
 pop ds
 popa
 popf
 ret

/* C17 MUTE groups already handle other source notes in this program.
   REGIONS also choke earlier slices of their own source note. */
region_mute_groups:
 fc 0x5b00, C17_mute_groups
 pushf
 pusha
 push es
 cmp byte ptr es:[bx+5], 4
 jb .Lregion_mute_done
 cmp byte ptr es:[bx+5], 7
 ja .Lregion_mute_done
 les si, [bp+6]
 cmp byte ptr es:[si+4], 4
 jne .Lregion_mute_done
 push word ptr [bp-8]
 fc 0x5b00, C17_overlap_stop
.Lregion_mute_done:
 pop es
 popa
 popf
 retf

/* Avoid native synthetic releases of all 16 pads for each REGIONS hit. */
pad_release:
 cmp byte ptr [0x636a], 2
 je .Lpad_no_release
 push ax
 mov ah, 0
 mov al, 0
 fj 0x0fe8, 0x5dd3
.Lpad_no_release:
 fj 0x0fe8, 0x5de0
pad_mode:
 cmp byte ptr [0x636a], 2
 je .Lregion_pad
 cmp byte ptr [0x636a], 0
 fj 0x0fe8, 0x5dec
.Lregion_pad:
 cmp byte ptr cs:[editor_active-module_start], 1
 jne .Lpad_not_editing
 cmp bl, cs:[editor_count-module_start]
 jae .Lpad_inactive
 mov cs:[editor_region-module_start], bl
 mov byte ptr cs:[editor_after-module_start], 0
 mov byte ptr cs:[editor_redraw-module_start], 1
 mov byte ptr [0x0b12], 1
.Lpad_not_editing:
 push ax
 mov al, ah
 call note_region_count
 mov cl, al
 pop ax
 cmp bl, cl
 jae .Lpad_inactive
 mov byte ptr [0x634b], 4
 mov byte ptr [0x634c], bl
 fj 0x0fe8, 0x5e2a
.Lpad_inactive:
 /* Native near return, before note publication or recording. */
 fj 0x0fe8, 0x5da5

/* AL source note -> AX committed count. No allocation/DMA. Other registers
   preserved; absent custom map means the original 16 regions. */
note_region_count:
 push bp
 push bx
 push cx
 push dx
 push si
 push di
 push ds
 push es
 maincall 0xa610
 les si, es:[si]
 mov ax, es
 or ax, si
 jz .Lnote_count_default
 call map_find
 jc .Lnote_count_default
 mov ax, cs:[di+M_COUNT]
 jmp .Lnote_count_done
.Lnote_count_default:
 mov ax, 16
.Lnote_count_done:
 pop es
 pop ds
 pop di
 pop si
 pop dx
 pop cx
 pop bx
 pop bp
 ret

/* Ring sidecar indexed by the same byte offset, published before write index. */
record_producer:
 pushf
 push ax
 push bx
 push dx
 push es
 push si
 mov bl, [0x0d32]
 xor bh, bh
 mov byte ptr cs:[bx+record_gates-module_start], 0
 xor dx, dx
 xor si, si
 mov es, si
 les si, es:[0xf4]
 cmp ah, es:[si+0x13]
 jne .Lrecord_publish
 mov dh, [0x634b]
 mov dl, [0x634c]
 cmp dh, 4
 jne .Lrecord_publish
 /* Capture overlap with the event's program, before another track can
    change the UI program. NOTE OFF uses native held-note duration. */
 push ax
 push bx
 push cx
 push dx
 push di
 mov al, ah
 maincall 0xa610
 mov al, es:[si+0x0a]
 pop di
 pop dx
 pop cx
 pop bx
 mov cs:[bx+record_gates-module_start], al
 pop ax
.Lrecord_publish:
 mov cs:[bx+record_vars-module_start], dx
 pop si
 pop es
 pop dx
 pop bx
 pop ax
 popf
 mov bl, [0x0d32]
 mov bh, 0
 fj 0x0fe8, 0x5e5f
record_read:
 inc word ptr cs:[record_reads-module_start]
 xor bh, bh
 push ax
 mov ax, cs:[bx+record_vars-module_start]
 mov cs:[record_current-module_start], ax
 mov al, cs:[bx+record_gates-module_start]
 mov cs:[record_current_gate-module_start], al
 pop ax
 mov cx, [bx+0xd0d8]
 fj 0x0fe8, 0xa0ad
record_variation:
 mov [bx], cl
 mov ax, cs:[record_current-module_start]
 /* Producer already captured the note/variation relationship. Do not test
    it again against the currently selected program in the consumer. */
 fj 0x0fe8, 0xa0f2
record_off:
 cmp cl, 0
 jne .Lrecord_on
 cmp byte ptr cs:[record_current-module_start+1], 4
 jne .Lrecord_native_off
 cmp byte ptr cs:[record_current_gate-module_start], 2
 jne .Lrecord_ignored
.Lrecord_native_off:
 fj 0x0fe8, 0xa10c
.Lrecord_on:
 fj 0x0fe8, 0xa0d4
.Lrecord_ignored:
 fj 0x0fe8, 0xa0bc
record_commit:
 inc word ptr cs:[record_commits-module_start]
 mov word ptr cs:[record_last-module_start], ax
 mov [bx+1], ax
 cmp ah, 4
 jne .Lcommit_native
 inc word ptr cs:[record_hits-module_start]
 cmp byte ptr cs:[record_current_gate-module_start], 2
 je .Lcommit_native
 /* REGIONS is one-shot. Duration 1 does not address the native per-note
    Note-Off map, and each captured hit is flushed before the next dequeue. */
 or byte ptr [bx], 0x80
 mov word ptr [bx+3], 1
 or byte ptr [0x63cb], 1
 push es
 auxcall 0xa339
 pop es
 fj 0x0fe8, 0xa104
.Lcommit_native:
 mov ax, [0x1d4c]
 fj 0x0fe8, 0xa0f8

/* Preserve a saved REGIONS prefix against AFTER/slider substitutions. */
prefix_read:
 mov dh, es:[si+3]
 mov cl, es:[si+5]
 cmp dh, 0x84
 jne .Lprefix_native
 cmp cl, 16
 jae .Lprefix_invalid
 fj 0x0fe8, 0x90e0
.Lprefix_invalid:
 mov dh, 0x80
 mov cl, 64
 fj 0x0fe8, 0x90e0
.Lprefix_native:
 fj 0x0fe8, 0x9054

/* STEP retains the prefix+note pair. Display is one-based, storage zero-based.
   Never let the native tuning renderer clamp a region to tuning's 4..124. */
step_draw:
 mov al, es:[si+3]
 cmp al, 0x84
 jne .Lstep_draw_native
 mov byte ptr [0x597a], 4
 int 0x2b
 .byte 0x0e,0x42,0x0b
 .asciz "REG: "
 xor ax, ax
 mov al, es:[si+5]
 inc ax
 int 0x2b
 .byte 0x3e,0x60,0x0b
 fj 0, 0x93f1
.Lstep_draw_native:
 and al, 3
 fj 0, 0x9365
step_type_up:
 les si, [0x5982]
 mov al, es:[si+3]
 cmp al, 0x84
 je .Lstep_type_locked_up
 fj 0, 0x921c
.Lstep_type_locked_up:
 fj 0, 0x9220
step_type_down:
 les si, [0x5982]
 mov al, es:[si+3]
 cmp al, 0x84
 je .Lstep_type_locked_down
 fj 0, 0x9230
.Lstep_type_locked_down:
 fj 0, 0x9234
step_value_up:
 les si, [0x5982]
 mov al, es:[si+5]
 cmp byte ptr es:[si+3], 0x84
 jne .Lstep_up_native
 push cx
 push ax
 mov al, es:[si+4]
 call note_region_count
 mov cl, al
 dec cl
 pop ax
 cmp al, cl
 pop cx
 jae .Lstep_up_done
 inc al
 mov es:[si+5], al
.Lstep_up_done:
 fj 0, 0x9273
.Lstep_up_native:
 fj 0, 0x9268
step_value_down:
 les si, [0x5982]
 mov al, es:[si+5]
 cmp byte ptr es:[si+3], 0x84
 jne .Lstep_down_native
 test al, al
 jz .Lstep_down_done
 dec al
 mov es:[si+5], al
.Lstep_down_done:
 fj 0, 0x9287
.Lstep_down_native:
 fj 0, 0x927c

/* WINDOW edits must retain REGIONS semantics, including mixed selections. */
step_window_type:
 mov al, es:[si+3]
 cmp al, 0x84
 jne .Lwindow_type_native
 /* A region is a source slice, so its type cannot be changed into TUNE. */
 fj 0, 0x8704
.Lwindow_type_native:
 and al, 0x7f
 fj 0, 0x8871
step_window_up:
 cmp byte ptr [0x5a7f], 4
 jne .Lwindow_up_native
 xor ah, ah
 add al, [0x5a80]
 adc ah, 0
 cmp ax, 15
 jbe .Lwindow_up_done
 mov al, 15
.Lwindow_up_done:
 fj 0, 0x8901
.Lwindow_up_native:
 add al, [0x5a80]
 cmp al, 127
 fj 0, 0x88fd
step_window_draw:
 mov al, [0x5a80]
 mov ah, [0x5a7f]
 cmp ah, 4
 jne .Lwindow_draw_native
 cmp al, 15
 jbe .Lwindow_draw_value
 mov al, 15
 mov [0x5a80], al
.Lwindow_draw_value:
 xor ah, ah
 inc ax
 int 0x2b
 .byte 0x3e,0x9c,0x1a
 fj 0, 0x898b
.Lwindow_draw_native:
 fj 0, 0x8922
step_window_apply:
 cmp byte ptr es:[di+3], 0x84
 jne .Lwindow_apply_ordinary
 cmp byte ptr [0x5a7e], 4
 jne .Lwindow_apply_skip
 cmp byte ptr [0x5a7f], 4
 jne .Lwindow_apply_skip
 mov al, [0x5a80]
 cmp al, 15
 jbe .Lwindow_apply_region
 mov al, 15
.Lwindow_apply_region:
 push cx
 push ax
 mov al, es:[di+4]
 call note_region_count
 mov cl, al
 dec cl
 pop ax
 cmp al, cl
 jbe .Lwindow_apply_count_ok
 mov al, cl
.Lwindow_apply_count_ok:
 pop cx
 mov es:[di+5], al
.Lwindow_apply_skip:
 fj 0, 0x89e9
.Lwindow_apply_ordinary:
 cmp byte ptr [0x5a7e], 4
 jne .Lwindow_apply_native
 cmp byte ptr [0x5a7f], 4
 je .Lwindow_apply_skip
.Lwindow_apply_native:
 cmp byte ptr [0x5a7e], 4
 fj 0, 0x89d6

/* MAIN redraw is a foreground seam, after C17 has selected the track's
   program. Prepare only samples referenced by saved REGIONS in this sequence,
   including after disk reload. No DMA/allocation occurs in a note callback. */
main_prepare:
 fc 0x5b00, C17_sync_draw
 pushf
 pusha
 push ds
 push es
 call cache_collect
 mov es, [0x1d0a]
 mov ax, es
 cmp ax, 0x6a00
 jb .Lscan_done
 cmp ax, 0xa000
 jae .Lscan_done
 cmp byte ptr es:[0x13], 1
 jb .Lscan_done
 cmp byte ptr es:[0x13], 99
 ja .Lscan_done
 mov si, 0x530
.Lscan_next:
 mov al, es:[si]
 cmp al, 0xff
 je .Lscan_done
 mov ah, al
 and ah, 0xc0
 cmp ah, 0x40
 jne .Lscan_advance
 cmp byte ptr es:[si+3], 0x84
 jne .Lscan_advance
 cmp byte ptr es:[si+5], 16
 jae .Lscan_advance
 /* Avoid crossing a segment when reading the adjacent six-byte note. */
 cmp si, 0xfff4
 ja .Lscan_advance
 and al, 63
 cmp al, es:[si+6]
 jne .Lscan_advance
 mov ah, es:[si+4]
 cmp ah, 35
 jb .Lscan_advance
 cmp ah, 98
 jae .Lscan_check_last
 jmp .Lscan_note
.Lscan_check_last:
 jne .Lscan_advance
.Lscan_note:
 push es
 push si
 mov dl, ah
 xor bh, bh
 mov bl, al
 mov es, [0x1d0a]
 test byte ptr es:[bx+0x430], 0x40
 jz .Lscan_restore
 mov al, es:[bx+0x4f0]
 shr al, 3
 push 0x491a
 pop es
 test al, al
 jnz .Lscan_slot
 mov al, es:[0x9d70]
 inc al
.Lscan_slot:
 cmp al, 1
 jb .Lscan_restore
 cmp al, 24
 ja .Lscan_restore
 xor ah, ah
 dec ax
 mov bx, ax
 shl bx, 2
 les bx, es:[bx+0x9cb2]
 mov ax, es
 cmp ax, 0x6a00
 jb .Lscan_restore
 cmp word ptr es:[bx], 2
 jbe .Lscan_restore
 mov al, dl
 sub al, 35
 mov ah, 29
 mul ah
 add bx, ax
 les si, es:[bx+30]
 mov ax, es
 or ax, si
 jz .Lscan_restore
 call prepare
.Lscan_restore:
 pop si
 pop es
.Lscan_advance:
 /* Normalize each record pointer so all field reads stay within a segment. */
 add si, 6
 mov ax, si
 shr ax, 4
 mov bx, es
 add bx, ax
 cmp bx, 0xa000
 jae .Lscan_done
 mov es, bx
 and si, 15
 jmp .Lscan_next
.Lscan_done:
 pop es
 pop ds
 popa
 popf
 retf

/* Conservative reclamation: stale metadata is reclaimed only while every
   native voice is idle. Generation checks prevent freeing a reused handle. */
cache_collect:
 cmp byte ptr cs:[cache_gc_hold-module_start], 0
 je .Lcollect_go
 ret
.Lcollect_go:
 pusha
 push es
 push 0x491a
 pop es
 mov bx, 0x9a6e
 mov cx, 32
.Lcollect_idle:
 cmp byte ptr es:[bx], 0xff
 jne .Lcollect_done
 add bx, 18
 loop .Lcollect_idle
 mov di, offset cache_table-module_start
 mov cx, CACHE_COUNT
.Lcollect_slot:
 cmp word ptr cs:[di+C_READY], 0x5247
 jne .Lcollect_next
 les si, cs:[di+C_PTR]
 call lookup
 jc .Lcollect_reclaim
 cmp bx, di
 je .Lcollect_next
.Lcollect_reclaim:
 mov word ptr cs:[di+C_READY], 0
 mov ax, cs:[di+C_HANDLE]
 cmp ax, 130
 jae .Lcollect_next
 mov bx, ax
 shl bx, 2
 mov dx, cs:[bx+pool_generations-module_start]
 cmp dx, cs:[di+C_HANDLE_GEN]
 jne .Lcollect_next
 mov dx, cs:[bx+pool_generations-module_start+2]
 cmp dx, cs:[di+C_HANDLE_GEN+2]
 jne .Lcollect_next
 fc PCM_CS, PCM_pcm_release
.Lcollect_next:
 add di, CACHE_BYTES
 loop .Lcollect_slot
.Lcollect_done:
 pop es
 popa
 ret

/* Per-handle generations change on native allocation and release. */
pool_allocate:
 mov ax, [bp-2]
 mov [0x56a2], ax
 pushf
 push bx
 mov bx, ax
 call bump_generation
 pop bx
 popf
 retf
pool_free:
 mov di, [bp+4]
 pushf
 push bx
 mov bx, di
 call bump_generation
 pop bx
 popf
 cmp [0x56a2], di
 retf
bump_generation:
 cmp bx, 130
 jae .Lgeneration_done
 shl bx, 2
 add word ptr cs:[bx+pool_generations-module_start], 1
 adc word ptr cs:[bx+pool_generations-module_start+2], 0
.Lgeneration_done:
 ret

/* ES:SI source metadata -> BX cache, CF. Never allocates in the audio path. */
lookup:
 push ax
 push cx
 push dx
 push di
 mov bx, offset cache_table-module_start
 mov cx, CACHE_COUNT
.Llookup_next:
 cmp word ptr cs:[bx+C_READY], 0x5247
 jne .Llookup_skip
 mov ax, cs:[map_epoch-module_start]
 cmp ax, cs:[bx+C_MAP_REV]
 jne .Llookup_skip
 mov ax, cs:[map_epoch-module_start+2]
 cmp ax, cs:[bx+C_MAP_REV+2]
 jne .Llookup_skip
 cmp si, cs:[bx+C_PTR]
 jne .Llookup_skip
 mov ax, es
 cmp ax, cs:[bx+C_PTR+2]
 jne .Llookup_skip
 mov ax, es:[si+0x30]
 cmp ax, cs:[bx+C_SOURCE]
 jne .Llookup_skip
 cmp ax, 130
 jae .Llookup_skip
 mov di, ax
 shl di, 2
 mov ax, cs:[di+pool_generations-module_start]
 cmp ax, cs:[bx+C_SOURCE_GEN]
 jne .Llookup_skip
 mov ax, cs:[di+pool_generations-module_start+2]
 cmp ax, cs:[bx+C_SOURCE_GEN+2]
 jne .Llookup_skip
 mov di, cs:[bx+C_HANDLE]
 cmp di, 130
 jae .Llookup_skip
 shl di, 2
 mov ax, cs:[di+pool_generations-module_start]
 cmp ax, cs:[bx+C_HANDLE_GEN]
 jne .Llookup_skip
 mov ax, cs:[di+pool_generations-module_start+2]
 cmp ax, cs:[bx+C_HANDLE_GEN+2]
 jne .Llookup_skip
 mov ax, es:[si+0x14]
 cmp ax, cs:[bx+C_START]
 jne .Llookup_skip
 mov ax, es:[si+0x16]
 cmp ax, cs:[bx+C_START+2]
 jne .Llookup_skip
 mov ax, es:[si+0x18]
 cmp ax, cs:[bx+C_END]
 jne .Llookup_skip
 mov ax, es:[si+0x1a]
 cmp ax, cs:[bx+C_END+2]
 jne .Llookup_skip
 mov ax, es:[si+0x1c]
 cmp ax, cs:[bx+C_LENGTH]
 jne .Llookup_skip
 mov ax, es:[si+0x1e]
 cmp ax, cs:[bx+C_LENGTH+2]
 jne .Llookup_skip
 mov al, es:[si+0x13]
 cmp al, cs:[bx+C_STEREO]
 je .Llookup_ok
.Llookup_skip:
 add bx, CACHE_BYTES
 loop .Llookup_next_jump
 jmp .Llookup_missing
.Llookup_next_jump:
 jmp .Llookup_next
.Llookup_missing:
 pop di
 pop dx
 pop cx
 pop ax
 stc
 ret
.Llookup_ok:
 pop di
 pop dx
 pop cx
 pop ax
 clc
 ret

/* Foreground cache creation. Source metadata and allocator generations are
   copied before publication. All native DMA uses are synchronous. */
prepare:
 push bp
 mov bp, sp
 sub sp, 24
 mov word ptr [bp-24], 0
 pusha
 push ds
 push es
 call lookup
 jnc .Lprepare_ok
 call cache_collect
 mov bx, offset cache_table-module_start
 mov cx, CACHE_COUNT
.Lempty_slot:
 cmp word ptr cs:[bx+C_READY], 0
 je .Lprepare_slot
 add bx, CACHE_BYTES
 loop .Lempty_slot
 mov word ptr cs:[cache_status-module_start], 2
 jmp .Lprepare_bad
.Lprepare_slot:
 mov [bp-2], bx
 mov cs:[bx+C_PTR], si
 mov ax, es
 mov cs:[bx+C_PTR+2], ax
 mov ax, es:[si+0x30]
 cmp ax, 130
 jae .Lprepare_bad
 mov cs:[bx+C_SOURCE], ax
 mov di, ax
 shl di, 2
 mov ax, cs:[di+pool_generations-module_start]
 mov cs:[bx+C_SOURCE_GEN], ax
 mov ax, cs:[di+pool_generations-module_start+2]
 mov cs:[bx+C_SOURCE_GEN+2], ax
 mov al, es:[si+0x13]
 mov cs:[bx+C_STEREO], al
 mov ax, es:[si+0x1c]
 mov dx, es:[si+0x1e]
 mov cs:[bx+C_LENGTH], ax
 mov cs:[bx+C_LENGTH+2], dx
 mov ax, es:[si+0x14]
 mov dx, es:[si+0x16]
 mov cs:[bx+C_START], ax
 mov cs:[bx+C_START+2], dx
 mov cx, es:[si+0x1a]
 mov di, es:[si+0x18]
 mov cs:[bx+C_END], di
 mov cs:[bx+C_END+2], cx
 call mapped_layout
 jc .Lprepare_bad
 mov bx, [bp-2]
 mov cs:[bx+C_PLANE], ax
 mov cs:[bx+C_PLANE+2], dx
 cmp byte ptr cs:[bx+C_STEREO], 0
 je .Lallocate
 add ax, ax
 adc dx, dx
.Lallocate:
 mov [bp-6], ax
 mov [bp-4], dx
 fc PCM_CS, PCM_pcm_allocate
 jc .Lprepare_bad
 mov bx, [bp-2]
 mov cs:[bx+C_HANDLE], ax
 mov di, ax
 shl di, 2
 mov cx, cs:[di+pool_generations-module_start]
 mov cs:[bx+C_HANDLE_GEN], cx
 mov cx, cs:[di+pool_generations-module_start+2]
 mov cs:[bx+C_HANDLE_GEN+2], cx
 mov [bp-22], ax
 mov word ptr [bp-20], 0
 mov word ptr [bp-18], 0
 mov ax, [bp-6]
 mov dx, [bp-4]
 mov [bp-16], ax
 mov [bp-14], dx
 push ss
 pop ds
 lea si, [bp-22]
 fc PCM_CS, PCM_pcm_zero
 jc .Lprepare_release
 mov word ptr [bp-8], 0
 mov word ptr [bp-10], 0
.Lcopy_region:
 mov bx, [bp-2]
 mov ax, cs:[bx+C_SOURCE]
 mov [bp-22], ax
 mov ax, cs:[bx+C_HANDLE]
 mov [bp-20], ax
 mov di, [bp-8]
 imul di, di, 24
 add di, bx
 add di, C_LAYOUT
 mov ax, cs:[di]
 mov dx, cs:[di+2]
 mov [bp-18], ax
 mov [bp-16], dx
 mov ax, cs:[di+4]
 mov dx, cs:[di+6]
 sub ax, [bp-18]
 sbb dx, [bp-16]
 mov [bp-6], ax
 mov [bp-4], dx
 mov ax, cs:[di+8]
 mov dx, cs:[di+10]
 mov [bp-14], ax
 mov [bp-12], dx
 /* Request is 16 bytes at BP-22: count belongs at BP-10, BP-8.
    Loop counters live in saved registers DI/CX instead of that request. */
 mov ax, [bp-8]
 push ax
 mov ax, [bp-10]
 push ax
 mov ax, [bp-6]
 mov dx, [bp-4]
 mov [bp-10], ax
 mov [bp-8], dx
 cmp word ptr [bp-24], 1
 jne .Lcopy_mono_plane
 mov ax, cs:[bx+C_LENGTH]
 mov dx, cs:[bx+C_LENGTH+2]
 add ax, 15
 adc dx, 0
 and ax, 0xfff0
 add [bp-18], ax
 adc [bp-16], dx
 mov ax, cs:[bx+C_PLANE]
 mov dx, cs:[bx+C_PLANE+2]
 add [bp-14], ax
 adc [bp-12], dx
.Lcopy_mono_plane:
 lea si, [bp-22]
 fc PCM_CS, PCM_pcm_copy
 pop ax
 mov [bp-10], ax
 pop ax
 mov [bp-8], ax
 jc .Lprepare_release
 inc word ptr [bp-8]
 mov bx, [bp-2]
 xor ax, ax
 mov al, cs:[bx+C_COUNT]
 cmp word ptr [bp-8], ax
 jb .Lcopy_region
 mov bx, [bp-2]
 cmp byte ptr cs:[bx+C_STEREO], 0
 je .Lpublish
 cmp word ptr [bp-24], 1
 je .Lpublish
 mov word ptr [bp-24], 1
 mov word ptr [bp-8], 0
 jmp .Lcopy_region
.Lpublish:
 mov ax, cs:[map_epoch-module_start]
 mov cs:[bx+C_MAP_REV], ax
 mov ax, cs:[map_epoch-module_start+2]
 mov cs:[bx+C_MAP_REV+2], ax
 mov word ptr cs:[bx+C_READY], 0x5247
 mov word ptr cs:[cache_status-module_start], 0
 inc word ptr cs:[prepared-module_start]
.Lprepare_ok:
 pop es
 pop ds
 popa
 leave
 clc
 ret
.Lprepare_release:
 mov bx, [bp-2]
 mov ax, cs:[bx+C_HANDLE]
 fc PCM_CS, PCM_pcm_release
.Lprepare_bad:
 mov word ptr cs:[cache_status-module_start], 1
 pop es
 pop ds
 popa
 leave
 stc
 ret

/* BP is the original 5402 frame; never expose negative native duration for
   a short region. DSP loops in zero guard while finite CPU timers clean up. */
voice_start:
 cmp byte ptr [bp-0x45], 4
 jne .Lvoice_native
 pusha
 push es
 les si, [bp-6]
 call lookup
 jc .Lvoice_missing
 mov al, cs:[bx+C_COUNT]
 cmp [bp-0x46], al
 jae .Lvoice_inactive
 mov word ptr [bp-0x4a], bx
 push bx
 mov ax, cs:[bx+C_HANDLE]
 fc PCM_CS, PCM_pcm_resolve
 pop bx
 jc .Lvoice_missing
 xor ch, ch
 mov cl, [bp-0x46]
 imul di, cx, 24
 add di, bx
 add di, C_LAYOUT
 mov bx, ax
 mov cx, dx
 add ax, cs:[di+8]
 adc dx, cs:[di+10]
 mov [bp-0x32], ax
 mov [bp-0x30], dx
 mov ax, bx
 mov dx, cx
 add ax, cs:[di+20]
 adc dx, cs:[di+22]
 mov [bp-0x2e], ax
 mov [bp-0x2c], dx
 sub ax, 16
 sbb dx, 0
 mov [bp-0x2a], ax
 mov [bp-0x28], dx
 mov byte ptr [bp-0x44], 1
 /* Keep the source note's native Voice Overlap byte at BP-43. */
 mov byte ptr [bp-0x42], 0
 mov word ptr [bp-0x10], 0
 mov ax, cs:[di+4]
 mov dx, cs:[di+6]
 sub ax, cs:[di]
 sbb dx, cs:[di+2]
 /* ceil(length*10/441)+40 ms, then native pitch compensation. */
 mov bx, ax
 mov cx, dx
 shl ax, 1
 rcl dx, 1
 shl ax, 1
 rcl dx, 1
 add ax, bx
 adc dx, cx
 shl ax, 1
 rcl dx, 1
 add ax, 440
 adc dx, 0
 push 0
 push 441
 push dx
 push ax
 fc 0x3000, 0x001c
 add ax, 40
 adc dx, 0
 mov [bp-0xc], ax
 mov [bp-0xa], dx
 inc word ptr cs:[hits-module_start]
 jmp .Lvoice_pop
.Lvoice_missing:
 inc word ptr cs:[misses-module_start]
.Lvoice_inactive:
 mov word ptr [bp-0xc], 0
 mov word ptr [bp-0xa], 0
.Lvoice_pop:
 pop es
 popa
 mov ax, [bp-0xc]
 mov dx, [bp-0xa]
 retf
.Lvoice_native:
 mov [bp-0xc], ax
 mov [bp-0xa], dx
 retf
stereo_stride:
 cmp byte ptr [bp-0x45], 4
 jne .Lstereo_native
 push bx
 mov bx, [bp-0x4a]
 mov ax, cs:[bx+C_PLANE]
 mov dx, cs:[bx+C_PLANE+2]
 pop bx
 retf
.Lstereo_native:
 mov ax, es:[bx+0x1c]
 mov dx, es:[bx+0x1e]
 add ax, 15
 adc dx, 0
 and al, 0xf0
 retf
voice_shape:
 les bx, [bp+0x0c]
 cmp byte ptr es:[bx+3], 4
 jne .Lshape_native
 /* Descriptor +5 remains POLY / MONO / NOTE OFF from the program. */
 mov byte ptr es:[bx+6], 0
 mov word ptr es:[bx+0x38], 0
.Lshape_native:
 mov al, es:[bx+4]
 retf
envelope_mode:
 cmp byte ptr es:[bx+3], 4
 je .Lenvelope_regions
 cmp byte ptr es:[bx+4], 0
 retf
.Lenvelope_regions:
 /* ZF=1 selects finite one-shot counters, without clearing DSP loop mode. */
 cmp bx, bx
 retf
voice_capture:
 fc 0x5b00, C17_voice_capture
 pushf
 cmp byte ptr es:[bx+3], 4
 jne .Lcapture_native
 /* The DSP loops only over silent guard words. CPU Note Off must see a
    one-shot: C17 otherwise waits for an infinite loop timer (-1), while
    region safety timers are deliberately finite. DSP registers stay intact. */
 mov byte ptr [si+0x9a71], 0
.Lcapture_native:
 popf
 retf
/* Begin editor.S */
/* Included in adapter.S: Classic-specific REGION EDIT and ALL extension. */
.global editor_open, editor_active, editor_region, editor_field, editor_dirty
.global editor_points, editor_count, editor_source, marker_maps, map_epoch
.global all_create, all_append, all_loaded, marker_load_status
.global editor_ui_reset
.equ MAP_COUNT, 16
.equ MAP_BYTES, 108
.equ M_VALID, 0
.equ M_STEREO, 2
.equ M_LENGTH, 4
.equ M_NAME, 8
.equ M_POINTS, 24
.equ M_PTR, 92
.equ M_HANDLE, 96
.equ M_GENERATION, 98
.equ M_COUNT, 104
.equ D_COUNT, 92
.equ DISK_MAP_BYTES, 96
.equ TRAILER_BYTES, 1584

/* ES:SI metadata -> DI committed map, CF missing. Pending maps loaded from
   ALL bind by the exact 16-byte name, PCM length and mono/stereo flag. */
map_find:
 push ax
 push bx
 push cx
 push dx
 mov di, offset marker_maps-module_start
 mov cx, MAP_COUNT
.Lmap_next:
 cmp word ptr cs:[di+M_VALID], 1
 jne .Lmap_skip
 mov ax, es:[si+0x1c]
 cmp ax, cs:[di+M_LENGTH]
 jne .Lmap_skip
 mov ax, es:[si+0x1e]
 cmp ax, cs:[di+M_LENGTH+2]
 jne .Lmap_skip
 mov al, es:[si+0x13]
 cmp al, cs:[di+M_STEREO]
 jne .Lmap_skip
 cmp si, cs:[di+M_PTR]
 jne .Lmap_name
 mov ax, es
 cmp ax, cs:[di+M_PTR+2]
 jne .Lmap_name
 mov bx, es:[si+0x30]
 cmp bx, 130
 jae .Lmap_skip
 cmp bx, cs:[di+M_HANDLE]
 jne .Lmap_name
 shl bx, 2
 mov ax, cs:[bx+pool_generations-module_start]
 cmp ax, cs:[di+M_GENERATION]
 jne .Lmap_name
 mov ax, cs:[bx+pool_generations-module_start+2]
 cmp ax, cs:[di+M_GENERATION+2]
 je .Lmap_found
.Lmap_name:
 push cx
 push si
 push di
 add di, M_NAME
 mov cx, 8
.Lmap_compare_name:
 mov ax, es:[si]
 cmp ax, cs:[di]
 jne .Lmap_name_bad
 add si, 2
 add di, 2
 loop .Lmap_compare_name
 pop di
 pop si
 pop cx
 mov ax, es
 mov cs:[di+M_PTR], si
 mov cs:[di+M_PTR+2], ax
 mov bx, es:[si+0x30]
 cmp bx, 130
 jae .Lmap_skip
 mov cs:[di+M_HANDLE], bx
 shl bx, 2
 mov ax, cs:[bx+pool_generations-module_start]
 mov cs:[di+M_GENERATION], ax
 mov ax, cs:[bx+pool_generations-module_start+2]
 mov cs:[di+M_GENERATION+2], ax
 jmp .Lmap_found
.Lmap_name_bad:
 pop di
 pop si
 pop cx
.Lmap_skip:
 add di, MAP_BYTES
 loop .Lmap_next_jump
 pop dx
 pop cx
 pop bx
 pop ax
 stc
 ret
.Lmap_next_jump:
 jmp .Lmap_next
.Lmap_found:
 pop dx
 pop cx
 pop bx
 pop ax
 clc
 ret

/* Build exact guarded PCM rows from committed boundaries, or the native
   equal split for a source without custom markers. BX is the cache slot. */
mapped_layout:
 push si
 push di
 push bx
 push cx
 call map_find
 jc .Lmapped_even
 mov ax, cs:[di+M_COUNT]
 mov cs:[bx+C_COUNT], al
 push di
 lea di, [bx+C_LAYOUT]
 push cs
 pop es
 xor ax, ax
 mov cx, 192
 rep stosw
 pop di
 add di, M_POINTS
 mov si, di
 lea di, [bx+C_LAYOUT]
 push cs
 pop es
 xor ax, ax
 xor dx, dx
 xor cx, cx
 mov cl, cs:[bx+C_COUNT]
.Lmapped_row:
 push cx
 push ax
 push dx
 mov ax, cs:[si]
 mov dx, cs:[si+2]
 mov es:[di], ax
 mov es:[di+2], dx
 mov bx, cs:[si+4]
 mov cx, cs:[si+6]
 mov es:[di+4], bx
 mov es:[di+6], cx
 sub bx, ax
 sbb cx, dx
 pop dx
 pop ax
 jc .Lmapped_bad_row
 add di, 8
 fc CORE_CS, CORE_regions_guard
 jc .Lmapped_bad_row
 mov ax, es:[di+12]
 mov dx, es:[di+14]
 add di, 16
 add si, 4
 pop cx
 loop .Lmapped_row
 pop cx
 pop bx
 pop di
 pop si
 clc
 ret
.Lmapped_bad_row:
 pop cx
 pop cx
 pop bx
 pop di
 pop si
 stc
 ret
.Lmapped_even:
 mov byte ptr cs:[bx+C_COUNT], 16
 mov ax, cs:[bx+C_START]
 mov dx, cs:[bx+C_START+2]
 mov cx, cs:[bx+C_END+2]
 lea di, [bx+C_LAYOUT]
 mov bx, cs:[bx+C_END]
 push cs
 pop es
 fc CORE_CS, CORE_regions_layout
 pop cx
 pop bx
 pop di
 pop si
 ret

editor_open:
 cmp byte ptr [0x636a], 2
 je .Ledit_open
 retf
.Ledit_open:
 maincall 0x1775
 jz .Ledit_stopped
 retf
.Ledit_stopped:
 mov al, [0x6367]
 maincall 0xa610
 les si, es:[si]
 mov ax, es
 or ax, si
 jnz .Ledit_source
 retf
.Ledit_source:
 mov cs:[editor_source-module_start], si
 mov cs:[editor_source-module_start+2], es
 mov ax, es:[si+0x1c]
 mov dx, es:[si+0x1e]
 mov cs:[editor_length-module_start], ax
 mov cs:[editor_length-module_start+2], dx
 or dx, dx
 jnz .Ledit_length_ok
 cmp ax, 16
 jae .Ledit_length_ok
 retf
.Ledit_length_ok:
 call regions_quiet
 call prepare
 jnc .Ledit_prepared
 retf
.Ledit_prepared:
 mov byte ptr cs:[editor_count-module_start], 16
 les si, cs:[editor_source-module_start]
 call map_find
 jc .Ledit_initial_even
 mov al, cs:[di+M_COUNT]
 mov cs:[editor_count-module_start], al
 push ds
 push cs
 pop ds
 push cs
 pop es
 lea si, [di+M_POINTS]
 mov di, offset editor_points-module_start
 mov cx, 34
 rep movsw
 pop ds
 jmp .Ledit_initial_done
.Ledit_initial_even:
 call editor_even_points
.Ledit_initial_done:
 mov byte ptr cs:[editor_dirty-module_start], 0
 mov byte ptr cs:[editor_region-module_start], 0
 mov byte ptr cs:[editor_field-module_start], 0
 mov byte ptr cs:[editor_zoom-module_start], 0
 mov byte ptr cs:[editor_status-module_start], 0
 mov byte ptr cs:[editor_after-module_start], 0
 mov byte ptr cs:[editor_digit-module_start], 0
 mov byte ptr cs:[wave_valid-module_start], 0
 mov al, [0x0d38]
 mov cs:[editor_old_levels-module_start], al
 mov al, [0x0d3a]
 mov cs:[editor_old_after-module_start], al
 xor ax, ax
 mov es, ax
 les si, es:[0x00f4]
 mov cs:[editor_variation_owner-module_start], si
 mov cs:[editor_variation_owner-module_start+2], es
 mov al, es:[si+0x13]
 mov cs:[editor_old_note-module_start], al
 mov al, [0x6367]
 mov es:[si+0x13], al
 mov byte ptr [0x0d38], 1
 mov byte ptr [0x0d3a], 0
 int 0x2b
 .byte 0x22
 int 0x2b
 .byte 0x62,0,0,0,0
 /* Native compositor ORs E510 and XORs EC90 over the main plane.
    Clear both former-page layers when taking fullscreen ownership. */
 push ds
 pop es
 xor ax, ax
 mov di, 0xe510
 mov cx, 1920
 rep stosw
 int 0x50
 mov byte ptr cs:[editor_active-module_start], 1
 int 0x5b
 .word editor_back-module_start
 int 0x5d
 .word editor_refresh-module_start
 int 0x64
 .word editor_back-module_start
 int 0x65
 .word editor_even-module_start
 int 0x66
 .word editor_count_action-module_start
 int 0x67
 .word editor_zoom_action-module_start
 int 0x68
 .word editor_play-module_start
 int 0x69
 .word editor_apply_action-module_start
 int 0x5f
 .word editor_increase-module_start
 int 0x5e
 .word editor_decrease-module_start
 int 0x6c
 .word editor_left-module_start,editor_right-module_start,editor_up-module_start,editor_down-module_start
 mov word ptr [0x0e30], offset editor_digit_right-module_start
 mov [0x0e32], cs
 mov word ptr [0x0e34], offset editor_digit_left-module_start
 mov [0x0e36], cs
 mov word ptr [0x0e48], offset editor_wave_idle-module_start
 mov [0x0e4a], cs
 /* Physical MAIN is DCC; INT 5B binds DD0 (a different native action). */
 mov word ptr [0x0dcc], offset editor_main-module_start
 mov [0x0dce], cs
 mov word ptr [0x0de4], offset editor_after_down-module_start
 mov [0x0de6], cs
 mov word ptr [0x0ecc], offset editor_after_up-module_start
 mov [0x0ece], cs
 mov word ptr [0x0e60], offset editor_fader-module_start
 mov [0x0e62], cs
 mov word ptr [0x0e58], 0x0ec0
 mov word ptr [0x0e5a], 0
 mov byte ptr cs:[editor_redraw-module_start], 1
 mov byte ptr [0x0b12], 1
 retf

/* INT 50 resets the native page handlers. Leaving through any global mode
   shortcut must also release editor ownership, not just through BACK. */
editor_ui_reset:
 sti
 cmp byte ptr cs:[editor_active-module_start], 1
 jne .Lui_reset_native
 call editor_restore_levels
 mov byte ptr cs:[editor_active-module_start], 0
 mov byte ptr cs:[editor_after-module_start], 0
.Lui_reset_native:
 maincall 0x0dfb
 iret

editor_restore_levels:
 push ax
 push si
 push es
 push 0x1f31
 pop es
 mov al, cs:[editor_old_levels-module_start]
 mov es:[0x0d38], al
 mov al, cs:[editor_old_after-module_start]
 mov es:[0x0d3a], al
 les si, cs:[editor_variation_owner-module_start]
 mov al, cs:[editor_old_note-module_start]
 mov es:[si+0x13], al
 pop es
 pop si
 pop ax
 ret

editor_back:
 mov byte ptr cs:[editor_active-module_start], 0
 mov byte ptr cs:[editor_after-module_start], 0
 call editor_restore_levels
 maincall 0x102e
 retf
editor_main:
 /* MAIN cancels uncommitted manual markers, but keeps audition/16 LEVELS
    enabled for the selected source, exactly as TURN ON does. */
 mov byte ptr cs:[editor_active-module_start], 0
 mov byte ptr cs:[editor_after-module_start], 0
 mov byte ptr [0x0d38], 1
 mov byte ptr [0x0d3a], 0
 maincall 0x102e
 retf
editor_left:
 mov byte ptr cs:[editor_field-module_start], 0
 jmp editor_cursor_done
editor_right:
 mov byte ptr cs:[editor_field-module_start], 1
 jmp editor_cursor_done
editor_up:
 cmp byte ptr cs:[editor_region-module_start], 0
 je editor_cursor_done
 dec byte ptr cs:[editor_region-module_start]
 jmp editor_cursor_done
editor_down:
 mov al, cs:[editor_region-module_start]
 inc al
 cmp al, cs:[editor_count-module_start]
 jae editor_cursor_done
 inc byte ptr cs:[editor_region-module_start]
editor_cursor_done:
 mov byte ptr cs:[editor_after-module_start], 0
 mov byte ptr cs:[editor_redraw-module_start], 1
 mov byte ptr [0x0b12], 1
 retf

editor_even_points:
 pusha
 push es
 les si, cs:[editor_source-module_start]
 mov ax, es:[si+0x14]
 mov dx, es:[si+0x16]
 mov bx, es:[si+0x18]
 mov cx, es:[si+0x1a]
 push cs
 pop es
 mov di, offset editor_points-module_start
 fc CORE_CS, CORE_regions_split
 /* Select every second/fourth boundary from the exact 16-way division. */
 mov ax, 64
 xor dx, dx
 xor cx, cx
 mov cl, cs:[editor_count-module_start]
 div cx
 mov bx, ax
 mov si, offset editor_points-module_start
 mov di, si
 inc cx
.Leven_compact:
 mov ax, cs:[si]
 mov dx, cs:[si+2]
 mov es:[di], ax
 mov es:[di+2], dx
 add si, bx
 add di, 4
 loop .Leven_compact
 pop es
 popa
 call editor_fill_tail
 ret
editor_even:
 mov byte ptr cs:[editor_after-module_start], 0
 call editor_even_points
 jmp editor_changed
editor_count_action:
 /* Keep the old draft if allocation fails: displayed and audible counts
    must not diverge after a failed automatic APPLY. */
 pusha
 push ds
 push es
 push cs
 pop ds
 push cs
 pop es
 mov si, offset editor_points-module_start
 mov di, offset editor_count_backup-module_start
 mov cx, 34
 rep movsw
 mov al, [editor_count-module_start]
 stosb
 mov al, [editor_region-module_start]
 stosb
 mov al, [editor_dirty-module_start]
 stosb
 pop es
 pop ds
 popa
 shr byte ptr cs:[editor_count-module_start], 1
 cmp byte ptr cs:[editor_count-module_start], 4
 jae .Lcount_selected
 mov byte ptr cs:[editor_count-module_start], 16
.Lcount_selected:
 mov al, cs:[editor_count-module_start]
 cmp cs:[editor_region-module_start], al
 jb .Lcount_region_ok
 dec al
 mov cs:[editor_region-module_start], al
.Lcount_region_ok:
 mov byte ptr cs:[editor_after-module_start], 0
 call editor_even_points
 mov byte ptr cs:[editor_dirty-module_start], 1
 call editor_apply
 jnc .Lcount_applied
 pusha
 push ds
 push es
 push cs
 pop ds
 push cs
 pop es
 mov si, offset editor_count_backup-module_start
 mov di, offset editor_points-module_start
 mov cx, 34
 rep movsw
 lodsb
 mov [editor_count-module_start], al
 lodsb
 mov [editor_region-module_start], al
 lodsb
 mov [editor_dirty-module_start], al
 pop es
 pop ds
 popa
.Lcount_applied:
 mov byte ptr cs:[editor_redraw-module_start], 1
 mov byte ptr [0x0b12], 1
 retf

/* Unused boundaries mirror the last END; they never describe playable pads. */
editor_fill_tail:
 pusha
 xor bx, bx
 mov bl, cs:[editor_count-module_start]
 mov cx, 16
 sub cx, bx
 jz .Ltail_done
 shl bx, 2
 add bx, offset editor_points-module_start
 mov ax, cs:[bx]
 mov dx, cs:[bx+2]
.Ltail_next:
 add bx, 4
 mov cs:[bx], ax
 mov cs:[bx+2], dx
 loop .Ltail_next
.Ltail_done:
 popa
 ret
editor_zoom_action:
 inc byte ptr cs:[editor_zoom-module_start]
 cmp byte ptr cs:[editor_zoom-module_start], 4
 jb .Lzoom_ok
 mov byte ptr cs:[editor_zoom-module_start], 0
.Lzoom_ok:
 mov byte ptr cs:[editor_redraw-module_start], 1
 mov byte ptr [0x0b12], 1
 retf

/* SI points at the edited boundary. Bounds are strict and inclusive. */
editor_bounds:
 xor ax, ax
 mov al, cs:[editor_region-module_start]
 add al, cs:[editor_field-module_start]
 mov bx, ax
 shl bx, 2
 lea si, [bx+editor_points-module_start]
 xor dx, dx
 xor cx, cx
 test ax, ax
 jz .Lbound_min
 mov dx, cs:[si-4]
 mov cx, cs:[si-2]
 add dx, 1
 adc cx, 0
.Lbound_min:
 mov cs:[editor_min-module_start], dx
 mov cs:[editor_min-module_start+2], cx
 cmp al, cs:[editor_count-module_start]
 je .Lbound_outer
 mov dx, cs:[si+4]
 mov cx, cs:[si+6]
 sub dx, 1
 sbb cx, 0
 jmp .Lbound_max
.Lbound_outer:
 mov dx, cs:[editor_length-module_start]
 mov cx, cs:[editor_length-module_start+2]
.Lbound_max:
 mov cs:[editor_max-module_start], dx
 mov cs:[editor_max-module_start+2], cx
 ret
editor_increase:
 call editor_bounds
 call editor_digit_step
 mov ax, cs:[si]
 mov dx, cs:[si+2]
 add ax, bx
 adc dx, cx
 jmp editor_clamp
editor_decrease:
 call editor_bounds
 call editor_digit_step
 mov ax, cs:[si]
 mov dx, cs:[si+2]
 sub ax, bx
 sbb dx, cx
 jnc editor_clamp
 xor ax, ax
 xor dx, dx
editor_clamp:
 cmp dx, cs:[editor_max-module_start+2]
 ja .Lclamp_max
 jb .Lclamp_min_check
 cmp ax, cs:[editor_max-module_start]
 jbe .Lclamp_min_check
.Lclamp_max:
 mov ax, cs:[editor_max-module_start]
 mov dx, cs:[editor_max-module_start+2]
.Lclamp_min_check:
 cmp dx, cs:[editor_min-module_start+2]
 jb .Lclamp_min
 ja .Lclamp_store
 cmp ax, cs:[editor_min-module_start]
 jae .Lclamp_store
.Lclamp_min:
 mov ax, cs:[editor_min-module_start]
 mov dx, cs:[editor_min-module_start+2]
.Lclamp_store:
 mov cs:[si], ax
 mov cs:[si+2], dx
editor_changed:
 call editor_fill_tail
 mov byte ptr cs:[editor_dirty-module_start], 1
 mov byte ptr cs:[editor_redraw-module_start], 1
 mov byte ptr [0x0b12], 1
 mov byte ptr cs:[editor_status-module_start], 0
 retf

/* Native TRIM ring contract: AX=2 and DX>0 is a new third detent.
   Returning towards centre must not select another digit. */
editor_digit_right:
 test dx, dx
 jz .Ldigit_done
 cmp ax, 2
 jne .Ldigit_done
 cmp byte ptr cs:[editor_digit-module_start], 0
 je .Ldigit_done
 dec byte ptr cs:[editor_digit-module_start]
 jmp .Ldigit_redraw
editor_digit_left:
 test dx, dx
 jz .Ldigit_done
 cmp ax, 2
 jne .Ldigit_done
 cmp byte ptr cs:[editor_digit-module_start], 6
 jae .Ldigit_done
 inc byte ptr cs:[editor_digit-module_start]
.Ldigit_redraw:
 mov byte ptr cs:[editor_redraw-module_start], 1
 mov byte ptr [0x0b12], 1
.Ldigit_done:
 retf
editor_digit_step:
 xor bx, bx
 mov bl, cs:[editor_digit-module_start]
 shl bx, 2
 mov cx, cs:[bx+editor_powers-module_start+2]
 mov bx, cs:[bx+editor_powers-module_start]
 ret
editor_after_down:
 mov byte ptr cs:[editor_after-module_start], 1
 retf
editor_after_up:
 mov byte ptr cs:[editor_after-module_start], 0
 retf
editor_fader:
 cmp byte ptr cs:[editor_after-module_start], 1
 je .Lfader_edit
 retf
.Lfader_edit:
 cmp ax, 127
 jbe .Lfader_value_ok
 retf
.Lfader_value_ok:
 mov cs:[editor_fader_value-module_start], ax
 call editor_bounds
 mov ax, cs:[editor_max-module_start]
 mov dx, cs:[editor_max-module_start+2]
 sub ax, cs:[editor_min-module_start]
 sbb dx, cs:[editor_min-module_start+2]
 /* L <= 24 bits; multiply by a seven-bit fader without 32-bit overflow. */
 mov bx, cs:[editor_fader_value-module_start]
 mov cx, dx
 mul bx
 push ax
 push dx
 mov ax, cx
 mul bx
 mov cx, ax
 pop dx
 add dx, cx
 pop ax
 mov cx, 127
 call divide_u32_u16
 add ax, cs:[editor_min-module_start]
 adc dx, cs:[editor_min-module_start+2]
 jmp editor_clamp

/* DX:AX / CX -> DX:AX quotient, BX remainder. SI preserved. */
divide_u32_u16:
 push si
 mov si, ax
 mov ax, dx
 xor dx, dx
 div cx
 mov bx, ax
 mov ax, si
 div cx
 mov si, dx
 mov dx, bx
 mov bx, si
 pop si
 ret

editor_apply_action:
 call editor_apply
 jnc editor_main
 mov byte ptr cs:[editor_redraw-module_start], 1
 mov byte ptr [0x0b12], 1
 retf
editor_apply:
 cmp byte ptr cs:[editor_dirty-module_start], 0
 jne .Lapply_begin
 clc
 ret
.Lapply_begin:
 maincall 0x1775
 jz .Lapply_transport_stopped
 mov byte ptr cs:[editor_status-module_start], 3
 stc
 ret
.Lapply_transport_stopped:
 call regions_quiet
 pusha
 push ds
 push es
 mov byte ptr cs:[editor_status-module_start], 1
 /* Rebuilding requires idle voices; retain the old cache on failure. */
 push 0x491a
 pop es
 mov bx, 0x9a6e
 mov cx, 32
.Lapply_idle:
 cmp byte ptr es:[bx], 0xff
 jne .Lapply_failed
 add bx, 18
 loop .Lapply_idle
 les si, cs:[editor_source-module_start]
 call map_find
 jnc .Lapply_slot
 mov di, offset marker_maps-module_start
 mov cx, MAP_COUNT
.Lapply_empty:
 cmp word ptr cs:[di+M_VALID], 0
 je .Lapply_slot
 add di, MAP_BYTES
 loop .Lapply_empty
 mov byte ptr cs:[editor_status-module_start], 2
 jmp .Lapply_failed
.Lapply_slot:
 mov cs:[editor_map_slot-module_start], di
 push ds
 push cs
 pop ds
 push cs
 pop es
 mov si, di
 mov di, offset editor_map_backup-module_start
 mov cx, MAP_BYTES/2
 rep movsw
 pop ds
 les si, cs:[editor_source-module_start]
 mov di, cs:[editor_map_slot-module_start]
 mov word ptr cs:[di+M_VALID], 0
 mov al, es:[si+0x13]
 xor ah, ah
 mov cs:[di+M_STEREO], ax
 mov ax, es:[si+0x1c]
 mov cs:[di+M_LENGTH], ax
 mov ax, es:[si+0x1e]
 mov cs:[di+M_LENGTH+2], ax
 xor ax, ax
 mov al, cs:[editor_count-module_start]
 mov cs:[di+M_COUNT], ax
 push si
 push di
 add di, M_NAME
 mov cx, 8
.Lapply_name:
 mov ax, es:[si]
 mov cs:[di], ax
 add si, 2
 add di, 2
 loop .Lapply_name
 pop di
 pop si
 mov cs:[di+M_PTR], si
 mov cs:[di+M_PTR+2], es
 mov bx, es:[si+0x30]
 mov cs:[di+M_HANDLE], bx
 shl bx, 2
 mov ax, cs:[bx+pool_generations-module_start]
 mov cs:[di+M_GENERATION], ax
 mov ax, cs:[bx+pool_generations-module_start+2]
 mov cs:[di+M_GENERATION+2], ax
 push ds
 push cs
 pop ds
 push cs
 pop es
 add di, M_POINTS
 mov si, offset editor_points-module_start
 mov cx, 34
 rep movsw
 pop ds
 mov di, cs:[editor_map_slot-module_start]
 mov word ptr cs:[di+M_VALID], 1
 add word ptr cs:[map_epoch-module_start], 1
 adc word ptr cs:[map_epoch-module_start+2], 0
 mov byte ptr cs:[cache_gc_hold-module_start], 1
 les si, cs:[editor_source-module_start]
 call prepare
 mov byte ptr cs:[cache_gc_hold-module_start], 0
 jc .Lapply_rollback
 mov byte ptr cs:[editor_dirty-module_start], 0
 mov byte ptr cs:[editor_status-module_start], 0
 call cache_collect
 pop es
 pop ds
 popa
 clc
 ret
.Lapply_rollback:
 sub word ptr cs:[map_epoch-module_start], 1
 sbb word ptr cs:[map_epoch-module_start+2], 0
 push cs
 pop ds
 push cs
 pop es
 mov si, offset editor_map_backup-module_start
 mov di, cs:[editor_map_slot-module_start]
 mov cx, MAP_BYTES/2
 rep movsw
 mov byte ptr cs:[editor_status-module_start], 2
.Lapply_failed:
 pop es
 pop ds
 popa
 stc
 ret

editor_play:
 /* Audition the committed manual markers or the auto-applied split. */
 mov al, 100
 mov ah, cs:[editor_region-module_start]
 auxcall 0x5da6
.Lplay_end:
 mov byte ptr cs:[editor_redraw-module_start], 1
 mov byte ptr [0x0b12], 1
 retf

editor_refresh:
 cmp byte ptr cs:[editor_redraw-module_start], 0
 jne .Lrefresh_now
 retf
.Lrefresh_now:
 mov byte ptr cs:[editor_redraw-module_start], 0
 pusha
 push ds
 push es
 int 0x2b
 .byte 4
 int 0x2b
 .byte 0x60,0,0,248,60
 call editor_header_frame
 int 0x2b
 .byte 0x0e,2,1
 .asciz "REGION EDIT"
 int 0x2b
 .byte 0x0e,158,1
 .asciz "REG:   /"
 xor ax, ax
 mov al, cs:[editor_count-module_start]
 int 0x2b
 .byte 0x3e,206,1
 xor ax, ax
 mov al, cs:[editor_region-module_start]
 inc ax
 int 0x2b
 .byte 0x3e,188,1
 int 0x2b
 .byte 0x0e,0,12
 .asciz "St:"
 int 0x2b
 .byte 0x0e,128,12
 .asciz "End:"
 xor bx, bx
 mov bl, cs:[editor_region-module_start]
 shl bx, 2
 mov ax, cs:[bx+editor_points-module_start]
 mov dx, cs:[bx+editor_points-module_start+2]
 int 0x2b
 .byte 0x48,24,12
 mov ax, cs:[bx+editor_points-module_start+4]
 mov dx, cs:[bx+editor_points-module_start+6]
 int 0x2b
 .byte 0x48,158,12
 xor ax, ax
 mov al, cs:[editor_digit-module_start]
 mov cl, 6
 mul cl
 mov dl, 43
 sub dl, al
 mov cl, 23
 cmp byte ptr cs:[editor_field-module_start], 0
 je .Lhighlight_digit
 mov cl, 157
.Lhighlight_digit:
 mov ch, 11
 mov dh, 9
 call editor_invert_rect
 call editor_wave
 cmp byte ptr cs:[editor_status-module_start], 1
 je .Lstatus_wait
 cmp byte ptr cs:[editor_status-module_start], 2
 je .Lstatus_memory
 cmp byte ptr cs:[editor_status-module_start], 3
 je .Lstatus_transport
 jmp .Lstatus_done
.Lstatus_wait:
 int 0x2b
 .byte 0x0e,0,43
 .asciz "WAIT FOR SOUND TO FINISH"
 jmp .Lstatus_done
.Lstatus_memory:
 int 0x2b
 .byte 0x0e,0,43
 .asciz "NO FREE BUFFER / MAP SLOT"
 jmp .Lstatus_done
.Lstatus_transport:
 int 0x2b
 .byte 0x0e,0,43
 .asciz "STOP SEQUENCE BEFORE APPLY"
 jmp .Lstatus_done
.Lstatus_done:
 int 0x2b
 .byte 0x68,1,1
 .asciz "BACK"
 int 0x2b
 .byte 0x68,2,1
 .asciz "EVEN"
 cmp byte ptr cs:[editor_count-module_start], 8
 je .Lcount_label8
 cmp byte ptr cs:[editor_count-module_start], 4
 je .Lcount_label4
 int 0x2b
 .byte 0x68,3,1
 .asciz "16"
 jmp .Lcount_label_done
.Lcount_label8:
 int 0x2b
 .byte 0x68,3,1
 .asciz "8"
 jmp .Lcount_label_done
.Lcount_label4:
 int 0x2b
 .byte 0x68,3,1
 .asciz "4"
.Lcount_label_done:
 int 0x2b
 .byte 0x68,4,1
 .asciz "ZOOM"
 int 0x2b
 .byte 0x68,5,1
 .asciz "PLAY"
 int 0x2b
 .byte 0x68,6,1
 .asciz "APPLY"
 pop es
 pop ds
 popa
 retf

/* Native TRIM-style title frame; numeric fields sit below its dotted edge. */
editor_header_frame:
 mov cx, 0
 mov dx, 0x0198
 int 0x2b
 .byte 0x9a
 mov cx, 0
 mov dx, 0x0b01
 int 0x2b
 .byte 0x9a
 mov cx, 151
 mov dx, 0x0b01
 int 0x2b
 .byte 0x9a
 mov cx, 0x0a00
.Lheader_bottom:
 mov dx, 0x0101
 int 0x2b
 .byte 0x9a
 add cl, 2
 cmp cl, 151
 jb .Lheader_bottom
 ret

/* Invert the complete field through the selected power of ten, matching
   native TRIM. The digits to its right remain on the normal background. */
editor_invert_rect:
 pusha
 push es
 push 0x1f31
 pop es
 mov al, cl
 xor ah, ah
 mov bx, ax
 shr bx, 3
 mov al, ch
 xor ah, ah
 shl ax, 5
 add bx, ax
 add bx, 0xdd90
 and cl, 7
 mov al, 0x80
 shr al, cl
 xor ch, ch
 mov cl, dl
.Lfield_column:
 mov di, bx
 mov dl, dh
.Lfield_row:
 xor es:[di], al
 add di, 32
 dec dl
 jnz .Lfield_row
 ror al, 1
 jnc .Lfield_same
 inc bx
.Lfield_same:
 loop .Lfield_column
 pop es
 popa
 ret

/* Native TRIM resolution and gain: 245 columns of signed PCM minima/maxima,
   2427 PCM units per vertical pixel. Foreground work is bounded to 1024
   samples per pass, with an IRQ opportunity after every 16-word transfer.
   Cached peaks are reused while only the selection/digit changes. */
.equ WAVE_COLUMNS, 245
editor_wave:
 pusha
 push ds
 push es
 les si, cs:[editor_source-module_start]
 mov ax, es:[si+0x30]
 fc PCM_CS, PCM_pcm_resolve
 jc .Lwave_done
 mov cs:[wave_base-module_start], ax
 mov cs:[wave_base-module_start+2], dx
 xor bx, bx
 mov bl, cs:[editor_region-module_start]
 shl bx, 2
 mov ax, cs:[bx+editor_points-module_start]
 mov dx, cs:[bx+editor_points-module_start+2]
 mov cs:[wave_left-module_start], ax
 mov cs:[wave_left-module_start+2], dx
 mov cx, cs:[bx+editor_points-module_start+4]
 mov si, cs:[bx+editor_points-module_start+6]
 sub cx, ax
 sbb si, dx
 mov cs:[wave_span-module_start], cx
 mov cs:[wave_span-module_start+2], si
 cmp byte ptr cs:[editor_field-module_start], 0
 je .Lwave_marker_start
 mov ax, cs:[bx+editor_points-module_start+4]
 mov dx, cs:[bx+editor_points-module_start+6]
.Lwave_marker_start:
 mov cs:[wave_marker-module_start], ax
 mov cs:[wave_marker-module_start+2], dx
 cmp byte ptr cs:[editor_zoom-module_start], 0
 je .Lwave_window_ready
 cmp byte ptr cs:[editor_zoom-module_start], 3
 je .Lwave_whole_source
 mov bx, 128
 cmp byte ptr cs:[editor_zoom-module_start], 1
 je .Lwave_fine
 mov bx, 1024
.Lwave_fine:
 mov cx, ax
 mov si, dx
 sub ax, bx
 sbb dx, 0
 jnc .Lwave_left_ok
 xor ax, ax
 xor dx, dx
.Lwave_left_ok:
 mov cs:[wave_left-module_start], ax
 mov cs:[wave_left-module_start+2], dx
 add cx, bx
 adc si, 0
 cmp si, cs:[editor_length-module_start+2]
 ja .Lwave_right_clamp
 jb .Lwave_right_ok
 cmp cx, cs:[editor_length-module_start]
 jbe .Lwave_right_ok
.Lwave_right_clamp:
 mov cx, cs:[editor_length-module_start]
 mov si, cs:[editor_length-module_start+2]
.Lwave_right_ok:
 sub cx, ax
 sbb si, dx
 mov cs:[wave_span-module_start], cx
 mov cs:[wave_span-module_start+2], si
 jmp .Lwave_window_ready
.Lwave_whole_source:
 mov word ptr cs:[wave_left-module_start], 0
 mov word ptr cs:[wave_left-module_start+2], 0
 mov ax, cs:[editor_length-module_start]
 mov dx, cs:[editor_length-module_start+2]
 mov cs:[wave_span-module_start], ax
 mov cs:[wave_span-module_start+2], dx
.Lwave_window_ready:
 cmp byte ptr cs:[wave_valid-module_start], 1
 jne .Lwave_new_window
 mov ax, cs:[wave_left-module_start]
 cmp ax, cs:[wave_cached_left-module_start]
 jne .Lwave_new_window
 mov ax, cs:[wave_left-module_start+2]
 cmp ax, cs:[wave_cached_left-module_start+2]
 jne .Lwave_new_window
 mov ax, cs:[wave_span-module_start]
 cmp ax, cs:[wave_cached_span-module_start]
 jne .Lwave_new_window
 mov ax, cs:[wave_span-module_start+2]
 cmp ax, cs:[wave_cached_span-module_start+2]
 je .Lwave_draw
.Lwave_new_window:
 mov ax, cs:[wave_left-module_start]
 mov dx, cs:[wave_left-module_start+2]
 mov cs:[wave_cached_left-module_start], ax
 mov cs:[wave_cached_left-module_start+2], dx
 mov cs:[wave_position-module_start], ax
 mov cs:[wave_position-module_start+2], dx
 mov ax, cs:[wave_span-module_start]
 mov dx, cs:[wave_span-module_start+2]
 mov cs:[wave_cached_span-module_start], ax
 mov cs:[wave_cached_span-module_start+2], dx
 mov cx, WAVE_COLUMNS
 call divide_u32_u16
 mov cs:[wave_step-module_start], ax
 mov cs:[wave_step-module_start+2], dx
 mov cs:[wave_remainder-module_start], bx
 mov word ptr cs:[wave_fraction-module_start], 0
 mov word ptr cs:[wave_index-module_start], 0
 mov word ptr cs:[wave_remaining-module_start], 0
 mov word ptr cs:[wave_remaining-module_start+2], 0
 push cs
 pop es
 mov di, offset wave_peaks-module_start
 xor ax, ax
 mov cx, WAVE_COLUMNS*2
 rep stosw
 mov byte ptr cs:[wave_valid-module_start], 1
.Lwave_draw:
 xor si, si
.Lwave_draw_column:
 mov bx, si
 shl bx, 2
 mov ax, cs:[bx+wave_peaks-module_start]
 cwd
 mov cx, 2427
 idiv cx
 test ax, ax
 jns .Lwave_min_pixel
 dec ax
.Lwave_min_pixel:
 mov di, ax
 mov ax, cs:[bx+wave_peaks-module_start+2]
 cwd
 idiv cx
 mov bx, ax
 sub bx, di
 jnz .Lwave_height
 inc bx
.Lwave_height:
 mov dh, bl
 mov dl, 1
 mov ch, 34
 sub ch, al
 mov ax, si
 inc ax
 mov cl, al
 push si
 int 0x2b
 .byte 0x9a
 pop si
 inc si
 cmp si, WAVE_COLUMNS
 jb .Lwave_draw_column
 cmp byte ptr cs:[editor_zoom-module_start], 3
 jne .Lwave_local_marker
 call editor_wave_overview
 jmp .Lwave_done
.Lwave_local_marker:
 mov ax, cs:[wave_marker-module_start]
 mov dx, cs:[wave_marker-module_start+2]
 sub ax, cs:[wave_left-module_start]
 sbb dx, cs:[wave_left-module_start+2]
 call editor_wave_project
 cmp ax, WAVE_COLUMNS-1
 jbe .Lwave_local_x
 mov ax, WAVE_COLUMNS-1
.Lwave_local_x:
 inc ax
 mov cl, al
 mov ch, 21
 mov dx, 0x1b01
 int 0x2b
 .byte 0x9a
.Lwave_done:
 pop es
 pop ds
 popa
 ret

/* E48 is the native foreground idle callback (not a timer or audio IRQ).
   Scan every source word, including transients between display columns. */
editor_wave_idle:
 cmp byte ptr cs:[editor_active-module_start], 1
 jne .Lwave_idle_return
 cmp byte ptr cs:[wave_valid-module_start], 1
 jne .Lwave_idle_return
 cmp word ptr cs:[wave_index-module_start], WAVE_COLUMNS
 jb .Lwave_idle_work
.Lwave_idle_return:
 retf
.Lwave_idle_work:
 pusha
 push ds
 push es
 mov word ptr cs:[wave_budget-module_start], 1024
.Lwave_idle_next:
 mov ax, cs:[wave_remaining-module_start]
 or ax, cs:[wave_remaining-module_start+2]
 jnz .Lwave_read_chunk
 mov ax, cs:[wave_position-module_start]
 mov dx, cs:[wave_position-module_start+2]
 add ax, cs:[wave_step-module_start]
 adc dx, cs:[wave_step-module_start+2]
 mov bx, cs:[wave_fraction-module_start]
 add bx, cs:[wave_remainder-module_start]
 cmp bx, WAVE_COLUMNS
 jb .Lwave_next_boundary
 sub bx, WAVE_COLUMNS
 add ax, 1
 adc dx, 0
.Lwave_next_boundary:
 mov cs:[wave_fraction-module_start], bx
 mov cs:[wave_next-module_start], ax
 mov cs:[wave_next-module_start+2], dx
 sub ax, cs:[wave_position-module_start]
 sbb dx, cs:[wave_position-module_start+2]
 mov bx, ax
 or bx, dx
 jnz .Lwave_column_size
 inc ax /* Sub-pixel sample lengths repeat the current in-range sample. */
.Lwave_column_size:
 mov cs:[wave_remaining-module_start], ax
 mov cs:[wave_remaining-module_start+2], dx
.Lwave_read_chunk:
 mov cx, 16
 cmp cx, cs:[wave_budget-module_start]
 jbe .Lwave_budget_ready
 mov cx, cs:[wave_budget-module_start]
.Lwave_budget_ready:
 cmp word ptr cs:[wave_remaining-module_start+2], 0
 jne .Lwave_chunk_ready
 cmp cs:[wave_remaining-module_start], cx
 jae .Lwave_chunk_ready
 mov cx, cs:[wave_remaining-module_start]
.Lwave_chunk_ready:
 mov cs:[wave_chunk-module_start], cx
 mov ax, cs:[wave_position-module_start]
 mov dx, cs:[wave_position-module_start+2]
 add ax, cs:[wave_base-module_start]
 adc dx, cs:[wave_base-module_start+2]
 push 0x491a
 pop ds
 pushf
 cli
 push dx
 push ax
 push cs
 push offset wave_word-module_start
 push cx
 fc 0x3b7c, 0x0ffa
 popf
 mov bx, cs:[wave_index-module_start]
 shl bx, 2
 add bx, offset wave_peaks-module_start
 push cs
 push offset wave_word-module_start
 push word ptr cs:[wave_chunk-module_start]
 push cs
 push bx
 add bx, 2
 push cs
 push bx
 fc 0x3b7c, 0x827e /* Native TRIM signed min/max reducer, retf 14. */
 mov ax, cs:[wave_chunk-module_start]
 sub cs:[wave_budget-module_start], ax
 add cs:[wave_position-module_start], ax
 adc word ptr cs:[wave_position-module_start+2], 0
 sub cs:[wave_remaining-module_start], ax
 sbb word ptr cs:[wave_remaining-module_start+2], 0
 mov ax, cs:[wave_remaining-module_start]
 or ax, cs:[wave_remaining-module_start+2]
 jnz .Lwave_idle_continue
 mov ax, cs:[wave_next-module_start]
 mov dx, cs:[wave_next-module_start+2]
 mov cs:[wave_position-module_start], ax
 mov cs:[wave_position-module_start+2], dx
 inc word ptr cs:[wave_index-module_start]
 /* Redraw in groups of eight completed columns, and the final column. */
 test word ptr cs:[wave_index-module_start], 7
 jz .Lwave_idle_redraw
 cmp word ptr cs:[wave_index-module_start], WAVE_COLUMNS
 jne .Lwave_idle_continue
.Lwave_idle_redraw:
 mov byte ptr cs:[editor_redraw-module_start], 1
 push 0x1f31
 pop es
 mov byte ptr es:[0x0b12], 1
.Lwave_idle_continue:
 cmp word ptr cs:[wave_budget-module_start], 0
 je .Lwave_idle_done
 cmp word ptr cs:[wave_index-module_start], WAVE_COLUMNS
 jae .Lwave_idle_done
 jmp .Lwave_idle_next
.Lwave_idle_done:
 pop es
 pop ds
 popa
 retf

/* DX:AX window-relative boundary -> AX pixel offset 0..245. Native unsigned DWORD
   division keeps the mapping exact for samples longer than 65535 words.
   A 24-bit PCM position times 245 fits in a DWORD. Preserve other registers. */
editor_wave_project:
 push bx
 push cx
 push dx
 push si
 push di
 push bp
 push ds
 push es
 mov cx, dx
 mov bx, WAVE_COLUMNS
 mul bx
 mov si, ax
 mov di, dx
 mov ax, cx
 mul bx
 add ax, di
 mov dx, ax
 mov ax, si
 push word ptr cs:[wave_span-module_start+2]
 push word ptr cs:[wave_span-module_start]
 push dx
 push ax
 fc 0x3000, 0x001c
 pop es
 pop ds
 pop bp
 pop di
 pop si
 pop dx
 pop cx
 pop bx
 ret

/* Highlight the complete draft region in the whole-source view. The active
   START/END marker uses the same projection as the selection boundaries.
   Invert only the main plot plane; its normal refresh clears the selection,
   so no XOR overlay survives a zoom change or leaving the editor. */
editor_wave_overview:
 xor bx, bx
 mov bl, cs:[editor_region-module_start]
 shl bx, 2
 mov ax, cs:[bx+editor_points-module_start]
 mov dx, cs:[bx+editor_points-module_start+2]
 call editor_wave_project
 inc ax
 mov cs:[wave_selection_x-module_start], ax
 mov ax, cs:[bx+editor_points-module_start+4]
 mov dx, cs:[bx+editor_points-module_start+6]
 call editor_wave_project
 inc ax
 sub ax, cs:[wave_selection_x-module_start]
 jnz .Loverview_width
 inc ax /* A sub-pixel region remains visible as one pixel. */
.Loverview_width:
 mov cs:[wave_selection_width-module_start], ax
 mov ax, cs:[wave_marker-module_start]
 mov dx, cs:[wave_marker-module_start+2]
 call editor_wave_project
 inc ax
 mov cs:[wave_marker_x-module_start], ax
 cmp word ptr cs:[wave_selection_width-module_start], 1
 jne .Loverview_marker
 cmp ax, cs:[wave_selection_x-module_start]
 je .Loverview_selection /* Do not erase a one-pixel selection with its marker. */
.Loverview_marker:
 mov cl, al
 mov ch, 21
 mov dx, 0x1b01
 int 0x2b
 .byte 0x9a
.Loverview_selection:
 mov ax, cs:[wave_selection_x-module_start]
 mov bx, ax
 shr bx, 3
 add bx, 0xdd90+21*32
 mov cl, al
 and cl, 7
 mov dl, 0x80
 shr dl, cl
 mov cx, cs:[wave_selection_width-module_start]
 push 0x1f31
 pop es
.Loverview_column:
 mov di, bx
 mov si, 27
.Loverview_row:
 xor byte ptr es:[di], dl
 add di, 32
 dec si
 jnz .Loverview_row
 ror dl, 1
 jnc .Loverview_same_byte
 inc bx
.Loverview_same_byte:
 loop .Loverview_column
 ret

/* ALL trailer: 16 zero sentinel bytes, 32-byte signed/versioned header,
   sixteen 96-byte records. Native sequence records remain unchanged. */
all_stage:
 pusha
 push ds
 push es
 push cs
 pop ds
 push cs
 pop es
 mov di, offset all_trailer-module_start
 xor ax, ax
 mov cx, TRAILER_BYTES/2
 rep stosw
 mov si, offset all_signature-module_start
 mov di, offset all_trailer-module_start+16
 mov cx, 8
 rep movsw
 mov word ptr [all_trailer-module_start+32], MAP_COUNT
 mov word ptr [all_trailer-module_start+34], DISK_MAP_BYTES
 mov si, offset marker_maps-module_start
 mov di, offset all_trailer-module_start+48
 mov bx, MAP_COUNT
.Lstage_record:
 cmp word ptr [si+M_VALID], 1
 jne .Lstage_skip
 call map_refresh_name
 push si
 push di
 mov cx, 46
 rep movsw
 pop di
 pop si
 mov ax, [si+M_COUNT]
 mov [di+D_COUNT], ax
.Lstage_skip:
 add si, MAP_BYTES
 add di, DISK_MAP_BYTES
 dec bx
 jnz .Lstage_record
 mov si, offset all_trailer-module_start+48
 mov cx, MAP_COUNT*DISK_MAP_BYTES/2
 xor dx, dx
.Lstage_sum:
 lodsw
 add dx, ax
 loop .Lstage_sum
 mov [all_trailer-module_start+36], dx
 pop es
 pop ds
 popa
 ret

/* Preserve marker ownership across a native sound rename, but never read
   a stale metadata pointer after its original allocation has been freed. */
map_refresh_name:
 pusha
 push es
 les bx, cs:[si+M_PTR]
 mov ax, es
 or ax, bx
 jz .Lrefresh_name_done
 mov di, cs:[si+M_HANDLE]
 cmp di, 130
 jae .Lrefresh_name_done
 shl di, 2
 mov ax, cs:[di+pool_generations-module_start]
 cmp ax, cs:[si+M_GENERATION]
 jne .Lrefresh_name_done
 mov ax, cs:[di+pool_generations-module_start+2]
 cmp ax, cs:[si+M_GENERATION+2]
 jne .Lrefresh_name_done
 mov ax, es:[bx+0x30]
 cmp ax, cs:[si+M_HANDLE]
 jne .Lrefresh_name_done
 mov ax, es:[bx+0x1c]
 cmp ax, cs:[si+M_LENGTH]
 jne .Lrefresh_name_done
 mov ax, es:[bx+0x1e]
 cmp ax, cs:[si+M_LENGTH+2]
 jne .Lrefresh_name_done
 add si, M_NAME
 mov cx, 8
.Lrefresh_name_word:
 mov ax, es:[bx]
 mov cs:[si], ax
 add bx, 2
 add si, 2
 loop .Lrefresh_name_word
.Lrefresh_name_done:
 pop es
 popa
 ret
all_create:
 call all_stage
 add word ptr [0x0b0e], TRAILER_BYTES
 adc word ptr [0x0b10], 0
 maincall 0x40ef
 jnc .Lall_created
 fj 0, 0x4414
.Lall_created:
 fj 0, 0x34d1
all_append:
 pusha
 push es
 push cs
 pop es
 mov si, offset all_trailer-module_start
 mov cx, TRAILER_BYTES
 mov bl, 9
 mov bh, [0x78a8]
 int 0x2c
 pop es
 popa
 jnc .Lall_appended
 fj 0, 0x4414
.Lall_appended:
 mov bl, 10
 mov bh, [0x78a8]
 fj 0, 0x356c

/* Native ALL reader has consumed the file into the sequence arena. Copy
   the validated extension before the normal allocator reuses its bytes. */
all_loaded:
 push bx
 mov bx, ax
 shr bx, 4
 mov ax, es
 add ax, bx
 mov cs:[marker_read_end-module_start], ax
 pop bx
 xor ax, ax
 mov es:[di], ax
 pusha
 push ds
 push es
 push cs
 pop es
 mov di, offset marker_maps-module_start
 mov cx, MAP_COUNT*MAP_BYTES/2
 rep stosw
 mov word ptr cs:[marker_load_status-module_start], 0
 mov word ptr cs:[marker_disk_version-module_start], 0
 add word ptr cs:[map_epoch-module_start], 1
 adc word ptr cs:[map_epoch-module_start+2], 0
 fc 0x0fe8, 0x97de
 mov cx, 99
.Lall_walk:
 mov ax, es
 cmp ax, cs:[marker_read_end-module_start]
 jae .Lall_load_done
 mov bx, es:[0]
 test bx, bx
 jz .Lall_extension
 cmp bx, 0x54
 jb .Lall_load_done
 add ax, bx
 jc .Lall_load_done
 mov es, ax
 loop .Lall_walk
 jmp .Lall_load_done
.Lall_extension:
 mov bx, cs:[marker_read_end-module_start]
 sub bx, ax
 cmp bx, TRAILER_BYTES/16
 jb .Lall_load_done
 mov si, 16
 mov di, offset all_signature-module_start
 mov cx, 7
.Lall_magic:
 mov ax, es:[si]
 cmp ax, cs:[di]
 jne .Lall_load_done
 add si, 2
 add di, 2
 loop .Lall_magic
 /* Version 1 has sixteen regions. Version 2 stores count in record +92. */
 mov ax, es:[si]
 cmp ax, 0x3130
 je .Lall_version1
 cmp ax, 0x3230
 jne .Lall_load_done
 mov word ptr cs:[marker_disk_version-module_start], 2
 jmp .Lall_version_ready
.Lall_version1:
 mov word ptr cs:[marker_disk_version-module_start], 1
.Lall_version_ready:
 mov word ptr cs:[marker_load_status-module_start], 2
 cmp word ptr es:[32], MAP_COUNT
 jne .Lall_load_done
 cmp word ptr es:[34], DISK_MAP_BYTES
 jne .Lall_load_done
 xor dx, dx
 mov si, 48
 mov cx, MAP_COUNT*DISK_MAP_BYTES/2
.Lall_checksum:
 add dx, es:[si]
 add si, 2
 loop .Lall_checksum
 cmp dx, es:[36]
 jne .Lall_load_done
 mov si, 48
 mov cx, MAP_COUNT
.Lall_validate:
 cmp word ptr es:[si], 0
 je .Lall_validate_next
 cmp word ptr es:[si], 1
 jne .Lall_load_done
 call validate_disk_map
 jc .Lall_load_done
.Lall_validate_next:
 add si, DISK_MAP_BYTES
 loop .Lall_validate
 mov si, 48
 mov di, offset marker_maps-module_start
 mov bx, MAP_COUNT
.Lall_copy_map:
 push si
 mov cx, 46
.Lall_copy_word:
 mov ax, es:[si]
 mov cs:[di], ax
 add si, 2
 add di, 2
 loop .Lall_copy_word
 mov ax, 16
 cmp word ptr cs:[marker_disk_version-module_start], 1
 je .Lall_copy_count
 mov ax, es:[si] /* SI now points at serialized +92. */
.Lall_copy_count:
 mov cs:[di+M_COUNT-92], ax
 add di, MAP_BYTES-92
 pop si
 add si, DISK_MAP_BYTES
 dec bx
 jnz .Lall_copy_map
 mov word ptr cs:[marker_load_status-module_start], 1
.Lall_load_done:
 pop es
 pop ds
 popa
 fj 0, 0xeddd

/* ES:SI serialized map. Positive strictly ordered points inside PCM length. */
validate_disk_map:
 pusha
 mov di, 16
 cmp word ptr cs:[marker_disk_version-module_start], 1
 je .Lmap_count_ok
 mov di, es:[si+D_COUNT]
 cmp di, 16
 je .Lmap_count_ok
 cmp di, 8
 je .Lmap_count_ok
 cmp di, 4
 jne .Lmap_invalid
.Lmap_count_ok:
 cmp word ptr es:[si+M_STEREO], 1
 ja .Lmap_invalid
 mov bx, es:[si+M_LENGTH]
 mov cx, es:[si+M_LENGTH+2]
 cmp cx, 0xff
 ja .Lmap_invalid
 test cx, cx
 jnz .Lmap_length_ok
 cmp bx, 16
 jb .Lmap_invalid
.Lmap_length_ok:
 add si, M_POINTS
 mov ax, es:[si]
 mov dx, es:[si+2]
 push di
.Lmap_order:
 cmp dx, es:[si+6]
 ja .Lmap_order_invalid
 jb .Lmap_increasing
 cmp ax, es:[si+4]
 jae .Lmap_order_invalid
.Lmap_increasing:
 add si, 4
 mov ax, es:[si]
 mov dx, es:[si+2]
 dec di
 jnz .Lmap_order
 pop di
 cmp dx, cx
 ja .Lmap_invalid
 jb .Lmap_tail_check
 cmp ax, bx
 ja .Lmap_invalid
.Lmap_tail_check:
 mov cx, 16
 sub cx, di
 jz .Lmap_valid
.Lmap_tail:
 add si, 4
 cmp ax, es:[si]
 jne .Lmap_invalid
 cmp dx, es:[si+2]
 jne .Lmap_invalid
 loop .Lmap_tail
.Lmap_valid:
 popa
 clc
 ret
.Lmap_order_invalid:
 pop di
.Lmap_invalid:
 popa
 stc
 ret

/* End editor.S */
code_end:
.balign 4
install_status: .word 0
install_failed_remaining: .word 0
cache_status: .word 0
prepared: .word 0
hits: .word 0
misses: .word 0
record_hits: .word 0
record_current: .word 0
record_reads: .word 0
record_commits: .word 0
record_last: .word 0
record_vars: .fill 256,1,0
record_gates: .fill 256,1,0
record_current_gate: .byte 0
.balign 2
pool_generations: .fill 130*4,1,0
cache_table: .fill CACHE_COUNT*CACHE_BYTES,1,0
menu_f2_frame: .fill 162,1,0
/* Begin editor_data.inc */
.balign 4
map_epoch: .long 0
cache_gc_hold: .byte 0
editor_active: .byte 0
editor_region: .byte 0
editor_count: .byte 16
editor_field: .byte 0
editor_digit: .byte 0
wave_valid: .byte 0
editor_dirty: .byte 0
editor_redraw: .byte 0
editor_after: .byte 0
editor_zoom: .byte 0
editor_status: .byte 0
editor_old_levels: .byte 0
editor_old_after: .byte 0
editor_old_note: .byte 0
editor_variation_owner: .long 0
.balign 2 /* V53 word DMA requires the waveform destination to be even. */
editor_fader_value: .word 0
editor_source: .long 0
editor_length: .long 0
editor_min: .long 0
editor_max: .long 0
editor_map_slot: .word 0
editor_points: .fill 68,1,0
editor_count_backup: .fill 71,1,0
.balign 2
editor_powers: .long 1,10,100,1000,10000,100000,1000000,10000000
editor_map_backup: .fill MAP_BYTES,1,0
wave_base: .long 0
wave_position: .long 0
wave_step: .long 0
wave_left: .long 0
wave_span: .long 0
wave_marker: .long 0
wave_selection_x: .word 0
wave_selection_width: .word 0
wave_marker_x: .word 0
wave_cached_left: .long 0
wave_cached_span: .long 0
wave_next: .long 0
wave_remaining: .long 0
wave_chunk: .word 0
wave_budget: .word 0
.balign 2
wave_word: .fill 256,1,0
wave_peaks: .fill WAVE_COLUMNS*4,1,0
wave_index: .word 0
wave_remainder: .word 0
wave_fraction: .word 0
wave_marker_drawn: .byte 0
.balign 2
marker_load_status: .word 0
marker_disk_version: .word 0
marker_read_end: .word 0
marker_maps: .fill MAP_COUNT*MAP_BYTES,1,0
all_trailer: .fill TRAILER_BYTES,1,0
all_signature: .ascii "MPC2KREGIONS0002"

/* End editor_data.inc */
/* Begin hooks.inc */
hook_table:
.word 0x0, 0xa8ab, 6, expected_0-module_start, patch_0-module_start
.word 0x0, 0xa91f, 9, expected_1-module_start, patch_1-module_start
.word 0x0, 0xa931, 5, expected_2-module_start, patch_2-module_start
.word 0x0, 0xaa32, 5, expected_3-module_start, patch_3-module_start
.word 0x0, 0xa99c, 5, expected_4-module_start, patch_4-module_start
.word 0xfe8, 0x5dce, 5, expected_5-module_start, patch_5-module_start
.word 0xfe8, 0x5de7, 5, expected_6-module_start, patch_6-module_start
.word 0xfe8, 0x5e59, 6, expected_7-module_start, patch_7-module_start
.word 0xfe8, 0xa0a7, 6, expected_8-module_start, patch_8-module_start
.word 0xfe8, 0xa0d4, 9, expected_9-module_start, patch_9-module_start
.word 0xfe8, 0xa0cf, 5, expected_10-module_start, patch_10-module_start
.word 0xfe8, 0xa0f2, 6, expected_11-module_start, patch_11-module_start
.word 0xfe8, 0x904c, 8, expected_12-module_start, patch_12-module_start
.word 0x3000, 0x249a, 6, expected_13-module_start, patch_13-module_start
.word 0x3000, 0x24ac, 7, expected_14-module_start, patch_14-module_start
.word 0x3000, 0x2a24, 5, expected_15-module_start, patch_15-module_start
.word 0x3000, 0x2c89, 6, expected_16-module_start, patch_16-module_start
.word 0x3000, 0x2ddb, 16, expected_17-module_start, patch_17-module_start
.word 0x3b7c, 0x25c8, 7, expected_18-module_start, patch_18-module_start
.word 0x3b7c, 0x2640, 5, expected_19-module_start, patch_19-module_start
.word 0x3b7c, 0x278a, 7, expected_20-module_start, patch_20-module_start
.word 0x0, 0x935f, 6, expected_21-module_start, patch_21-module_start
.word 0x0, 0x9214, 8, expected_22-module_start, patch_22-module_start
.word 0x0, 0x9228, 8, expected_23-module_start, patch_23-module_start
.word 0x0, 0x9260, 8, expected_24-module_start, patch_24-module_start
.word 0x0, 0x9274, 8, expected_25-module_start, patch_25-module_start
.word 0x0, 0x10fe, 7, expected_26-module_start, patch_26-module_start
.word 0x0, 0x886b, 6, expected_27-module_start, patch_27-module_start
.word 0x0, 0x88f7, 6, expected_28-module_start, patch_28-module_start
.word 0x0, 0x891b, 7, expected_29-module_start, patch_29-module_start
.word 0x0, 0x89d1, 5, expected_30-module_start, patch_30-module_start
.word 0x0, 0x34c9, 5, expected_31-module_start, patch_31-module_start
.word 0x0, 0x3566, 6, expected_32-module_start, patch_32-module_start
.word 0x0, 0xedd8, 5, expected_33-module_start, patch_33-module_start
.word 0x0, 0xde3, 5, expected_34-module_start, patch_34-module_start
.word 0x0, 0xaa1c, 2, expected_35-module_start, patch_35-module_start
.word 0xfe8, 0x8ff2, 3, expected_36-module_start, patch_36-module_start
.word 0x5b00, 0x335, 3, expected_37-module_start, patch_37-module_start
.word 0xfe8, 0x6abc, 3, expected_38-module_start, patch_38-module_start
.word 0xfe8, 0xb70d, 2, expected_39-module_start, patch_39-module_start
.word 0x3000, 0x2c02, 4, expected_40-module_start, patch_40-module_start
expected_0:
.byte 0xc7,0x6,0x58,0xe,0x3,0xaa
patch_0:
.byte 0x9a
.word menu_frame_capture-module_start, 0x62d2
.fill 1,1,0x90
expected_1:
.byte 0xcd,0x2b,0x16,0x49,0x1a,0x6a,0x63,0x6c,0x63
patch_1:
.byte 0x9a
.word menu_label-module_start, 0x62d2
.fill 4,1,0x90
expected_2:
.byte 0x80,0x3e,0x6a,0x63,0x0
patch_2:
.byte 0xea
.word menu_type-module_start, 0x62d2
.fill 0,1,0x90
expected_3:
.byte 0x80,0x3e,0x6a,0x63,0x0
patch_3:
.byte 0xea
.word menu_cursor-module_start, 0x62d2
.fill 0,1,0x90
expected_4:
.byte 0xc6,0x6,0x38,0xd,0x1
patch_4:
.byte 0xea
.word menu_enable-module_start, 0x62d2
.fill 0,1,0x90
expected_5:
.byte 0x50,0xb4,0x0,0xb0,0x0
patch_5:
.byte 0xea
.word pad_release-module_start, 0x62d2
.fill 0,1,0x90
expected_6:
.byte 0x80,0x3e,0x6a,0x63,0x0
patch_6:
.byte 0xea
.word pad_mode-module_start, 0x62d2
.fill 0,1,0x90
expected_7:
.byte 0x8a,0x1e,0x32,0xd,0xb7,0x0
patch_7:
.byte 0xea
.word record_producer-module_start, 0x62d2
.fill 1,1,0x90
expected_8:
.byte 0x2a,0xff,0x8b,0x8f,0xd8,0xd0
patch_8:
.byte 0xea
.word record_read-module_start, 0x62d2
.fill 1,1,0x90
expected_9:
.byte 0x88,0xf,0x8a,0x26,0x4b,0x63,0xa0,0x4c,0x63
patch_9:
.byte 0xea
.word record_variation-module_start, 0x62d2
.fill 4,1,0x90
expected_10:
.byte 0x80,0xf9,0x0,0x74,0x38
patch_10:
.byte 0xea
.word record_off-module_start, 0x62d2
.fill 0,1,0x90
expected_11:
.byte 0x89,0x47,0x1,0xa1,0x4c,0x1d
patch_11:
.byte 0xea
.word record_commit-module_start, 0x62d2
.fill 1,1,0x90
expected_12:
.byte 0x26,0x8a,0x74,0x3,0x26,0x8a,0x4c,0x5
patch_12:
.byte 0xea
.word prefix_read-module_start, 0x62d2
.fill 3,1,0x90
expected_13:
.byte 0x8b,0x46,0xfe,0xa3,0xa2,0x56
patch_13:
.byte 0x9a
.word pool_allocate-module_start, 0x62d2
.fill 1,1,0x90
expected_14:
.byte 0x8b,0x7e,0x4,0x39,0x3e,0xa2,0x56
patch_14:
.byte 0x9a
.word pool_free-module_start, 0x62d2
.fill 2,1,0x90
expected_15:
.byte 0x9a,0x0,0x0,0xa0,0x53
patch_15:
.byte 0x9a
.word region_mute_groups-module_start, 0x62d2
.fill 0,1,0x90
expected_16:
.byte 0x89,0x46,0xf4,0x89,0x56,0xf6
patch_16:
.byte 0x9a
.word voice_start-module_start, 0x62d2
.fill 1,1,0x90
expected_17:
.byte 0x26,0x8b,0x47,0x1c,0x26,0x8b,0x57,0x1e,0x5,0xf,0x0,0x83,0xd2,0x0,0x24,0xf0
patch_17:
.byte 0x9a
.word stereo_stride-module_start, 0x62d2
.fill 11,1,0x90
expected_18:
.byte 0xc4,0x5e,0xc,0x26,0x8a,0x47,0x4
patch_18:
.byte 0x9a
.word voice_shape-module_start, 0x62d2
.fill 2,1,0x90
expected_19:
.byte 0x26,0x80,0x7f,0x4,0x0
patch_19:
.byte 0x9a
.word envelope_mode-module_start, 0x62d2
.fill 0,1,0x90
expected_20:
.byte 0x9a,0x23,0x5,0x0,0x5b,0x90,0x90
patch_20:
.byte 0x9a
.word voice_capture-module_start, 0x62d2
.fill 2,1,0x90
expected_21:
.byte 0x26,0x8a,0x44,0x3,0x24,0x3
patch_21:
.byte 0xea
.word step_draw-module_start, 0x62d2
.fill 1,1,0x90
expected_22:
.byte 0xc4,0x36,0x82,0x59,0x26,0x8a,0x44,0x3
patch_22:
.byte 0xea
.word step_type_up-module_start, 0x62d2
.fill 3,1,0x90
expected_23:
.byte 0xc4,0x36,0x82,0x59,0x26,0x8a,0x44,0x3
patch_23:
.byte 0xea
.word step_type_down-module_start, 0x62d2
.fill 3,1,0x90
expected_24:
.byte 0xc4,0x36,0x82,0x59,0x26,0x8a,0x44,0x5
patch_24:
.byte 0xea
.word step_value_up-module_start, 0x62d2
.fill 3,1,0x90
expected_25:
.byte 0xc4,0x36,0x82,0x59,0x26,0x8a,0x44,0x5
patch_25:
.byte 0xea
.word step_value_down-module_start, 0x62d2
.fill 3,1,0x90
expected_26:
.byte 0x9a,0x51,0x8,0x0,0x5b,0x90,0x90
patch_26:
.byte 0x9a
.word main_prepare-module_start, 0x62d2
.fill 2,1,0x90
expected_27:
.byte 0x26,0x8a,0x44,0x3,0x24,0x7f
patch_27:
.byte 0xea
.word step_window_type-module_start, 0x62d2
.fill 1,1,0x90
expected_28:
.byte 0x2,0x6,0x80,0x5a,0x3c,0x7f
patch_28:
.byte 0xea
.word step_window_up-module_start, 0x62d2
.fill 1,1,0x90
expected_29:
.byte 0xa0,0x80,0x5a,0x8a,0x26,0x7f,0x5a
patch_29:
.byte 0xea
.word step_window_draw-module_start, 0x62d2
.fill 2,1,0x90
expected_30:
.byte 0x80,0x3e,0x7e,0x5a,0x4
patch_30:
.byte 0xea
.word step_window_apply-module_start, 0x62d2
.fill 0,1,0x90
expected_31:
.byte 0xe8,0x23,0xc,0x73,0x3
patch_31:
.byte 0xea
.word all_create-module_start, 0x62d2
.fill 0,1,0x90
expected_32:
.byte 0xb3,0xa,0x8a,0x3e,0xa8,0x78
patch_32:
.byte 0xea
.word all_append-module_start, 0x62d2
.fill 1,1,0x90
expected_33:
.byte 0x2b,0xc0,0x26,0x89,0x5
patch_33:
.byte 0xea
.word all_loaded-module_start, 0x62d2
.fill 0,1,0x90
expected_34:
.byte 0xfb,0xe8,0x14,0x0,0xcf
patch_34:
.byte 0xea
.word editor_ui_reset-module_start, 0x62d2
.fill 0,1,0x90
expected_35:
.byte 0xb0,0x1
patch_35:
.byte 0xb0,0x2
expected_36:
.byte 0x80,0xe6,0x3
patch_36:
.byte 0x80,0xe6,0x7
expected_37:
.byte 0x80,0xe6,0x3
patch_37:
.byte 0x80,0xe6,0x7
expected_38:
.byte 0x80,0xe4,0x3
patch_38:
.byte 0x80,0xe4,0x7
expected_39:
.byte 0x24,0x3
patch_39:
.byte 0x24,0x7
expected_40:
.byte 0xc8,0x48,0x0,0x0
patch_40:
.byte 0xc8,0x4c,0x0,0x0

/* End hooks.inc */
.balign 4
module_end:

.endif /* region_adapter */
/* xl_regions: assembly unit 24. */
.if MOD_UNIT == 24
/* Native MPC2000XL REGIONS with image-specific bindings. */
.intel_syntax noprefix
.code16
.arch i186
.text
/* Begin layout.inc */
.equ MOD_CS,29723
.equ BASE_MUTE,1459

/* End layout.inc */
.global module_start,module_end,code_end
.equ UI_DS,0x2275
.equ SEQ_DS,0x0fe7
.equ SYS_DS,0x582b
.equ MAP_COUNT,16
.equ MAP_BYTES,108
.equ M_VALID,0
.equ M_STEREO,2
.equ M_LENGTH,4
.equ M_NAME,8
.equ M_POINTS,24
.equ M_PTR,92
.equ M_HANDLE,96
.equ M_GENERATION,98
.equ M_COUNT,104
.equ M_REV,106
.equ C_BYTES,152
.equ C_READY,0
.equ C_PTR,2
.equ C_GEN,6
.equ C_REV,8
.equ C_COUNT,10
.equ C_STEREO,11
.equ C_BASE,12
.equ C_CAPACITY,16
.equ C_PLANE,20
.equ C_LAYOUT,24 /* 16 pairs: destination offset, exact source length */
.macro fc seg,ip
 .byte 0x9a
 .word \ip,\seg
.endm
.macro fj seg,ip
 .byte 0xea
 .word \ip,\seg
.endm
.macro nearxl seg,ip,retip
 push cs
 push offset .Lret\@-module_start
 push \retip
 push \seg
 push \ip
 retf
.Lret\@:
.endm
.macro event key,fn
 int 0x96
 .word \key,\fn-module_start,MOD_CS
.endm
.macro text x,y,str
 pusha
 push es
 mov cl,\x
 mov ch,\y
 mov bl,5
 mov bh,0
 mov ah,80
 mov dx,cs
 mov si,offset .Ltext\@-module_start
 int 0x90
 pop es
 popa
 jmp .Ltext_end\@
.Ltext\@: .asciz "\str"
.Ltext_end\@:
.endm
.macro number x,y,width
 pusha
 mov cl,\x
 mov ch,\y
 mov bl,8
 mov bh,\width
 int 0x90
 popa
.endm
.macro button key,str
 pusha
 push ds
 push SYS_DS
 pop ds
 push cs
 push offset .Lbutton\@-module_start
 fc 0x3e19,0x0662
 add sp,4
 pop ds
 popa
 jmp .Lbutton_end\@
.Lbutton\@:
 .byte 2,0x1a,\key,1
 .asciz "\str"
 .byte 0
.Lbutton_end\@:
.endm
module_start:
/* Menu draw replaces just the parameter field and the conditional type row. */
.global menu_draw,menu_cursor,menu_enable,pad_transform
menu_draw:
 nearxl 0x267b,0xb468,0x0036
 cmp byte ptr [0x2abb],2
 je .Lmenu_regions
 mov dx,ds
 int 0x8f
 .byte 0x1e,0,0x49,0x1a
 .word 0x2abb,0x2abd
 nearxl 0x267b,0xb4c8,0x0036
 retf
.Lmenu_regions:
 text 73,26,"REGIONS "
 button 2,"EDIT"
 event 0x66,editor_open
 retf
menu_cursor:
 cmp byte ptr [0x2abb],1
 je .Lnative_type_cursor
 fj 0x267b,0xb5f0 /* native return at 31da0 */
.Lnative_type_cursor:
 fj 0x267b,0xb5f1
menu_enable:
 call regions_quiet
 cmp byte ptr [0x2abb],2
 jne .Lmenu_turnon
 pusha
 push ds
 push es
 mov al,[0x2ab8]
 call note_source
 jc .Lmenu_failed
 call prepare
 jc .Lmenu_failed
 pop es
 pop ds
 popa
.Lmenu_turnon:
 mov bl,[0x2ab8]
 mov bh,[0x2ab9]
 fj 0x267b,0xb54e
.Lmenu_failed:
 pop es
 pop ds
 popa
 text 37,36,"REGIONS: NO FREE MEMORY"
 retf

/* AL note -> ES:SI sound, BX native note record. Caller remains intact except
   AX/BX/SI/ES. INT C5 resolves the active sequence track's DRUM/program. */
note_source:
 push bp
 push cx
 push dx
 cmp al,35
 jb .Lsource_bad
 cmp al,98
 ja .Lsource_bad
 sub al,35
 xor ah,ah
 mov bx,ax
 push bx
 int 0xc5
 pop bx
 mov ax,es
 or ax,si
 jz .Lsource_bad
 mov ax,bx
 imul bx,bx,24
 add bx,si
 add bx,30
 shl ax,2
 add si,ax
 les si,es:[si+0x7de]
 mov ax,es
 cmp ax,SYS_DS
 jne .Lsource_bad
 cmp si,0x991a
 jb .Lsource_bad
 cmp si,0xd71a
 jae .Lsource_bad
 pop dx
 pop cx
 pop bp
 clc
 ret
.Lsource_bad:
 pop dx
 pop cx
 pop bp
 stc
 ret

regions_quiet:
 pushf
 pusha
 push ds
 push es
 push SYS_DS
 pop ds
 xor si,si
.Lquiet:
 pushf
 cli
 push si
 fc 0x3e19,0x3a02
 add sp,2
 /* Native stop schedules a short release. Force the envelope to zero before
    reusing DSP channel zero for foreground PCM transfers. */
 mov ax,si
 or ah,3
 out 0x80,ax
 xor ax,ax
 out 0x82,ax
 out 0x84,ax
 out 0x86,ax
 popf
 inc si
 cmp si,32
 jb .Lquiet
 pop es
 pop ds
 popa
 popf
 ret

/* Native 16 LEVELS transform, DS=SEQ_DS, BL physical pad, CL velocity.
   Type 4 travels in a ring sidecar; native two-bit encoding is preserved. */
pad_transform:
 cmp byte ptr cs:[cache_gc_hold-module_start],0
 jne .Lpad_busy
 cmp byte ptr [0x4d9],2
 jne .Lpad_native
 push bx
 push si
 push es
 push ax
 call note_region_count
 mov dl,al
 pop ax
 cmp bl,dl
 jae .Lpad_silent
 cmp byte ptr cs:[editor_active-module_start],1
 jne .Lpad_publish
 mov cs:[editor_region-module_start],bl
 mov byte ptr cs:[editor_redraw-module_start],1
 call editor_signal
.Lpad_publish:
 mov dh,4
 mov dl,bl
 pop es
 pop si
 pop bx
 fj 0,0x0db8
.Lpad_silent:
 xor cx,cx
 xor dx,dx
 mov al,34
 pop es
 pop si
 pop bx
 fj 0,0x0db8
.Lpad_native:
 cmp byte ptr [0x4d9],0
 fj 0,0x0d83
.Lpad_busy:
 xor cx,cx
 xor dx,dx
 mov al,34
 fj 0,0x0db8

note_region_count:
 pusha
 push es
 call note_source
 jc .Lcount_default
 call map_find
 jc .Lcount_default
 mov al,cs:[di+M_COUNT]
 jmp .Lcount_return
.Lcount_default:
 mov al,16
.Lcount_return:
 mov cs:[count_return-module_start],al
 pop es
 popa
 mov al,cs:[count_return-module_start]
 ret

/* ES:SI native metadata -> DI committed map. Pool generations protect reuse;
   an ALL-loaded unbound map matches full name, length, and mono/stereo. */
map_find:
 push ax
 push bx
 push cx
 push dx
 mov di,offset marker_maps-module_start
 mov cx,MAP_COUNT
.Lmap_next:
 cmp word ptr cs:[di+M_VALID],1
 jne .Lmap_skip
 mov ax,es:[si+0x2e]
 cmp ax,cs:[di+M_LENGTH]
 jne .Lmap_skip
 mov ax,es:[si+0x30]
 cmp ax,cs:[di+M_LENGTH+2]
 jne .Lmap_skip
 mov al,es:[si+0x25]
 cmp al,cs:[di+M_STEREO]
 jne .Lmap_skip
 mov bx,si
 sub bx,0x991a
 mov ax,bx
 xor dx,dx
 mov bx,62
 div bx
 shl ax,1
 mov bx,ax
 cmp si,cs:[di+M_PTR]
 jne .Lmap_name
 mov ax,cs:[bx+pool_generations-module_start]
 cmp ax,cs:[di+M_GENERATION]
 je .Lmap_found
.Lmap_name:
 cmp word ptr cs:[di+M_PTR+2],0
 jne .Lmap_skip
 push cx
 push si
 push di
 add si,0x12
 add di,M_NAME
 mov cx,8
.Lmap_compare:
 mov ax,es:[si]
 cmp ax,cs:[di]
 jne .Lmap_name_bad
 add si,2
 add di,2
 loop .Lmap_compare
 pop di
 pop si
 pop cx
 mov cs:[di+M_PTR],si
 mov word ptr cs:[di+M_PTR+2],SYS_DS
 mov cs:[di+M_HANDLE],bx
 mov ax,cs:[bx+pool_generations-module_start]
 mov cs:[di+M_GENERATION],ax
 jmp .Lmap_found
.Lmap_name_bad:
 pop di
 pop si
 pop cx
.Lmap_skip:
 add di,MAP_BYTES
 dec cx
 jnz .Lmap_next
 pop dx
 pop cx
 pop bx
 pop ax
 stc
 ret
.Lmap_found:
 pop dx
 pop cx
 pop bx
 pop ax
 clc
 ret
/* Begin arena.inc */
/* Guarded audio stays outside the native allocation limit. Source descriptors
   and PCM are never resized; original SND/APS serialization stays native. */
lookup:
 push ax
 push cx
 push dx
 push di
 call map_find
 jc .Llookup_bad
 mov ax,di
 sub ax,offset marker_maps-module_start
 xor dx,dx
 mov cx,MAP_BYTES
 div cx
 imul bx,ax,C_BYTES
 add bx,offset cache_table-module_start
 cmp word ptr cs:[bx+C_READY],0x5247
 jne .Llookup_bad
 cmp si,cs:[bx+C_PTR]
 jne .Llookup_bad
 mov ax,cs:[di+M_GENERATION]
 cmp ax,cs:[bx+C_GEN]
 jne .Llookup_bad
 mov ax,cs:[di+M_REV]
 cmp ax,cs:[bx+C_REV]
 jne .Llookup_bad
 pop di
 pop dx
 pop cx
 pop ax
 clc
 ret
.Llookup_bad:
 pop di
 pop dx
 pop cx
 pop ax
 stc
 ret

/* Create the original EVEN map on first use. */
map_ensure:
 call map_find
 jnc .Lensure_done
 mov di,offset marker_maps-module_start
 mov cx,MAP_COUNT
.Lensure_slot:
 cmp word ptr cs:[di+M_VALID],0
 je .Lensure_new
 add di,MAP_BYTES
 loop .Lensure_slot
 stc
 ret
.Lensure_new:
 push si
 push di
 add si,0x12
 add di,M_NAME
 mov cx,8
.Lensure_name:
 mov ax,es:[si]
 mov cs:[di],ax
 add si,2
 add di,2
 loop .Lensure_name
 pop di
 pop si
 mov cs:[di+M_PTR],si
 mov cs:[di+M_PTR+2],es
 mov al,es:[si+0x25]
 xor ah,ah
 mov cs:[di+M_STEREO],ax
 mov ax,es:[si+0x2e]
 mov cs:[di+M_LENGTH],ax
 mov ax,es:[si+0x30]
 mov cs:[di+M_LENGTH+2],ax
 mov ax,si
 sub ax,0x991a
 xor dx,dx
 mov bx,62
 div bx
 shl ax,1
 mov bx,ax
 mov cs:[di+M_HANDLE],bx
 mov ax,cs:[bx+pool_generations-module_start]
 mov cs:[di+M_GENERATION],ax
 mov word ptr cs:[di+M_COUNT],16
 mov word ptr cs:[di+M_REV],1
 push di
 push es
 mov ax,es:[si+0x26]
 mov dx,es:[si+0x28]
 mov bx,es:[si+0x2a]
 mov cx,es:[si+0x2c]
 add di,M_POINTS
 push cs
 pop es
 push cs
 call regions_split
 pop es
 pop di
 jc .Lensure_done
 mov word ptr cs:[di+M_VALID],1
.Lensure_done:
 ret

/* ES:SI -> allocate once for the entire source; APPLY refills that capacity.
   Native foreground cannot concurrently mutate metadata. Panel IRQs remain
   enabled between sixteen-word transfers. Every failure precedes publication. */
prepare:
 push bp
 mov bp,sp
 sub sp,26
 pusha
 push ds
 push es
 mov [bp-2],si
 mov byte ptr cs:[cache_gc_hold-module_start],1
 test byte ptr es:[si+0x0d],1
 jnz .Lprepare_bad
 call lookup
 jnc .Lprepare_ok
 call map_ensure
 jc .Lprepare_bad
 mov [bp-4],di
 mov ax,di
 sub ax,offset marker_maps-module_start
 xor dx,dx
 mov bx,MAP_BYTES
 div bx
 imul bx,ax,C_BYTES
 add bx,offset cache_table-module_start
 mov [bp-6],bx
 mov ax,es:[si+0x2e]
 mov dx,es:[si+0x30]
 add ax,527 /* one alignment plus 16 worst-case (15+16) guards */
 adc dx,0
 and ax,0xfff0
 cmp byte ptr es:[si+0x25],0
 je .Lcapacity_mono
 add ax,ax
 adc dx,dx
.Lcapacity_mono:
 mov [bp-8],ax
 mov [bp-10],dx
 cmp dx,cs:[bx+C_CAPACITY+2]
 jb .Lcapacity_ready
 ja .Lcapacity_allocate
 cmp ax,cs:[bx+C_CAPACITY]
 jbe .Lcapacity_ready
.Lcapacity_allocate:
 push SYS_DS
 pop ds
 cmp word ptr cs:[arena_original-module_start+2],0
 jne .Larena_known
 mov ax,[0x8fc6]
 mov dx,[0x8fc8]
 mov cs:[arena_original-module_start],ax
 mov cs:[arena_original-module_start+2],dx
 sub ax,16
 sbb dx,0
 mov cs:[arena_limit-module_start],ax
 mov cs:[arena_limit-module_start+2],dx
.Larena_known:
 mov ax,cs:[arena_limit-module_start]
 mov dx,cs:[arena_limit-module_start+2]
 sub ax,[bp-8]
 sbb dx,[bp-10]
 jc .Lprepare_bad
 mov [bp-12],ax
 mov [bp-14],dx
 /* Check the live high-water mark, compact only if required. */
 fc 0x3e19,0x193e
 cmp dx,[bp-14]
 ja .Lcompact
 jb .Larena_space
 cmp ax,[bp-12]
 jbe .Larena_space
.Lcompact:
 fc 0x3e19,0x1a18
 fc 0x3e19,0x193e
 cmp dx,[bp-14]
 ja .Lprepare_bad
 jb .Larena_space
 cmp ax,[bp-12]
 ja .Lprepare_bad
.Larena_space:
 mov bx,[bp-6]
 mov ax,[bp-12]
 mov dx,[bp-14]
 mov cs:[bx+C_BASE],ax
 mov cs:[bx+C_BASE+2],dx
 mov cs:[arena_limit-module_start],ax
 mov cs:[arena_limit-module_start+2],dx
 mov [0x8fc6],ax
 mov [0x8fc8],dx
 mov ax,[bp-8]
 mov dx,[bp-10]
 mov cs:[bx+C_CAPACITY],ax
 mov cs:[bx+C_CAPACITY+2],dx
.Lcapacity_ready:
 mov si,[bp-2]
 push SYS_DS
 pop es
 mov di,[bp-4]
 mov bx,[bp-6]
 mov word ptr cs:[bx+C_READY],0
 mov cs:[bx+C_PTR],si
 mov cs:[bx+C_PTR+2],es
 mov ax,cs:[di+M_GENERATION]
 mov cs:[bx+C_GEN],ax
 mov ax,cs:[di+M_REV]
 mov cs:[bx+C_REV],ax
 mov al,cs:[di+M_COUNT]
 mov cs:[bx+C_COUNT],al
 mov al,es:[si+0x25]
 mov cs:[bx+C_STEREO],al
 /* Compact cached rows: destination relative to plane, exact length. */
 add di,M_POINTS
 lea si,[bx+C_LAYOUT]
 xor ax,ax
 xor dx,dx
 xor cx,cx
 mov cl,cs:[bx+C_COUNT]
.Llayout:
 mov cs:[si],ax
 mov cs:[si+2],dx
 push cx
 push ax
 push dx
 mov ax,cs:[di+4]
 mov dx,cs:[di+6]
 sub ax,cs:[di]
 sbb dx,cs:[di+2]
 mov cs:[si+4],ax
 mov cs:[si+6],dx
 add ax,31
 adc dx,0
 and ax,0xfff0
 pop bx
 pop cx
 add ax,cx
 adc dx,bx
 pop cx
 add si,8
 add di,4
 loop .Llayout
 mov bx,[bp-6]
 mov cs:[bx+C_PLANE],ax
 mov cs:[bx+C_PLANE+2],dx
 mov word ptr [bp-16],0 /* channel */
.Lchannel:
 mov word ptr [bp-18],0 /* region */
.Lregion_copy:
 mov bx,[bp-6]
 mov si,[bp-18]
 shl si,3
 add si,bx
 add si,C_LAYOUT
 mov di,[bp-18]
 shl di,2
 add di,[bp-4]
 add di,M_POINTS
 mov ax,cs:[di]
 mov dx,cs:[di+2]
 mov cx,[bp-2]
 push SYS_DS
 pop es
 mov di,cx
 add ax,es:[di+0x0a]
 adc dx,es:[di+0x0c]
 cmp word ptr [bp-16],0
 je .Lcopy_source_ready
 mov cx,es:[di+0x2e]
 mov di,es:[di+0x30]
 add cx,15
 adc di,0
 and cx,0xfff0
 add ax,cx
 adc dx,di
.Lcopy_source_ready:
 mov cs:[dma_source-module_start],ax
 mov cs:[dma_source-module_start+2],dx
 mov ax,cs:[si]
 mov dx,cs:[si+2]
 add ax,cs:[bx+C_BASE]
 adc dx,cs:[bx+C_BASE+2]
 cmp word ptr [bp-16],0
 je .Lcopy_dest_ready
 add ax,cs:[bx+C_PLANE]
 adc dx,cs:[bx+C_PLANE+2]
.Lcopy_dest_ready:
 mov cs:[dma_destination-module_start],ax
 mov cs:[dma_destination-module_start+2],dx
 mov ax,cs:[si+4]
 mov dx,cs:[si+6]
 mov cs:[dma_remaining-module_start],ax
 mov cs:[dma_remaining-module_start+2],dx
 call pcm_copy_words
 /* Pad from first zero through the aligned silent DSP loop. */
 mov ax,cs:[si+4]
 neg ax
 and ax,15
 add ax,16
 mov cs:[dma_remaining-module_start],ax
 mov word ptr cs:[dma_remaining-module_start+2],0
 call pcm_zero_words
 inc word ptr [bp-18]
 mov ax,[bp-18]
 xor ch,ch
 mov cl,cs:[bx+C_COUNT]
 cmp ax,cx
 jb .Lregion_copy
 cmp byte ptr cs:[bx+C_STEREO],0
 je .Lprepare_publish
 inc word ptr [bp-16]
 cmp word ptr [bp-16],2
 jb .Lchannel
.Lprepare_publish:
 mov word ptr cs:[bx+C_READY],0x5247
 inc word ptr cs:[prepared-module_start]
.Lprepare_ok:
 mov byte ptr cs:[cache_gc_hold-module_start],0
 pop es
 pop ds
 popa
 leave
 clc
 ret
.Lprepare_bad:
 mov byte ptr cs:[cache_gc_hold-module_start],0
 pop es
 pop ds
 popa
 leave
 stc
 ret

/* DSP source/dest/count DWORDs. Native DMA retains all its segment-bank setup.
   Do not call from an interrupt, voice callback, or while another DMA owns ports. */
pcm_copy_words:
 pushf
 pusha
 push ds
 push es
 push SYS_DS
 pop ds
.Ldma_copy:
 mov ax,cs:[dma_remaining-module_start]
 or ax,cs:[dma_remaining-module_start+2]
 jz .Ldma_done
 call dma_chunk
 pushf
 cli
 push 0x1000
 push cx
 push cs
 push offset dma_buffer-module_start
 push word ptr cs:[dma_source-module_start+2]
 push word ptr cs:[dma_source-module_start]
 fc 0x3e19,0x0066
 add sp,12
 call dma_write
 popf
 mov cx,cs:[dma_chunk_words-module_start]
 add cs:[dma_source-module_start],cx
 adc word ptr cs:[dma_source-module_start+2],0
 call dma_advance
 jmp .Ldma_copy
.Ldma_done:
 pop es
 pop ds
 popa
 popf
 ret
pcm_zero_words:
 pushf
 pusha
 push ds
 push es
 push cs
 pop es
 mov di,offset dma_buffer-module_start
 xor ax,ax
 mov cx,16
 rep stosw
 push SYS_DS
 pop ds
.Ldma_zero:
 mov ax,cs:[dma_remaining-module_start]
 or ax,cs:[dma_remaining-module_start+2]
 jz .Ldma_done
 call dma_chunk
 pushf
 cli
 call dma_write
 popf
 call dma_advance
 jmp .Ldma_zero

dma_chunk:
 mov cx,16
 cmp word ptr cs:[dma_remaining-module_start+2],0
 jne .Lchunk_ready
 cmp cs:[dma_remaining-module_start],cx
 jae .Lchunk_ready
 mov cx,cs:[dma_remaining-module_start]
.Lchunk_ready:
 mov cs:[dma_chunk_words-module_start],cx
 ret
dma_write:
 push word ptr cs:[dma_chunk_words-module_start]
 push cs
 push offset dma_buffer-module_start
 push word ptr cs:[dma_destination-module_start+2]
 push word ptr cs:[dma_destination-module_start]
 fc 0x3e19,0x0034
 add sp,10
 ret
dma_advance:
 mov cx,cs:[dma_chunk_words-module_start]
 add cs:[dma_destination-module_start],cx
 adc word ptr cs:[dma_destination-module_start+2],0
 sub cs:[dma_remaining-module_start],cx
 sbb word ptr cs:[dma_remaining-module_start+2],0
 ret

cache_collect:
 ret

.global sample_free
sample_free:
 pushf
 pusha
 push es
 /* Native entry has already resolved the freed node into ES:SI. */
 mov ax,si
 sub ax,0x991a
 xor dx,dx
 mov bx,62
 div bx
 shl ax,1
 mov bx,ax
 inc word ptr cs:[bx+pool_generations-module_start]
 mov bx,offset cache_table-module_start
 mov di,offset marker_maps-module_start
 mov cx,MAP_COUNT
.Lfree_maps:
 cmp si,cs:[di+M_PTR]
 jne .Lfree_next
 mov word ptr cs:[di+M_PTR],0
 mov word ptr cs:[di+M_PTR+2],0
 mov word ptr cs:[bx+C_READY],0
.Lfree_next:
 add di,MAP_BYTES
 add bx,C_BYTES
 loop .Lfree_maps
 pop es
 popa
 popf
 mov ax,es:[si]
 mov dx,es:[si+2]
 retf

/* Drop guarded copies while retaining pending marker maps. Used only during
   foreground file loading, after quieting voices. No native sample moves. */
cache_reset:
 pusha
 push ds
 push es
 push SYS_DS
 pop ds
 mov ax,cs:[arena_original-module_start]
 mov dx,cs:[arena_original-module_start+2]
 or dx,dx
 jz .Lcache_reset_clear
 mov [0x8fc6],ax
 mov [0x8fc8],dx
.Lcache_reset_clear:
 push cs
 pop es
 mov di,offset cache_table-module_start
 xor ax,ax
 mov cx,MAP_COUNT*C_BYTES/2
 rep stosw
 mov cs:[arena_original-module_start],ax
 mov cs:[arena_original-module_start+2],ax
 pop es
 pop ds
 popa
 ret

/* End arena.inc */
/* Begin editor.inc */
.global editor_open,editor_main,editor_ui_reset
editor_open:
 cmp byte ptr [0x2abb],2
 jne .Lopen_return
 mov al,[0x2ab8]
 call note_source
 jc .Lopen_return
 test byte ptr es:[si+0x0d],1
 jnz .Lopen_return
 mov ax,es:[si+0x2e]
 mov dx,es:[si+0x30]
 mov cs:[editor_length-module_start],ax
 mov cs:[editor_length-module_start+2],dx
 or dx,dx
 jnz .Lopen_length
 cmp ax,16
 jb .Lopen_return
.Lopen_length:
 mov cs:[editor_source-module_start],si
 mov cs:[editor_source-module_start+2],es
 call regions_quiet
 call prepare
 jc .Lopen_return
 call map_find
 jc .Lopen_return
 mov cs:[editor_map_slot-module_start],di
 mov al,cs:[di+M_COUNT]
 mov cs:[editor_count-module_start],al
 push ds
 push cs
 pop ds
 push cs
 pop es
 lea si,[di+M_POINTS]
 mov di,offset editor_points-module_start
 mov cx,34
 rep movsw
 pop ds
 mov byte ptr cs:[editor_dirty-module_start],0
 mov byte ptr cs:[editor_region-module_start],0
 mov byte ptr cs:[editor_field-module_start],0
 mov byte ptr cs:[editor_zoom-module_start],0
 mov byte ptr cs:[editor_status-module_start],0
 mov byte ptr cs:[editor_digit-module_start],0
 mov byte ptr cs:[editor_preview_pad-module_start],0xff
 mov byte ptr cs:[editor_after-module_start],0
 mov byte ptr cs:[wave_valid-module_start],0
 push SEQ_DS
 pop es
 mov al,es:[0x4378]
 mov cs:[editor_old_levels-module_start],al
 mov al,es:[0x4377]
 mov cs:[editor_old_after-module_start],al
 mov ax,es:[0x4d7]
 mov cs:[editor_old_settings-module_start],ax
 mov ax,es:[0x4d9]
 mov cs:[editor_old_settings-module_start+2],ax
 mov al,es:[0x4db]
 mov cs:[editor_old_settings-module_start+4],al
 mov bl,[0x2ab8]
 mov bh,[0x2ab9]
 mov cx,2
 mov dl,[0x2aba]
 mov al,1
 int 0xc7
 int 0xa4
 mov byte ptr cs:[editor_active-module_start],1
 event 0x60,editor_back
 event 0x66,editor_even
 event 0x6c,editor_count_action
 event 0x72,editor_zoom_action
 event 0x78,editor_play
 int 0x97
 .word 0x78,editor_play_up-module_start,MOD_CS
 event 0x7e,editor_apply_action
 event 0x0c,editor_main
 event 0xc0,editor_refresh
 event 0xc6,editor_wave_idle
 event 0xb4,editor_decrease
 event 0xba,editor_increase
 event 0x8a,editor_left
 event 0x90,editor_right
 event 0x96,editor_up
 event 0x9c,editor_down
 int 0x98
 .word 0x8a,editor_digit_left-module_start,MOD_CS
 int 0x98
 .word 0x90,editor_digit_right-module_start,MOD_CS
 event 0x4e,editor_after_down
 int 0x97
 .word 0x4e,editor_after_up-module_start,MOD_CS
 event 0xd8,editor_fader
 mov byte ptr cs:[editor_redraw-module_start],1
 call editor_signal
.Lopen_return:
 retf

editor_signal:
 push ax
 push es
 push SEQ_DS
 pop es
 mov byte ptr es:[0x63],1
 pop es
 pop ax
 ret

editor_restore_levels:
 push ax
 push es
 push SEQ_DS
 pop es
 mov al,cs:[editor_old_levels-module_start]
 mov es:[0x4378],al
 mov al,cs:[editor_old_after-module_start]
 mov es:[0x4377],al
 mov ax,cs:[editor_old_settings-module_start]
 mov es:[0x4d7],ax
 mov ax,cs:[editor_old_settings-module_start+2]
 mov es:[0x4d9],ax
 mov al,cs:[editor_old_settings-module_start+4]
 mov es:[0x4db],al
 pop es
 pop ax
 ret
editor_ui_reset:
 cmp byte ptr cs:[editor_active-module_start],0
 je .Lreset_done
 call editor_preview_end
 call editor_restore_levels
 mov byte ptr cs:[editor_active-module_start],0
.Lreset_done:
 sti
 mov ax,SEQ_DS
 mov ds,ax
 fj 0,0x4250
editor_back:
 call editor_restore_levels
editor_main:
 call editor_preview_end
 mov byte ptr cs:[editor_active-module_start],0
 mov byte ptr cs:[editor_after-module_start],0
 fj 0x267b,0x007a
/* Begin editor_common.inc */
editor_left:
 mov byte ptr cs:[editor_field-module_start], 0
 jmp editor_cursor_done
editor_right:
 mov byte ptr cs:[editor_field-module_start], 1
 jmp editor_cursor_done
editor_up:
 cmp byte ptr cs:[editor_region-module_start], 0
 je editor_cursor_done
 dec byte ptr cs:[editor_region-module_start]
 jmp editor_cursor_done
editor_down:
 mov al, cs:[editor_region-module_start]
 inc al
 cmp al, cs:[editor_count-module_start]
 jae editor_cursor_done
 inc byte ptr cs:[editor_region-module_start]
editor_cursor_done:
 mov byte ptr cs:[editor_after-module_start], 0
 mov byte ptr cs:[editor_redraw-module_start], 1
 call editor_signal
 retf

editor_even_points:
 pusha
 push es
 les si, cs:[editor_source-module_start]
 mov ax, es:[si+0x26]
 mov dx, es:[si+0x28]
 mov bx, es:[si+0x2a]
 mov cx, es:[si+0x2c]
 push cs
 pop es
 mov di, offset editor_points-module_start
 push cs
 call regions_split
 /* Select every second/fourth boundary from the exact 16-way division. */
 mov ax, 64
 xor dx, dx
 xor cx, cx
 mov cl, cs:[editor_count-module_start]
 div cx
 mov bx, ax
 mov si, offset editor_points-module_start
 mov di, si
 inc cx
.Leven_compact:
 mov ax, cs:[si]
 mov dx, cs:[si+2]
 mov es:[di], ax
 mov es:[di+2], dx
 add si, bx
 add di, 4
 loop .Leven_compact
 pop es
 popa
 call editor_fill_tail
 ret
editor_even:
 mov byte ptr cs:[editor_after-module_start], 0
 call editor_even_points
 jmp editor_changed
editor_count_action:
 /* Keep the old draft if allocation fails: displayed and audible counts
    must not diverge after a failed automatic APPLY. */
 pusha
 push ds
 push es
 push cs
 pop ds
 push cs
 pop es
 mov si, offset editor_points-module_start
 mov di, offset editor_count_backup-module_start
 mov cx, 34
 rep movsw
 mov al, [editor_count-module_start]
 stosb
 mov al, [editor_region-module_start]
 stosb
 mov al, [editor_dirty-module_start]
 stosb
 pop es
 pop ds
 popa
 shr byte ptr cs:[editor_count-module_start], 1
 cmp byte ptr cs:[editor_count-module_start], 4
 jae .Lcount_selected
 mov byte ptr cs:[editor_count-module_start], 16
.Lcount_selected:
 mov al, cs:[editor_count-module_start]
 cmp cs:[editor_region-module_start], al
 jb .Lcount_region_ok
 dec al
 mov cs:[editor_region-module_start], al
.Lcount_region_ok:
 mov byte ptr cs:[editor_after-module_start], 0
 call editor_even_points
 mov byte ptr cs:[editor_dirty-module_start], 1
 call editor_apply
 jnc .Lcount_applied
 pusha
 push ds
 push es
 push cs
 pop ds
 push cs
 pop es
 mov si, offset editor_count_backup-module_start
 mov di, offset editor_points-module_start
 mov cx, 34
 rep movsw
 lodsb
 mov [editor_count-module_start], al
 lodsb
 mov [editor_region-module_start], al
 lodsb
 mov [editor_dirty-module_start], al
 pop es
 pop ds
 popa
.Lcount_applied:
 mov byte ptr cs:[editor_redraw-module_start], 1
 call editor_signal
 retf

/* Unused boundaries mirror the last END; they never describe playable pads. */
editor_fill_tail:
 pusha
 xor bx, bx
 mov bl, cs:[editor_count-module_start]
 mov cx, 16
 sub cx, bx
 jz .Ltail_done
 shl bx, 2
 add bx, offset editor_points-module_start
 mov ax, cs:[bx]
 mov dx, cs:[bx+2]
.Ltail_next:
 add bx, 4
 mov cs:[bx], ax
 mov cs:[bx+2], dx
 loop .Ltail_next
.Ltail_done:
 popa
 ret
editor_zoom_action:
 inc byte ptr cs:[editor_zoom-module_start]
 cmp byte ptr cs:[editor_zoom-module_start], 4
 jb .Lzoom_ok
 mov byte ptr cs:[editor_zoom-module_start], 0
.Lzoom_ok:
 mov byte ptr cs:[editor_redraw-module_start], 1
 call editor_signal
 retf

/* SI points at the edited boundary. Bounds are strict and inclusive. */
editor_bounds:
 xor ax, ax
 mov al, cs:[editor_region-module_start]
 add al, cs:[editor_field-module_start]
 mov bx, ax
 shl bx, 2
 lea si, [bx+editor_points-module_start]
 xor dx, dx
 xor cx, cx
 test ax, ax
 jz .Lbound_min
 mov dx, cs:[si-4]
 mov cx, cs:[si-2]
 add dx, 1
 adc cx, 0
.Lbound_min:
 mov cs:[editor_min-module_start], dx
 mov cs:[editor_min-module_start+2], cx
 cmp al, cs:[editor_count-module_start]
 je .Lbound_outer
 mov dx, cs:[si+4]
 mov cx, cs:[si+6]
 sub dx, 1
 sbb cx, 0
 jmp .Lbound_max
.Lbound_outer:
 mov dx, cs:[editor_length-module_start]
 mov cx, cs:[editor_length-module_start+2]
.Lbound_max:
 mov cs:[editor_max-module_start], dx
 mov cs:[editor_max-module_start+2], cx
 ret
editor_increase:
 call editor_bounds
 call editor_digit_step
 mov ax, cs:[si]
 mov dx, cs:[si+2]
 add ax, bx
 adc dx, cx
 jmp editor_clamp
editor_decrease:
 call editor_bounds
 call editor_digit_step
 mov ax, cs:[si]
 mov dx, cs:[si+2]
 sub ax, bx
 sbb dx, cx
 jnc editor_clamp
 xor ax, ax
 xor dx, dx
editor_clamp:
 cmp dx, cs:[editor_max-module_start+2]
 ja .Lclamp_max
 jb .Lclamp_min_check
 cmp ax, cs:[editor_max-module_start]
 jbe .Lclamp_min_check
.Lclamp_max:
 mov ax, cs:[editor_max-module_start]
 mov dx, cs:[editor_max-module_start+2]
.Lclamp_min_check:
 cmp dx, cs:[editor_min-module_start+2]
 jb .Lclamp_min
 ja .Lclamp_store
 cmp ax, cs:[editor_min-module_start]
 jae .Lclamp_store
.Lclamp_min:
 mov ax, cs:[editor_min-module_start]
 mov dx, cs:[editor_min-module_start+2]
.Lclamp_store:
 mov cs:[si], ax
 mov cs:[si+2], dx
editor_changed:
 call editor_fill_tail
 mov byte ptr cs:[editor_dirty-module_start], 1
 mov byte ptr cs:[editor_redraw-module_start], 1
 call editor_signal
 mov byte ptr cs:[editor_status-module_start], 0
 retf

/* XL native TRIM contract: SHIFT + cursor selects a decimal digit.
   Each key event moves once; no Classic outer-ring detent protocol. */
editor_digit_right:
 cmp byte ptr cs:[editor_digit-module_start], 0
 je .Ldigit_done
 dec byte ptr cs:[editor_digit-module_start]
 jmp .Ldigit_redraw
editor_digit_left:
 cmp byte ptr cs:[editor_digit-module_start], 6
 jae .Ldigit_done
 inc byte ptr cs:[editor_digit-module_start]
.Ldigit_redraw:
 mov byte ptr cs:[editor_redraw-module_start], 1
 call editor_signal
.Ldigit_done:
 retf
editor_digit_step:
 xor bx, bx
 mov bl, cs:[editor_digit-module_start]
 shl bx, 2
 mov cx, cs:[bx+editor_powers-module_start+2]
 mov bx, cs:[bx+editor_powers-module_start]
 ret
editor_after_down:
 mov byte ptr cs:[editor_after-module_start], 1
 retf
editor_after_up:
 mov byte ptr cs:[editor_after-module_start], 0
 retf
editor_fader:
 cmp byte ptr cs:[editor_after-module_start], 1
 je .Lfader_edit
 retf
.Lfader_edit:
 cmp ax, 127
 jbe .Lfader_value_ok
 retf
.Lfader_value_ok:
 mov cs:[editor_fader_value-module_start], ax
 call editor_bounds
 mov ax, cs:[editor_max-module_start]
 mov dx, cs:[editor_max-module_start+2]
 sub ax, cs:[editor_min-module_start]
 sbb dx, cs:[editor_min-module_start+2]
 /* L <= 24 bits; multiply by a seven-bit fader without 32-bit overflow. */
 mov bx, cs:[editor_fader_value-module_start]
 mov cx, dx
 mul bx
 push ax
 push dx
 mov ax, cx
 mul bx
 mov cx, ax
 pop dx
 add dx, cx
 pop ax
 mov cx, 127
 call divide_u32_u16
 add ax, cs:[editor_min-module_start]
 adc dx, cs:[editor_min-module_start+2]
 jmp editor_clamp

/* DX:AX / CX -> DX:AX quotient, BX remainder. SI preserved. */
divide_u32_u16:
 push si
 mov si, ax
 mov ax, dx
 xor dx, dx
 div cx
 mov bx, ax
 mov ax, si
 div cx
 mov si, dx
 mov dx, bx
 mov bx, si
 pop si
 ret


/* End editor_common.inc */
editor_apply_action:
 call editor_apply
 jnc editor_main
 retf
editor_apply:
 cmp byte ptr cs:[editor_dirty-module_start],0
 jne .Lapply_dirty
 clc
 ret
.Lapply_dirty:
 call regions_quiet
 pusha
 push ds
 push es
 push cs
 pop ds
 push cs
 pop es
 mov si,[editor_map_slot-module_start]
 mov di,offset editor_map_backup-module_start
 mov cx,MAP_BYTES/2
 rep movsw
 mov di,[editor_map_slot-module_start]
 xor ax,ax
 mov al,[editor_count-module_start]
 mov [di+M_COUNT],ax
 inc word ptr [di+M_REV]
 add di,M_POINTS
 mov si,offset editor_points-module_start
 mov cx,34
 rep movsw
 les si,[editor_source-module_start]
 call prepare
 jc .Lapply_rollback
 mov byte ptr cs:[editor_dirty-module_start],0
 mov byte ptr cs:[editor_status-module_start],0
 pop es
 pop ds
 popa
 clc
 ret
.Lapply_rollback:
 push cs
 pop ds
 push cs
 pop es
 mov si,offset editor_map_backup-module_start
 mov di,[editor_map_slot-module_start]
 mov cx,MAP_BYTES/2
 rep movsw
 mov byte ptr cs:[editor_status-module_start],2
 pop es
 pop ds
 popa
 stc
 ret
editor_play:
 call editor_preview_end
 push ds
 push SEQ_DS
 pop ds
 mov al,100
 mov ah,cs:[editor_region-module_start]
 mov cs:[editor_preview_pad-module_start],ah
 nearxl 0,0x0c76,0x42cd
 pop ds
 retf
editor_play_up:
 call editor_preview_end
 retf
editor_preview_end:
 pusha
 push ds
 mov ah,cs:[editor_preview_pad-module_start]
 cmp ah,16
 jae .Lpreview_ended
 mov byte ptr cs:[editor_preview_pad-module_start],0xff
 push SEQ_DS
 pop ds
 xor al,al
 nearxl 0,0x0c76,0x42cd
.Lpreview_ended:
 pop ds
 popa
 ret
editor_refresh:
 cmp byte ptr cs:[editor_redraw-module_start],0
 jne .Lrefresh_now
 retf
.Lrefresh_now:
 mov byte ptr cs:[editor_redraw-module_start],0
 pusha
 push ds
 push es
 mov bl,2
 int 0x90
 call editor_header_frame
 text 2,1,"REGION EDIT"
 text 158,1,"REG:   /"
 xor ax,ax
 mov al,cs:[editor_count-module_start]
 number 206,1,2
 mov al,cs:[editor_region-module_start]
 inc ax
 number 188,1,2
 text 0,12,"St:"
 text 128,12,"End:"
 xor bx,bx
 mov bl,cs:[editor_region-module_start]
 shl bx,2
 mov ax,cs:[bx+editor_points-module_start]
 mov dx,cs:[bx+editor_points-module_start+2]
 number 24,12,7
 mov ax,cs:[bx+editor_points-module_start+4]
 mov dx,cs:[bx+editor_points-module_start+6]
 number 158,12,7
 xor ax,ax
 mov al,cs:[editor_digit-module_start]
 mov cl,6
 mul cl
 mov dl,43
 sub dl,al
 mov cl,23
 cmp byte ptr cs:[editor_field-module_start],0
 je .Ldigit_plot
 mov cl,157
.Ldigit_plot:
 mov ch,11
 mov dh,9
 call editor_invert_rect
 call editor_wave
 cmp byte ptr cs:[editor_status-module_start],2
 jne .Lbuttons
 text 0,43,"NO FREE BUFFER / MAP SLOT"
.Lbuttons:
 button 1,"BACK"
 button 2,"EVEN"
 cmp byte ptr cs:[editor_count-module_start],8
 je .Llabel8
 cmp byte ptr cs:[editor_count-module_start],4
 je .Llabel4
 button 3,"16"
 jmp .Lcount_label_done
.Llabel8:
 button 3,"8"
 jmp .Lcount_label_done
.Llabel4:
 button 3,"4"
.Lcount_label_done:
 button 4,"ZOOM"
 button 5,"PLAY"
 button 6,"APPLY"
 pop es
 pop ds
 popa
 retf

/* Match the native TRIM sound-name frame, above the numeric row. */
editor_header_frame:
 mov cx,0
 mov dx,0x0193
 call plot_rect
 mov cx,0
 mov dx,0x0b01
 call plot_rect
 mov cx,146
 mov dx,0x0b01
 call plot_rect
 mov cx,0x0a00
.Lheader_bottom:
 mov dx,0x0101
 call plot_rect
 add cl,2
 cmp cl,146
 jb .Lheader_bottom
 ret

/* TRIM highlights the whole numeric field through the active digit;
   less-significant digits to its right retain the normal background. */
editor_invert_rect:
 pusha
 push es
 push SEQ_DS
 pop es
 mov al,cl
 xor ah,ah
 mov bx,ax
 shr bx,3
 mov al,ch
 xor ah,ah
 shl ax,5
 add bx,ax
 add bx,0x57a2
 and cl,7
 mov al,0x80
 shr al,cl
 xor ch,ch
 mov cl,dl
.Lfield_column:
 mov di,bx
 mov dl,dh
.Lfield_row:
 xor es:[di],al
 add di,32
 dec dl
 jnz .Lfield_row
 ror al,1
 jnc .Lfield_same
 inc bx
.Lfield_same:
 loop .Lfield_column
 pop es
 popa
 ret

/* Pixel rectangle in the native main plane. CL/CH=x/y, DL/DH=w/h. */
plot_rect:
 pusha
 push es
 push SEQ_DS
 pop es
 mov al,cl
 xor ah,ah
 mov bx,ax
 shr bx,3
 mov al,ch
 xor ah,ah
 shl ax,5
 add bx,ax
 add bx,0x57a2
 and cl,7
 mov al,0x80
 shr al,cl
 xor ch,ch
 mov cl,dl
.Lplot_column:
 mov di,bx
 mov dl,dh
.Lplot_row:
 or es:[di],al
 add di,32
 dec dl
 jnz .Lplot_row
 ror al,1
 jnc .Lplot_same
 inc bx
.Lplot_same:
 loop .Lplot_column
 pop es
 popa
 ret
/* Begin wave.inc */
.equ WAVE_COLUMNS, 245
editor_wave:
 pusha
 push ds
 push es
 les si, cs:[editor_source-module_start]
 mov ax, es:[si+0x0a]
 mov dx, es:[si+0x0c]
 mov cs:[wave_base-module_start], ax
 mov cs:[wave_base-module_start+2], dx
 xor bx, bx
 mov bl, cs:[editor_region-module_start]
 shl bx, 2
 mov ax, cs:[bx+editor_points-module_start]
 mov dx, cs:[bx+editor_points-module_start+2]
 mov cs:[wave_left-module_start], ax
 mov cs:[wave_left-module_start+2], dx
 mov cx, cs:[bx+editor_points-module_start+4]
 mov si, cs:[bx+editor_points-module_start+6]
 sub cx, ax
 sbb si, dx
 mov cs:[wave_span-module_start], cx
 mov cs:[wave_span-module_start+2], si
 cmp byte ptr cs:[editor_field-module_start], 0
 je .Lwave_marker_start
 mov ax, cs:[bx+editor_points-module_start+4]
 mov dx, cs:[bx+editor_points-module_start+6]
.Lwave_marker_start:
 mov cs:[wave_marker-module_start], ax
 mov cs:[wave_marker-module_start+2], dx
 cmp byte ptr cs:[editor_zoom-module_start], 0
 je .Lwave_window_ready
 cmp byte ptr cs:[editor_zoom-module_start], 3
 je .Lwave_whole_source
 mov bx, 128
 cmp byte ptr cs:[editor_zoom-module_start], 1
 je .Lwave_fine
 mov bx, 1024
.Lwave_fine:
 mov cx, ax
 mov si, dx
 sub ax, bx
 sbb dx, 0
 jnc .Lwave_left_ok
 xor ax, ax
 xor dx, dx
.Lwave_left_ok:
 mov cs:[wave_left-module_start], ax
 mov cs:[wave_left-module_start+2], dx
 add cx, bx
 adc si, 0
 cmp si, cs:[editor_length-module_start+2]
 ja .Lwave_right_clamp
 jb .Lwave_right_ok
 cmp cx, cs:[editor_length-module_start]
 jbe .Lwave_right_ok
.Lwave_right_clamp:
 mov cx, cs:[editor_length-module_start]
 mov si, cs:[editor_length-module_start+2]
.Lwave_right_ok:
 sub cx, ax
 sbb si, dx
 mov cs:[wave_span-module_start], cx
 mov cs:[wave_span-module_start+2], si
 jmp .Lwave_window_ready
.Lwave_whole_source:
 mov word ptr cs:[wave_left-module_start], 0
 mov word ptr cs:[wave_left-module_start+2], 0
 mov ax, cs:[editor_length-module_start]
 mov dx, cs:[editor_length-module_start+2]
 mov cs:[wave_span-module_start], ax
 mov cs:[wave_span-module_start+2], dx
.Lwave_window_ready:
 cmp byte ptr cs:[wave_valid-module_start], 1
 jne .Lwave_new_window
 mov ax, cs:[wave_left-module_start]
 cmp ax, cs:[wave_cached_left-module_start]
 jne .Lwave_new_window
 mov ax, cs:[wave_left-module_start+2]
 cmp ax, cs:[wave_cached_left-module_start+2]
 jne .Lwave_new_window
 mov ax, cs:[wave_span-module_start]
 cmp ax, cs:[wave_cached_span-module_start]
 jne .Lwave_new_window
 mov ax, cs:[wave_span-module_start+2]
 cmp ax, cs:[wave_cached_span-module_start+2]
 je .Lwave_draw
.Lwave_new_window:
 mov ax, cs:[wave_left-module_start]
 mov dx, cs:[wave_left-module_start+2]
 mov cs:[wave_cached_left-module_start], ax
 mov cs:[wave_cached_left-module_start+2], dx
 mov cs:[wave_position-module_start], ax
 mov cs:[wave_position-module_start+2], dx
 mov ax, cs:[wave_span-module_start]
 mov dx, cs:[wave_span-module_start+2]
 mov cs:[wave_cached_span-module_start], ax
 mov cs:[wave_cached_span-module_start+2], dx
 mov cx, WAVE_COLUMNS
 call divide_u32_u16
 mov cs:[wave_step-module_start], ax
 mov cs:[wave_step-module_start+2], dx
 mov cs:[wave_remainder-module_start], bx
 mov word ptr cs:[wave_fraction-module_start], 0
 mov word ptr cs:[wave_index-module_start], 0
 mov word ptr cs:[wave_remaining-module_start], 0
 mov word ptr cs:[wave_remaining-module_start+2], 0
 push cs
 pop es
 mov di, offset wave_peaks-module_start
 xor ax, ax
 mov cx, WAVE_COLUMNS*2
 rep stosw
 mov byte ptr cs:[wave_valid-module_start], 1
.Lwave_draw:
 xor si, si
.Lwave_draw_column:
 mov bx, si
 shl bx, 2
 mov ax, cs:[bx+wave_peaks-module_start]
 cwd
 mov cx, 2427
 idiv cx
 test ax, ax
 jns .Lwave_min_pixel
 dec ax
.Lwave_min_pixel:
 mov di, ax
 mov ax, cs:[bx+wave_peaks-module_start+2]
 cwd
 idiv cx
 mov bx, ax
 sub bx, di
 jnz .Lwave_height
 inc bx
.Lwave_height:
 mov dh, bl
 mov dl, 1
 mov ch, 34
 sub ch, al
 mov ax, si
 inc ax
 mov cl, al
 push si
 call plot_rect
 pop si
 inc si
 cmp si, WAVE_COLUMNS
 jb .Lwave_draw_column
 cmp byte ptr cs:[editor_zoom-module_start], 3
 jne .Lwave_local_marker
 call editor_wave_overview
 jmp .Lwave_done
.Lwave_local_marker:
 mov ax, cs:[wave_marker-module_start]
 mov dx, cs:[wave_marker-module_start+2]
 sub ax, cs:[wave_left-module_start]
 sbb dx, cs:[wave_left-module_start+2]
 call editor_wave_project
 cmp ax, WAVE_COLUMNS-1
 jbe .Lwave_local_x
 mov ax, WAVE_COLUMNS-1
.Lwave_local_x:
 inc ax
 mov cl, al
 mov ch, 21
 mov dx, 0x1b01
 call plot_rect
.Lwave_done:
 pop es
 pop ds
 popa
 ret

/* E48 is the native foreground idle callback (not a timer or audio IRQ).
   Scan every source word, including transients between display columns. */
editor_wave_idle:
 cmp byte ptr cs:[editor_active-module_start], 1
 jne .Lwave_idle_return
 cmp byte ptr cs:[wave_valid-module_start], 1
 jne .Lwave_idle_return
 cmp word ptr cs:[wave_index-module_start], WAVE_COLUMNS
 jb .Lwave_idle_work
.Lwave_idle_return:
 retf
.Lwave_idle_work:
 pusha
 push ds
 push es
 mov word ptr cs:[wave_budget-module_start], 1024
.Lwave_idle_next:
 mov ax, cs:[wave_remaining-module_start]
 or ax, cs:[wave_remaining-module_start+2]
 jnz .Lwave_read_chunk
 mov ax, cs:[wave_position-module_start]
 mov dx, cs:[wave_position-module_start+2]
 add ax, cs:[wave_step-module_start]
 adc dx, cs:[wave_step-module_start+2]
 mov bx, cs:[wave_fraction-module_start]
 add bx, cs:[wave_remainder-module_start]
 cmp bx, WAVE_COLUMNS
 jb .Lwave_next_boundary
 sub bx, WAVE_COLUMNS
 add ax, 1
 adc dx, 0
.Lwave_next_boundary:
 mov cs:[wave_fraction-module_start], bx
 mov cs:[wave_next-module_start], ax
 mov cs:[wave_next-module_start+2], dx
 sub ax, cs:[wave_position-module_start]
 sbb dx, cs:[wave_position-module_start+2]
 mov bx, ax
 or bx, dx
 jnz .Lwave_column_size
 inc ax /* Sub-pixel sample lengths repeat the current in-range sample. */
.Lwave_column_size:
 mov cs:[wave_remaining-module_start], ax
 mov cs:[wave_remaining-module_start+2], dx
.Lwave_read_chunk:
 mov cx, 16
 cmp cx, cs:[wave_budget-module_start]
 jbe .Lwave_budget_ready
 mov cx, cs:[wave_budget-module_start]
.Lwave_budget_ready:
 cmp word ptr cs:[wave_remaining-module_start+2], 0
 jne .Lwave_chunk_ready
 cmp cs:[wave_remaining-module_start], cx
 jae .Lwave_chunk_ready
 mov cx, cs:[wave_remaining-module_start]
.Lwave_chunk_ready:
 mov cs:[wave_chunk-module_start], cx
 mov ax, cs:[wave_position-module_start]
 mov dx, cs:[wave_position-module_start+2]
 add ax, cs:[wave_base-module_start]
 adc dx, cs:[wave_base-module_start+2]
 push SYS_DS
 pop ds
 pushf
 cli
 /* The native PCM transfer owns DSP channel zero. Defer a background scan
    while that voice is playing; clear its finished release before DMA. */
 cmp byte ptr [0x960a],0xff
 jne .Lwave_dma_busy
 push ax
 mov ax,0x0300
 out 0x80,ax
 xor ax,ax
 out 0x82,ax
 out 0x84,ax
 out 0x86,ax
 pop ax
 push 0x1000
 push cx
 push cs
 push offset wave_word-module_start
 push dx
 push ax
 fc 0x3e19,0x0066
 add sp,12
 popf
 mov bx,cs:[wave_index-module_start]
 shl bx,2
 add bx,offset wave_peaks-module_start
 mov si,offset wave_word-module_start
 mov cx,cs:[wave_chunk-module_start]
.Lreduce:
 mov ax,cs:[si]
 cmp ax,cs:[bx]
 jge .Lreduce_max
 mov cs:[bx],ax
.Lreduce_max:
 cmp ax,cs:[bx+2]
 jle .Lreduce_next
 mov cs:[bx+2],ax
.Lreduce_next:
 add si,2
 loop .Lreduce
 mov ax, cs:[wave_chunk-module_start]
 sub cs:[wave_budget-module_start], ax
 add cs:[wave_position-module_start], ax
 adc word ptr cs:[wave_position-module_start+2], 0
 sub cs:[wave_remaining-module_start], ax
 sbb word ptr cs:[wave_remaining-module_start+2], 0
 mov ax, cs:[wave_remaining-module_start]
 or ax, cs:[wave_remaining-module_start+2]
 jnz .Lwave_idle_continue
 mov ax, cs:[wave_next-module_start]
 mov dx, cs:[wave_next-module_start+2]
 mov cs:[wave_position-module_start], ax
 mov cs:[wave_position-module_start+2], dx
 inc word ptr cs:[wave_index-module_start]
 /* Redraw in groups of eight completed columns, and the final column. */
 test word ptr cs:[wave_index-module_start], 7
 jz .Lwave_idle_redraw
 cmp word ptr cs:[wave_index-module_start], WAVE_COLUMNS
 jne .Lwave_idle_continue
.Lwave_idle_redraw:
 mov byte ptr cs:[editor_redraw-module_start], 1
 call editor_signal
.Lwave_idle_continue:
 cmp word ptr cs:[wave_budget-module_start], 0
 je .Lwave_idle_done
 cmp word ptr cs:[wave_index-module_start], WAVE_COLUMNS
 jae .Lwave_idle_done
 jmp .Lwave_idle_next
.Lwave_dma_busy:
 popf
 jmp .Lwave_idle_done
.Lwave_idle_done:
 pop es
 pop ds
 popa
 retf

/* DX:AX window-relative boundary -> AX pixel offset 0..245. Native unsigned DWORD
   division keeps the mapping exact for samples longer than 65535 words.
   A 24-bit PCM position times 245 fits in a DWORD. Preserve other registers. */
editor_wave_project:
 push bx
 push cx
 push dx
 push si
 push di
 push bp
 push ds
 push es
 mov cx, dx
 mov bx, WAVE_COLUMNS
 mul bx
 mov si, ax
 mov di, dx
 mov ax, cx
 mul bx
 add ax, di
 mov dx, ax
 mov ax, si
 push word ptr cs:[wave_span-module_start+2]
 push word ptr cs:[wave_span-module_start]
 push dx
 push ax
 fc 0x35b0,0x00ac
 pop es
 pop ds
 pop bp
 pop di
 pop si
 pop dx
 pop cx
 pop bx
 ret

/* Highlight the complete draft region in the whole-source view. The active
   START/END marker uses the same projection as the selection boundaries.
   Invert only the main plot plane; its normal refresh clears the selection,
   so no XOR overlay survives a zoom change or leaving the editor. */
editor_wave_overview:
 xor bx, bx
 mov bl, cs:[editor_region-module_start]
 shl bx, 2
 mov ax, cs:[bx+editor_points-module_start]
 mov dx, cs:[bx+editor_points-module_start+2]
 call editor_wave_project
 inc ax
 mov cs:[wave_selection_x-module_start], ax
 mov ax, cs:[bx+editor_points-module_start+4]
 mov dx, cs:[bx+editor_points-module_start+6]
 call editor_wave_project
 inc ax
 sub ax, cs:[wave_selection_x-module_start]
 jnz .Loverview_width
 inc ax /* A sub-pixel region remains visible as one pixel. */
.Loverview_width:
 mov cs:[wave_selection_width-module_start], ax
 mov ax, cs:[wave_marker-module_start]
 mov dx, cs:[wave_marker-module_start+2]
 call editor_wave_project
 inc ax
 mov cs:[wave_marker_x-module_start], ax
 cmp word ptr cs:[wave_selection_width-module_start], 1
 jne .Loverview_marker
 cmp ax, cs:[wave_selection_x-module_start]
 je .Loverview_selection /* Do not erase a one-pixel selection with its marker. */
.Loverview_marker:
 mov cl, al
 mov ch, 21
 mov dx, 0x1b01
 call plot_rect
.Loverview_selection:
 mov ax, cs:[wave_selection_x-module_start]
 mov bx, ax
 shr bx, 3
 add bx, 0x57a2+21*32
 mov cl, al
 and cl, 7
 mov dl, 0x80
 shr dl, cl
 mov cx, cs:[wave_selection_width-module_start]
 push SEQ_DS
 pop es
.Loverview_column:
 mov di, bx
 mov si, 27
.Loverview_row:
 xor byte ptr es:[di], dl
 add di, 32
 dec si
 jnz .Loverview_row
 ror dl, 1
 jnc .Loverview_same_byte
 inc bx
.Loverview_same_byte:
 loop .Loverview_column
 ret

/* End wave.inc */
/* End editor.inc */
/* Begin sequencer.inc */
/* Ring velocity bit 7 is unused by native 0..127 velocity. It carries the
   fifth variation kind through every native ring consumer without widening
   the ring or touching the pad bank bits. Persistent events use type 4. */
.global ring_producer,ring_repeat,ring_read,ring_read_record,pad_release
ring_producer:
 cmp dh,4
 jne .Lring_native
 or cl,0x80
.Lring_native:
 mov bx,[0x2cc]
 shl dh,6
 fj 0,0x0d02
ring_repeat:
 cmp dh,4
 jne .Lrepeat_native
 or cl,0x80
.Lrepeat_native:
 mov bx,[0x2cc]
 shl dh,6
 fj 0,0x70b8
ring_read:
 mov dl,ch
 mov dh,ah
 shr dh,6
 test cl,0x80
 jz .Lring_decoded
 and cl,0x7f
 mov dh,4
.Lring_decoded:
 retf
ring_read_record:
 fc MOD_CS,ring_read-module_start
 retf
pad_release:
 mov dh,[bx+0x50e]
 mov dl,[bx+0x51e]
 mov al,[bx+0x4ee]
 mov ah,[bx+0x4fe]
 fj 0,0x0ce2

.global voice_start,voice_address,voice_stereo,voice_envelope,voice_finite
voice_start:
 mov [bp-4],ax
 mov [bp-2],dx
 cmp byte ptr cs:[cache_gc_hold-module_start],0
 je .Lvoice_available
 mov word ptr [bp-4],0
 mov word ptr [bp-2],0
 retf
.Lvoice_available:
 cmp byte ptr [bp-0x4b],3
 jne .Lvoice_kind
 cmp byte ptr [bp-0x4a],112
 jb .Lvoice_kind
 mov byte ptr [bp-0x4b],4
 sub byte ptr [bp-0x4a],112
.Lvoice_kind:
 cmp byte ptr [bp-0x4b],4
 jne .Lvoice_return
 pusha
 push es
 les si,[bp-8]
 call lookup
 jc .Lvoice_missing
 mov al,cs:[bx+C_COUNT]
 cmp [bp-0x4a],al
 jae .Lvoice_missing
 xor ax,ax
 mov al,[bp-0x4a]
 shl ax,3
 add bx,ax
 mov ax,cs:[bx+C_LAYOUT+4]
 mov dx,cs:[bx+C_LAYOUT+6]
 mov bx,ax
 mov cx,dx
 shl ax,1
 rcl dx,1
 shl ax,1
 rcl dx,1
 add ax,bx
 adc dx,cx
 shl ax,1
 rcl dx,1
 add ax,440
 adc dx,0
 push 0
 push 441
 push dx
 push ax
 fc 0x35b0,0x00ac
 add ax,40
 adc dx,0
 mov [bp-4],ax
 mov [bp-2],dx
 mov byte ptr [bp-0x49],1
 inc word ptr cs:[hits-module_start]
 jmp .Lvoice_pop
.Lvoice_missing:
 mov word ptr [bp-4],0
 mov word ptr [bp-2],0
 inc word ptr cs:[misses-module_start]
.Lvoice_pop:
 pop es
 popa
.Lvoice_return:
 retf

/* Called immediately before native conversion to absolute PCM addresses. */
voice_address:
 cmp byte ptr [bp-0x4b],4
 jne .Laddress_native
 pusha
 push es
 les si,[bp-8]
 call lookup
 jc .Laddress_done
 xor ax,ax
 mov al,[bp-0x4a]
 shl ax,3
 mov di,bx
 add di,ax
 add di,C_LAYOUT
 mov ax,cs:[bx+C_BASE]
 mov dx,cs:[bx+C_BASE+2]
 add ax,cs:[di]
 adc dx,cs:[di+2]
 sub ax,es:[si+0x0a]
 sbb dx,es:[si+0x0c]
 mov [bp-0x38],ax
 mov [bp-0x36],dx
 add ax,cs:[di+4]
 adc dx,cs:[di+6]
 add ax,15
 adc dx,0
 and ax,0xfff0
 mov [bp-0x30],ax
 mov [bp-0x2e],dx
 add ax,16
 adc dx,0
 mov [bp-0x34],ax
 mov [bp-0x32],dx
 mov word ptr [bp-0x2c],0
 mov word ptr [bp-0x2a],0
 mov byte ptr [bp-0x47],0
.Laddress_done:
 pop es
 popa
.Laddress_native:
 les bx,[bp-8]
 mov ax,es:[bx+0x0a]
 retf
voice_stereo:
 cmp byte ptr [bp-0x4b],4
 jne .Lstereo_native
 push bx
 push si
 push es
 les si,[bp-8]
 call lookup
 mov ax,cs:[bx+C_PLANE]
 mov dx,cs:[bx+C_PLANE+2]
 pop es
 pop si
 pop bx
 jmp .Lstereo_add
.Lstereo_native:
 les bx,[bp-8]
 mov ax,es:[bx+0x0e]
 mov dx,es:[bx+0x10]
 shr dx,1
 rcr ax,1
.Lstereo_add:
 add [bp-0x38],ax
 adc [bp-0x36],dx
 add [bp-0x34],ax
 adc [bp-0x32],dx
 add [bp-0x30],ax
 adc [bp-0x2e],dx
 retf
voice_envelope:
 mov al,es:[bx+7]
 cmp byte ptr es:[bx+5],4
 jne .Lenvelope_native
 xor al,al
 mov byte ptr es:[bx+9],0
 mov word ptr es:[bx+0x3a],0
.Lenvelope_native:
 mov [bp-0xf],al
 retf
voice_finite:
 cmp byte ptr es:[bx+5],4
 je .Lfinite_region
 cmp byte ptr es:[bx+7],0
 retf
.Lfinite_region:
 cmp bx,bx
 retf

/* XL stores two variation-kind bits in the two velocity/value high bits.
   FILTER values 112..127 lie outside its native 0..100 editor range. They
   carry REG 1..16 on disk without changing native event size or timestamps. */
.global record_pack,event_decode
record_pack:
 mov byte ptr cs:[record_kind-module_start],dh
 cmp dh,4
 jne .Lpack_native
 pusha
 push es
 sub al,35
 xor ah,ah
 mov bx,ax
 push bx
 int 0xc5
 pop bx
 imul bx,bx,24
 add bx,si
 mov al,es:[bx+35]
 mov cs:[record_gate-module_start],al
 pop es
 popa
 mov dh,3
 add dl,112
.Lpack_native:
 shl dl,1
 rcr dx,1
 mov [si+7],dl
 shl cl,1
 shr dh,1
 rcr cl,1
 mov [si+6],cl
 retf
event_decode:
 mov dl,es:[si+7]
 shl dx,1
 shr dl,1
 cmp dh,3
 jne .Levent_native
 cmp dl,112
 jb .Levent_native
 sub dl,112
 mov dh,4
 fj 0,0x6133
.Levent_native:
 fj 0,0x6113

.global record_commit
record_commit:
 or byte ptr es:[bx+0x680],1
 cmp byte ptr cs:[record_kind-module_start],4
 jne .Lrecord_commit_done
 cmp byte ptr cs:[record_gate-module_start],2
 je .Lrecord_commit_done
 mov byte ptr [si+9],1
 pusha
 push es
 nearxl 0,0x661a,0x42cd
 pop es
 popa
.Lrecord_commit_done:
 retf

.global region_mute_groups
region_mute_groups:
 pushf
 pusha
 push es
 cmp byte ptr [bp+8],4
 je .Lmute_region
 cmp byte ptr [bp+8],3
 jne .Lmute_return
 cmp byte ptr [bp+9],112
 jb .Lmute_return
.Lmute_region:
 cmp byte ptr es:[bx],4
 jb .Lmute_return
 cmp byte ptr es:[bx],7
 ja .Lmute_return
 xor si,si
 mov di,0x9609
.Lmute_same:
 mov al,[bp+4]
 cmp [di],al
 jne .Lmute_next_same
 mov al,[bp+5]
 cmp [di+1],al
 jne .Lmute_next_same
 push si
 fc 0x3e19,0x3a36
 add sp,2
.Lmute_next_same:
 add di,20
 inc si
 cmp si,32
 jb .Lmute_same
.Lmute_return:
 pop es
 popa
 popf
 fj 0x7700,BASE_MUTE

/* End sequencer.inc */
/* Begin step.inc */
.global step_draw,step_type_decode,step_type_store,step_value_editor
/* Native STEP row, ES:DI packed XL event, AH native variation kind. */
step_draw:
 cmp ah,3
 jne .Lstep_native
 cmp byte ptr es:[di+7],0xf0
 jb .Lstep_native
 add cl,42
 mov dx,cs
 mov si,offset step_reg_label-module_start
 mov ah,3
 mov bl,5
 int 0x90
 add cl,24
 mov al,es:[di+7]
 and ax,0x7f
 sub ax,111
 mov bh,2
 mov bl,8
 int 0x90
 retf
.Lstep_native:
 push ax
 mov al,3
 mul ah
 add ax,0x2136
 mov si,ax
 mov ah,3
 mov dx,ds
 add cl,42
 mov bl,5
 int 0x90
 pop ax
 mov al,es:[di+7]
 and al,0x7f
 add cl,24
 push cx
 nearxl 0x267b,0x7870,0x0036
 pop cx
 retf
step_reg_label: .ascii "REG"
step_type_decode:
 mov al,es:[di+6]
 shl ax,1
 mov al,es:[di+7]
 shl ax,1
 mov al,ah
 and ax,3
 cmp al,3
 jne .Ltype_decoded
 cmp byte ptr es:[di+7],0xf0
 jb .Ltype_decoded
 inc ax
.Ltype_decoded:
 retf
step_type_store:
 les di,[0x1920]
 cmp al,4
 jne .Ltype_store_native
 or byte ptr es:[di+6],0x80
 mov byte ptr es:[di+7],0xf0
 retf
.Ltype_store_native:
 cmp byte ptr es:[di+7],0xf0
 jb .Ltype_keep_value
 mov byte ptr es:[di+7],64
.Ltype_keep_value:
 mov ah,al
 fj 0x267b,0x8048
step_value_editor:
 les di,[0x1920]
 mov al,es:[di+6]
 test al,0x80
 jz .Lvalue_native
 cmp byte ptr es:[di+7],0xf0
 jb .Lvalue_native
 mov word ptr [0x1924],0x784f
 mov al,es:[di+7]
 and ax,0x7f
 sub ax,111
 mov bx,1
 mov dx,16
 mov di,offset step_region_store-module_start
 int 0x7f
 retf
.Lvalue_native:
 fj 0x267b,0x8086
step_region_store:
 cmp ax,1
 jae .Lregion_min
 mov ax,1
.Lregion_min:
 cmp ax,16
 jbe .Lregion_max
 mov ax,16
.Lregion_max:
 add al,111
 or al,0x80
 les di,[0x1920]
 mov es:[di+7],al
 retf

/* End step.inc */
/* Begin persistence.inc */
/* ALL has a fixed header and explicit per-sequence sizes. Append a signed
   native-XL map trailer after the last sequence. A legacy file clears maps.
   Scratch aliases the editor draft backup; disk pages cannot own the editor. */
.equ disk_buffer,editor_map_backup-module_start
.equ disk_sum,wave_selection_x-module_start
.equ disk_expected,wave_selection_width-module_start
.global all_append,all_loaded,main_prepare
all_append:
 int 0xea
 jnc .Lall_stage
 fj 0x1a9b,0x4d42
.Lall_stage:
 pusha
 push ds
 push es
 /* Add all canonical disk records to the 16-bit checksum first. */
 xor bx,bx
 mov cs:[disk_sum],bx
 mov bp,offset marker_maps-module_start
 mov dx,MAP_COUNT
.Lall_sum:
 call disk_pack
 call disk_checksum
 add bp,MAP_BYTES
 dec dx
 jnz .Lall_sum
 push cs
 pop es
 mov di,offset disk_buffer
 xor ax,ax
 mov cx,24
 rep stosw
 push ds
 push cs
 pop ds
 mov si,offset all_signature-module_start
 mov di,offset disk_buffer+16
 mov cx,8
 rep movsw
 pop ds
 mov word ptr cs:[disk_buffer+32],MAP_COUNT
 mov word ptr cs:[disk_buffer+34],96
 mov ax,cs:[disk_sum]
 mov cs:[disk_buffer+36],ax
 mov si,offset disk_buffer
 mov cx,48
 mov bl,9
 int 0x91
 jc .Lall_write_failed
 mov bp,offset marker_maps-module_start
 mov dx,MAP_COUNT
.Lall_write:
 call disk_pack
 push dx
 push bp
 push cs
 pop es
 mov si,offset disk_buffer
 mov cx,96
 mov bl,9
 int 0x91
 pop bp
 pop dx
 jc .Lall_write_failed
 add bp,MAP_BYTES
 dec dx
 jnz .Lall_write
 pop es
 pop ds
 popa
 fj 0x1a9b,0x4d39
.Lall_write_failed:
 pop es
 pop ds
 popa
 fj 0x1a9b,0x4d42

/* BP map -> canonical 96-byte record; stale native pointers never persist. */
disk_pack:
 pusha
 push ds
 push es
 push cs
 pop ds
 push cs
 pop es
 /* Refresh names after a native rename, checking the pool generation first. */
 cmp word ptr cs:[bp+M_VALID],1
 jne .Lpack_copy
 cmp word ptr cs:[bp+M_PTR+2],SYS_DS
 jne .Lpack_copy
 mov bx,cs:[bp+M_HANDLE]
 mov ax,cs:[bx+pool_generations-module_start]
 cmp ax,cs:[bp+M_GENERATION]
 jne .Lpack_copy
 les si,cs:[bp+M_PTR]
 mov di,bp
 add di,M_NAME
 mov cx,8
.Lpack_name:
 mov ax,es:[si+0x12]
 mov cs:[di],ax
 add si,2
 add di,2
 loop .Lpack_name
 push cs
 pop es
.Lpack_copy:
 mov si,bp
 mov di,offset disk_buffer
 mov cx,46
 rep movsw
 mov ax,cs:[bp+M_COUNT]
 stosw
 xor ax,ax
 stosw
 pop es
 pop ds
 popa
 ret
disk_checksum:
 pusha
 mov si,offset disk_buffer
 mov cx,48
 mov ax,cs:[disk_sum]
.Lsum_word:
 add ax,cs:[si]
 add si,2
 loop .Lsum_word
 mov cs:[disk_sum],ax
 popa
 ret
all_loaded:
 call regions_quiet
 call cache_reset
 pusha
 push ds
 push es
 call maps_clear
 push cs
 pop es
 mov di,offset disk_buffer
 mov cx,48
 mov bl,6
 int 0x91
 jc .Lloaded_done
 push ds
 push cs
 pop ds
 mov si,offset all_signature-module_start
 mov di,offset disk_buffer+16
 mov cx,8
 repe cmpsw
 pop ds
 jne .Lloaded_done
 cmp word ptr cs:[disk_buffer+32],MAP_COUNT
 jne .Lloaded_done
 cmp word ptr cs:[disk_buffer+34],96
 jne .Lloaded_done
 mov ax,cs:[disk_buffer+36]
 mov cs:[disk_expected],ax
 mov word ptr cs:[disk_sum],0
 mov bp,offset marker_maps-module_start
 mov dx,MAP_COUNT
.Lloaded_map:
 push dx
 push bp
 push cs
 pop es
 mov di,offset disk_buffer
 mov cx,96
 mov bl,6
 int 0x91
 pop bp
 pop dx
 jc .Lloaded_bad
 call disk_checksum
 call disk_validate
 jc .Lloaded_bad
 push ds
 push cs
 pop ds
 push cs
 pop es
 mov si,offset disk_buffer
 mov di,bp
 mov cx,46
 rep movsw
 mov ax,[disk_buffer+92]
 mov cs:[bp+M_COUNT],ax
 mov word ptr cs:[bp+M_REV],1
 pop ds
 add bp,MAP_BYTES
 dec dx
 jnz .Lloaded_map
 mov ax,cs:[disk_sum]
 cmp ax,cs:[disk_expected]
 jne .Lloaded_bad
 mov word ptr cs:[marker_load_status-module_start],1
 jmp .Lloaded_done
.Lloaded_bad:
 call maps_clear
 mov word ptr cs:[marker_load_status-module_start],2
.Lloaded_done:
 pop es
 pop ds
 popa
 mov word ptr [0x710],0
 retf
maps_clear:
 pusha
 push es
 push cs
 pop es
 xor ax,ax
 mov di,offset marker_maps-module_start
 mov cx,MAP_COUNT*MAP_BYTES/2
 rep stosw
 mov word ptr cs:[marker_load_status-module_start],0
 pop es
 popa
 ret
/* Strict monotone boundaries, finite length, count and stereo validation. */
disk_validate:
 pusha
 cmp word ptr cs:[disk_buffer],0
 je .Ldisk_ok
 cmp word ptr cs:[disk_buffer],1
 jne .Ldisk_bad
 cmp word ptr cs:[disk_buffer+2],1
 ja .Ldisk_bad
 cmp word ptr cs:[disk_buffer+6],0x100
 jae .Ldisk_bad
 mov cx,cs:[disk_buffer+92]
 cmp cx,4
 je .Ldisk_count
 cmp cx,8
 je .Ldisk_count
 cmp cx,16
 jne .Ldisk_bad
.Ldisk_count:
 mov si,offset disk_buffer+24
 mov ax,cs:[si]
 mov dx,cs:[si+2]
.Ldisk_boundary:
 cmp dx,cs:[si+6]
 ja .Ldisk_bad
 jb .Ldisk_next
 cmp ax,cs:[si+4]
 jae .Ldisk_bad
.Ldisk_next:
 add si,4
 mov ax,cs:[si]
 mov dx,cs:[si+2]
 loop .Ldisk_boundary
 cmp dx,cs:[disk_buffer+6]
 ja .Ldisk_bad
 jb .Ldisk_ok
 cmp ax,cs:[disk_buffer+4]
 ja .Ldisk_bad
.Ldisk_ok:
 popa
 clc
 ret
.Ldisk_bad:
 popa
 stc
 ret

/* Bind pending ALL maps to the currently loaded native linked sound list
   before MAIN can dispatch PLAY. Never allocate PCM from the audio IRQ. */
main_prepare:
 pusha
 push ds
 push es
 push SYS_DS
 pop ds
 les si,[0x98dc]
.Lprepare_list:
 mov ax,es
 cmp ax,SYS_DS
 jne .Lprepare_list_end
 cmp si,0x991a
 jb .Lprepare_list_end
 cmp si,0xd71a
 jae .Lprepare_list_end
 push si
 call map_find
 jc .Lprepare_list_next
 call lookup
 jnc .Lprepare_list_next
 call regions_quiet
 call prepare
.Lprepare_list_next:
 pop si
 push SYS_DS
 pop es
 les si,es:[si]
 jmp .Lprepare_list
.Lprepare_list_end:
 pop es
 pop ds
 popa
 mov al,0
 mov [0x0f2f],al
 retf
all_signature: .ascii "MPCXLREGIONS0001"

/* End persistence.inc */
/* Begin math.inc */
/* DX:AX=start, CX:BX=end (exclusive), ES:DI=17 DWORD boundaries.
 * All registers and IF/DF preserved. CF=1 => invalid input, no writes.
 * At least 16 PCM words; addresses <= 0x00FFFFFF; output cannot wrap ES.
 * q=L/16, r=L%16. Each iteration adds q and carries floor(i*r/16).
 */
regions_split:
    push bp
    mov bp, sp
    sub sp, 12
    pushf
    pusha
    cmp di, 0xffbc
    ja .Lsplit_bad
    cmp dx, 0x00ff
    ja .Lsplit_bad
    cmp cx, 0x00ff
    ja .Lsplit_bad
    mov word ptr [bp-2], ax
    mov word ptr [bp-4], dx
    sub bx, ax
    sbb cx, dx
    jc .Lsplit_bad
    test cx, cx
    jnz .Lsplit_length_ok
    cmp bx, 16
    jb .Lsplit_bad
.Lsplit_length_ok:
    mov ax, bx
    and ax, 15
    mov word ptr [bp-10], ax
    mov word ptr [bp-12], 0
    mov ax, bx
    mov dx, cx
    mov cx, 4
.Lsplit_divide:
    shr dx, 1
    rcr ax, 1
    loop .Lsplit_divide
    mov word ptr [bp-6], ax
    mov word ptr [bp-8], dx
    mov ax, word ptr [bp-2]
    mov dx, word ptr [bp-4]
    mov cx, 16
    cld
    stosw
    xchg ax, dx
    stosw
    xchg ax, dx
.Lsplit_next:
    add ax, word ptr [bp-6]
    adc dx, word ptr [bp-8]
    mov bx, word ptr [bp-12]
    add bx, word ptr [bp-10]
    cmp bx, 16
    jb .Lsplit_store
    sub bx, 16
    add ax, 1
    adc dx, 0
.Lsplit_store:
    mov word ptr [bp-12], bx
    stosw
    xchg ax, dx
    stosw
    xchg ax, dx
    loop .Lsplit_next
    popa
    popf
    leave
    clc
    retf
.Lsplit_bad:
    popa
    popf
    leave
    stc
    retf

/* DX:AX=aligned destination start, CX:BX=nonzero source length.
 * ES:DI=16-byte descriptor: start, first_zero, loop_start, dsp_end (DWORDs).
 * END must fit bits 23..4. All registers and IF/DF preserved. CF result.
 * Does not copy PCM. Every validation precedes the first output write.
 */
regions_guard:
    push bp
    mov bp, sp
    sub sp, 12
    pushf
    pusha
    cmp di, 0xfff0
    ja .Lguard_bad
    test ax, 15
    jnz .Lguard_bad
    cmp dx, 0xff
    ja .Lguard_bad
    cmp cx, 0xff
    ja .Lguard_bad
    mov word ptr [bp-2], ax
    mov word ptr [bp-4], dx
    mov si, bx
    or si, cx
    jz .Lguard_bad
    add ax, bx
    adc dx, cx
    jc .Lguard_bad
    mov word ptr [bp-6], ax
    mov word ptr [bp-8], dx
    add ax, 15
    adc dx, 0
    jc .Lguard_bad
    and ax, 0xfff0
    mov word ptr [bp-10], ax
    mov word ptr [bp-12], dx
    add ax, 16
    adc dx, 0
    jc .Lguard_bad
    cmp dx, 0xff
    ja .Lguard_bad
    jb .Lguard_write
    cmp ax, 0xfff0
    ja .Lguard_bad
.Lguard_write:
    mov word ptr es:[di+12], ax
    mov word ptr es:[di+14], dx
    mov ax, word ptr [bp-2]
    mov dx, word ptr [bp-4]
    mov word ptr es:[di], ax
    mov word ptr es:[di+2], dx
    mov ax, word ptr [bp-6]
    mov dx, word ptr [bp-8]
    mov word ptr es:[di+4], ax
    mov word ptr es:[di+6], dx
    mov ax, word ptr [bp-10]
    mov dx, word ptr [bp-12]
    mov word ptr es:[di+8], ax
    mov word ptr es:[di+10], dx
    popa
    popf
    leave
    clc
    retf
.Lguard_bad:
    popa
    popf
    leave
    stc
    retf


/* End math.inc */
code_end:
.balign 4
/* Begin data.inc */
.balign 4
map_epoch: .long 0
cache_gc_hold: .byte 0
editor_active: .byte 0
editor_region: .byte 0
editor_count: .byte 16
editor_field: .byte 0
editor_digit: .byte 0
wave_valid: .byte 0
editor_dirty: .byte 0
editor_redraw: .byte 0
editor_after: .byte 0
editor_zoom: .byte 0
editor_status: .byte 0
editor_old_levels: .byte 0
editor_old_after: .byte 0
editor_preview_pad: .byte 0xff
editor_old_settings: .fill 5,1,0
.balign 2 /* V53 word DMA requires the waveform destination to be even. */
editor_fader_value: .word 0
editor_source: .long 0
editor_length: .long 0
editor_min: .long 0
editor_max: .long 0
editor_map_slot: .word 0
editor_points: .fill 68,1,0
editor_count_backup: .fill 71,1,0
.balign 2
editor_powers: .long 1,10,100,1000,10000,100000,1000000,10000000
editor_map_backup: .fill MAP_BYTES,1,0
wave_base: .long 0
wave_position: .long 0
wave_step: .long 0
wave_left: .long 0
wave_span: .long 0
wave_marker: .long 0
wave_selection_x: .word 0
wave_selection_width: .word 0
wave_marker_x: .word 0
wave_cached_left: .long 0
wave_cached_span: .long 0
wave_next: .long 0
wave_remaining: .long 0
wave_chunk: .word 0
wave_budget: .word 0
.balign 2
wave_word: .fill 32,1,0
wave_peaks: .fill WAVE_COLUMNS*4,1,0
wave_index: .word 0
wave_remainder: .word 0
wave_fraction: .word 0
wave_marker_drawn: .byte 0
.balign 2

.balign 2
record_kind: .byte 0
record_gate: .byte 0
marker_load_status: .word 0
marker_maps: .fill MAP_COUNT*MAP_BYTES,1,0
pool_generations: .fill 256*2,1,0
.org 0x3470
cache_table: .fill MAP_COUNT*C_BYTES,1,0
arena_original: .long 0
arena_limit: .long 0
prepared: .word 0
hits: .word 0
misses: .word 0
count_return: .byte 16
.balign 2
dma_source: .long 0
dma_destination: .long 0
dma_remaining: .long 0
dma_chunk_words: .word 0
dma_buffer: .fill 32,1,0

/* End data.inc */
module_end:

.endif /* xl_regions */
