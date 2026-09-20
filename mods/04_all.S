/* Final firmware source: all.
 * Assembly source sections for this feature.
 */
/* parameter_copy: assembly unit 9. */
.if MOD_UNIT == 9
/* C08: shared PARAMS ALL modal. Appended after the complete C07 R1 SYS.
 * CS is the existing C02 extension segment (MZ 23B0, loaded 53B0).
 * No firmware code/data caves; only the two caller IPs are redirected.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
segment_start:
.org 0x4fc4
.global extension_start, extension_end, params_render, all_open
.global all_draw, all_bank, all_program, all_cancel, all_events
.global descriptors, descriptors_end, all_active, saved_descriptor
.global saved_program, saved_value, saved_bank, bank_notes

.macro old_call offset
    push cs
    .byte 0xe8
    .word \offset - (. - segment_start + 2)
.endm
.macro native target
    push cs
    call \target
.endm
.macro resource name
    push cs
    push \name - segment_start
    old_call 0x251 /* C02 draw_resource */
.endm
.macro set_ds
    .byte 0xe8
    .word 0x6f - (. - segment_start + 2)
.endm

extension_start:
params_render:
    pusha
    push ds
    push es
    set_ds
    push ds
    push 0x214c
    old_call 0x251
    mov al, byte ptr [0x210a]
    call find_descriptor
    jc .Lrender_done
    resource all_button
.Lrender_done:
    pop es
    pop ds
    popa
    retf

/* AL = page selection; SI = immutable descriptor, CF = not supported.
 * Descriptor: selector:u8, note offset:u8, width:u8, reserved:u8,
 *             min:i16, max:i16, LCD caption offset:u16.
 * One list drives button visibility, validation, rendering and copying.
 */
find_descriptor:
    mov si, descriptors - segment_start
.Lfind_loop:
    cmp al, byte ptr cs:[si]
    je .Lfound
    add si, 10
    cmp si, descriptors_end - segment_start
    jb .Lfind_loop
    stc
    ret
.Lfound:
    clc
    ret

/* DS = native SYS data; output ES:BX = currently allocated program.
 * Native layout: 30-byte header, 64 records of 29 bytes. */
get_program:
    les bx, dword ptr [0x9d12]
    mov ax, es
    or ax, bx
    jz .Lprogram_bad
    cmp bx, 0xf8a2 /* final record must not wrap the 16-bit offset */
    ja .Lprogram_bad
    cmp word ptr es:[bx], 2 /* native empty/deleted program sentinel */
    jbe .Lprogram_bad
    clc
    ret
.Lprogram_bad:
    stc
    ret

all_open:
    pusha
    push ds
    push es
    set_ds
    mov byte ptr cs:[all_active - segment_start], 0
    mov al, byte ptr [0x210a]
    call find_descriptor
    jc .Lopen_done
    mov word ptr cs:[saved_descriptor - segment_start], si
    call get_program
    jc .Lopen_done
    mov word ptr cs:[saved_program - segment_start], bx
    mov word ptr cs:[saved_program - segment_start+2], es
    mov al, byte ptr [0x8ce0] /* selected note, not selected pad */
    sub al, 35
    cmp al, 63
    ja .Lopen_done
    xor ah, ah
    imul di, ax, 29
    xor ax, ax
    mov al, byte ptr cs:[si+1]
    add di, ax
    add di, bx
    xor ax, ax
    mov al, byte ptr es:[di+0x1e]
    cmp byte ptr cs:[si+2], 2
    jne .Lsource_ready
    mov ax, word ptr es:[di+0x1e]
