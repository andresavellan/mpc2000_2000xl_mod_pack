.if MOD_UNIT == 1

.intel_syntax noprefix
.code16
.arch i186
.text
.global mute_on_note, navigation_mode, mode_label, mode_labels
.global stop_voice_segment, payload_end

mute_on_note:
    pusha
    push     es
    mov      dl, byte ptr es:[bx+5]
    cmp      dl, 4
    jb       .Ldone
    cmp      dl, 7
    ja       .Ldone
    xor      si, si
    mov      di, 0x9a6e

.Lvoice:
    mov      al, byte ptr [di]
    cmp      al, 35
    jb       .Lnext
    cmp      al, 98
    ja       .Lnext
    xor      ah, ah
    cmp      ax, word ptr [bp-8]
    je       .Lnext
    imul     bx, ax, 29
    add      bx, word ptr [0x9d12]
    sub      bx, 0x03d9
    mov      ax, word ptr [0x9d14]
    mov      es, ax
    cmp      byte ptr es:[bx+5], dl
    jne      .Lnext
    push     si

    .byte    0x9a
    .word    0x2810

stop_voice_segment:
    .word    0x0b7c

.Lnext:
    add      di, 18
    inc      si
    cmp      si, 32
    jb       .Lvoice

.Ldone:
    pop      es
    popa
    cmp      byte ptr es:[bx+5], 2
    retf

navigation_mode:
    pushf
    mov      al, byte ptr es:[bx+5]
    cmp      al, 3
    jbe      .Loriginal_mode
    xor      al, al

.Loriginal_mode:
    cbw
    popf
    retf

mode_label:
    xor      ah, ah
    cmp      al, 7
    jbe      .Lvalid_label
    xor      ax, ax

.Lvalid_label:
    imul     ax, ax, 7
    add      ax, mode_labels - mute_on_note
    mov      dx, cs
    retf

mode_labels:
    .asciz   "NORMAL", "SIMULT", "VEL SW", "DCY SW"
    .asciz   "MUTE 1", "MUTE 2", "MUTE 3", "MUTE 4"
    .ascii   "VUBEATZ MPC2000 MUTE GROUPS C01\0"
    .balign  16, 0

payload_end:

.endif

.if MOD_UNIT == 23
.if MOD_PART == 6

mute_label:
    cmp      bl, 4
    jb       .Lnative_label
    cmp      bl, 7
    ja       .Linvalid_label
    sub      bl, 4
    shl      bx, 1
    mov      dx, word ptr cs:[bx+mute_labels-segment_start]
    mov      cx, MOD_CS
    mov      bx, 4
    retf

.Linvalid_label:
    xor      bx, bx

.Lnative_label:
    shl      bx, 2
    mov      dx, word ptr [bx+0x2bfe]
    mov      cx, word ptr [bx+0x2c00]
    retf

mute_labels:
    .word    mute1-segment_start, mute2-segment_start, mute3-segment_start, mute4-segment_start

mute1:
    .asciz   "MUTE 1"

mute2:
    .asciz   "MUTE 2"

mute3:
    .asciz   "MUTE 3"

mute4:
    .asciz   "MUTE 4"

mute_trigger:
    pushf
    push     dx
    mov      al, byte ptr [bp+5]
    cmp      al, byte ptr [bp-1]
    jne      .Lmute_done
    mov      dl, byte ptr es:[bx]
    cmp      dl, 4
    jb       .Lmute_done
    cmp      dl, 7
    ja       .Lmute_done
    pusha
    push     es
    xor      si, si
    mov      di, 0x9609

.Lmute_scan:
    mov      al, byte ptr [bp+4]
    cmp      al, byte ptr [di]
    jne      .Lmute_next
    mov      al, byte ptr [di+1]
    cmp      al, byte ptr [bp+5]
    je       .Lmute_next
    sub      al, 35
    cmp      al, 63
    ja       .Lmute_next
    xor      ah, ah
    imul     bx, ax, 24
    add      bx, word ptr [bp-6]
    add      bx, 30
    mov      es, word ptr [bp-4]
    cmp      byte ptr es:[bx], dl
    jne      .Lmute_next
    push     dx
    push     si
    farcall  0x3e19, 0x3a36
    add      sp, 2
    pop      dx

.Lmute_next:
    add      di, 20
    inc      si
    cmp      si, 32
    jb       .Lmute_scan
    pop      es
    popa

.Lmute_done:
    pop      dx
    popf
    les      bx, dword ptr [bp-10]
    mov      al, byte ptr es:[bx+12]
    retf
    .balign  2, 0
.global extension_end

extension_end:

.endif
.endif
