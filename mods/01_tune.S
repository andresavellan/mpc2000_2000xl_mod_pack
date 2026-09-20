/* Final firmware source: tune.
 * Assembly source sections for this feature.
 */
/* pitch_lookup: assembly unit 6. */
.if MOD_UNIT == 6
/* C06: move the existing SI pitch helper out of PURGE into an appended CS.
 * DS continues to address the native table; no CS-relative data references.
 * Same three paths and flags as the original Candidate 11 helper.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
.global pitch_helper, pitch_low, pitch_high, pitch_done, payload_end
pitch_helper:
    cmp si, -240
    jl pitch_low
    cmp si, 240
    jg pitch_high
    add si, si
    mov ax, [si+0x07f8]
    retf
pitch_low:
    add si, 120
    add si, si
    mov ax, [si+0x07f8]
    shr ax, 1
    retf
pitch_high:
    sub si, 120
    add si, si
    mov ax, [si+0x07f8]
    shl ax, 1
    jns pitch_done
    mov ax, 0x7fff
pitch_done:
    retf
payload_end:

.endif /* pitch_lookup */
/* xl_program_parameters: section 1. */
.if MOD_UNIT == 23
.if MOD_PART == 0
/* MPC2000XL extension. Assembled at the end of the OS image, CS=7700.
 * PARAMS/pitch code derives from our parity implementation; no SDS storage. */
.intel_syntax noprefix
.code16
.arch i186
.text
segment_start:
.macro farcall seg, off
    .byte 0x9a
    .word \off, \seg
.endm
.macro farjump seg, off
    .byte 0xea
    .word \off, \seg
.endm
.macro set_ds
    push 0x582b
    pop ds
.endm
.macro save
    pusha
    push ds
    push es
    set_ds
.endm
.macro restore
    pop es
    pop ds
    popa
.endm
.macro resource label
    push cs
    push \label - segment_start
    farcall 0x3e19,0x0662
    add sp,4
.endm

.equ MOD_CS, 0x7700
.org 0
.global block1_start, block1_end, decode_transpose, pitch_playback, pitch_lookup
.global transpose_edit, transpose_draw, transpose_changed, tempo_lookup
block1_start:

.endif
.endif
/* xl_program_parameters: section 3. */
.if MOD_UNIT == 23
.if MOD_PART == 2
pitch_lookup:
    cmp si,-360
    jge .Lmin_ok
    mov si,-360
.Lmin_ok:
    cmp si,360
    jle .Lmax_ok
    mov si,360
.Lmax_ok:
    cmp si,-240
    jl .Llow
    cmp si,240
    jg .Lhigh
    add si,si
    mov ax,word ptr [si+0x236]
    ret
.Llow:
    add si,120
    add si,si
    mov ax,word ptr [si+0x236]
    shr ax,1
    ret
.Lhigh:
    sub si,120
    add si,si
    mov ax,word ptr [si+0x236]
    shl ax,1
    cmp ax,0x7fff
    jbe .Lratio_done
    mov ax,0x7fff
.Lratio_done:
    ret

/* Tempo estimate calls also use the same bounded pitch lookup. */
tempo_lookup:
    push si
    mov si,word ptr [bp+0x0c]
    call pitch_lookup
    pop si
    retf

/* DS=582B; selected DRUM 0..3 -> validated program ES:BX. */
get_program:
    mov al,byte ptr [0xd7be]
    cmp al,3
    ja .Lbad_program
    xor ah,ah
    add ax,0x5c
    push ax
    farcall 0x35b0,0x0418
    add sp,2
    mov bx,ax
    mov es,dx
    or ax,dx
    jz .Lbad_program
    cmp bx,0xf9e2 /* 30-byte header + 64*24-byte records must not wrap */
    ja .Lbad_program
    cmp word ptr es:[bx],0x1e
    jb .Lbad_program
    clc
    ret
.Lbad_program:
    stc
    ret


.endif
.endif