.Lsource_ready:
    cmp ax, word ptr cs:[si+4]
    jl .Lopen_done
    cmp ax, word ptr cs:[si+6]
    jg .Lopen_done
    mov word ptr cs:[saved_value - segment_start], ax
    /* INT 37 is the native bank getter, returning 0..3 (SYS 0000:1F04).
     * Snapshot it and the effective map (program or MASTER), so a bank
     * key press during confirmation cannot change the displayed target. */
    int 0x37
    cmp al, 3
    ja .Lopen_done
    mov byte ptr cs:[saved_bank - segment_start], al
    add al, 'A'
    mov byte ptr cs:[bank_letter - segment_start], al
    mov al, byte ptr cs:[saved_bank - segment_start]
    xor ah, ah
    shl ax, 4
    les bx, dword ptr [0x9d16]
    mov dx, es
    or dx, bx
    jz .Lopen_done
    cmp bx, 0xffc0
    ja .Lopen_done
    add bx, ax
    mov di, bank_notes - segment_start
    mov cx, 16
.Lsnapshot_map:
    mov al, byte ptr es:[bx]
    mov byte ptr cs:[di], al
    inc bx
    inc di
    loop .Lsnapshot_map
    old_call 0x26f /* stop_audition */
    mov byte ptr cs:[all_active - segment_start], 1
    push cs
    push all_events - segment_start
    old_call 0x256 /* register_events */
    old_call 0x26a /* disable_edit: digits/wheel cannot edit behind modal */
.Lopen_done:
    pop es
    pop ds
    popa
    retf

all_draw:
    pusha
    push ds
    push es
    set_ds
    resource all_screen
    mov si, word ptr cs:[saved_descriptor - segment_start]
    /* Table address was resolved by all_open, never supplied by the user. */
    push cs
    push word ptr cs:[si+8]
    old_call 0x251
    pop es
    pop ds
    popa
    retf

/* Scope adapters preserve caller AX. All mutation lives in apply_scope. */
all_bank:
    push ax
    xor ax, ax
    call apply_scope
    pop ax
    old_call 0x279 /* native enter_params */
    retf
all_program:
    push ax
    mov ax, 1
    call apply_scope
    pop ax
    old_call 0x279
    retf

apply_scope:
    pusha
    push ds
    push es
    set_ds
    mov bp, ax /* zero = bank, one = all 64 program note records */
    cmp byte ptr cs:[all_active - segment_start], 1
    jne .Lapply_done
    mov byte ptr cs:[all_active - segment_start], 0 /* consume confirmation once */
    mov si, word ptr cs:[saved_descriptor - segment_start]
    /* Resolve the saved selector again; reject a changed/invalid address. */
    cmp si, descriptors - segment_start
    jb .Lapply_done
    cmp si, descriptors_end - segment_start
    jae .Lapply_done
    mov dx, si
    mov al, byte ptr cs:[si]
    call find_descriptor
    jc .Lapply_done
    cmp si, dx
    jne .Lapply_done
    call get_program
    jc .Lapply_done
    cmp bx, word ptr cs:[saved_program - segment_start]
    jne .Lapply_done
    mov ax, es
    cmp ax, word ptr cs:[saved_program - segment_start+2]
    jne .Lapply_done
    mov ax, word ptr cs:[saved_value - segment_start]
    cmp ax, word ptr cs:[si+4]
    jl .Lapply_done
    cmp ax, word ptr cs:[si+6]
    jg .Lapply_done
    xor ax, ax
    mov al, byte ptr cs:[si+1]
    add bx, ax
    add bx, 0x1e
    mov dx, word ptr cs:[saved_value - segment_start]
    mov cx, 64
    or bp, bp
    jnz .Lprogram_loop_start
    cmp byte ptr cs:[saved_bank - segment_start], 3
    ja .Lapply_done
    mov cx, 16
    xor di, di
.Lbank_loop:
    mov al, byte ptr cs:[bank_notes - segment_start+di]
    inc di
    sub al, 35
    cmp al, 63
    ja .Lbank_next /* OFF (34), and any out-of-range map entries */
    xor ah, ah
    imul bp, ax, 29
    add bp, bx
    call write_value
.Lbank_next:
    loop .Lbank_loop
    jmp .Lapply_done
.Lprogram_loop_start:
    mov bp, bx
.Lprogram_loop:
    call write_value
    add bp, 29
    loop .Lprogram_loop
.Lapply_done:
    pop es
    pop ds
    popa
    ret

