/* Final firmware source: program transpose.
 * Assembly source sections for this feature.
 */
/* program_ui: assembly unit 2. */
.if MOD_UNIT == 2
/* MPC2000 Classic 1.72, extension C02. C01 Mute Groups stays byte-identical.
 * All new code/data is appended at SYS 0x26300 (relative segment 23B0).
 * Native far-call stubs share one MZ relocation per destination.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
.set APP_SEG, 0x23b0
.global extension_start, extension_end
.global transpose_pitch, assign_render, params_render, assign_register, params_register
.global transpose_open, transpose_draw, transpose_close, transpose_zero, transpose_changed
.global transpose_save
.global all_open, all_draw, all_apply, all_cancel
.global assign_events, params_events, transpose_events, all_events
.global transpose_value, transpose_program, all_program, all_field, all_value

.macro native target
    push cs
    call \target
.endm
.macro resource name
    push cs
    push \name - extension_start
    native draw_resource
.endm
.macro events name
    push cs
    push \name - extension_start
    native register_events
.endm
.macro stub name, seg, off
\name:
    .byte 0xea
    .word \off
.global reloc_\name
reloc_\name:
    .word \seg
.endm

extension_start:
/* Replace MOV ES,[BP+10h] / PUSH ES:[SI+0Dh] before the sole native
 * program-note pitch call. Return the transposed TUNE in AX; caller pushes
 * it. ES remains the original note-record segment. Sample TUNE, velocity,
 * native +/-360 clamp and the hardware-confirmed pitch helper stay intact.
 */
transpose_pitch:
    push bx
    push dx
    mov es, word ptr [bp+0x10]
    mov ax, word ptr es:[si+0x0d]
    push es
    push ax
    les bx, dword ptr [0x9d12]
    mov dx, es
    or dx, bx
    jz .Lpitch_neutral
    mov al, byte ptr es:[bx+0x1d]
    cmp al, 11
    jb .Lpitch_neutral
    cmp al, 59
    ja .Lpitch_neutral
    xor ah, ah
    sub ax, 35
    imul dx, ax, 10
    jmp .Lpitch_add
.Lpitch_neutral:
    xor dx, dx
.Lpitch_add:
    pop ax
    add ax, dx
    pop es
    pop dx
    pop bx
    retf

/* The original resources and tables remain in place. */
assign_render:
    push ds
    push 0x1f1e
    native draw_resource
    resource trans_button
    retf
params_render:
    push ds
    push 0x214c
    native draw_resource
    call selected_field
    or bx, bx
    jz .Lparams_render_done
    resource all_button
.Lparams_render_done:
    retf
assign_register:
    events assign_events
    retf
params_register:
    events params_events
    retf

set_ds:
    push ax
    .byte 0xb8
.global reloc_native_ds
reloc_native_ds:
    .word 0x191a
    mov ds, ax
    pop ax
    ret

transpose_open:
    pusha
    push ds
    push es
    call set_ds
    les bx, dword ptr [0x9d12]
    mov ax, es
    mov word ptr cs:[transpose_program - extension_start + 2], ax
    mov word ptr cs:[transpose_program - extension_start], bx
    or ax, bx
    jz .Ltranspose_open_done
    mov al, byte ptr es:[bx+0x1d]
    cmp al, 11
    jb .Ltranspose_default
    cmp al, 59
    jbe .Ltranspose_decode
.Ltranspose_default:
    mov al, 35
.Ltranspose_decode:
    sub al, 35
    mov byte ptr cs:[transpose_value - extension_start], al
    native stop_audition
    events transpose_events
    /* Signed-byte native editor: pointer, min, max, digits, x, y,
     * draw callback (0 = native), change callback. Callee pops 22 bytes.
     */
    push cs
    push transpose_value - extension_start
    push -24
    push 24
    push 2
    push 140
    push 25
    push 0
    push 0
    push cs
    push transpose_changed - extension_start
    native edit_signed_byte
.Ltranspose_open_done:
    pop es
    pop ds
    popa
    retf

