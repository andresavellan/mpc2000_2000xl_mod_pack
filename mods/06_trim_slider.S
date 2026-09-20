/* Final firmware source: trim slider.
 * Assembly source sections for this feature.
 */
/* trim_slider: assembly unit 14. */
.if MOD_UNIT == 14
/* C13: hold AFTER to position the native TRIM START/END editor.
 * All code/state is appended to C12, in the existing C02/C04 segment.
 * No sample data is written here: the native editor commits each change.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
segment_start:
.org 0x5c7c
.global extension_start, extension_end, install_trim, after_down, after_up
.global fader_changed, trim_events, native_commit_segment, held, target_field
.global target_sound, code_end
.macro old_call offset
    push cs
    .byte 0xe8
    .word \offset - (. - segment_start + 2)
.endm
.macro set_ds
    .byte 0xe8
    .word 0x6f - (. - segment_start + 2)
.endm
/* EXE callbacks return near. A verified native RETF instruction bridges
 * that return back to this segment, without changing any EXE bytes. */
.macro main_near offset
    push cs
    push .Lmain_return_\@ - segment_start
    push 0x0626
    push word ptr cs:[0x3914] /* C04 base + main_segment (0x1710 + 0x2204) */
    push \offset
    retf
.Lmain_return_\@:
.endm
.macro enter
    pushf
    pusha
    push ds
    push es
.endm
.macro leave
    pop es
    pop ds
    popa
    popf
    retf
.endm

extension_start:
install_trim:
    enter
    /* Replay the exact native table registration displaced by the hook. */
    push ds
    push 0x33f0
    old_call 0x256
    mov byte ptr cs:[held-segment_start], 0
    mov ax, word ptr cs:[0x3914]
    mov es, ax
    cmp byte ptr es:[0x626], 0xcb
    jne .Linstall_done
    mov dx, ax
    add ax, 0x1f31
    mov es, ax
    cmp word ptr es:[0xde4], 0x09a4
    jne .Linstall_done
    cmp word ptr es:[0xde6], dx
    jne .Linstall_done
    cmp word ptr es:[0xecc], 0x0ec0
    jne .Linstall_done
    cmp word ptr es:[0xece], dx
    jne .Linstall_done
    cmp word ptr es:[0xe60], 0xa82a
    jne .Linstall_done
    cmp word ptr es:[0xe62], dx
    jne .Linstall_done
    push cs
    push trim_events-segment_start
    old_call 0x256
.Linstall_done:
    leave

/* DS=SYS. CF clear only for the native 32-bit START/END editor with a
 * sound and nonnegative, ordered bounds inside its sample length.
 * Returns ES:BX=sound and CL=selected field. */
valid_target:
    mov cl, byte ptr [0x33b2]
    cmp cl, 2
    jb .Linvalid
    cmp cl, 3
    ja .Linvalid
    cmp byte ptr [0x8cb4], 4
    jne .Linvalid
    cmp word ptr [0x8cb6], 0x64d6
    jne .Linvalid
    mov ax, ds
    cmp word ptr [0x8cb8], ax
    jne .Linvalid
    les bx, dword ptr [0x9cae]
    mov ax, es
    or ax, bx
    jz .Linvalid
    cmp bx, 0xffdc
    ja .Linvalid
    mov ax, word ptr [0x8cbe]
    mov dx, word ptr [0x8cc0]
    test dx, 0x8000
    jnz .Linvalid
    cmp dx, word ptr es:[bx+0x1e]
    ja .Linvalid
    jb .Lmax_ok
    cmp ax, word ptr es:[bx+0x1c]
    ja .Linvalid
.Lmax_ok:
    sub ax, word ptr [0x8cba]
    sbb dx, word ptr [0x8cbc]
    jc .Linvalid
    test word ptr [0x8cbc], 0x8000
    jnz .Linvalid
    clc
    ret
.Linvalid:
    stc
    ret

after_down:
    enter
    set_ds
    call valid_target
    jc .Lafter_native
    mov byte ptr cs:[target_field-segment_start], cl
    mov word ptr cs:[target_sound-segment_start], bx
    mov word ptr cs:[target_sound-segment_start+2], es
    mov byte ptr cs:[held-segment_start], 1
    leave
.Lafter_native:
    mov byte ptr cs:[held-segment_start], 0
    pop es
    pop ds
    main_near 0x09a4
    popa
    popf
    retf

after_up:
    mov byte ptr cs:[held-segment_start], 0
    retf /* original release is the native no-op */

fader_changed:
    enter
    mov bp, ax /* panel gives AX=0..127 */
    cmp byte ptr cs:[held-segment_start], 1
    jne .Lfader_native
    cmp bp, 127
    ja .Lfader_done
    set_ds
    call valid_target
    jc .Ldisarm
    cmp cl, byte ptr cs:[target_field-segment_start]
    jne .Ldisarm
    cmp bx, word ptr cs:[target_sound-segment_start]
    jne .Ldisarm
    mov ax, es
    cmp ax, word ptr cs:[target_sound-segment_start+2]
    jne .Ldisarm
    /* min + floor((max-min)*position/127), without a 32-bit product
     * overflow. Divide range first into q*127+r, then q*p+(r*p)/127. */
    mov ax, word ptr [0x8cbe]
    mov dx, word ptr [0x8cc0]
    sub ax, word ptr [0x8cba]
    sbb dx, word ptr [0x8cbc]
    mov si, ax
    mov ax, dx
    xor dx, dx
    mov bx, 127
    div bx
    mov di, ax /* quotient high */
    mov ax, si
    div bx
    mov si, ax /* quotient low */
    mov ax, dx /* remainder */
    mul bp
    div bx
    mov cx, ax /* fractional contribution */
    mov ax, di
    mul bp
    mov di, ax
    mov ax, si
    mul bp
    add dx, di
    add ax, cx
    adc dx, 0
    add ax, word ptr [0x8cba]
    adc dx, word ptr [0x8cbc]
    mov byte ptr [0x8ca8], 0 /* end pending numeric entry */
    push dx
    push ax
    .byte 0x9a
    .word 0x2e62 /* native 32-bit value commit; RETF 4 */
native_commit_segment:
    .word 0x0b7c
.Lfader_done:
    leave
.Ldisarm:
    mov byte ptr cs:[held-segment_start], 0
.Lfader_native:
    pop es
    pop ds
    mov ax, bp
    main_near 0xa82a /* preserve ordinary NOTE VARIATION behavior */
    popa
    popf
    retf
code_end:
.balign 2
trim_events: .space 20 /* AFTER down/up, fader, terminator */
held: .byte 0
target_field: .byte 0
target_sound: .long 0
.asciz "VUBEATZ C13 TRIM AFTER FADER"
.balign 4
extension_end:

.endif /* trim_slider */