/* ES:BP = one validated note field, DX = value, SI = descriptor.
 * Do not overwrite the adjacent field when copying a byte parameter. */
write_value:
    cmp byte ptr cs:[si+2], 2
    je .Lwrite_word
    mov byte ptr es:[bp], dl
    ret
.Lwrite_word:
    mov word ptr es:[bp], dx
    ret

all_cancel:
    mov byte ptr cs:[all_active - segment_start], 0
    old_call 0x279
    retf

all_button:
    .byte 0x1a,5,1
    .asciz "ALL"
    .byte 0
all_screen:
    .byte 0x22,12,2,224,58
    .asciz "ALL FOR:"
    .byte 0x1a,4,2
    .asciz "CANCEL"
    .byte 0x1a,5,1
    .asciz "BANK"
    .byte 0x1a,6,1
    .asciz "PROGRAM"
    .byte 2,7,28,28
    .ascii "Current bank: "
bank_letter:
    .asciz "A"
    .byte 7,28,40
    .asciz "Copy selected value to:"
    .byte 0
.macro caption label, text
\label:
    .byte 7,28,16
    .asciz "\text"
    .byte 0
.endm
caption attack_caption, "Parameter: ATTACK"
caption decay_caption, "Parameter: DECAY"
caption decay_mode_caption, "Parameter: DECAY MODE"
caption freq_caption, "Parameter: FREQ"
caption reson_caption, "Parameter: RESON"
caption tune_caption, "Parameter: TUNE"
caption voice_caption, "Parameter: VOICE OVERLAP"
.balign 2,0
descriptors:
.macro descriptor selector, field, width, low, high, title
    .byte \selector, \field, \width, 0
    .word \low, \high, \title - segment_start
.endm
    descriptor 1, 0x0f, 1,    0, 100, attack_caption
    descriptor 2, 0x10, 1,    0, 100, decay_caption
    descriptor 3, 0x11, 1,    0,   1, decay_mode_caption
    descriptor 5, 0x12, 1,    0, 100, freq_caption
    descriptor 6, 0x13, 1,    0,  15, reson_caption
    descriptor 7, 0x0d, 2, -360, 360, tune_caption
    descriptor 8, 0x0a, 1,    0,   2, voice_caption
descriptors_end:
saved_descriptor: .word 0
saved_program:    .long 0
saved_value:      .word 0
saved_bank:       .byte 0
all_active:       .byte 0
bank_notes:       .space 16,0
/* The builder fills the native five-byte event entries and relocations. */
all_events:       .space 35,0
    .asciz "VUBEATZ MPC2000 C08 ALL BANK PROGRAM"
.balign 4,0
extension_end:

.endif /* parameter_copy */
/* xl_program_parameters: section 5. */
.if MOD_UNIT == 23
.if MOD_PART == 4
.global child_draw
child_draw:
    save
    cmp word ptr [0x8d66],8
    je .Lvoice_window
    farcall 0x4e16,0x1f3a
    jmp .Lchild_button
.Lvoice_window:
    farcall 0x4e16,0x2614
.Lchild_button:
    resource child_button
    restore
    retf
child_button:
    .byte 0x1a,3,1
    .asciz "ALL"
    .byte 0
/* Overlay F2 only while an editable note field is selected. AUTO stays F5. */
.global params_draw
params_draw:
    save
    farcall 0x4e16,0x0606
    mov ax,word ptr [0x8d66]
    call find_descriptor
    jc .Lparams_done
    resource main_button
.Lparams_done:
    restore
    retf
main_button:
    .byte 0x1a,2,1
    .asciz "ALL"
    .byte 0
block1_end:

/* Common ALL implementation follows the editor helpers. */
.balign 2,0
.global block2_start, block2_end, all_open, all_draw, all_bank, all_program, all_cancel
block2_start:
/* AX=main PARAMS selector. SI=immutable descriptor, CF=invalid. */
find_descriptor:
    sub ax,2
    cmp ax,6
    ja .Ldescriptor_bad
    shl ax,3
    mov si,descriptors-segment_start
    add si,ax
    clc
    ret