transpose_changed:
    pusha
    push ds
    push es
    call set_ds
    les bx, dword ptr cs:[transpose_program - extension_start]
    cmp bx, word ptr [0x9d12]
    jne .Ltranspose_changed_done
    mov ax, es
    cmp ax, word ptr [0x9d14]
    jne .Ltranspose_changed_done
    or ax, bx
    jz .Ltranspose_changed_done
    mov al, byte ptr cs:[transpose_value - extension_start]
    cmp al, -24
    jl .Ltranspose_changed_done
    cmp al, 24
    jg .Ltranspose_changed_done
    add al, 35
    mov byte ptr es:[bx+0x1d], al
.Ltranspose_changed_done:
    pop es
    pop ds
    popa
    retf

transpose_zero:
    mov byte ptr cs:[transpose_value - extension_start], 0
    push cs
    call transpose_changed
    retf

transpose_draw:
    pusha
    push ds
    push es
    call set_ds
    resource trans_screen
    push 54
    push 12
    mov al, byte ptr [0x9d70]
    xor ah, ah
    inc ax
    cwd
    push dx
    push ax
    push 2
    native draw_unsigned
    native draw_editor
    pop es
    pop ds
    popa
    retf
transpose_close:
    native enter_assign
    retf

/* Native PGM writer has already copied all 30 header bytes to SS:BP-1Eh.
 * Preserve the encoded transpose instead of unconditionally writing 35.
 * Out-of-range legacy values serialize as neutral. Reproduce the displaced
 * LEA and preserve flags/registers, except AX as in the original sequence.
 */
transpose_save:
    pushf
    cmp byte ptr [bp-1], 11
    jb .Lsave_neutral
    cmp byte ptr [bp-1], 59
    jbe .Lsave_ready
.Lsave_neutral:
    mov byte ptr [bp-1], 35
.Lsave_ready:
    popf
    lea ax, [bp-0x1e]
    retf

/* Return BX = byte offset in a 29-byte note record, or zero.
 * DS:210A is the PARAMS page's selected-field index.
 */
selected_field:
    mov al, byte ptr [0x210a]
    mov bx, 0x12
    cmp al, 5
    je .Lfield_done
    inc bx
    cmp al, 6
    je .Lfield_done
    mov bx, 0x0a
    cmp al, 8
    je .Lfield_done
    xor bx, bx
.Lfield_done:
    ret

all_open:
    pusha
    push ds
    push es
    call set_ds
    call selected_field
    or bx, bx
    jz .Lall_open_done
    mov word ptr cs:[all_field - extension_start], bx
    mov di, bx
    mov al, byte ptr [0x8ce0]
    sub al, 35
    cmp al, 63
    ja .Lall_open_done
    xor ah, ah
    imul si, ax, 29
    les bx, dword ptr [0x9d12]
    mov ax, es
    mov word ptr cs:[all_program - extension_start + 2], ax
    mov word ptr cs:[all_program - extension_start], bx
    or ax, bx
    jz .Lall_open_done
    add si, bx
    add si, di
    mov al, byte ptr es:[si+0x1e]
    mov byte ptr cs:[all_value - extension_start], al
    native stop_audition
    events all_events
    native disable_edit
.Lall_open_done:
    pop es
    pop ds
    popa
    retf

all_draw:
    pusha
    push ds
    push es
    call set_ds
    resource all_screen
    mov ax, word ptr cs:[all_field - extension_start]
    cmp ax, 0x12
    je .Ldraw_freq
    cmp ax, 0x13
    je .Ldraw_reson
    resource voice_caption
    jmp .Lall_draw_done
.Ldraw_freq:
    resource freq_caption
    jmp .Lall_draw_done
.Ldraw_reson:
    resource reson_caption
.Lall_draw_done:
    pop es
    pop ds
    popa
    retf

all_apply:
    pusha
    push ds
    push es
    call set_ds
    mov di, word ptr cs:[all_field - extension_start]
    cmp di, 0x12
    je .Lapply_valid
    cmp di, 0x13
    je .Lapply_valid
    cmp di, 0x0a
    jne .Lapply_done