.Ldescriptor_bad:
    stc
    ret

all_open:
    save
    mov byte ptr cs:[all_active-segment_start],0
    mov ax,word ptr [0x8d66]
    mov word ptr cs:[saved_selector-segment_start],ax
    call find_descriptor
    jc .Lopen_done
    call get_program
    jc .Lopen_done
    mov word ptr cs:[saved_program-segment_start],bx
    mov word ptr cs:[saved_program-segment_start+2],es
    mov al,byte ptr [0xd7c0]
    sub al,35
    cmp al,63
    ja .Lopen_done
    xor ah,ah
    imul di,ax,24
    xor ax,ax
    mov al,byte ptr cs:[si]
    add di,ax
    add di,bx
    xor ax,ax
    mov al,byte ptr es:[di+0x1e]
    cmp byte ptr cs:[si+1],2
    jne .Lsource_ready
    mov ax,word ptr es:[di+0x1e]
.Lsource_ready:
    cmp ax,word ptr cs:[si+2]
    jl .Lopen_done
    cmp ax,word ptr cs:[si+4]
    jg .Lopen_done
    mov word ptr cs:[saved_value-segment_start],ax
    farcall 0x3e19,0x0752 /* native bank getter, INT37 + zero extend AL */
    cmp ax,3
    ja .Lopen_done
    mov byte ptr cs:[saved_bank-segment_start],al
    add al,'A'
    mov byte ptr cs:[bank_letter-segment_start],al
    mov al,byte ptr [0xd7be]
    xor ah,ah
    add ax,0x60 /* native effective pad map (PROGRAM or MASTER) */
    push ax
    farcall 0x35b0,0x0418
    add sp,2
    mov bx,ax
    mov es,dx
    or ax,dx
    jz .Lopen_done
    cmp bx,0xffc0
    ja .Lopen_done
    mov al,byte ptr cs:[saved_bank-segment_start]
    xor ah,ah
    shl ax,4
    add bx,ax
    mov di,bank_notes-segment_start
    mov cx,16
.Lsnapshot:
    mov al,byte ptr es:[bx]
    mov byte ptr cs:[di],al
    inc bx
    inc di
    loop .Lsnapshot
    farcall 0x4e16,0x086c /* stop audition and disable native pad callback */
    mov byte ptr cs:[all_active-segment_start],1
    push cs
    push all_events-segment_start
    farcall 0x3e19,0x0724
    add sp,4
    /* Event 1 in all_events already clears editors and old callbacks.
     * INT A4 here would erase the newly installed modal handlers. */
    push cs
    call all_draw
.Lopen_done:
    restore
    retf

all_draw:
    save
    resource all_screen
    mov ax,word ptr cs:[saved_selector-segment_start]
    call find_descriptor
    jc .Lall_draw_done
    push cs
    push word ptr cs:[si+6]
    farcall 0x3e19,0x0662
    add sp,4
.Lall_draw_done:
    restore
    retf

all_bank:
    push ax
    xor ax,ax
    call apply_scope
    pop ax
    jmp all_cancel
all_program:
    push ax
    mov ax,1
    call apply_scope
    pop ax
    jmp all_cancel

apply_scope:
    save
    mov bp,ax /* 0=bank, 1=program */
    cmp byte ptr cs:[all_active-segment_start],1
    jne .Lapply_done
    mov byte ptr cs:[all_active-segment_start],0
    mov ax,word ptr cs:[saved_selector-segment_start]
    call find_descriptor
    jc .Lapply_done
    call get_program
    jc .Lapply_done
    cmp bx,word ptr cs:[saved_program-segment_start]
    jne .Lapply_done
    mov ax,es
    cmp ax,word ptr cs:[saved_program-segment_start+2]
    jne .Lapply_done
    mov dx,word ptr cs:[saved_value-segment_start]
    cmp dx,word ptr cs:[si+2]
    jl .Lapply_done
    cmp dx,word ptr cs:[si+4]
    jg .Lapply_done
    xor ax,ax
    mov al,byte ptr cs:[si]
    add bx,ax
    add bx,0x1e
    mov cx,64
    or bp,bp
    jnz .Lprogram_start
    mov cx,16
    xor di,di