.Lapply_valid:
    /* Refuse to write if the active program changed while confirming. */
    mov bx, word ptr cs:[all_program - extension_start]
    cmp bx, word ptr [0x9d12]
    jne .Lapply_done
    mov ax, word ptr cs:[all_program - extension_start + 2]
    cmp ax, word ptr [0x9d14]
    jne .Lapply_done
    mov es, ax
    or ax, bx
    jz .Lapply_done
    add di, bx
    add di, 0x1e
    mov al, byte ptr cs:[all_value - extension_start]
    mov cx, 64
.Lapply_loop:
    mov byte ptr es:[di], al
    add di, 29
    loop .Lapply_loop
.Lapply_done:
    pop es
    pop ds
    popa
    native enter_params
    retf
all_cancel:
    native enter_params
    retf

/* Far-jump adapters: PUSH CS/CALL supplies the native RETF frame. */
stub draw_resource,    0x0000, 0x1e0e
stub register_events,  0x0000, 0x1ede
stub edit_signed_byte, 0x0b7c, 0x337c
stub draw_unsigned,    0x0b7c, 0x01e0
stub draw_editor,      0x0b7c, 0x2df0
stub disable_edit,     0x0b7c, 0x2dae
stub stop_audition,    0x0b7c, 0x62c4
stub enter_assign,     0x0000, 0x5478
stub enter_params,     0x0000, 0x5b40

/* Native LCD command streams: F5 was empty on both original pages. */
trans_button:
    .byte 0x1a,5,1
    .asciz "TRANS"
    .byte 0
all_button:
    .byte 0x1a,5,1
    .asciz "ALL"
    .byte 0
trans_screen:
    .byte 0x22,12,2,224,58
    .asciz "Transpose Program"
    .byte 0x1a,4,2
    .asciz "CLOSE"
    .byte 0x1a,5,1
    .asciz "ZERO"
    .byte 0x1a,6,1
    .asciz "PLAY"
    .byte 2,7,24,12
    .asciz "Pgm:"
    .byte 7,50,25
    .asciz "Transpose:"
    .byte 7,32,38
    .asciz "Whole program (-24..+24)"
    .byte 0
all_screen:
    .byte 0x22,12,2,224,58
    .asciz "Apply to all pads"
    .byte 0x1a,4,2
    .asciz "CANCEL"
    .byte 0x1a,5,1
    .asciz "DO IT"
    .byte 2,7,38,28
    .asciz "Apply to all 64 notes?"
    .byte 7,38,40
    .asciz "Only this parameter."
    .byte 0
freq_caption:
    .byte 7,38,16
    .asciz "Filter frequency"
    .byte 0
reson_caption:
    .byte 7,38,16
    .asciz "Filter resonance"
    .byte 0
voice_caption:
    .byte 7,38,16
    .asciz "Voice overlap"
    .byte 0
.balign 2,0
transpose_program: .long 0
all_program:       .long 0
all_field:         .word 0
transpose_value:   .byte 0
all_value:         .byte 0
/* Filled by the builder, including relocated far pointers. */
assign_events:     .space 75,0
params_events:     .space 75,0
transpose_events:  .space 45,0
all_events:        .space 30,0
    .asciz "VUBEATZ MPC2000 FULL MODS C02"
.balign 16,0
extension_end:

.endif /* program_ui */
/* program_transpose: assembly unit 10. */
.if MOD_UNIT == 10
/* C08 R1: append TRANS -36..+36 to the exact C08.
 * Shared C02 CS/state, existing signed-number renderer from C07 R1.
 * Program byte +1D keeps semitones+35: old -24..+24 values are unchanged;
 * the new -36 endpoint is FF, decoded explicitly before multiplication.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
segment_start:
.org 0x5390
.global extension_start, extension_end, decode_transpose
.global transpose_pitch, transpose_open, transpose_changed, transpose_save
.global transpose_screen
.macro old_call offset
    push cs
    .byte 0xe8
    .word \offset - (. - segment_start + 2)
.endm
.macro set_ds
    .byte 0xe8
    .word 0x6f - (. - segment_start + 2)
.endm
extension_start:
/* AL encoded program byte -> AX signed semitones. Invalid = neutral.
 * This exact decoder is shared by playback, the editor and PGM save. */