.Lbank_loop:
    mov al,byte ptr cs:[bank_notes-segment_start+di]
    inc di
    sub al,35
    cmp al,63
    ja .Lbank_next /* OFF (34) and invalid pad mappings do not write */
    xor ah,ah
    imul bp,ax,24
    add bp,bx
    call write_value
.Lbank_next:
    loop .Lbank_loop
    jmp .Lapply_done
.Lprogram_start:
    mov bp,bx
.Lprogram_loop:
    call write_value
    add bp,24
    loop .Lprogram_loop
.Lapply_done:
    restore
    ret
write_value:
    cmp byte ptr cs:[si+1],2
    je .Lword
    mov byte ptr es:[bp],dl
    ret
.Lword:
    mov word ptr es:[bp],dx
    ret

all_cancel:
    save
    mov byte ptr cs:[all_active-segment_start],0
    farcall 0x4e16,0x055a /* re-enter PARAMS with original selection */
    restore
    retf

/* LCD captions are resources; descriptor drives both validation and label. */
.macro caption name, text
\name:
    .byte 2,7,28,16
    .asciz "Parameter: \text"
    .byte 0
.endm
caption attack_caption,"ATTACK"
caption decay_caption,"DECAY"
caption mode_caption,"DECAY MODE"
caption freq_caption,"FREQ"
caption reson_caption,"RESON"
caption tune_caption,"TUNE"
caption voice_caption,"VOICE OVERLAP"
.global descriptors, descriptors_end
.balign 2,0
descriptors:
.macro descriptor field,width,lo,hi,title
    .byte \field,\width
    .word \lo,\hi,\title-segment_start
.endm
    descriptor 0x0a,1,0,100,attack_caption
    descriptor 0x0b,1,0,100,decay_caption
    descriptor 0x0c,1,0,1,mode_caption
    descriptor 0x0d,1,0,100,freq_caption
    descriptor 0x0e,1,0,15,reson_caption
    descriptor 0x08,2,-360,360,tune_caption
    descriptor 0x05,1,0,2,voice_caption
descriptors_end:
block2_end:

.global block4_start,block4_end,all_screen,bank_letter,all_events
.global all_active,saved_selector,saved_program,saved_value,saved_bank,bank_notes
block4_start:
all_screen:
    /* Clear bottom planes BEFORE drawing the same native frame as TUNE. */
    .byte 2,0x13,0,51,248,9,3,0x13,0,51,248,9,4,0x13,0,51,248,9
    .byte 2,0x22,12,2,224,58
    .asciz "ALL FOR:"
    .byte 0x1a,2,2
    .asciz "CANCEL"
    .byte 0x1a,4,1
    .asciz "BANK"
    /* Seven-letter PROGRAM must not index the native 0..6 char centering table. */
    .byte 4,0x13,165,51,45,9,0x11,165,51,45,9
    .byte 2,0x13,165,51,45,9,7,167,52
    .asciz "PROGRAM"
    .byte 7,28,28
    .ascii "Current bank: "
bank_letter:
    .asciz "A"
    .byte 0
.balign 2,0
saved_selector: .word 0
saved_program: .long 0
saved_value: .word 0
saved_bank: .byte 0
all_active: .byte 0
bank_notes: .space 16,0
.macro event key,target
    .byte \key
    .word \target-segment_start,MOD_CS
.endm
all_events:
    .byte 1
    .long 0
    event 0x32,all_draw
    event 3,all_cancel
    event 5,all_bank
    event 6,all_program
    event 0x15,all_cancel
    .byte 0
block4_end:

/* Keep the native ASSIGN event table and preview flag in their stock slots.
 * Only the new twelfth descriptor lives here. All dispatch sites share this
 * wrapper so pad changes and editor refreshes cannot index past native fields.
 */

.endif
.endif