decode_transpose:
    cmp al, 0xff
    je .Lminus36
    cmp al, 71
    ja .Lneutral
    xor ah, ah
    sub ax, 35
    ret
.Lminus36:
    mov ax, -36
    ret
.Lneutral:
    xor ax, ax
    ret

transpose_pitch:
    push bx
    push dx
    mov es, word ptr [bp+0x10]
    mov ax, word ptr es:[si+0x0d]
    push es
    push ax
    les bx, dword ptr [0x9d12]
    mov dx, es
    or dx, bx
    jz .Lpitch_neutral
    mov al, byte ptr es:[bx+0x1d]
    call decode_transpose
    imul dx, ax, 10
    jmp .Lpitch_add
.Lpitch_neutral:
    xor dx, dx
.Lpitch_add:
    pop ax
    add ax, dx
    pop es
    pop dx
    pop bx
    retf

transpose_open:
    pusha
    push ds
    push es
    set_ds
    les bx, dword ptr [0x9d12]
    mov ax, es
    mov word ptr cs:[0x390], ax
    mov word ptr cs:[0x38e], bx
    or ax, bx
    jz .Lopen_done
    mov al, byte ptr es:[bx+0x1d]
    call decode_transpose
    mov byte ptr cs:[0x398], al
    old_call 0x26f /* stop_audition */
    push cs
    push 0x430 /* original transpose_events, including ZERO and PLAY */
    old_call 0x256
    push cs
    push 0x398
    push -36
    push 36
    push 2
    push 140
    push 25
    push 0
    push 0
    push cs
    push 0xcf /* old callback entry redirects to transpose_changed */
    old_call 0x25b /* native signed-byte editor, RETF 22 */
.Lopen_done:
    pop es
    pop ds
    popa
    retf

transpose_changed:
    pusha
    push ds
    push es
    set_ds
    les bx, dword ptr cs:[0x38e]
    cmp bx, word ptr [0x9d12]
    jne .Lchanged_done
    mov ax, es
    cmp ax, word ptr [0x9d14]
    jne .Lchanged_done
    or ax, bx
    jz .Lchanged_done
    mov al, byte ptr cs:[0x398]
    cmp al, -36
    jl .Lchanged_done
    cmp al, 36
    jg .Lchanged_done
    add al, 35 /* -36 wraps to FF; other values become 00..47 */
    mov byte ptr es:[bx+0x1d], al
.Lchanged_done:
    pop es
    pop ds
    popa
    retf

/* PGM writer's stack-local header byte. Keep all valid old/new encodings;
 * invalid bytes serialize as neutral, just as before. Preserve native ABI. */
transpose_save:
    pushf
    push ax
    mov al, byte ptr [bp-1]
    call decode_transpose
    add al, 35
    mov byte ptr [bp-1], al
    pop ax
    popf
    lea ax, [bp-0x1e]
    retf

transpose_screen:
    .byte 0x22,12,2,224,58
    .asciz "Transpose Program"
    .byte 0x1a,4,2
    .asciz "CLOSE"
    .byte 0x1a,5,1
    .asciz "ZERO"
    .byte 0x1a,6,1
    .asciz "PLAY"
    .byte 2,7,24,12
    .asciz "Pgm:"
    .byte 7,50,25
    .asciz "Transpose:"
    .byte 7,32,38
    .asciz "Whole program (-36..+36)"
    .byte 0
    .asciz "VUBEATZ MPC2000 C08 R1 TRANS36"
.balign 4,0
extension_end:

.endif /* program_transpose */
/* xl_program_parameters: section 2. */
.if MOD_UNIT == 23
.if MOD_PART == 1
/* Program byte +1D -> signed semitones. Same encoding as Classic C08 R1. */
decode_transpose:
    cmp al,0xff
    je .Lminus36
    cmp al,71
    ja .Lneutral
    xor ah,ah
    sub ax,35
    ret
.Lminus36:
    mov ax,-36
    ret
.Lneutral:
    xor ax,ax
    ret

/* The native playback caller supplies the actual DRUM's program at SS:BP+0A.
 * Do NOT resolve the program selected for editing here (native multitimbrality).
 */
pitch_playback:
    push bx
    push es
    les bx,dword ptr [bp+0x0a]
    mov al,byte ptr es:[bx+0x1d]
    call decode_transpose
    imul ax,ax,10
    add si,ax
    pop es
    pop bx
    call pitch_lookup
    farjump 0x35b0,0x306f

/* SI=pitch in tenths of a semitone; AX=DSP ratio, 0x1000=unity.
 * Preserve all other registers except SI, which native playback consumes.
 * Use only the ORIGINAL 481 words. Extend by one octave, never index outside.
 */

.endif
.endif
/* xl_program_parameters: section 4. */
.if MOD_UNIT == 23
.if MOD_PART == 3
transpose_edit:
    save
    mov word ptr [0x8d5e],11
    call get_program
    jc .Ledit_done
    mov word ptr cs:[transpose_program-segment_start],bx
    mov word ptr cs:[transpose_program-segment_start+2],es
    mov al,byte ptr es:[bx+0x1d]
    call decode_transpose
    mov byte ptr cs:[transpose_value-segment_start],al
    push cs
    push transpose_value-segment_start
    push cs
    push transpose_descriptor-segment_start
    farcall 0x35b0,0x62be
    add sp,8
.Ledit_done:
    restore
    retf

transpose_changed:
    save
    call get_program
    jc .Lchanged_done
    cmp bx,word ptr cs:[transpose_program-segment_start]
    jne .Lchanged_done
    mov ax,es
    cmp ax,word ptr cs:[transpose_program-segment_start+2]
    jne .Lchanged_done
    mov al,byte ptr cs:[transpose_value-segment_start]
    cmp al,-36
    jl .Lchanged_done
    cmp al,36
    jg .Lchanged_done
    add al,35
    mov byte ptr es:[bx+0x1d],al
.Lchanged_done:
    restore
    retf

transpose_draw:
    save
    push cs
    push transpose_label-segment_start
    push 31
    push 9
    farcall 0x3e19,0x0988
    add sp,8
    call get_program
    jc .Ldraw_done
    mov al,byte ptr es:[bx+0x1d]
    call decode_transpose
    cwd
    push 2
    push dx
    push ax
    push 31
    push 69
    farcall 0x3e19,0x09ee
    add sp,10
    farcall 0x3e19,0x9e5a
.Ldraw_done:
    restore
    retf
transpose_program: .long 0
transpose_value: .byte 0

/* Filter/Voice callbacks draw the native window, then its ALL softkey. */

.endif
.endif
/* xl_program_parameters: section 6. */
.if MOD_UNIT == 23
.if MOD_PART == 5
.global assign_dispatch, assign_window, transpose_descriptor, mute_label, mute_trigger
assign_dispatch:
    cmp word ptr [0x8d5e],11
    je transpose_edit
    imul bx,word ptr [0x8d5e],42
    call far ptr [bx+0x2c9c]
    retf
assign_window:
    push ds
    mov cx,0x582b
    mov ds,cx
    cmp word ptr [0x8d5e],11
    je .Lno_transpose_window
    farjump 0x3e19,0xff76 /* stock 4E106 */
.Lno_transpose_window:
    pop ds
    retf
transpose_label: .asciz "Transpose:"
.balign 2,0
transpose_descriptor:
    .byte 69,31,18,3,1,0x80
    .long -36,36
    .word transpose_edit-segment_start,MOD_CS
    .word 0x0162,0x4e16 /* up: note */
    .word 0x0252,0x4e16 /* down: layer field */
    .long 0
    .word 0x02c8,0x4e16 /* right: mode */
    .word transpose_changed-segment_start,MOD_CS
    .long 0

/* Native modes 0..3 and additional MUTE 1..4 share the original note byte. */

.endif
.endif
