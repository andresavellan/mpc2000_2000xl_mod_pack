/* Final firmware source: folders.
 * Assembly source sections for this feature.
 */
/* directory_reader: assembly unit 3. */
.if MOD_UNIT == 3
/* C03: appended, read-only FAT directory navigation for Classic 1.72.
 * GNU as, 80186. No code is removed. EXE hooks are installed in RAM only.
 * Internal DS=CS; the original filesystem workspace is F000.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
.set MAX_CHAIN, 256
.set MAX_DEPTH, 16
.global extension_start, extension_end, install, fs_interrupt, ui_load, ui_filter
.global reloc_original_init, original_init, old_fs, main_segment, aux_segment
.global state_begin, state_end, sector_buffer, chain, staging_chain

.macro aux_near fileoff
    push bp
    push cs
    push offset .Laux_return\@
    push 0x0359 /* EXE 10FD9: RETF */
    push word ptr cs:[aux_segment]
    push (\fileoff - 0x10c80)
    retf
.Laux_return\@:
    pop bp
.endm
.macro main_near fileoff
    push bp
    push cs
    push offset .Lmain_return\@
    push 0x046b /* EXE 126B: RETF */
    push word ptr cs:[main_segment]
    push (\fileoff - 0x0e00)
    retf
.Lmain_return\@:
    pop bp
.endm
.macro unstack_jump target
    pop ds
    pop ax
    popf
    jmp \target
.endm

extension_start:
install:
    /* Displaced last native SYS initialization call, unchanged semantics. */
    push cs
    call original_init
    pushf
    pusha
    push ds
    push es
    cld
    push cs
    pop ds
    xor ax, ax
    mov es, ax
    cmp word ptr es:[0xbc], 0x0490 /* INT 2F: known bridge */
    jne .Linstall_done
    mov ax, es:[0xbe]
    mov [aux_segment], ax
    mov [old_fs+2], ax
    sub ax, 0x0fe8
    mov [main_segment], ax
    mov [main_continue+2], ax
    mov [main_return+2], ax
    mov [filter_continue+2], ax
    mov [filter_return+2], ax
    mov es, ax
    /* Original bytes or this same hook after a SYS reload. */
    cmp byte ptr es:[0xe98f], 0xea
    je .Lcheck_old_load_hook
    cmp word ptr es:[0xe98f], 0x11b3
    jne .Linstall_done
    cmp word ptr es:[0xe991], 0x3e8a
    jne .Linstall_done
    cmp word ptr es:[0xe993], 0x78a8
    jne .Linstall_done
    jmp .Lcheck_filter
.Lcheck_old_load_hook:
    cmp word ptr es:[0xe990], offset ui_load
    jne .Linstall_done
    mov ax, cs
    cmp word ptr es:[0xe992], ax
    jne .Linstall_done
.Lcheck_filter:
    cmp byte ptr es:[0xe3e7], 0xea
    je .Lcheck_old_filter_hook
    cmp word ptr es:[0xe3e7], 0x3e80
    jne .Linstall_done
    cmp word ptr es:[0xe3e9], 0x78c0
    jne .Linstall_done
    cmp byte ptr es:[0xe3eb], 0
    jne .Linstall_done
    jmp .Linstall_hooks
.Lcheck_old_filter_hook:
    cmp word ptr es:[0xe3e8], offset ui_filter
    jne .Linstall_done
    mov ax, cs
    cmp word ptr es:[0xe3ea], ax
    jne .Linstall_done
.Linstall_hooks:
    call reset_context
    mov byte ptr [drive], 0xff
    cli
    mov byte ptr es:[0xe98f], 0xea
    mov word ptr es:[0xe990], offset ui_load
    mov es:[0xe992], cs
    mov byte ptr es:[0xe994], 0x90
    mov byte ptr es:[0xe3e7], 0xea
    mov word ptr es:[0xe3e8], offset ui_filter
    mov es:[0xe3ea], cs
    xor ax, ax
    mov es, ax
    mov word ptr es:[0xb0], offset fs_interrupt
    mov es:[0xb2], cs
    mov byte ptr [installed], 1
.Linstall_done:
    pop es
    pop ds
    popa
    popf
    retf
original_init:
    .byte 0xea
    .word 0x0638
reloc_original_init:
    .word 0x0b7c

/* This hook replaces the LOAD / DO IT entry, not file format loaders. */
ui_load:
    cmp word ptr [0x78da], 0x443c /* <D> synthetic directory type */
    jne .Lui_native
    cmp byte ptr [0x78dc], 0x3e
    jne .Lui_native
    pusha
    push ds
    push es
    push ds
    pop es
    mov si, 0x78c9
    mov bh, [0x78a8]
    mov bl, 0x7e
    mov ax, 0x5646
    int 0x2c
    jc .Lui_failed
    pop es
    pop ds
    main_near 0xf13e
    int 0x52
    popa
    jmp far ptr cs:[main_return]
.Lui_failed:
    pop es
    pop ds
    popa
    int 0x2b
    .byte 0x20
    .asciz "Folder unavailable"
    jmp far ptr cs:[main_return]
.Lui_native:
    mov bl, 0x11
    mov bh, [0x78a8]
    jmp far ptr cs:[main_continue]

ui_filter:
    cmp word ptr es:[si+17], 0x443c
    jne .Lfilter_native
    cmp byte ptr es:[si+19], 0x3e
    jne .Lfilter_native
    /* Last comparison has ZF=1: folders survive every file-type filter. */
    jmp far ptr cs:[filter_return]
.Lfilter_native:
    cmp byte ptr [0x78c0], 0
    jmp far ptr cs:[filter_continue]

/* Preserve the exact original interrupt frame for all pass-through calls. */
fs_interrupt:
    pushf
    push ax
    push ds
    push cs
    pop ds
    cmp bl, 0x7e
    jne .Lnot_private
    cmp ax, 0x5646
    jne .Lprivate_bad
    unstack_jump service_navigate
.Lprivate_bad:
    unstack_jump service_bad_request
.Lnot_private:
    /* Motor housekeeping is not a user switch to another medium. */
    cmp bl, 0x0f
    je .Lpass
    cmp bl, 0x10
    je .Lpass
    cmp bh, [drive]
    je .Lsame_drive
    mov [drive], bh
    call reset_context
.Lsame_drive:
    cmp bl, 0
    je .Lreset_pass
    cmp bl, 1
    je .Lreset_pass
    cmp bl, 0x17
    je .Lreset_pass
    cmp bl, 0x11
    je .Lmedia_pass
    cmp bh, 9
    jae .Lpass
    mov ax, 0xf000
    mov ds, ax
    or bh, bh
    jnz .Ldisk_type
    cmp byte ptr [0xf892], 0
    jne .Lpass
    cmp byte ptr [0xf8e7], 2 /* 512-byte physical sectors only */
    jne .Lpass
    jmp .Lfat_type
.Ldisk_type:
    cmp byte ptr [0xf903], 0
    jne .Lpass
    cmp byte ptr [0xf965], 12
    je .Lfat_type
    cmp byte ptr [0xf965], 16
    jne .Lpass
.Lfat_type:
    cmp bl, 2
    je .Lfirst
    cmp bl, 3
    je .Lnext
    cmp bl, 0x16
    je .Lprevious
    cmp word ptr cs:[cwd], 0
    je .Lroot_pass
    cmp bl, 4
    je .Lopen
    cmp bl, 0x0e
    je .Lfind
    cmp bl, 0x0a
    je .Lclose
    cmp bl, 7
    je .Lwrite_blocked
    cmp bl, 8
    je .Lwrite_blocked
    cmp bl, 9
    je .Lwrite_blocked
    cmp bl, 0x0b
    je .Lwrite_blocked
    cmp bl, 0x0c
    je .Lwrite_blocked
    cmp bl, 0x14
    je .Lwrite_blocked
    cmp bl, 0x15
    je .Lwrite_blocked
    cmp bl, 0x18 /* floppy format setup */
    je .Lwrite_blocked
    cmp bl, 0x19 /* floppy low-level format / metadata initialization */
    je .Lwrite_blocked
    jmp .Lpass
.Lroot_pass:
    /* Root writes use native code; discard cached directory sectors. */
    mov byte ptr cs:[cache_valid], 0
.Lpass:
    pop ds
    pop ax
    popf
    jmp far ptr cs:[old_fs]
.Lreset_pass:
    call reset_context
    jmp .Lpass
.Lmedia_pass:
    unstack_jump service_media
.Lfirst:
    unstack_jump service_first
.Lnext:
    unstack_jump service_next
.Lprevious:
    unstack_jump service_previous
.Lopen:
    unstack_jump service_open
.Lfind:
    unstack_jump service_find
.Lclose:
    unstack_jump service_close
.Lwrite_blocked:
    unstack_jump service_write_blocked

.macro frame
    push bp
    mov bp, sp
    push ds
    push cs
    pop ds
    cld
    sti
.endm
/* The only output flag promised by INT 2C is CF. BP is preserved here. */
finish:
    push ax
    pushf
    pop ax
    and ax, 1
    and word ptr ss:[bp+6], 0xfffe
    or word ptr ss:[bp+6], ax
    pop ax
    pop ds
    pop bp
    iret

call_original:
    push bp
    pushf
    call far ptr cs:[old_fs]
    pop bp
    ret

service_media:
    frame
    call call_original
    jnc finish
    pushf
    call reset_context
    popf
    jmp finish
service_write_blocked:
    frame
    mov ax, 1 /* native write-protect error */
    stc
    jmp finish
service_bad_request:
    frame
    jmp service_error
service_close:
    frame
    xor ax, ax /* subdirectory opens are read-only: never flush metadata */
    jmp finish

reset_context:
    mov word ptr cs:[cwd], 0
    mov word ptr cs:[depth], 0
    mov word ptr cs:[cursor], 0xffff
    mov byte ptr cs:[cache_valid], 0
    ret

/* Geometry comes only from the mounted, native filesystem, never guessed. */
geometry:
    push es
    mov ax, 0xf000
    mov es, ax
    cmp byte ptr [drive], 0
    jne .Lgeometry_disk
    cmp byte ptr es:[0xf892], 0
    jne .Lgeometry_error
    cmp byte ptr es:[0xf8e7], 2
    jne .Lgeometry_error
    mov byte ptr [fat_bits], 12
    mov ax, es:[0xf8ac]
    mov [spc], ax
    mov ax, es:[0xf8aa]
    mov [data_sector], ax
    mov ax, es:[0xf89e]
    shr ax, 9
    mov [fat_sector], ax
    mov ax, es:[0xf89a]
    shr ax, 9
    mov [fat_sectors], ax
    mov ax, es:[0xf89c]
    add ax, 2 /* data-cluster count -> exclusive cluster bound */
    jc .Lgeometry_error
    mov [cluster_limit], ax
    mov ax, es:[0xf8a2]
    mov [floppy_root], ax
    mov dx, es:[0xf8a4]
    sub dx, ax
    shr dx, 5
    mov [root_entries], dx
    mov word ptr [partition], 0
    mov word ptr [partition+2], 0
    jmp .Lgeometry_check
.Lgeometry_disk:
    cmp byte ptr [drive], 9
    jae .Lgeometry_error
    cmp byte ptr es:[0xf903], 0
    jne .Lgeometry_error
    mov al, es:[0xf965]
    cmp al, 12
    je .Lgeometry_disk_ok
    cmp al, 16
    jne .Lgeometry_error
.Lgeometry_disk_ok:
    mov [fat_bits], al
    mov ax, es:[0xf98d]
    mov [spc], ax
    mov ax, es:[0xf995]
    mov [data_sector], ax
    mov ax, es:[0xf98f]
    mov [fat_sector], ax
    mov ax, es:[0xf993] /* F991 is the SECOND FAT's start, not its size */
    mov [fat_sectors], ax
    mov ax, es:[0xf98b]
    add ax, 2
    jc .Lgeometry_error
    mov [cluster_limit], ax
    mov ax, es:[0xfd9b]
    mov [root_sector], ax
    mov ax, es:[0xfd9d]
    mov [root_entries], ax
    mov ax, es:[0xf985]
    mov [partition], ax
    mov ax, es:[0xf987]
    mov [partition+2], ax
.Lgeometry_check:
    mov ax, [spc]
    or ax, ax
    jz .Lgeometry_error
    cmp ax, 32
    ja .Lgeometry_error
    mov dx, ax
    dec dx
    test ax, dx
    jnz .Lgeometry_error
    cmp word ptr [cluster_limit], 3
    jb .Lgeometry_error
    pop es
    clc
    ret
.Lgeometry_error:
    pop es
    stc
    ret

/* Native media check before first enumeration, file lookup and navigation. */
media_check:
    pusha
    push es
    mov bl, 0x11
    mov bh, [drive]
    call call_original
    pop es
    popa
    jnc .Lmedia_ok
    call reset_context
    stc
.Lmedia_ok:
    ret

service_first:
    frame
    call media_check
    jc .Lfirst_error
    call geometry
    jc .Lfirst_error
    mov word ptr [cursor], 0xffff
    xor ax, ax
    jmp enumerate_forward
.Lfirst_error:
    jmp service_error
service_next:
    frame
    mov ax, [cursor]
    inc ax
    jz service_error
    jmp enumerate_forward
service_previous:
    frame
    mov ax, [cursor]
.Lprevious_loop:
    or ax, ax
    jz .Lboundary
    dec ax
    call entry_at
    jc .Lboundary
    call acceptable_entry
    jc .Lprevious_loop
    jmp enum_success

enumerate_forward:
    call entry_at
    jc .Lboundary
    cmp byte ptr [entry], 0
    je .Lboundary
    call acceptable_entry
    jnc enum_success
    inc ax
    jnz enumerate_forward
.Lboundary:
    /* Classic callers expect the last valid name/size even on boundary CF. */
    cmp word ptr [cursor], 0xffff
    je service_error
    mov ax, [cursor]
    call entry_at
    jc service_error
    call expand_entry
    stc
    jmp finish
enum_success:
    mov [cursor], ax
    call expand_entry
    clc
    jmp finish
service_error:
    mov ax, 0xffff
    xor bx, bx
    xor dx, dx
    push ds
    pop es
    mov si, offset empty_name
    stc
    jmp finish

acceptable_entry:
    cmp word ptr [cwd], 0
    je .Laccept_regular
    or ax, ax
    jz .Laccepted /* synthetic parent */
.Laccept_regular:
    cmp byte ptr [entry], 0
    je .Lrejected
    cmp byte ptr [entry], 0xe5
    je .Lrejected
    cmp byte ptr [entry], 5
    je .Lrejected
    cmp byte ptr [entry], 0x2e
    je .Lrejected
    test byte ptr [entry+11], 0x0e
    jnz .Lrejected
.Laccepted:
    clc
    ret
.Lrejected:
    stc
    ret

/* AX = logical index; output 32-byte entry; AX preserved. */
entry_at:
    pusha
    push es
    push ds
    pop es
    cmp word ptr [cwd], 0
    je .Lentry_root
    or ax, ax
    jz .Lentry_parent
    dec ax
    mov bx, ax
    shr ax, 4 /* logical directory sector */
    xor dx, dx
    div word ptr [spc]
    cmp ax, [chain_count]
    jae .Lentry_fail
    push dx
    shl ax, 1
    mov si, ax
    mov ax, [chain+si]
    sub ax, 2
    mul word ptr [spc]
    add ax, [data_sector]
    adc dx, 0
    pop cx
    add ax, cx
    adc dx, 0
    jmp .Lentry_sector
.Lentry_root:
    cmp ax, [root_entries]
    jae .Lentry_fail
    cmp byte ptr [drive], 0
    jne .Lentry_root_disk
    shl ax, 5
    add ax, [floppy_root]
    mov si, ax
    mov ax, 0xf000
    push ds
    mov ds, ax
    mov di, offset entry
    mov cx, 16
    rep movsw
    pop ds
    jmp .Lentry_success
.Lentry_root_disk:
    mov bx, ax
    shr ax, 4
    xor dx, dx
    add ax, [root_sector]
    adc dx, 0
.Lentry_sector:
    push bx
    call read_sector
    pop bx
    jc .Lentry_fail
    and bx, 15
    shl bx, 5
    lea si, [sector_buffer+bx]
    mov di, offset entry
    mov cx, 16
    push ds
    pop es
    rep movsw
    jmp .Lentry_success
.Lentry_parent:
    mov si, offset parent_entry
    mov di, offset entry
    mov cx, 16
    rep movsw
.Lentry_success:
    pop es
    popa
    clc
    ret
.Lentry_fail:
    pop es
    popa
    stc
    ret

/* Read relative volume sector DX:AX into a private 512-byte buffer.
 * Does not overwrite cached floppy ROOT/FAT or native file data on SCSI.
 */
read_sector:
    cmp byte ptr [cache_valid], 0
    je .Lsector_read
    cmp ax, [cache_lba]
    jne .Lsector_read
    cmp dx, [cache_lba+2]
    jne .Lsector_read
    clc
    ret
.Lsector_read:
    mov byte ptr [cache_valid], 0
    mov [cache_lba], ax
    mov [cache_lba+2], dx
    pusha
    push es
    cmp byte ptr [drive], 0
    je .Lsector_floppy
    add ax, [partition]
    adc dx, [partition+2]
    mov bx, dx
    mov dx, ax
    push ds
    pop es
    mov di, offset sector_buffer
    mov cx, 1
    mov ah, 1
    push bp
    push ds
    push 0xf000
    pop ds
    int 0x2d
    pop ds
    pop bp
    jc .Lsector_failed
    jmp .Lsector_done
.Lsector_floppy:
    or dx, dx
    jnz .Lsector_failed
    push ds
    push 0xf000
    pop ds
    aux_near 0x120fc
    test byte ptr [0xf8f4], 0xc0
    jnz .Lfloppy_failed
    push cs
    pop es
    mov si, 0x5000
    mov di, offset sector_buffer
    mov cx, 256
    rep movsw
    pop ds
    jmp .Lsector_done
.Lfloppy_failed:
    pop ds
.Lsector_failed:
    pop es
    popa
    stc
    ret
.Lsector_done:
    mov byte ptr [cache_valid], 1
    pop es
    popa
    clc
    ret

/* AX current cluster -> AX successor, FFFF=end; CF invalid/I/O. */
fat_next:
    push bx
    push cx
    push dx
    push si
    push es
    mov cx, ax
    cmp byte ptr [fat_bits], 12
    jne .Lfat16
    shr ax, 1
    add ax, cx
    jmp .Lfat_byte_offset
.Lfat16:
    /* Avoid overflow of cluster*2 for clusters 8000h and above. */
    mov bx, ax
    shl bx, 1
    and bx, 511
    shr ax, 8
    jmp .Lfat_sector_index
.Lfat_byte_offset:
    mov bx, ax
    and bx, 511
    shr ax, 9
.Lfat_sector_index:
    cmp ax, [fat_sectors]
    jae .Lfat_error
    add ax, [fat_sector]
    xor dx, dx
    call read_sector
    jc .Lfat_error
    mov dl, [sector_buffer+bx]
    cmp bx, 511
    jne .Lfat_word_here
    push dx
    inc ax
    xor dx, dx
    call read_sector
    pop dx
    jc .Lfat_error
    mov dh, [sector_buffer]
    jmp .Lfat_word_loaded
.Lfat_word_here:
    mov dh, [sector_buffer+bx+1]
.Lfat_word_loaded:
    mov ax, dx
    cmp byte ptr [fat_bits], 12
    jne .Lfat16_end
    test cl, 1
    jz .Lfat12_low
    shr ax, 4
.Lfat12_low:
    and ax, 0x0fff
    cmp ax, 0x0ff8
    jae .Lfat_end
    cmp ax, 0x0ff0
    jae .Lfat_error
    jmp .Lfat_valid
.Lfat16_end:
    cmp ax, 0xfff8
    jae .Lfat_end
    cmp ax, 0xfff0
    jae .Lfat_error
.Lfat_valid:
    call valid_cluster
    jmp .Lfat_return
.Lfat_end:
    mov ax, 0xffff
    clc
    jmp .Lfat_return
.Lfat_error:
    stc
.Lfat_return:
    pop es
    pop si
    pop dx
    pop cx
    pop bx
    ret

valid_cluster:
    cmp ax, 2
    jb .Lcluster_invalid
    cmp ax, [cluster_limit]
    jae .Lcluster_invalid
    cmp byte ptr [fat_bits], 12
    jne .Lcluster16
    cmp ax, 0x0ff0
    jae .Lcluster_invalid
    clc
    ret
.Lcluster16:
    cmp ax, 0xfff0
    jae .Lcluster_invalid
    clc
    ret
.Lcluster_invalid:
    stc
    ret

/* Stage and validate the entire directory chain before committing CWD.
 * 256 unique clusters maximum; cycles and oversized directories fail closed.
 */
build_chain:
    mov word ptr [staging_count], 0
    or ax, ax
    jz .Lchain_ready
.Lchain_loop:
    call valid_cluster
    jc .Lchain_error
    mov cx, [staging_count]
    cmp cx, MAX_CHAIN
    jae .Lchain_error
    xor bx, bx
.Lchain_duplicate:
    jcxz .Lchain_store
    cmp ax, [staging_chain+bx]
    je .Lchain_error
    add bx, 2
    loop .Lchain_duplicate
.Lchain_store:
    mov [staging_chain+bx], ax
    inc word ptr [staging_count]
    call fat_next
    jc .Lchain_error
    cmp ax, 0xffff
    jne .Lchain_loop
    mov ax, [staging_count]
    mul word ptr [spc]
    or dx, dx
    jnz .Lchain_error
    cmp ax, 4094 /* leave room for virtual parent and 16-bit index */
    ja .Lchain_error
.Lchain_ready:
    clc
    ret
.Lchain_error:
    stc
    ret

/* Preserve native AKAI 16-character names. Folder display uses <D> only
 * in the returned copy; nothing is changed in the on-disk entry.
 */
expand_entry:
    push ds
    pop es
    mov di, offset name
    mov al, 0x20
    mov cx, 20
    rep stosb
    mov si, offset entry
    mov di, offset name
    mov cx, 8
    rep movsb
    test byte ptr [entry+11], 0x10
    jnz .Lexpand_directory
    mov si, offset entry+12
    mov cx, 8
.Lextended_check:
    cmp byte ptr [si], 0x20
    jb .Lexpand_extension
    cmp byte ptr [si], 0x7b
    jae .Lexpand_extension
    inc si
    loop .Lextended_check
    mov si, offset entry+12
    mov cx, 8
    rep movsb
.Lexpand_extension:
    mov byte ptr [name+16], 0x2e
    mov si, offset entry+8
    mov di, offset name+17
    mov cx, 3
    rep movsb
    mov bx, [entry+28]
    mov dx, [entry+30]
    jmp .Lexpanded
.Lexpand_directory:
    /* Preserve a PC folder's short extension in its displayed basename. */
    cmp byte ptr [entry+8], 0x20
    je .Ldirectory_marker
    mov di, offset name+8
.Ltrim_directory:
    cmp di, offset name
    jbe .Ldirectory_dot
    cmp byte ptr [di-1], 0x20
    jne .Ldirectory_dot
    dec di
    jmp .Ltrim_directory
.Ldirectory_dot:
    mov al, 0x2e
    stosb
    mov si, offset entry+8
    mov cx, 3
    rep movsb
.Ldirectory_marker:
    mov byte ptr [name+16], 0x2e
    mov word ptr [name+17], 0x443c
    mov byte ptr [name+19], 0x3e
    xor bx, bx /* directory size is zero; ui_load handles it before file guard */
    xor dx, dx
.Lexpanded:
    mov si, offset name
    xor ax, ax
    ret

copy_lookup:
    mov di, offset lookup
    mov cx, 20
.Lcopy_lookup:
    mov al, es:[si]
    cmp al, 0x61
    jb .Lcopy_upper
    cmp al, 0x7b
    jae .Lcopy_upper
    sub al, 0x20
.Lcopy_upper:
    mov [di], al
    inc si
    inc di
    loop .Lcopy_lookup
    ret
find_entry:
    call media_check
    jc .Lfind_failed
    call geometry
    jc .Lfind_failed
    xor ax, ax
.Lfind_loop:
    call entry_at
    jc .Lfind_failed
    cmp byte ptr [entry], 0
    je .Lfind_failed
    call acceptable_entry
    jc .Lfind_next
    push ax
    call expand_entry
    mov di, offset lookup
    mov cx, 20
    repe cmpsb
    pop ax
    je .Lfind_found
.Lfind_next:
    inc ax
    jnz .Lfind_loop
.Lfind_failed:
    mov ax, 0xffff
    stc
    ret
.Lfind_found:
    clc
    ret
service_find:
    frame
    call copy_lookup
    call find_entry
    jc service_error
    mov [cursor], ax
    call expand_entry
    clc
    jmp finish
service_open:
    frame
    call copy_lookup
    call find_entry
    jc service_error
    test byte ptr [entry+11], 0x10
    jnz service_error
    mov ax, 0xf000
    mov es, ax
    mov ax, [entry+26]
    mov bx, [entry+28]
    mov dx, [entry+30]
    mov cx, bx
    or cx, dx
    jz .Lopen_cluster_ready
    call valid_cluster
    jc service_error
.Lopen_cluster_ready:
    cmp byte ptr [drive], 0
    jne .Lopen_disk
    mov es:[0xf8b8], ax
    mov es:[0xf8b4], bx
    mov es:[0xf8b6], dx
    xor ax, ax
    mov es:[0xf8ba], ax
    mov es:[0xf8b2], ax
    mov es:[0xf8b0], ax
    mov es:[0xf8a6], ax
    mov es:[0xf8a8], ax
    mov byte ptr es:[0xf893], 0
    jmp .Lopened
.Lopen_disk:
    mov es:[0xffa9], ax
    mov es:[0xffa5], bx
    mov es:[0xffa7], dx
    mov word ptr es:[0xffab], 0
    mov byte ptr es:[0xf997], 0
.Lopened:
    xor ax, ax
    jmp finish

service_navigate:
    frame
    cmp bh, [drive]
    jne service_error
    /* Never change directories while native CREATE/WRITE is still open. */
    push es
    push ax
    mov ax, 0xf000
    mov es, ax
    cmp byte ptr [drive], 0
    jne .Lnav_write_disk
    cmp byte ptr es:[0xf893], 2
    jmp .Lnav_write_checked
.Lnav_write_disk:
    cmp byte ptr es:[0xf997], 2
.Lnav_write_checked:
    pop ax
    pop es
    je service_error
    call copy_lookup
    call find_entry
    jc service_error
    test byte ptr [entry+11], 0x10
    jz service_error
    or ax, ax
    jnz .Lnav_child
    cmp word ptr [cwd], 0
    je .Lnav_child
    mov bx, [depth]
    or bx, bx
    jz service_error
    dec bx
    shl bx, 1
    mov ax, [parents+bx]
    mov [next_cwd], ax
    call build_chain
    jc service_error
    dec word ptr [depth]
    jmp .Lnav_commit
.Lnav_child:
    cmp word ptr [depth], MAX_DEPTH
    jae service_error
    mov ax, [entry+26]
    cmp ax, 2
    jb service_error
    cmp ax, [cwd]
    je service_error
    mov cx, [depth]
    xor bx, bx
.Lnav_ancestor:
    jcxz .Lnav_unique
    cmp ax, [parents+bx]
    je service_error
    add bx, 2
    loop .Lnav_ancestor
.Lnav_unique:
    mov [next_cwd], ax
    call build_chain
    jc service_error
    mov bx, [depth]
    shl bx, 1
    mov ax, [cwd]
    mov [parents+bx], ax
    inc word ptr [depth]
.Lnav_commit:
    push ds
    pop es
    mov si, offset staging_chain
    mov di, offset chain
    mov cx, [staging_count]
    mov [chain_count], cx
    rep movsw
    mov ax, [next_cwd]
    mov [cwd], ax
    mov word ptr [cursor], 0xffff
    mov byte ptr [cache_valid], 0
    xor ax, ax
    jmp finish

.align 2
old_fs: .word 0x06be, 0
main_segment: .word 0
aux_segment: .word 0
main_continue: .word 0xe995, 0
main_return: .word 0xe9a1, 0
filter_continue: .word 0xe3ec, 0
filter_return: .word 0xe407, 0
empty_name: .ascii "                .   "
parent_entry:
    .ascii "..         "
    .byte 0x10
    .space 20
.align 2
state_begin:
installed: .byte 0
drive: .byte 0xff
cache_valid: .byte 0
fat_bits: .byte 0
cwd: .word 0
next_cwd: .word 0
depth: .word 0
cursor: .word 0xffff
spc: .word 0
data_sector: .word 0
fat_sector: .word 0
fat_sectors: .word 0
cluster_limit: .word 0
root_sector: .word 0
root_entries: .word 0
floppy_root: .word 0
partition: .long 0
cache_lba: .long 0
chain_count: .word 0
staging_count: .word 0
parents: .space MAX_DEPTH*2
entry: .space 32
name: .space 20
lookup: .space 20
.align 2
chain: .space MAX_CHAIN*2
staging_chain: .space MAX_CHAIN*2
.balign 512
sector_buffer: .space 512
state_end:
.align 16
extension_end:

.endif /* directory_reader */
/* directory_io: assembly unit 4. */
.if MOD_UNIT == 4
/* C04: appended FAT directory navigation and file writer for Classic 1.72.
 * GNU as, 80186. No code is removed. EXE hooks are installed in RAM only.
 * Internal DS=CS; the original filesystem workspace is F000.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
.set MAX_CHAIN, 256
.set MAX_DEPTH, 16
.global extension_start, extension_end, install, fs_interrupt, ui_load, ui_filter
.global reloc_original_init, original_init, old_fs, main_segment, aux_segment
.global state_begin, state_end, sector_buffer, chain, staging_chain

.macro aux_near fileoff
    push bp
    push cs
    push offset .Laux_return\@
    push 0x0359 /* EXE 10FD9: RETF */
    push word ptr cs:[aux_segment]
    push (\fileoff - 0x10c80)
    retf
.Laux_return\@:
    pop bp
.endm
.macro main_near fileoff
    push bp
    push cs
    push offset .Lmain_return\@
    push 0x046b /* EXE 126B: RETF */
    push word ptr cs:[main_segment]
    push (\fileoff - 0x0e00)
    retf
.Lmain_return\@:
    pop bp
.endm
.macro unstack_jump target
    pop ds
    pop ax
    popf
    jmp \target
.endm

extension_start:
install:
    /* Displaced last native SYS initialization call, unchanged semantics. */
    push cs
    call original_init
    pushf
    pusha
    push ds
    push es
    cld
    push cs
    pop ds
    xor ax, ax
    mov es, ax
    cmp word ptr es:[0xbc], 0x0490 /* INT 2F: known bridge */
    jne .Linstall_done
    mov ax, es:[0xbe]
    mov [aux_segment], ax
    mov [old_fs+2], ax
    sub ax, 0x0fe8
    mov [main_segment], ax
    mov [main_continue+2], ax
    mov [main_return+2], ax
    mov [filter_continue+2], ax
    mov [filter_return+2], ax
    mov es, ax
    /* Original bytes or this same hook after a SYS reload. */
    cmp byte ptr es:[0xe98f], 0xea
    je .Lcheck_old_load_hook
    cmp word ptr es:[0xe98f], 0x11b3
    jne .Linstall_done
    cmp word ptr es:[0xe991], 0x3e8a
    jne .Linstall_done
    cmp word ptr es:[0xe993], 0x78a8
    jne .Linstall_done
    jmp .Lcheck_filter
.Lcheck_old_load_hook:
    cmp word ptr es:[0xe990], offset ui_load
    jne .Linstall_done
    mov ax, cs
    cmp word ptr es:[0xe992], ax
    jne .Linstall_done
.Lcheck_filter:
    cmp byte ptr es:[0xe3e7], 0xea
    je .Lcheck_old_filter_hook
    cmp word ptr es:[0xe3e7], 0x3e80
    jne .Linstall_done
    cmp word ptr es:[0xe3e9], 0x78c0
    jne .Linstall_done
    cmp byte ptr es:[0xe3eb], 0
    jne .Linstall_done
    jmp .Linstall_hooks
.Lcheck_old_filter_hook:
    cmp word ptr es:[0xe3e8], offset ui_filter
    jne .Linstall_done
    mov ax, cs
    cmp word ptr es:[0xe3ea], ax
    jne .Linstall_done
.Linstall_hooks:
    /* Native INT 2A aborts to the main UI, bypassing normal RET/CF paths.
     * Latch an active I/O failure before forwarding its original frame. */
    push es
    mov ax, [main_segment]
    mov [old_fatal+2], ax
    xor ax, ax
    mov es, ax
    cmp word ptr es:[0xa8], 0x0ef7
    jne .Lcheck_old_fatal_hook
    mov ax, [main_segment]
    cmp es:[0xaa], ax
    jne .Linstall_write_mismatch
    jmp .Lfatal_gate_ready
.Lcheck_old_fatal_hook:
    cmp word ptr es:[0xa8], offset fatal_interrupt
    jne .Linstall_write_mismatch
    mov ax, cs
    cmp es:[0xaa], ax
    jne .Linstall_write_mismatch
.Lfatal_gate_ready:
    /* Physical floppy WRITE's error exit must return to our transaction.
     * Native callers retain the displaced TEST and original error handling. */
    mov ax, [aux_segment]
    mov es, ax
    mov [floppy_write_continue+2], ax
    mov [floppy_write_return+2], ax
    cmp byte ptr es:[0x1a17], 0xea
    je .Lcheck_old_write_hook
    cmp word ptr es:[0x1a17], 0x06f6
    jne .Linstall_write_mismatch
    cmp word ptr es:[0x1a19], 0xf8f4
    jne .Linstall_write_mismatch
    cmp byte ptr es:[0x1a1b], 0xc0
    jne .Linstall_write_mismatch
    jmp .Linstall_write_ok
.Lcheck_old_write_hook:
    cmp word ptr es:[0x1a18], offset floppy_write_result
    jne .Linstall_write_mismatch
    mov ax, cs
    cmp word ptr es:[0x1a1a], ax
    jne .Linstall_write_mismatch
.Linstall_write_ok:
    cli
    mov byte ptr es:[0x1a17], 0xea
    mov word ptr es:[0x1a18], offset floppy_write_result
    mov es:[0x1a1a], cs
    pop es
    call reset_context
    mov byte ptr [writer_state], 0
    mov byte ptr [write_fault], 0
    mov byte ptr [drive], 0xff
    cli
    mov byte ptr es:[0xe98f], 0xea
    mov word ptr es:[0xe990], offset ui_load
    mov es:[0xe992], cs
    mov byte ptr es:[0xe994], 0x90
    mov byte ptr es:[0xe3e7], 0xea
    mov word ptr es:[0xe3e8], offset ui_filter
    mov es:[0xe3ea], cs
    xor ax, ax
    mov es, ax
    mov word ptr es:[0xb0], offset fs_interrupt
    mov es:[0xb2], cs
    mov word ptr es:[0xa8], offset fatal_interrupt
    mov es:[0xaa], cs
    mov byte ptr [installed], 1
    jmp .Linstall_done
.Linstall_write_mismatch:
    pop es
.Linstall_done:
    pop es
    pop ds
    popa
    popf
    retf
original_init:
    .byte 0xea
    .word 0x0638
reloc_original_init:
    .word 0x0b7c

/* This hook replaces the LOAD / DO IT entry, not file format loaders. */
ui_load:
    cmp word ptr [0x78da], 0x443c /* <D> synthetic directory type */
    jne .Lui_native
    cmp byte ptr [0x78dc], 0x3e
    jne .Lui_native
    pusha
    push ds
    push es
    push ds
    pop es
    mov si, 0x78c9
    mov bh, [0x78a8]
    mov bl, 0x7e
    mov ax, 0x5646
    int 0x2c
    jc .Lui_failed
    pop es
    pop ds
    main_near 0xf13e
    int 0x52
    popa
    jmp far ptr cs:[main_return]
.Lui_failed:
    pop es
    pop ds
    popa
    int 0x2b
    .byte 0x20
    .asciz "Folder unavailable"
    jmp far ptr cs:[main_return]
.Lui_native:
    mov bl, 0x11
    mov bh, [0x78a8]
    jmp far ptr cs:[main_continue]

ui_filter:
    cmp word ptr es:[si+17], 0x443c
    jne .Lfilter_native
    cmp byte ptr es:[si+19], 0x3e
    jne .Lfilter_native
    /* Last comparison has ZF=1: folders survive every file-type filter. */
    jmp far ptr cs:[filter_return]
.Lfilter_native:
    cmp byte ptr [0x78c0], 0
    jmp far ptr cs:[filter_continue]

/* Preserve the exact original interrupt frame for all pass-through calls. */
fs_interrupt:
    pushf
    push ax
    push ds
    push cs
    pop ds
    cmp bl, 0x7e
    jne .Lnot_private
    cmp ax, 0x5646
    jne .Lprivate_bad
    unstack_jump service_navigate
.Lprivate_bad:
    unstack_jump service_bad_request
.Lnot_private:
    /* Motor housekeeping is not a user switch to another medium. */
    cmp bl, 0x0f
    je .Lpass
    cmp bl, 0x10
    je .Lpass
    /* A live writer owns its drive, directory slot and file chain. */
    cmp byte ptr [writer_state], 0
    je .Lwriter_idle
    cmp bh, [drive]
    jne .Lrequest_failed
    cmp bl, 8
    je .Lwrite_byte
    cmp bl, 9
    je .Lwrite_block
    cmp bl, 0x0a
    je .Lclose
    cmp bl, 0x11
    je .Lmedia_pass
    cmp byte ptr [writer_state], 2
    jne .Lrequest_failed
    /* Explicit remount can recover a failed writer; never a live one. */
    cmp bl, 1
    je .Lreset_pass
    cmp bl, 0
    je .Lreset_pass
    jmp .Lrequest_failed
.Lwriter_idle:
    /* Ambiguous disk errors block all later mutations, including ROOT. */
    cmp byte ptr [write_fault], 0
    je .Lfault_clear
    cmp bl, 7
    jb .Lfault_clear
    cmp bl, 0x0c
    jbe .Lrequest_failed
    cmp bl, 0x14
    je .Lrequest_failed
    cmp bl, 0x15
    je .Lrequest_failed
    cmp bl, 0x18
    je .Lrequest_failed
    cmp bl, 0x19
    je .Lrequest_failed
.Lfault_clear:
    cmp bh, [drive]
    je .Lsame_drive
    mov [drive], bh
    call reset_context
.Lsame_drive:
    cmp bl, 0
    je .Lreset_pass
    cmp bl, 1
    je .Lreset_pass
    cmp bl, 0x17
    je .Lreset_pass
    cmp bl, 0x11
    je .Lmedia_pass
    cmp bh, 9
    jae .Lpass
    mov ax, 0xf000
    mov ds, ax
    or bh, bh
    jnz .Ldisk_type
    cmp byte ptr [0xf892], 0
    jne .Lpass
    cmp byte ptr [0xf8e7], 2 /* 512-byte physical sectors only */
    jne .Lpass
    jmp .Lfat_type
.Ldisk_type:
    cmp byte ptr [0xf903], 0
    jne .Lpass
    cmp byte ptr [0xf965], 12
    je .Lfat_type
    cmp byte ptr [0xf965], 16
    jne .Lpass
.Lfat_type:
    cmp bl, 2
    je .Lfirst
    cmp bl, 3
    je .Lnext
    cmp bl, 0x16
    je .Lprevious
    cmp word ptr cs:[cwd], 0
    je .Lroot_pass
    cmp bl, 4
    je .Lopen
    cmp bl, 0x0e
    je .Lfind
    cmp bl, 0x0a
    je .Lclose
    cmp bl, 7
    je .Lcreate
    cmp bl, 8
    je .Lwrite_byte
    cmp bl, 9
    je .Lwrite_block
    cmp bl, 0x0b
    je .Lwrite_blocked
    cmp bl, 0x0c
    je .Lwrite_blocked
    cmp bl, 0x14
    je .Ldelete
    cmp bl, 0x15
    je .Lwrite_blocked
    cmp bl, 0x18 /* floppy format setup */
    je .Lwrite_blocked
    cmp bl, 0x19 /* floppy low-level format / metadata initialization */
    je .Lwrite_blocked
    jmp .Lpass
.Lroot_pass:
    /* Root writes use native code; discard cached directory sectors. */
    mov byte ptr cs:[cache_valid], 0
.Lpass:
    pop ds
    pop ax
    popf
    jmp far ptr cs:[old_fs]
.Lreset_pass:
    call reset_context
    mov byte ptr cs:[writer_state], 0
    mov byte ptr cs:[write_fault], 0
    jmp .Lpass
.Lmedia_pass:
    unstack_jump service_media
.Lfirst:
    unstack_jump service_first
.Lnext:
    unstack_jump service_next
.Lprevious:
    unstack_jump service_previous
.Lopen:
    unstack_jump service_open
.Lfind:
    unstack_jump service_find
.Lclose:
    unstack_jump service_close_write
.Lcreate:
    unstack_jump service_create
.Lwrite_byte:
    unstack_jump service_write_byte
.Lwrite_block:
    unstack_jump service_write_block
.Ldelete:
    unstack_jump service_delete
.Lrequest_failed:
    unstack_jump service_io_error
.Lwrite_blocked:
    unstack_jump service_write_blocked

.macro frame
    push bp
    mov bp, sp
    push ds
    push cs
    pop ds
    cld
    sti
.endm
/* The only output flag promised by INT 2C is CF. BP is preserved here. */
finish:
    push ax
    pushf
    pop ax
    and ax, 1
    and word ptr ss:[bp+6], 0xfffe
    or word ptr ss:[bp+6], ax
    pop ax
    pop ds
    pop bp
    iret

call_original:
    push bp
    pushf
    call far ptr cs:[old_fs]
    pop bp
    ret

service_media:
    frame
    mov byte ptr [io_active], 1
    call call_original
    mov byte ptr [io_active], 0
    jnc finish
    pushf
    call media_lost
    call reset_context
    popf
    jmp finish
service_write_blocked:
    frame
    mov ax, 1 /* native write-protect error */
    stc
    jmp finish
service_bad_request:
    frame
    jmp service_error
reset_context:
    mov word ptr cs:[cwd], 0
    mov word ptr cs:[depth], 0
    mov word ptr cs:[cursor], 0xffff
    mov byte ptr cs:[cache_valid], 0
    mov byte ptr cs:[volume_pinned], 0
    ret

/* Geometry comes only from the mounted, native filesystem, never guessed. */
geometry:
    push es
    mov ax, 0xf000
    mov es, ax
    cmp byte ptr [drive], 0
    jne .Lgeometry_disk
    cmp byte ptr es:[0xf892], 0
    jne .Lgeometry_error
    cmp byte ptr es:[0xf8e7], 2
    jne .Lgeometry_error
    mov byte ptr [fat_bits], 12
    mov ax, es:[0xf8ac]
    mov [spc], ax
    mov ax, es:[0xf8aa]
    mov [data_sector], ax
    mov ax, es:[0xf89e]
    shr ax, 9
    mov [fat_sector], ax
    mov ax, es:[0xf89a]
    shr ax, 9
    mov [fat_sectors], ax
    mov ax, es:[0xf89c]
    add ax, 2 /* data-cluster count -> exclusive cluster bound */
    jc .Lgeometry_error
    mov [cluster_limit], ax
    mov ax, es:[0xf8a2]
    mov [floppy_root], ax
    mov dx, es:[0xf8a4]
    sub dx, ax
    shr dx, 5
    mov [root_entries], dx
    mov word ptr [partition], 0
    mov word ptr [partition+2], 0
    jmp .Lgeometry_check
.Lgeometry_disk:
    cmp byte ptr [drive], 9
    jae .Lgeometry_error
    cmp byte ptr es:[0xf903], 0
    jne .Lgeometry_error
    mov al, es:[0xf965]
    cmp al, 12
    je .Lgeometry_disk_ok
    cmp al, 16
    jne .Lgeometry_error
.Lgeometry_disk_ok:
    mov [fat_bits], al
    mov ax, es:[0xf98d]
    mov [spc], ax
    mov ax, es:[0xf995]
    mov [data_sector], ax
    mov ax, es:[0xf98f]
    mov [fat_sector], ax
    mov ax, es:[0xf993] /* F991 is the SECOND FAT's start, not its size */
    mov [fat_sectors], ax
    mov ax, es:[0xf98b]
    add ax, 2
    jc .Lgeometry_error
    mov [cluster_limit], ax
    mov ax, es:[0xfd9b]
    mov [root_sector], ax
    mov ax, es:[0xfd9d]
    mov [root_entries], ax
    mov ax, es:[0xf985]
    mov [partition], ax
    mov ax, es:[0xf987]
    mov [partition+2], ax
.Lgeometry_check:
    mov ax, [spc]
    or ax, ax
    jz .Lgeometry_error
    cmp ax, 32
    ja .Lgeometry_error
    mov dx, ax
    dec dx
    test ax, dx
    jnz .Lgeometry_error
    cmp word ptr [cluster_limit], 3
    jb .Lgeometry_error
    pop es
    clc
    ret
.Lgeometry_error:
    pop es
    stc
    ret

/* Native media check before first enumeration, file lookup and navigation. */
media_check:
    pusha
    push es
    mov bl, 0x11
    mov bh, [drive]
    mov byte ptr [io_active], 1
    call call_original
    mov byte ptr [io_active], 0
    pop es
    popa
    jnc .Lmedia_ok
    call media_lost
    call reset_context
    stc
.Lmedia_ok:
    ret

service_first:
    frame
    call media_check
    jc .Lfirst_error
    call geometry
    jc .Lfirst_error
    mov word ptr [cursor], 0xffff
    xor ax, ax
    jmp enumerate_forward
.Lfirst_error:
    jmp service_error
service_next:
    frame
    mov ax, [cursor]
    inc ax
    jz service_error
    jmp enumerate_forward
service_previous:
    frame
    mov ax, [cursor]
.Lprevious_loop:
    or ax, ax
    jz .Lboundary
    dec ax
    call entry_at
    jc .Lboundary
    call acceptable_entry
    jc .Lprevious_loop
    jmp enum_success

enumerate_forward:
    call entry_at
    jc .Lboundary
    cmp byte ptr [entry], 0
    je .Lboundary
    call acceptable_entry
    jnc enum_success
    inc ax
    jnz enumerate_forward
.Lboundary:
    /* Classic callers expect the last valid name/size even on boundary CF. */
    cmp word ptr [cursor], 0xffff
    je service_error
    mov ax, [cursor]
    call entry_at
    jc service_error
    call expand_entry
    stc
    jmp finish
enum_success:
    mov [cursor], ax
    call expand_entry
    clc
    jmp finish
service_error:
    mov ax, 0xffff
    xor bx, bx
    xor dx, dx
    push ds
    pop es
    mov si, offset empty_name
    stc
    jmp finish

acceptable_entry:
    cmp word ptr [cwd], 0
    je .Laccept_regular
    or ax, ax
    jz .Laccepted /* synthetic parent */
.Laccept_regular:
    cmp byte ptr [entry], 0
    je .Lrejected
    cmp byte ptr [entry], 0xe5
    je .Lrejected
    cmp byte ptr [entry], 5
    je .Lrejected
    cmp byte ptr [entry], 0x2e
    je .Lrejected
    test byte ptr [entry+11], 0x0e
    jnz .Lrejected
.Laccepted:
    clc
    ret
.Lrejected:
    stc
    ret

/* AX = logical index; output 32-byte entry; AX preserved. */
entry_at:
    pusha
    push es
    push ds
    pop es
    cmp word ptr [cwd], 0
    je .Lentry_root
    or ax, ax
    jz .Lentry_parent
    dec ax
    mov bx, ax
    shr ax, 4 /* logical directory sector */
    xor dx, dx
    div word ptr [spc]
    cmp ax, [chain_count]
    jae .Lentry_fail
    push dx
    shl ax, 1
    mov si, ax
    mov ax, [chain+si]
    sub ax, 2
    mul word ptr [spc]
    add ax, [data_sector]
    adc dx, 0
    pop cx
    add ax, cx
    adc dx, 0
    jmp .Lentry_sector
.Lentry_root:
    cmp ax, [root_entries]
    jae .Lentry_fail
    cmp byte ptr [drive], 0
    jne .Lentry_root_disk
    shl ax, 5
    add ax, [floppy_root]
    mov si, ax
    mov ax, 0xf000
    push ds
    mov ds, ax
    mov di, offset entry
    mov cx, 16
    rep movsw
    pop ds
    jmp .Lentry_success
.Lentry_root_disk:
    mov bx, ax
    shr ax, 4
    xor dx, dx
    add ax, [root_sector]
    adc dx, 0
.Lentry_sector:
    push bx
    call read_sector
    pop bx
    jc .Lentry_fail
    and bx, 15
    shl bx, 5
    lea si, [sector_buffer+bx]
    mov di, offset entry
    mov cx, 16
    push ds
    pop es
    rep movsw
    jmp .Lentry_success
.Lentry_parent:
    mov si, offset parent_entry
    mov di, offset entry
    mov cx, 16
    rep movsw
.Lentry_success:
    pop es
    popa
    clc
    ret
.Lentry_fail:
    pop es
    popa
    stc
    ret

/* Read relative volume sector DX:AX into a private 512-byte buffer.
 * Does not overwrite cached floppy ROOT/FAT or native file data on SCSI.
 */
read_sector:
    cmp byte ptr [cache_valid], 0
    je .Lsector_read
    cmp ax, [cache_lba]
    jne .Lsector_read
    cmp dx, [cache_lba+2]
    jne .Lsector_read
    clc
    ret
.Lsector_read:
    mov byte ptr [io_active], 1
    mov byte ptr [cache_valid], 0
    mov [cache_lba], ax
    mov [cache_lba+2], dx
    pusha
    push es
    cmp byte ptr [drive], 0
    je .Lsector_floppy
    add ax, [partition]
    adc dx, [partition+2]
    mov bx, dx
    mov dx, ax
    push ds
    pop es
    mov di, offset sector_buffer
    mov cx, 1
    mov ah, 1
    push bp
    push ds
    push 0xf000
    pop ds
    int 0x2d
    pop ds
    pop bp
    jc .Lsector_failed
    jmp .Lsector_done
.Lsector_floppy:
    or dx, dx
    jnz .Lsector_failed
    call floppy_read_sector
    jc .Lsector_failed
    jmp .Lsector_done
.Lsector_failed:
    mov byte ptr [io_active], 0
    pop es
    popa
    stc
    ret
.Lsector_done:
    mov byte ptr [io_active], 0
    mov byte ptr [cache_valid], 1
    pop es
    popa
    clc
    ret

/* AX current cluster -> AX successor, FFFF=end; CF invalid/I/O. */
fat_next:
    call fat_raw
    jc .Lnext_failed
    cmp byte ptr [fat_bits], 12
    jne .Lnext_fat16
    cmp ax, 0x0ff8
    jae .Lnext_end
    jmp valid_cluster
.Lnext_fat16:
    cmp ax, 0xfff8
    jae .Lnext_end
    jmp valid_cluster
.Lnext_end:
    mov ax, 0xffff
    clc
.Lnext_failed:
    ret
/* Raw FAT value, including zero (free); no link classification. */
fat_raw:
    push bx
    push cx
    push dx
    push si
    push es
    mov cx, ax
    cmp byte ptr [fat_bits], 12
    jne .Lfat16
    shr ax, 1
    add ax, cx
    jmp .Lfat_byte_offset
.Lfat16:
    /* Avoid overflow of cluster*2 for clusters 8000h and above. */
    mov bx, ax
    shl bx, 1
    and bx, 511
    shr ax, 8
    jmp .Lfat_sector_index
.Lfat_byte_offset:
    mov bx, ax
    and bx, 511
    shr ax, 9
.Lfat_sector_index:
    cmp ax, [fat_sectors]
    jae .Lfat_error
    add ax, [fat_sector]
    xor dx, dx
    call read_sector
    jc .Lfat_error
    mov dl, [sector_buffer+bx]
    cmp bx, 511
    jne .Lfat_word_here
    push dx
    inc ax
    xor dx, dx
    call read_sector
    pop dx
    jc .Lfat_error
    mov dh, [sector_buffer]
    jmp .Lfat_word_loaded
.Lfat_word_here:
    mov dh, [sector_buffer+bx+1]
.Lfat_word_loaded:
    mov ax, dx
    cmp byte ptr [fat_bits], 12
    jne .Lfat_raw_done
    test cl, 1
    jz .Lfat12_low
    shr ax, 4
.Lfat12_low:
    and ax, 0x0fff
.Lfat_raw_done:
    clc
    jmp .Lfat_return
.Lfat_error:
    stc
.Lfat_return:
    pop es
    pop si
    pop dx
    pop cx
    pop bx
    ret

valid_cluster:
    cmp ax, 2
    jb .Lcluster_invalid
    cmp ax, [cluster_limit]
    jae .Lcluster_invalid
    cmp byte ptr [fat_bits], 12
    jne .Lcluster16
    cmp ax, 0x0ff0
    jae .Lcluster_invalid
    clc
    ret
.Lcluster16:
    cmp ax, 0xfff0
    jae .Lcluster_invalid
    clc
    ret
.Lcluster_invalid:
    stc
    ret

/* Stage and validate the entire directory chain before committing CWD.
 * 256 unique clusters maximum; cycles and oversized directories fail closed.
 */
build_chain:
    mov word ptr [staging_count], 0
    or ax, ax
    jz .Lchain_ready
.Lchain_loop:
    call valid_cluster
    jc .Lchain_error
    mov cx, [staging_count]
    cmp cx, MAX_CHAIN
    jae .Lchain_error
    xor bx, bx
.Lchain_duplicate:
    jcxz .Lchain_store
    cmp ax, [staging_chain+bx]
    je .Lchain_error
    add bx, 2
    loop .Lchain_duplicate
.Lchain_store:
    mov [staging_chain+bx], ax
    inc word ptr [staging_count]
    call fat_next
    jc .Lchain_error
    cmp ax, 0xffff
    jne .Lchain_loop
    mov ax, [staging_count]
    mul word ptr [spc]
    or dx, dx
    jnz .Lchain_error
    cmp ax, 4094 /* leave room for virtual parent and 16-bit index */
    ja .Lchain_error
.Lchain_ready:
    clc
    ret
.Lchain_error:
    stc
    ret

/* Preserve native AKAI 16-character names. Folder display uses <D> only
 * in the returned copy; nothing is changed in the on-disk entry.
 */
expand_entry:
    push ds
    pop es
    mov di, offset name
    mov al, 0x20
    mov cx, 20
    rep stosb
    mov si, offset entry
    mov di, offset name
    mov cx, 8
    rep movsb
    test byte ptr [entry+11], 0x10
    jnz .Lexpand_directory
    mov si, offset entry+12
    mov cx, 8
.Lextended_check:
    cmp byte ptr [si], 0x20
    jb .Lexpand_extension
    cmp byte ptr [si], 0x7b
    jae .Lexpand_extension
    inc si
    loop .Lextended_check
    mov si, offset entry+12
    mov cx, 8
    rep movsb
.Lexpand_extension:
    mov byte ptr [name+16], 0x2e
    mov si, offset entry+8
    mov di, offset name+17
    mov cx, 3
    rep movsb
    mov bx, [entry+28]
    mov dx, [entry+30]
    jmp .Lexpanded
.Lexpand_directory:
    /* Preserve a PC folder's short extension in its displayed basename. */
    cmp byte ptr [entry+8], 0x20
    je .Ldirectory_marker
    mov di, offset name+8
.Ltrim_directory:
    cmp di, offset name
    jbe .Ldirectory_dot
    cmp byte ptr [di-1], 0x20
    jne .Ldirectory_dot
    dec di
    jmp .Ltrim_directory
.Ldirectory_dot:
    mov al, 0x2e
    stosb
    mov si, offset entry+8
    mov cx, 3
    rep movsb
.Ldirectory_marker:
    mov byte ptr [name+16], 0x2e
    mov word ptr [name+17], 0x443c
    mov byte ptr [name+19], 0x3e
    xor bx, bx /* directory size is zero; ui_load handles it before file guard */
    xor dx, dx
.Lexpanded:
    mov si, offset name
    xor ax, ax
    ret

copy_lookup:
    mov di, offset lookup
    mov cx, 20
.Lcopy_lookup:
    mov al, es:[si]
    cmp al, 0x61
    jb .Lcopy_upper
    cmp al, 0x7b
    jae .Lcopy_upper
    sub al, 0x20
.Lcopy_upper:
    mov [di], al
    inc si
    inc di
    loop .Lcopy_lookup
    ret
find_entry:
    call media_check
    jc .Lfind_failed
    call geometry
    jc .Lfind_failed
    xor ax, ax
.Lfind_loop:
    call entry_at
    jc .Lfind_failed
    cmp byte ptr [entry], 0
    je .Lfind_failed
    call acceptable_entry
    jc .Lfind_next
    push ax
    call expand_entry
    mov di, offset lookup
    mov cx, 20
    repe cmpsb
    pop ax
    je .Lfind_found
.Lfind_next:
    inc ax
    jnz .Lfind_loop
.Lfind_failed:
    mov ax, 0xffff
    stc
    ret
.Lfind_found:
    clc
    ret
service_find:
    frame
    call copy_lookup
    call find_entry
    jc service_error
    mov [cursor], ax
    call expand_entry
    clc
    jmp finish
service_open:
    frame
    call copy_lookup
    call find_entry
    jc service_error
    test byte ptr [entry+11], 0x10
    jnz service_error
    mov ax, 0xf000
    mov es, ax
    mov ax, [entry+26]
    mov bx, [entry+28]
    mov dx, [entry+30]
    mov cx, bx
    or cx, dx
    jz .Lopen_cluster_ready
    call valid_cluster
    jc service_error
.Lopen_cluster_ready:
    cmp byte ptr [drive], 0
    jne .Lopen_disk
    mov es:[0xf8b8], ax
    mov es:[0xf8b4], bx
    mov es:[0xf8b6], dx
    xor ax, ax
    mov es:[0xf8ba], ax
    mov es:[0xf8b2], ax
    mov es:[0xf8b0], ax
    mov es:[0xf8a6], ax
    mov es:[0xf8a8], ax
    mov byte ptr es:[0xf893], 0
    jmp .Lopened
.Lopen_disk:
    mov es:[0xffa9], ax
    mov es:[0xffa5], bx
    mov es:[0xffa7], dx
    mov word ptr es:[0xffab], 0
    mov byte ptr es:[0xf997], 0
.Lopened:
    xor ax, ax
    jmp finish

service_navigate:
    frame
    cmp byte ptr [writer_state], 0
    jne service_error
    cmp bh, [drive]
    jne service_error
    /* Never change directories while native CREATE/WRITE is still open. */
    push es
    push ax
    mov ax, 0xf000
    mov es, ax
    cmp byte ptr [drive], 0
    jne .Lnav_write_disk
    cmp byte ptr es:[0xf893], 2
    jmp .Lnav_write_checked
.Lnav_write_disk:
    cmp byte ptr es:[0xf997], 2
.Lnav_write_checked:
    pop ax
    pop es
    je service_error
    call copy_lookup
    call find_entry
    jc service_error
    test byte ptr [entry+11], 0x10
    jz service_error
    or ax, ax
    jnz .Lnav_child
    cmp word ptr [cwd], 0
    je .Lnav_child
    mov bx, [depth]
    or bx, bx
    jz service_error
    dec bx
    shl bx, 1
    mov ax, [parents+bx]
    mov [next_cwd], ax
    call build_chain
    jc service_error
    dec word ptr [depth]
    jmp .Lnav_commit
.Lnav_child:
    cmp word ptr [depth], MAX_DEPTH
    jae service_error
    mov ax, [entry+26]
    cmp ax, 2
    jb service_error
    cmp ax, [cwd]
    je service_error
    mov cx, [depth]
    xor bx, bx
.Lnav_ancestor:
    jcxz .Lnav_unique
    cmp ax, [parents+bx]
    je service_error
    add bx, 2
    loop .Lnav_ancestor
.Lnav_unique:
    mov [next_cwd], ax
    call build_chain
    jc service_error
    cmp word ptr [cwd], 0
    jne .Lnav_pin_ready
    call pin_volume
    jc service_error
.Lnav_pin_ready:
    mov bx, [depth]
    shl bx, 1
    mov ax, [cwd]
    mov [parents+bx], ax
    inc word ptr [depth]
.Lnav_commit:
    push ds
    pop es
    mov si, offset staging_chain
    mov di, offset chain
    mov cx, [staging_count]
    mov [chain_count], cx
    rep movsw
    mov ax, [next_cwd]
    mov [cwd], ax
    mov word ptr [cursor], 0xffff
    mov byte ptr [cache_valid], 0
    xor ax, ax
    jmp finish

/* Writer and checked physical I/O, in the same appended segment. */
/* Begin writer.inc */
/* C04 internal routines. DS=CS unless explicitly stated.
 * No firmware code is executed by the host-side candidate builder.
 * All sector/FAT mutation helpers preserve registers and report CF.
 * AX error contract: 1 protected, 2 directory/name, 3 full, 4 I/O/context.
 */
.global service_create, service_write_byte, service_write_block
.global service_close_write, service_delete, write_sector, fat_set
.global writer_state, write_fault, write_buffer, fat_buffer, volume_boot
.global floppy_write_result
.global fatal_interrupt, old_fatal, io_active

/* Preserve the interrupted native CS:IP and its inline error message. */
fatal_interrupt:
    pushf
    cmp byte ptr cs:[io_active], 1
    jne .Lfatal_forward
    mov byte ptr cs:[write_fault], 1
    mov word ptr cs:[writer_error], 4
    cmp byte ptr cs:[writer_state], 0
    je .Lfatal_idle
    mov byte ptr cs:[writer_state], 2
.Lfatal_idle:
    mov byte ptr cs:[io_active], 0
    mov byte ptr cs:[safe_floppy_write], 0
.Lfatal_forward:
    popf
    jmp far ptr cs:[old_fatal]

service_io_error:
    frame
    mov ax, 4
    stc
    jmp finish

media_lost:
    cmp word ptr cs:[cwd], 0
    je .Llost_writer
    mov byte ptr cs:[write_fault], 1
.Llost_writer:
    cmp byte ptr cs:[writer_state], 0
    je .Llost_done
    mov byte ptr cs:[writer_state], 2
    mov word ptr cs:[writer_error], 4
.Llost_done:
    ret

/* Capture the volume boot sector when first leaving ROOT. A changed boot
 * sector refuses CREATE/DELETE/CLOSE instead of using stale directory LBAs.
 * Identical cloned media and swaps during a transfer still require care. */
pin_volume:
    pusha
    push es
    mov byte ptr [volume_pinned], 0
    mov byte ptr [cache_valid], 0
    xor ax, ax
    xor dx, dx
    call read_sector
    jc .Lpin_failed
    push ds
    pop es
    mov si, offset sector_buffer
    mov di, offset volume_boot
    mov cx, 256
    rep movsw
    mov byte ptr [volume_pinned], 1
    pop es
    popa
    clc
    ret
.Lpin_failed:
    pop es
    popa
    stc
    ret

check_volume:
    pusha
    push es
    cmp byte ptr [volume_pinned], 1
    jne .Lvolume_failed
    cmp word ptr [cwd], 0
    je .Lvolume_failed
    call media_check
    jc .Lvolume_failed
    mov byte ptr [cache_valid], 0
    xor ax, ax
    xor dx, dx
    call read_sector
    jc .Lvolume_failed
    push ds
    pop es
    mov si, offset volume_boot
    mov di, offset sector_buffer
    mov cx, 256
    repe cmpsw
    jne .Lvolume_failed
    pop es
    popa
    clc
    ret
.Lvolume_failed:
    mov byte ptr [write_fault], 1
    pop es
    popa
    stc
    ret

/* The native mount supports two FAT copies. Validate all writable ranges
 * against the pinned BPB, including the final partial FAT sector. */
write_preflight:
    mov word ptr [writer_error], 4
    cmp byte ptr [write_fault], 0
    jne .Lpreflight_failed
    call check_volume
    jc .Lpreflight_failed
    call geometry
    jc .Lpreflight_failed
    cmp word ptr [volume_boot+11], 512
    jne .Lpreflight_failed
    cmp byte ptr [volume_boot+16], 2
    jne .Lpreflight_failed
    xor ax, ax
    mov al, [volume_boot+13]
    cmp ax, [spc]
    jne .Lpreflight_failed
    mov ax, [volume_boot+14]
    cmp ax, [fat_sector]
    jne .Lpreflight_failed
    or ax, ax
    jz .Lpreflight_failed
    mov ax, [volume_boot+22]
    cmp ax, [fat_sectors]
    jne .Lpreflight_failed
    or ax, ax
    jz .Lpreflight_failed
    add ax, [fat_sector]
    jc .Lpreflight_failed
    mov [second_fat], ax
    add ax, [fat_sectors]
    jc .Lpreflight_failed
    mov [write_root_sector], ax
    mov bx, [volume_boot+17]
    cmp bx, [root_entries]
    jne .Lpreflight_failed
    add bx, 15
    jc .Lpreflight_failed
    shr bx, 4
    add ax, bx
    jc .Lpreflight_failed
    cmp ax, [data_sector]
    jne .Lpreflight_failed
    xor dx, dx
    mov ax, [volume_boot+19]
    or ax, ax
    jnz .Lpreflight_total
    mov ax, [volume_boot+32]
    mov dx, [volume_boot+34]
.Lpreflight_total:
    mov [volume_sectors], ax
    mov [volume_sectors+2], dx
    sub ax, [data_sector]
    sbb dx, 0
    jc .Lpreflight_failed
    cmp dx, [spc]
    jae .Lpreflight_failed
    div word ptr [spc]
    add ax, 2
    jc .Lpreflight_failed
    cmp ax, [cluster_limit]
    jne .Lpreflight_failed
    mov ax, [cluster_limit]
    dec ax
    call fat_position
    jc .Lpreflight_failed
    cmp bx, 511
    jne .Lpreflight_capacity
    inc ax
    cmp ax, [fat_sectors]
    jae .Lpreflight_failed
.Lpreflight_capacity:
    cmp byte ptr [drive], 0
    jne .Lpreflight_disk
    mov ax, [write_root_sector]
    mov cx, 512
    mul cx
    or dx, dx
    jnz .Lpreflight_failed
    cmp ax, [floppy_root]
    jne .Lpreflight_failed
    push es
    push 0xf000
    pop es
    cmp byte ptr es:[0xf890], 0
    pop es
    je .Lpreflight_ready
    mov word ptr [writer_error], 1
    jmp .Lpreflight_failed
.Lpreflight_disk:
    mov ax, [root_sector]
    cmp ax, [write_root_sector]
    jne .Lpreflight_failed
    cmp byte ptr [fat_bits], 12
    jne .Lpreflight_ready
    /* Native FAT12 cache begins at E000 and must end before F800. */
    cmp word ptr [fat_sectors], 12
    ja .Lpreflight_failed
.Lpreflight_ready:
    /* Refuse a stale map if the directory chain changed since navigation. */
    mov ax, [cwd]
    call build_chain
    jc .Lpreflight_failed
    mov cx, [staging_count]
    cmp cx, [chain_count]
    jne .Lpreflight_failed
    push es
    push ds
    pop es
    mov si, offset staging_chain
    mov di, offset chain
    repe cmpsw
    pop es
    jne .Lpreflight_failed
    mov word ptr [alloc_hint], 2
    clc
    ret
.Lpreflight_failed:
    stc
    ret

/* AX cluster -> AX FAT-sector index, BX byte offset. AX/BX/DX clobbered. */
fat_position:
    cmp byte ptr [fat_bits], 12
    jne .Lposition16
    mov bx, ax
    shr ax, 1
    add ax, bx
    jc .Lposition_bad
    mov bx, ax
    and bx, 511
    shr ax, 9
    jmp .Lposition_check
.Lposition16:
    mov bx, ax
    shl bx, 1
    and bx, 511
    shr ax, 8
.Lposition_check:
    cmp ax, [fat_sectors]
    jae .Lposition_bad
    clc
    ret
.Lposition_bad:
    stc
    ret

/* AX LBA -> AX cylinder/head, BX sector(1-based)/count=1, DS=F000.
 * A checked seek uses native command helpers, bypassing the fatal UI path. */
floppy_seek:
    xor dx, dx
    xor bx, bx
    mov bl, [0xf8e8]
    or bl, bl
    jz .Lseek_failed
    div bx
    cmp ax, 160
    jae .Lseek_failed
    mov bl, dl
    inc bl
    mov bh, 1
    xor ah, ah
    shr al, 1
    rcl ah, 1
    push ax
    push bx
    mov byte ptr [0xf8e1], 3
    mov byte ptr [0xf8e2], 0x0f
    mov byte ptr [0xf8e3], 0
    mov [0xf8e4], al
    cli
    aux_near 0x1287c
    sti
    aux_near 0x1293d
    aux_near 0x12846
    cmp al, 0x20
    pop bx
    pop ax
    jne .Lseek_failed
    clc
    ret
.Lseek_failed:
    stc
    ret

/* AX LBA -> sector_buffer. The native DMA read buffer remains F000:5000. */
floppy_read_sector:
    pusha
    push ds
    push es
    push 0xf000
    pop ds
    mov word ptr [0xf8a6], 0
    mov word ptr [0xf8a8], 0
    call floppy_seek
    jc .Lfloppy_read_bad
    aux_near 0x1256e /* read body, after its unchecked seek */
    test byte ptr [0xf8f4], 0xc0
    jnz .Lfloppy_read_bad
    push cs
    pop es
    mov si, 0x5000
    mov di, offset sector_buffer
    mov cx, 256
    rep movsw
    pop es
    pop ds
    popa
    clc
    ret
.Lfloppy_read_bad:
    pop es
    pop ds
    popa
    stc
    ret

/* Runtime hook at EXE 12697. Caller has already set DS=F000. */
floppy_write_result:
    cmp byte ptr cs:[safe_floppy_write], 1
    jne .Lfloppy_result_native
    test byte ptr [0xf8f4], 0xc0
    jnz .Lfloppy_result_bad
    clc
    jmp far ptr cs:[floppy_write_return]
.Lfloppy_result_bad:
    stc
    jmp far ptr cs:[floppy_write_return]
.Lfloppy_result_native:
    test byte ptr [0xf8f4], 0xc0
    jmp far ptr cs:[floppy_write_continue]

/* DX:AX relative LBA, DS:SI = 512 bytes. Always preserves every register.
 * Successful FAT writes are also copied into the native filesystem caches.
 * On an uncertain write, latch a fault and never try a blind rollback. */
write_sector:
    pusha
    push es
    mov byte ptr [io_active], 1
    mov byte ptr [cache_valid], 0
    cmp byte ptr [write_fault], 0
    jne .Lwrite_sector_bad
    cmp dx, [volume_sectors+2]
    ja .Lwrite_sector_bad
    jb .Lwrite_sector_lower_bound
    cmp ax, [volume_sectors]
    jae .Lwrite_sector_bad
.Lwrite_sector_lower_bound:
    or dx, dx
    jnz .Lwrite_sector_in_range
    cmp ax, [fat_sector]
    jb .Lwrite_sector_bad
.Lwrite_sector_in_range:
    cmp byte ptr [drive], 0
    je .Lwrite_sector_floppy
    add ax, [partition]
    adc dx, [partition+2]
    jc .Lwrite_sector_bad
    mov bx, dx
    mov dx, ax
    push ds
    pop es
    mov di, si
    mov cx, 1
    mov ah, 2
    push bp
    int 0x2d
    pop bp
    jc .Lwrite_sector_bad
    jmp .Lwrite_sector_ok
.Lwrite_sector_floppy:
    or dx, dx
    jnz .Lwrite_sector_bad
    push ax
    push ds
    push 0xf000
    pop es
    mov di, 0x5000
    mov cx, 256
    rep movsw
    push es
    pop ds
    mov word ptr [0xf8a6], 0
    mov word ptr [0xf8a8], 0
    pop es /* original DS=CS; keep it for the source-segment restore */
    pop ax
    call floppy_seek
    jc .Lwrite_floppy_failed
    mov si, 0x5000
    mov byte ptr cs:[safe_floppy_write], 1
    aux_near 0x12608 /* DMA write body; no unchecked seek */
    mov byte ptr cs:[safe_floppy_write], 0
    jc .Lwrite_floppy_failed
    push cs
    pop ds
    jmp .Lwrite_sector_ok
.Lwrite_floppy_failed:
    push cs
    pop ds
.Lwrite_sector_bad:
    mov byte ptr [io_active], 0
    mov byte ptr [write_fault], 1
    mov word ptr [writer_error], 4
    pop es
    popa
    stc
    ret
.Lwrite_sector_ok:
    mov byte ptr [io_active], 0
    pop es
    popa
    clc
    ret

/* Mirror compare/copy: AX relative LBA, DI staging buffer, registers saved. */
stage_fat_sector:
    pusha
    push es
    xor dx, dx
    mov byte ptr [cache_valid], 0
    call read_sector
    jc .Lstage_fat_bad
    push ds
    pop es
    push di
    mov si, offset sector_buffer
    mov cx, 256
    rep movsw
    pop di
    add ax, [fat_sectors]
    jc .Lstage_fat_bad
    call read_sector
    jc .Lstage_fat_bad
    mov si, offset sector_buffer
    mov cx, 256
    repe cmpsw
    jne .Lstage_fat_bad
    pop es
    popa
    clc
    ret
.Lstage_fat_bad:
    mov byte ptr [write_fault], 1
    mov word ptr [writer_error], 4
    pop es
    popa
    stc
    ret

/* AX = first FAT relative LBA; DS:SI = committed page. */
sync_native_fat:
    pusha
    push es
    push 0xf000
    pop es
    sub ax, [fat_sector]
    cmp byte ptr [drive], 0
    je .Lsync_floppy
    cmp byte ptr [fat_bits], 12
    je .Lsync_disk12
    xor bx, bx
    mov bl, es:[0xf998]
    sub ax, bx
    cmp ax, 1
    ja .Lsync_done
    shl ax, 9
    add ax, 0xf99b
    mov di, ax
    mov cx, 256
    rep movsw
    jmp .Lsync_done
.Lsync_disk12:
    shl ax, 9
    add ax, 0xe000
    mov di, ax
    mov cx, 256
    rep movsw
    jmp .Lsync_done
.Lsync_floppy:
    shl ax, 9
    add ax, es:[0xf89e]
    mov di, ax
    push si
    mov cx, 256
    rep movsw
    pop si
    mov di, ax
    add di, es:[0xf89a]
    mov cx, 256
    rep movsw
.Lsync_done:
    pop es
    popa
    ret

/* AX cluster, DX new FAT value. Preserve the adjacent FAT12 nibble.
 * Compare both copies before changing either; write mirror then first FAT.
 * A two-sector FAT12 entry is staged in full before any mutation. */
fat_set:
    pusha
    push es
    call valid_cluster
    jc .Lset_fat_bad
    mov [fat_edit_cluster], ax
    mov [fat_edit_value], dx
    call fat_position
    jc .Lset_fat_bad
    mov [fat_edit_offset], bx
    mov word ptr [fat_edit_pages], 1
    cmp bx, 511
    jne .Lset_fat_position
    mov word ptr [fat_edit_pages], 2
    inc ax
    cmp ax, [fat_sectors]
    jae .Lset_fat_bad
    dec ax
.Lset_fat_position:
    add ax, [fat_sector]
    mov [fat_edit_lba], ax
    mov di, offset fat_buffer
    call stage_fat_sector
    jc .Lset_fat_bad
    cmp word ptr [fat_edit_pages], 2
    jne .Lset_fat_modify
    inc ax
    add di, 512
    call stage_fat_sector
    jc .Lset_fat_bad
.Lset_fat_modify:
    mov bx, [fat_edit_offset]
    mov dx, [fat_edit_value]
    cmp byte ptr [fat_bits], 16
    je .Lset_fat_word
    and dx, 0x0fff
    mov ax, [fat_buffer+bx]
    test word ptr [fat_edit_cluster], 1
    jz .Lset_fat_even
    and ax, 0x000f
    shl dx, 4
    jmp .Lset_fat_merge
.Lset_fat_even:
    and ax, 0xf000
.Lset_fat_merge:
    or dx, ax
.Lset_fat_word:
    mov [fat_buffer+bx], dx
    mov ax, [fat_edit_lba]
    add ax, [fat_sectors]
    xor dx, dx
    mov si, offset fat_buffer
    mov cx, [fat_edit_pages]
.Lset_fat_mirror:
    call write_sector
    jc .Lset_fat_bad
    inc ax
    add si, 512
    loop .Lset_fat_mirror
    mov ax, [fat_edit_lba]
    mov si, offset fat_buffer
    mov cx, [fat_edit_pages]
.Lset_fat_primary:
    call write_sector
    jc .Lset_fat_bad
    call sync_native_fat
    inc ax
    add si, 512
    loop .Lset_fat_primary
    pop es
    popa
    clc
    ret
.Lset_fat_bad:
    pop es
    popa
    stc
    ret

/* Return a newly reserved EOC cluster in AX, all other registers preserved.
 * Search is bounded and wraps once. Metadata is not published until CLOSE. */
allocate_cluster:
    push bx
    push cx
    push dx
    mov cx, [cluster_limit]
    sub cx, 2
    mov bx, [alloc_hint]
    cmp bx, [cluster_limit]
    jb .Lallocate_scan
    mov bx, 2
.Lallocate_scan:
    mov ax, bx
    call valid_cluster
    jc .Lallocate_next
    call fat_raw
    jc .Lallocate_io
    or ax, ax
    jnz .Lallocate_next
    mov ax, bx
    mov dx, 0xffff
    call fat_set
    jc .Lallocate_io
    inc bx
    mov [alloc_hint], bx
    pop dx
    pop cx
    pop bx
    clc
    ret
.Lallocate_next:
    inc bx
    cmp bx, [cluster_limit]
    jb .Lallocate_continue
    mov bx, 2
.Lallocate_continue:
    loop .Lallocate_scan
    mov word ptr [writer_error], 3
    jmp .Lallocate_failed
.Lallocate_io:
    mov byte ptr [write_fault], 1
    mov word ptr [writer_error], 4
.Lallocate_failed:
    pop dx
    pop cx
    pop bx
    stc
    ret

/* AX cluster -> DX:AX first data sector. */
cluster_sector:
    sub ax, 2
    mul word ptr [spc]
    add ax, [data_sector]
    adc dx, 0
    ret

/* Validate before DELETE or freeing an old/aborted file. The bounded walk
 * detects cycles without a file-size cap; never free a current/parent dir.
 * A malformed cross-link to another ordinary file is not a disk repair job. */
validate_file_chain:
    pusha
    or ax, ax
    jz .Lfile_chain_ok
    mov dx, [cluster_limit]
    sub dx, 2
.Lfile_chain_loop:
    call valid_cluster
    jc .Lfile_chain_bad
    cmp ax, [cwd]
    je .Lfile_chain_bad
    mov cx, [chain_count]
    xor bx, bx
.Lfile_not_directory:
    jcxz .Lfile_parents
    cmp ax, [chain+bx]
    je .Lfile_chain_bad
    add bx, 2
    loop .Lfile_not_directory
.Lfile_parents:
    mov cx, [depth]
    xor bx, bx
.Lfile_not_parent:
    jcxz .Lfile_next
    cmp ax, [parents+bx]
    je .Lfile_chain_bad
    add bx, 2
    loop .Lfile_not_parent
.Lfile_next:
    call fat_next
    jc .Lfile_chain_bad
    cmp ax, 0xffff
    je .Lfile_chain_ok
    dec dx
    jnz .Lfile_chain_loop
.Lfile_chain_bad:
    popa
    stc
    ret
.Lfile_chain_ok:
    popa
    clc
    ret

free_file_chain:
    pusha
    call validate_file_chain
    jc .Lfree_file_bad
    or ax, ax
    jz .Lfree_file_ok
.Lfree_file_loop:
    mov bx, ax
    call fat_next
    jc .Lfree_file_bad
    push ax
    mov ax, bx
    xor dx, dx
    call fat_set
    pop ax
    jc .Lfree_file_bad
    cmp ax, 0xffff
    jne .Lfree_file_loop
.Lfree_file_ok:
    popa
    clc
    ret
.Lfree_file_bad:
    mov byte ptr [write_fault], 1
    mov word ptr [writer_error], 4
    popa
    stc
    ret

/* The common directory mapper also supplies the exact physical slot.
 * AX logical index (includes synthetic parent), outputs via pinned fields.
 * Called only for a real existing slot, after entry_at succeeded. */
pin_slot:
    pusha
    dec ax
    mov bx, ax
    and bx, 15
    shl bx, 5
    mov [slot_offset], bx
    shr ax, 4
    xor dx, dx
    div word ptr [spc]
    push dx
    shl ax, 1
    mov bx, ax
    mov ax, [chain+bx]
    call cluster_sector
    pop cx
    add ax, cx
    adc dx, 0
    mov [slot_lba], ax
    mov [slot_lba+2], dx
    popa
    ret

/* Append a zeroed cluster to a full directory, then extend its RAM map.
 * Data sectors are zeroed before the directory chain link is published. */
grow_directory:
    pusha
    cmp word ptr [chain_count], MAX_CHAIN
    jae .Lgrow_limit
    mov ax, [chain_count]
    inc ax
    mul word ptr [spc]
    or dx, dx
    jnz .Lgrow_limit
    cmp ax, 4094
    ja .Lgrow_limit
    call allocate_cluster
    jc .Lgrow_bad
    mov [grown_cluster], ax
    call cluster_sector
    mov si, offset zero_sector
    mov cx, [spc]
.Lgrow_zero:
    call write_sector
    jc .Lgrow_bad
    add ax, 1
    adc dx, 0
    loop .Lgrow_zero
    mov bx, [chain_count]
    shl bx, 1
    mov ax, [chain+bx-2]
    mov dx, [grown_cluster]
    call fat_set
    jc .Lgrow_bad
    mov [chain+bx], dx
    inc word ptr [chain_count]
    popa
    clc
    ret
.Lgrow_limit:
    mov word ptr [writer_error], 2
.Lgrow_bad:
    popa
    stc
    ret

/* Names use the existing Classic 16+dot+3 convention, not VFAT. */
validate_lookup:
    cmp byte ptr [lookup], 0x20
    jbe .Llookup_bad
    cmp byte ptr [lookup], 0x2e
    je .Llookup_bad
    cmp byte ptr [lookup+16], 0x2e
    jne .Llookup_bad
    mov si, offset lookup
    mov cx, 20
.Llookup_char:
    lodsb
    cmp al, 0x20
    jb .Llookup_bad
    cmp al, 0x7b
    jae .Llookup_bad
    cmp al, 0x22
    je .Llookup_bad
    cmp al, 0x2a
    je .Llookup_bad
    cmp al, 0x2f
    je .Llookup_bad
    cmp al, 0x3a
    je .Llookup_bad
    cmp al, 0x3c
    je .Llookup_bad
    cmp al, 0x3e
    je .Llookup_bad
    cmp al, 0x3f
    je .Llookup_bad
    cmp al, 0x5c
    je .Llookup_bad
    loop .Llookup_char
    clc
    ret
.Llookup_bad:
    mov word ptr [writer_error], 2
    stc
    ret

/* Reject protected, directory, volume and VFAT-owned entries before any
 * mutation. AX logical index; restore the selected entry after looking back. */
mutable_file:
    test byte ptr [entry+11], 0x1f
    jnz .Lmutable_bad
    cmp word ptr [entry+26], 0
    jne .Lmutable_chain
    mov bx, [entry+28]
    or bx, [entry+30]
    jnz .Lmutable_bad
.Lmutable_chain:
    push ax
    mov ax, [entry+26]
    call validate_file_chain
    pop ax
    jc .Lmutable_bad
slot_without_lfn:
    cmp ax, 1
    jbe .Lmutable_ok
    push ax
    dec ax
    call entry_at
    jc .Lmutable_previous_bad
    cmp byte ptr [entry], 0xe5
    je .Lmutable_previous_ok
    cmp byte ptr [entry+11], 0x0f
    je .Lmutable_previous_bad
.Lmutable_previous_ok:
    pop ax
    call entry_at
    ret
.Lmutable_previous_bad:
    pop ax
.Lmutable_bad:
    mov word ptr [writer_error], 4
    stc
    ret
.Lmutable_ok:
    clc
    ret

/* One bounded directory scan distinguishes a full directory from I/O
 * failure. Existing files can be replaced with a new chain at CLOSE.
 * Explicit native DELETE-before-CREATE flows retain their original order. */
service_create:
    frame
    mov [create_time], cx
    mov [create_date], dx
    call copy_lookup
    call validate_lookup
    jc writer_service_error
    push ds
    pop es
    mov si, offset lookup
    mov di, offset writer_entry
    aux_near 0x121b8
    call write_preflight
    jc writer_service_error
    mov ax, [chain_count]
    mul word ptr [spc]
    shl ax, 4
    mov [directory_slots], ax
    mov word ptr [free_slot], 0
    mov word ptr [writer_old_cluster], 0
    mov ax, 1
.Lcreate_scan:
    cmp ax, [directory_slots]
    ja .Lcreate_scan_end
    call entry_at
    jc writer_service_error
    cmp byte ptr [entry], 0
    je .Lcreate_end_marker
    cmp byte ptr [entry], 0xe5
    jne .Lcreate_occupied
    cmp word ptr [free_slot], 0
    jne .Lcreate_next
    mov [free_slot], ax
    jmp .Lcreate_next
.Lcreate_occupied:
    /* Hidden/protected files still participate in collision detection. */
    cmp byte ptr [entry+11], 0x0f
    je .Lcreate_next
    push ax
    call expand_entry
    mov di, offset lookup
    mov cx, 20
    repe cmpsb
    pop ax
    jne .Lcreate_check_short_collision
    call mutable_file
    jc writer_service_error
    mov dx, [entry+26]
    mov [writer_old_cluster], dx
    jmp .Lcreate_pin
.Lcreate_check_short_collision:
    /* Keep a unique on-disk short-name key, including existing folders. */
    push ax
    mov si, offset entry
    mov di, offset writer_entry
    mov cx, 11
    repe cmpsb
    pop ax
    jne .Lcreate_next
    mov word ptr [writer_error], 2
    jmp writer_service_error
.Lcreate_next:
    inc ax
    jmp .Lcreate_scan
.Lcreate_end_marker:
    cmp word ptr [free_slot], 0
    jne .Lcreate_scan_end
    mov [free_slot], ax
.Lcreate_scan_end:
    mov ax, [free_slot]
    or ax, ax
    jnz .Lcreate_free
    call grow_directory
    jc writer_service_error
    mov ax, [directory_slots]
    inc ax
    mov bx, [spc]
    shl bx, 4
    add [directory_slots], bx
.Lcreate_free:
    call entry_at
    jc writer_service_error
    call slot_without_lfn
    jc writer_service_error
.Lcreate_pin:
    mov [writer_slot], ax
    call pin_slot
    mov ax, [slot_lba]
    mov [writer_lba], ax
    mov ax, [slot_lba+2]
    mov [writer_lba+2], ax
    mov ax, [slot_offset]
    mov [writer_offset], ax
    push ds
    pop es
    mov si, offset entry
    mov di, offset writer_before
    mov cx, 16
    rep movsw
    mov di, offset writer_entry
    mov cx, 16
    xor ax, ax
    rep stosw
    mov di, offset writer_entry
    mov si, offset lookup
    aux_near 0x121b8 /* native pure name encoder, with both DS/ES=CS */
    mov ax, [create_time]
    mov [writer_entry+22], ax
    mov ax, [create_date]
    mov [writer_entry+24], ax
    mov byte ptr [writer_entry+11], 0x20
    xor ax, ax
    mov [writer_first], ax
    mov [writer_last], ax
    mov [writer_sector], ax
    mov [writer_used], ax
    mov [writer_size], ax
    mov [writer_size+2], ax
    mov byte ptr [writer_state], 1
    jmp finish

writer_service_error:
    mov ax, [writer_error]
    stc
    jmp finish

/* Reserve the next data cluster only when another sector is needed.
 * An exact sector/cluster boundary never allocates an unused extra cluster. */
writer_prepare_sector:
    pusha
    cmp word ptr [writer_last], 0
    je .Lwriter_allocate
    mov ax, [writer_sector]
    cmp ax, [spc]
    jb .Lwriter_sector_ready
.Lwriter_allocate:
    call allocate_cluster
    jc .Lwriter_prepare_bad
    mov bx, [writer_last]
    or bx, bx
    jz .Lwriter_first_cluster
    mov dx, ax
    mov ax, bx
    call fat_set
    jc .Lwriter_prepare_bad
    mov ax, dx
    jmp .Lwriter_allocated
.Lwriter_first_cluster:
    mov [writer_first], ax
.Lwriter_allocated:
    mov [writer_last], ax
    mov word ptr [writer_sector], 0
.Lwriter_sector_ready:
    popa
    clc
    ret
.Lwriter_prepare_bad:
    popa
    stc
    ret

writer_flush_sector:
    pusha
    cmp word ptr [writer_used], 0
    je .Lflush_sector_done
    call writer_prepare_sector
    jc .Lflush_sector_bad
    mov ax, [writer_last]
    call cluster_sector
    add ax, [writer_sector]
    adc dx, 0
    mov si, offset write_buffer
    call write_sector
    jc .Lflush_sector_bad
    inc word ptr [writer_sector]
    mov word ptr [writer_used], 0
.Lflush_sector_done:
    popa
    clc
    ret
.Lflush_sector_bad:
    popa
    stc
    ret

/* Fail a stream once. Capacity errors can release unpublished allocations;
 * after uncertain I/O, leave them alone rather than risking double-free. */
fail_writer:
    mov byte ptr [writer_state], 2
    cmp byte ptr [write_fault], 0
    jne .Lwriter_failed_done
    mov ax, [writer_first]
    call free_file_chain
    jc .Lwriter_failed_done
    mov word ptr [writer_first], 0
    mov word ptr [writer_last], 0
.Lwriter_failed_done:
    stc
    ret

service_write_byte:
    frame
    cmp byte ptr [writer_state], 1
    jne writer_service_error
    mov bx, [writer_used]
    mov [write_buffer+bx], al
    inc word ptr [writer_used]
    add word ptr [writer_size], 1
    adc word ptr [writer_size+2], 0
    jc .Lstream_full
    cmp word ptr [writer_used], 512
    jne .Lstream_ok
    call writer_flush_sector
    jc .Lstream_failed
.Lstream_ok:
    xor ax, ax
    jmp finish
.Lstream_full:
    mov word ptr [writer_error], 3
.Lstream_failed:
    call fail_writer
    jmp writer_service_error

service_write_block:
    frame
    cmp byte ptr [writer_state], 1
    jne writer_service_error
.Lwrite_block_loop:
    or cx, cx
    jz .Lstream_ok
    mov bx, 512
    sub bx, [writer_used]
    cmp bx, cx
    jbe .Lwrite_block_chunk
    mov bx, cx
.Lwrite_block_chunk:
    sub cx, bx
    push cx
    mov cx, bx
    mov di, offset write_buffer
    add di, [writer_used]
    add [writer_used], bx
    add [writer_size], bx
    adc word ptr [writer_size+2], 0
    jc .Lwrite_block_overflow
    push ds
    push es
    mov ax, es
    mov ds, ax
    push cs
    pop es
    rep movsb
    pop es
    pop ds
    pop cx
    cmp word ptr [writer_used], 512
    jne .Lwrite_block_loop
    call writer_flush_sector
    jc .Lstream_failed
    jmp .Lwrite_block_loop
.Lwrite_block_overflow:
    pop cx
    jmp .Lstream_full

/* If CREATE consumed the end marker, ensure the next entry remains an end
 * marker even on a pre-existing directory with garbage beyond its old end. */
preserve_end_marker:
    pusha
    cmp byte ptr [writer_before], 0
    jne .Lend_marker_done
    mov ax, [writer_slot]
    inc ax
    cmp ax, [directory_slots]
    ja .Lend_marker_done
    call entry_at
    jc .Lend_marker_bad
    call pin_slot
    mov bx, [slot_offset]
    mov byte ptr [sector_buffer+bx], 0
    mov ax, [slot_lba]
    mov dx, [slot_lba+2]
    mov si, offset sector_buffer
    call write_sector
    jc .Lend_marker_bad
.Lend_marker_done:
    popa
    clc
    ret
.Lend_marker_bad:
    popa
    stc
    ret

/* Compare the old slot before publishing its replacement. Any intervening
 * change is a context error, never permission to overwrite unknown bytes. */
commit_writer_entry:
    pusha
    push es
    mov ax, [writer_lba]
    mov dx, [writer_lba+2]
    mov byte ptr [cache_valid], 0
    call read_sector
    jc .Lcommit_entry_bad
    push ds
    pop es
    mov di, offset sector_buffer
    add di, [writer_offset]
    push di
    mov si, offset writer_before
    mov cx, 16
    repe cmpsw
    pop di
    jne .Lcommit_entry_bad
    mov si, offset writer_entry
    mov cx, 16
    rep movsw
    mov si, offset sector_buffer
    call write_sector
    jc .Lcommit_entry_bad
    pop es
    popa
    clc
    ret
.Lcommit_entry_bad:
    mov byte ptr [write_fault], 1
    mov word ptr [writer_error], 4
    pop es
    popa
    stc
    ret

service_close_write:
    frame
    cmp byte ptr [writer_state], 0
    je .Lclose_readonly
    cmp byte ptr [writer_state], 2
    je .Lclose_failed_state
    call check_volume
    jc .Lclose_stream_failed
    /* Zero only the unused tail of the final sector, preserving file size. */
    push ds
    pop es
    mov di, offset write_buffer
    add di, [writer_used]
    mov cx, 512
    sub cx, [writer_used]
    xor ax, ax
    rep stosb
    call writer_flush_sector
    jc .Lclose_stream_failed
    call preserve_end_marker
    jc .Lclose_stream_failed
    mov ax, [writer_first]
    mov [writer_entry+26], ax
    mov ax, [writer_size]
    mov [writer_entry+28], ax
    mov ax, [writer_size+2]
    mov [writer_entry+30], ax
    call commit_writer_entry
    jc .Lclose_stream_failed
    /* The new file is now published. Never free its chain on later errors. */
    mov word ptr [writer_first], 0
    mov ax, [writer_old_cluster]
    call free_file_chain
    jc .Lclose_failed_state
    mov byte ptr [writer_state], 0
    mov byte ptr [cache_valid], 0
.Lclose_readonly:
    xor ax, ax
    jmp finish
.Lclose_stream_failed:
    call fail_writer
.Lclose_failed_state:
    mov byte ptr [writer_state], 0
    jmp writer_service_error

/* Required by Classic overwrite and multi-file SAVE. Only regular files;
 * directory DELETE, RENAME, MKDIR, FORMAT and WIPE remain outside stage 2. */
service_delete:
    frame
    call copy_lookup
    call write_preflight
    jc writer_service_error
    call find_entry
    jc service_error
    call mutable_file
    jc writer_service_error
    call pin_slot
    mov dx, [entry+26]
    mov [writer_old_cluster], dx
    mov dx, [slot_lba]
    mov [writer_lba], dx
    mov dx, [slot_lba+2]
    mov [writer_lba+2], dx
    mov dx, [slot_offset]
    mov [writer_offset], dx
    push ds
    pop es
    mov si, offset entry
    mov di, offset writer_before
    mov cx, 16
    rep movsw
    mov si, offset entry
    mov di, offset writer_entry
    mov cx, 16
    rep movsw
    mov byte ptr [writer_entry], 0xe5
    call commit_writer_entry
    jc writer_service_error
    mov ax, [writer_old_cluster]
    call free_file_chain
    jc writer_service_error
    xor ax, ax
    jmp finish

/* Parallel write state is private: enumeration never moves a pending slot. */
.align 2
old_fatal: .word 0x0ef7, 0
io_active: .byte 0
.align 2
floppy_write_continue: .word 0x1a1c, 0
floppy_write_return: .word 0x1a21, 0
safe_floppy_write: .byte 0
volume_pinned: .byte 0
writer_state: .byte 0 /* 0 idle/read, 1 writing, 2 failed (CLOSE returns error) */
write_fault: .byte 0 /* ambiguous media/FAT failure: explicit remount required */
.align 2
writer_error: .word 4
second_fat: .word 0
write_root_sector: .word 0
volume_sectors: .long 0
alloc_hint: .word 2
fat_edit_cluster: .word 0
fat_edit_value: .word 0
fat_edit_offset: .word 0
fat_edit_pages: .word 0
fat_edit_lba: .word 0
grown_cluster: .word 0
slot_lba: .long 0
slot_offset: .word 0
writer_slot: .word 0
writer_lba: .long 0
writer_offset: .word 0
writer_first: .word 0
writer_last: .word 0
writer_sector: .word 0
writer_used: .word 0
writer_size: .long 0
writer_old_cluster: .word 0
create_time: .word 0
create_date: .word 0
free_slot: .word 0
directory_slots: .word 0
writer_entry: .space 32
writer_before: .space 32
.balign 512
volume_boot: .space 512
fat_buffer: .space 1024
write_buffer: .space 512
zero_sector: .space 512

/* End writer.inc */
.align 2
old_fs: .word 0x06be, 0
main_segment: .word 0
aux_segment: .word 0
main_continue: .word 0xe995, 0
main_return: .word 0xe9a1, 0
filter_continue: .word 0xe3ec, 0
filter_return: .word 0xe407, 0
empty_name: .ascii "                .   "
parent_entry:
    .ascii "..         "
    .byte 0x10
    .space 20
.align 2
state_begin:
installed: .byte 0
drive: .byte 0xff
cache_valid: .byte 0
fat_bits: .byte 0
cwd: .word 0
next_cwd: .word 0
depth: .word 0
cursor: .word 0xffff
spc: .word 0
data_sector: .word 0
fat_sector: .word 0
fat_sectors: .word 0
cluster_limit: .word 0
root_sector: .word 0
root_entries: .word 0
floppy_root: .word 0
partition: .long 0
cache_lba: .long 0
chain_count: .word 0
staging_count: .word 0
parents: .space MAX_DEPTH*2
entry: .space 32
name: .space 20
lookup: .space 20
.align 2
chain: .space MAX_CHAIN*2
staging_chain: .space MAX_CHAIN*2
.balign 512
sector_buffer: .space 512
state_end:
.align 16
extension_end:

.endif /* directory_io */
/* directory_management: assembly unit 5. */
.if MOD_UNIT == 5
/* C05 delta, same CS as C04. Only this suffix is appended to the SYS.
 * Native LOAD F5 opens folder management; no firmware execution on host.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
/* Begin c04_bindings.inc */
/* Identity-gated C04 same-CS references; generated by C05 builder. */
.set MAX_CHAIN, 256
.set MAX_DEPTH, 16
.set main_continue, c05_start - 0x2a10 + 0x2208
.set main_return, c05_start - 0x2a10 + 0x220c
.set filter_continue, c05_start - 0x2a10 + 0x2210
.set filter_return, c05_start - 0x2a10 + 0x2214
.set floppy_write_continue, c05_start - 0x2a10 + 0x16fe
.set floppy_write_return, c05_start - 0x2a10 + 0x1702
.set reset_context, c05_start - 0x2a10 + 0x475
.set drive, c05_start - 0x2a10 + 0x224d
.set installed, c05_start - 0x2a10 + 0x224c
.set service_navigate, c05_start - 0x2a10 + 0xa29
.set service_bad_request, c05_start - 0x2a10 + 0x46a
.set cwd, c05_start - 0x2a10 + 0x2250
.set cache_valid, c05_start - 0x2a10 + 0x224e
.set service_media, c05_start - 0x2a10 + 0x43b
.set service_first, c05_start - 0x2a10 + 0x5b6
.set service_next, c05_start - 0x2a10 + 0x5d4
.set service_previous, c05_start - 0x2a10 + 0x5e4
.set service_open, c05_start - 0x2a10 + 0x99b
.set service_find, c05_start - 0x2a10 + 0x97e
.set service_io_error, c05_start - 0x2a10 + 0xb67
.set service_write_blocked, c05_start - 0x2a10 + 0x45c
.set finish, c05_start - 0x2a10 + 0x421
.set call_original, c05_start - 0x2a10 + 0x432
.set media_lost, c05_start - 0x2a10 + 0xb76
.set service_error, c05_start - 0x2a10 + 0x634
.set depth, c05_start - 0x2a10 + 0x2254
.set cursor, c05_start - 0x2a10 + 0x2256
.set volume_pinned, c05_start - 0x2a10 + 0x1707
.set geometry, c05_start - 0x2a10 + 0x497
.set fat_bits, c05_start - 0x2a10 + 0x224f
.set spc, c05_start - 0x2a10 + 0x2258
.set data_sector, c05_start - 0x2a10 + 0x225a
.set fat_sector, c05_start - 0x2a10 + 0x225c
.set fat_sectors, c05_start - 0x2a10 + 0x225e
.set cluster_limit, c05_start - 0x2a10 + 0x2260
.set floppy_root, c05_start - 0x2a10 + 0x2266
.set root_entries, c05_start - 0x2a10 + 0x2264
.set partition, c05_start - 0x2a10 + 0x2268
.set root_sector, c05_start - 0x2a10 + 0x2262
.set media_check, c05_start - 0x2a10 + 0x595
.set enumerate_forward, c05_start - 0x2a10 + 0x600
.set entry_at, c05_start - 0x2a10 + 0x676
.set acceptable_entry, c05_start - 0x2a10 + 0x644
.set enum_success, c05_start - 0x2a10 + 0x62a
.set entry, c05_start - 0x2a10 + 0x2294
.set expand_entry, c05_start - 0x2a10 + 0x89d
.set empty_name, c05_start - 0x2a10 + 0x2218
.set chain_count, c05_start - 0x2a10 + 0x2270
.set read_sector, c05_start - 0x2a10 + 0x721
.set parent_entry, c05_start - 0x2a10 + 0x222c
.set cache_lba, c05_start - 0x2a10 + 0x226c
.set floppy_read_sector, c05_start - 0x2a10 + 0xe1c
.set fat_next, c05_start - 0x2a10 + 0x796
.set fat_raw, c05_start - 0x2a10 + 0x7b6
.set valid_cluster, c05_start - 0x2a10 + 0x82d
.set build_chain, c05_start - 0x2a10 + 0x84f
.set staging_count, c05_start - 0x2a10 + 0x2272
.set name, c05_start - 0x2a10 + 0x22b4
.set copy_lookup, c05_start - 0x2a10 + 0x92e
.set lookup, c05_start - 0x2a10 + 0x22c8
.set find_entry, c05_start - 0x2a10 + 0x948
.set parents, c05_start - 0x2a10 + 0x2274
.set next_cwd, c05_start - 0x2a10 + 0x2252
.set pin_volume, c05_start - 0x2a10 + 0xb9a
.set writer_error, c05_start - 0x2a10 + 0x170a
.set safe_floppy_write, c05_start - 0x2a10 + 0x1706
.set check_volume, c05_start - 0x2a10 + 0xbc9
.set write_preflight, c05_start - 0x2a10 + 0xc08
.set second_fat, c05_start - 0x2a10 + 0x170c
.set write_root_sector, c05_start - 0x2a10 + 0x170e
.set volume_sectors, c05_start - 0x2a10 + 0x1710
.set fat_position, c05_start - 0x2a10 + 0xd78
.set alloc_hint, c05_start - 0x2a10 + 0x1714
.set floppy_seek, c05_start - 0x2a10 + 0xda7
.set stage_fat_sector, c05_start - 0x2a10 + 0xf50
.set sync_native_fat, c05_start - 0x2a10 + 0xf92
.set fat_edit_cluster, c05_start - 0x2a10 + 0x1716
.set fat_edit_value, c05_start - 0x2a10 + 0x1718
.set fat_edit_offset, c05_start - 0x2a10 + 0x171a
.set fat_edit_pages, c05_start - 0x2a10 + 0x171c
.set fat_edit_lba, c05_start - 0x2a10 + 0x171e
.set allocate_cluster, c05_start - 0x2a10 + 0x10bd
.set cluster_sector, c05_start - 0x2a10 + 0x111c
.set validate_file_chain, c05_start - 0x2a10 + 0x112b
.set free_file_chain, c05_start - 0x2a10 + 0x117b
.set pin_slot, c05_start - 0x2a10 + 0x11ad
.set slot_offset, c05_start - 0x2a10 + 0x1726
.set slot_lba, c05_start - 0x2a10 + 0x1722
.set grow_directory, c05_start - 0x2a10 + 0x11df
.set grown_cluster, c05_start - 0x2a10 + 0x1720
.set zero_sector, c05_start - 0x2a10 + 0x2000
.set validate_lookup, c05_start - 0x2a10 + 0x123f
.set mutable_file, c05_start - 0x2a10 + 0x128f
.set slot_without_lfn, c05_start - 0x2a10 + 0x12b1
.set create_time, c05_start - 0x2a10 + 0x173e
.set create_date, c05_start - 0x2a10 + 0x1740
.set writer_service_error, c05_start - 0x2a10 + 0x1445
.set writer_entry, c05_start - 0x2a10 + 0x1746
.set directory_slots, c05_start - 0x2a10 + 0x1744
.set free_slot, c05_start - 0x2a10 + 0x1742
.set writer_old_cluster, c05_start - 0x2a10 + 0x173c
.set writer_slot, c05_start - 0x2a10 + 0x1728
.set writer_lba, c05_start - 0x2a10 + 0x172a
.set writer_offset, c05_start - 0x2a10 + 0x172e
.set writer_before, c05_start - 0x2a10 + 0x1766
.set writer_first, c05_start - 0x2a10 + 0x1730
.set writer_last, c05_start - 0x2a10 + 0x1732
.set writer_sector, c05_start - 0x2a10 + 0x1734
.set writer_used, c05_start - 0x2a10 + 0x1736
.set writer_size, c05_start - 0x2a10 + 0x1738
.set writer_prepare_sector, c05_start - 0x2a10 + 0x144c
.set writer_flush_sector, c05_start - 0x2a10 + 0x1489
.set fail_writer, c05_start - 0x2a10 + 0x14bb
.set preserve_end_marker, c05_start - 0x2a10 + 0x1582
.set commit_writer_entry, c05_start - 0x2a10 + 0x15ba
.set extension_start, c05_start - 0x2a10 + 0x0
.set extension_end, c05_start - 0x2a10 + 0x2a00
.set install, c05_start - 0x2a10 + 0x0
.set fs_interrupt, c05_start - 0x2a10 + 0x24f
.set ui_load, c05_start - 0x2a10 + 0x1c8
.set ui_filter, c05_start - 0x2a10 + 0x231
.set reloc_original_init, c05_start - 0x2a10 + 0x1c6
.set original_init, c05_start - 0x2a10 + 0x1c3
.set old_fs, c05_start - 0x2a10 + 0x2200
.set main_segment, c05_start - 0x2a10 + 0x2204
.set aux_segment, c05_start - 0x2a10 + 0x2206
.set state_begin, c05_start - 0x2a10 + 0x224c
.set state_end, c05_start - 0x2a10 + 0x2a00
.set sector_buffer, c05_start - 0x2a10 + 0x2800
.set chain, c05_start - 0x2a10 + 0x22dc
.set staging_chain, c05_start - 0x2a10 + 0x24dc
.set old_fatal, c05_start - 0x2a10 + 0x16f8
.set fatal_interrupt, c05_start - 0x2a10 + 0xb31
.set floppy_write_result, c05_start - 0x2a10 + 0xe64
.set writer_state, c05_start - 0x2a10 + 0x1708
.set write_fault, c05_start - 0x2a10 + 0x1709
.set service_close_write, c05_start - 0x2a10 + 0x1605
.set service_create, c05_start - 0x2a10 + 0x12db
.set service_write_byte, c05_start - 0x2a10 + 0x14dd
.set service_write_block, c05_start - 0x2a10 + 0x1525
.set service_delete, c05_start - 0x2a10 + 0x167d
.set io_active, c05_start - 0x2a10 + 0x16fc
.set write_sector, c05_start - 0x2a10 + 0xe89
.set fat_set, c05_start - 0x2a10 + 0xff6
.set write_buffer, c05_start - 0x2a10 + 0x1e00
.set fat_buffer, c05_start - 0x2a10 + 0x1a00
.set volume_boot, c05_start - 0x2a10 + 0x1800

/* End c04_bindings.inc */
.org 0x2a10
c05_start:
c05_install:
    push cs
    call install
    pushf
    pusha
    push ds
    push es
    push cs
    pop ds
    cmp byte ptr [installed], 1
    jne install_done
    mov ax, [main_segment]
    mov [load_tail+2], ax
    mov es, ax
    cmp word ptr es:[0xe1b5], 0x6bcd
    jne install_existing
    cmp word ptr es:[0xe1b7], 0xe107
    jne install_done
    cmp byte ptr es:[0xe1b9], 0x32
    jne install_done
    jmp install_hook
install_existing:
    cmp byte ptr es:[0xe1b5], 0xea
    jne install_done
    cmp word ptr es:[0xe1b6], offset ui_load_keys
    jne install_done
    mov ax, cs
    cmp es:[0xe1b8], ax
    jne install_done
install_hook:
    cli
    mov byte ptr es:[0xe1b5], 0xea
    mov word ptr es:[0xe1b6], offset ui_load_keys
    mov es:[0xe1b8], cs
install_done:
    pop es
    pop ds
    popa
    popf
    retf

.macro main_call fileoff
    push bp
    push cs
    push offset return_\@
    push 0x046b
    push word ptr cs:[main_segment]
    push (\fileoff-0x0e00)
    retf
return_\@:
    pop bp
.endm
.macro button table, target
    mov word ptr [\table], offset \target
    mov [\table+2], cs
.endm
.macro lcd_text x,y,message
    int 0x2b
inline_begin_\@:
    .byte 0x0e, \x, \y
    .asciz "\message"
inline_end_\@:
.endm
.macro lcd_keys a,b,c,d,e,f
    int 0x2b
inline_begin_\@:
    .byte 0x6a
    .asciz "\a", "\b", "\c", "\d", "\e", "\f"
inline_end_\@:
.endm
.macro lcd_clear
    int 0x2b
inline_begin_\@:
    .byte 0x22
inline_end_\@:
.endm
.macro lcd_styles a,b,c,d,e,f
    int 0x2b
inline_begin_\@:
    .byte 0x6c,\a,\b,\c,\d,\e,\f
inline_end_\@:
.endm
.macro lcd_selected
    int 0x2b
inline_begin_\@:
    .byte 0x1a, 12, 24
    .word 0x78c9
inline_end_\@:
.endm

/* Displaced INT 6B: six far callback slots in the native data segment.
 * Native dispatch uses RETF when callback CS differs from main CS.
 * Resume AFTER the original inline table, retaining its trailing CALL/RET.
 */
ui_load_keys:
    int 0x2b
inline_begin_load_label:
    .byte 0x68,4,1
    .asciz "FOLDER"
inline_end_load_label:
    mov ax, cs:[main_segment]
    mov si, offset load_callbacks
    mov di, 0x0d84
    mov cx, 6
load_keys_loop:
    mov bx, cs:[si]
    mov [di], bx
    mov [di+2], ax
    add si, 2
    add di, 4
    loop load_keys_loop
    button 0x0d94, ui_menu
    jmp far ptr cs:[load_tail]

ui_menu:
    push ds
    push es
    pusha
    /* Capture selection and medium context before opening any dialog. */
    push cs
    pop es
    mov si, 0x78c9
    mov di, offset selected_name
    mov cx, 20
    cld
    rep movsb
    mov al, [0x78a8]
    mov cs:[menu_drive], al
    push cs
    pop ds
    cmp al, [drive]
    jne menu_context_bad
    cmp byte ptr [writer_state], 0
    jne menu_context_bad
    cmp byte ptr [write_fault], 0
    jne menu_context_bad
    mov ax, [cwd]
    mov [menu_cwd], ax
    call media_check
    jc menu_context_bad
    call geometry
    jc menu_context_bad
    cmp word ptr [cwd], 0
    jne menu_context_ready
    call pin_volume
    jc menu_context_bad
menu_context_ready:
    mov ax, [partition]
    mov [menu_partition], ax
    mov ax, [partition+2]
    mov [menu_partition+2], ax
    mov byte ptr [menu_valid], 1
    jmp menu_restore
menu_context_bad:
    mov byte ptr [menu_valid], 0
menu_restore:
    popa
    pop es
    pop ds
    call menu_draw
    retf

menu_draw:
    int 0x50
    lcd_clear
    lcd_text 12,8,"FOLDER MANAGEMENT"
    lcd_selected
    lcd_text 12,36,"NEW here; RENAME/DELETE selected"
    lcd_keys "NEW","RENAME","DELETE"," ","BACK"," "
    lcd_styles 1,1,1,0,2,0
    button 0x0d84, ui_new
    button 0x0d88, ui_rename
    button 0x0d8c, ui_delete
    button 0x0d94, ui_back
    /* No periodic redraw while editing: INT 42 owns those callbacks. */
    ret

ui_back:
    main_call 0xef2f
    main_call 0xf13e
    int 0x52
    retf
ui_cancel:
    call menu_draw
    retf

ui_new:
    mov byte ptr cs:[operation], 0
    push ds
    pop es
    mov di, 0x78de
    mov ax, 0x2020
    mov cx, 8
    rep stosw
    mov word ptr [0x78ee], 0x202e
    mov word ptr [0x78f0], 0x2020
    jmp ui_name
ui_rename:
    mov byte ptr cs:[operation], 1
    call selection_is_folder
    jc ui_bad_selection
    push ds
    pop es
    mov di, 0x78de
    mov si, offset selected_name
    mov cx, 8
copy_rename_name:
    mov al, cs:[si]
    stosb
    inc si
    loop copy_rename_name
    mov ax, 0x2020
    mov cx, 4
    rep stosw
    mov word ptr [0x78ee], 0x202e
    mov word ptr [0x78f0], 0x2020
ui_name:
    int 0x50
    lcd_clear
    cmp byte ptr cs:[operation], 0
    jne rename_title
    lcd_text 12,8,"NEW FOLDER"
    jmp name_title_done
rename_title:
    lcd_text 12,8,"RENAME FOLDER"
name_title_done:
    lcd_text 12,24,"Name:"
    lcd_text 12,36,"1-8 chars: A-Z 0-9 _ -"
    lcd_keys " "," "," "," ","CANCEL","DO IT"
    lcd_styles 0,0,0,0,2,1
    button 0x0d94, ui_cancel
    button 0x0d98, ui_execute
    mov ax, ds
    mov es, ax
    mov si, 0x78de
    mov cl, 0x5a
    mov ch, 0x18
    int 0x42
    retf

ui_delete:
    call selection_is_folder
    jc ui_bad_selection
    mov byte ptr cs:[operation], 2
    int 0x50
    lcd_clear
    lcd_text 12,8,"DELETE EMPTY FOLDER?"
    lcd_selected
    lcd_text 12,36,"Files inside prevent deletion."
    lcd_keys " "," "," "," ","CANCEL","DELETE"
    lcd_styles 0,0,0,0,2,1
    button 0x0d94, ui_cancel
    button 0x0d98, ui_execute
    retf
selection_is_folder:
    cmp byte ptr cs:[selected_name], '.'
    je selection_bad
    cmp word ptr cs:[selected_name+17], 0x443c
    jne selection_bad
    cmp byte ptr cs:[selected_name+19], '>'
    jne selection_bad
    clc
    ret
selection_bad:
    stc
    ret
ui_bad_selection:
    mov word ptr cs:[result], 6
    jmp ui_result

ui_execute:
    push ds
    push es
    pusha
    push cs
    pop es
    mov si, 0x78de
    mov di, offset proposed_name
    mov cx, 16
    cld
    rep movsb
    push cs
    pop ds
    call meta_execute
    mov [result], ax
    popa
    pop es
    pop ds
ui_result:
    int 0x50
    lcd_clear
    lcd_text 12,8,"FOLDER MANAGEMENT"
    cmp word ptr cs:[result], 0
    jne result_error
    lcd_text 12,24,"Done."
    jmp result_buttons
result_error:
    cmp word ptr cs:[result], 2
    jne result_not_name
    lcd_text 12,24,"Invalid name or name exists."
    jmp result_buttons
result_not_name:
    cmp word ptr cs:[result], 3
    jne result_not_full
    lcd_text 12,24,"Disk or directory is full."
    jmp result_buttons
result_not_full:
    cmp word ptr cs:[result], 5
    jne result_not_empty
    lcd_text 12,24,"Folder is not empty."
    jmp result_buttons
result_not_empty:
    cmp word ptr cs:[result], 6
    jne result_io
    lcd_text 12,24,"Select an unprotected folder."
    jmp result_buttons
result_io:
    lcd_text 12,24,"Media/protection error."
    lcd_text 12,36,"Reload disk before more changes."
result_buttons:
    lcd_keys " "," "," "," ","LOAD"," "
    lcd_styles 0,0,0,0,2,0
    button 0x0d94, ui_back
    retf

/* Metadata helpers: DS=CS, no outstanding native/C04 writer allowed.
 * Error codes: 1 protected, 2 name, 3 full, 4 media, 5 nonempty, 6 target.
 */
meta_code_start:
meta_execute:
    mov word ptr [writer_error], 4
    mov word ptr [new_cluster], 0
    cmp byte ptr [menu_valid], 1
    jne meta_error
    mov byte ptr [menu_valid], 0 /* one execution per captured context */
    cmp byte ptr [writer_state], 0
    jne meta_error
    cmp byte ptr [write_fault], 0
    jne meta_error
    /* Native ROOT writes do not use C04 writer_state. */
    push es
    push 0xf000
    pop es
    cmp byte ptr [drive], 0
    jne check_native_disk_writer
    cmp byte ptr es:[0xf893], 2
    jmp check_native_writer_done
check_native_disk_writer:
    cmp byte ptr es:[0xf997], 2
check_native_writer_done:
    pop es
    je meta_error
    mov al, [drive]
    cmp al, [menu_drive]
    jne meta_error
    mov ax, [cwd]
    cmp ax, [menu_cwd]
    jne meta_error
    call meta_preflight
    jc meta_error
    mov ax, [partition]
    cmp ax, [menu_partition]
    jne meta_error
    mov ax, [partition+2]
    cmp ax, [menu_partition+2]
    jne meta_error
    push ds
    pop es
    mov si, offset selected_name
    mov di, offset lookup
    mov cx, 10
    rep movsw
    mov word ptr [target_slot], 0xffff
    mov word ptr [new_cluster], 0
    cmp byte ptr [operation], 0
    je meta_prepare_new
    call find_entry
    jc meta_bad_target
    call meta_read_entry /* fresh ROOT sector, not the native floppy cache */
    jc meta_error
    push ax
    call expand_entry
    mov di, offset lookup
    mov cx, 20
    repe cmpsb
    pop ax
    jne meta_bad_target
    call validate_target
    jc meta_error
    mov [target_slot], ax
    call capture_slot
    cmp byte ptr [operation], 2
    je meta_remove
meta_prepare_new:
    call validate_name
    jc meta_error
    call scan_names
    jc meta_error
    cmp byte ptr [operation], 0
    je meta_mkdir
    /* RENAME changes only the 11-byte key and FAT short-name case bits. */
    mov si, offset short_name
    mov di, offset writer_entry
    mov cx, 11
    rep movsb
    mov byte ptr [writer_entry+12], 0
    call meta_commit
    jc meta_error
    jmp meta_success
meta_bad_target:
    mov word ptr [writer_error], 6
meta_error:
    /* Only an unpublished cluster after a certain, non-I/O failure may be
     * released. commit failure latches write_fault, forbidding rollback. */
    cmp word ptr [new_cluster], 0
    je meta_error_return
    cmp byte ptr [write_fault], 0
    jne meta_error_return
    push word ptr [writer_error]
    mov ax, [new_cluster]
    call free_file_chain
    pop ax
    jc meta_error_return
    mov [writer_error], ax
    mov word ptr [new_cluster], 0
meta_error_return:
    mov ax, [writer_error]
    stc
    ret
meta_success:
    mov byte ptr [cache_valid], 0
    mov word ptr [cursor], 0xffff
    xor ax, ax
    ret

/* Names intentionally narrower than native 16-byte AKAI file names.
 * Trailing spaces are padding; no embedded spaces, dots or extensions.
 */
validate_name:
    mov word ptr [writer_error], 2
    mov si, offset proposed_name
    mov di, offset short_name
    mov cx, 11
    mov al, ' '
    rep stosb
    mov di, offset short_name
    xor bx, bx
    mov cx, 16
name_char_loop:
    lodsb
    cmp al, ' '
    je name_padding
    cmp bx, 0
    jne name_invalid
    cmp di, offset short_name+8
    jae name_invalid
    cmp al, 'a'
    jb name_upper
    cmp al, 'z'
    ja name_upper
    sub al, 32
name_upper:
    cmp al, 'A'
    jb name_number
    cmp al, 'Z'
    jbe name_store
name_number:
    cmp al, '0'
    jb name_symbol
    cmp al, '9'
    jbe name_store
name_symbol:
    cmp al, '_'
    je name_store
    cmp al, '-'
    jne name_invalid
name_store:
    stosb
    jmp name_next
name_padding:
    inc bx
name_next:
    loop name_char_loop
    cmp byte ptr [short_name], ' '
    je name_invalid
    mov word ptr [writer_error], 4
    clc
    ret
name_invalid:
    stc
    ret

/* Physical directory bounds expressed in C04 logical index convention. */
meta_bounds:
    xor ax, ax
    mov dx, [root_entries]
    cmp word ptr [cwd], 0
    je bounds_done
    mov ax, [chain_count]
    mul word ptr [spc]
    shl ax, 4
    mov dx, ax
    inc dx
    mov ax, 1
bounds_done:
    mov [first_slot], ax
    mov [slots_end], dx /* exclusive */
    ret

/* AX slot preserved, entry receives fresh bytes. ROOT has no virtual '..'. */
meta_read_entry:
    cmp word ptr [cwd], 0
    jne meta_read_cwd
    cmp ax, [root_entries]
    jae meta_read_bad
    pusha
    push es
    call meta_pin_slot
    mov ax, [slot_lba]
    mov dx, [slot_lba+2]
    call read_sector
    jc meta_read_restore_bad
    push ds
    pop es
    mov si, offset sector_buffer
    add si, [slot_offset]
    mov di, offset entry
    mov cx, 16
    rep movsw
    pop es
    popa
    clc
    ret
meta_read_restore_bad:
    pop es
    popa
meta_read_bad:
    stc
    ret
meta_read_cwd:
    jmp entry_at

meta_pin_slot:
    cmp word ptr [cwd], 0
    jne meta_pin_cwd
    pusha
    mov bx, ax
    and bx, 15
    shl bx, 5
    mov [slot_offset], bx
    shr ax, 4
    xor dx, dx
    add ax, [write_root_sector]
    adc dx, 0
    mov [slot_lba], ax
    mov [slot_lba+2], dx
    popa
    ret
meta_pin_cwd:
    jmp pin_slot

/* Refuse a live immediately preceding VFAT entry, including ROOT slot 1. */
meta_no_lfn:
    cmp ax, [first_slot]
    jbe no_lfn_ok
    push ax
    dec ax
    call meta_read_entry
    jc no_lfn_previous_bad
    cmp byte ptr [entry], 0xe5
    je no_lfn_previous_ok
    cmp byte ptr [entry+11], 0x0f
    je no_lfn_previous_bad
no_lfn_previous_ok:
    pop ax
    call meta_read_entry
    ret
no_lfn_previous_bad:
    pop ax
    mov word ptr [writer_error], 6
    stc
    ret
no_lfn_ok:
    clc
    ret

validate_target:
    push ax
    call meta_bounds
    pop ax
    cmp byte ptr [entry], '.'
    je target_bad
    cmp byte ptr [entry], 0xe5
    je target_bad
    cmp byte ptr [entry], 0
    je target_bad
    mov bl, [entry+11]
    and bl, 0x1f
    cmp bl, 0x10
    jne target_bad
    /* Directory high cluster and size must be zero on FAT12/16. */
    mov bx, [entry+20]
    or bx, [entry+28]
    or bx, [entry+30]
    jnz target_bad
    push ax
    mov ax, [entry+26]
    call valid_cluster
    jc target_pop_bad
    call validate_file_chain /* excludes current/ancestor clusters */
target_pop_bad:
    pop ax
    jc target_bad
    call meta_no_lfn
    ret
target_bad:
    mov word ptr [writer_error], 6
    stc
    ret

capture_slot:
    mov [writer_slot], ax
    call meta_pin_slot
    mov dx, [slot_lba]
    mov [writer_lba], dx
    mov dx, [slot_lba+2]
    mov [writer_lba+2], dx
    mov dx, [slot_offset]
    mov [writer_offset], dx
    mov si, offset entry
    mov di, offset writer_before
    mov cx, 16
    rep movsw
    mov si, offset entry
    mov di, offset writer_entry
    mov cx, 16
    rep movsw
    ret

/* Every live SFN (files, directories, hidden/protected) owns its key. */
scan_names:
    call meta_bounds
    mov word ptr [available_slot], 0xffff
scan_next:
    cmp ax, [slots_end]
    jae scan_done
    call meta_read_entry
    jc scan_error
    cmp byte ptr [entry], 0
    je scan_end_marker
    cmp byte ptr [entry], 0xe5
    je scan_free
    cmp ax, [target_slot]
    je scan_advance
    cmp byte ptr [entry+11], 0x0f
    je scan_advance
    push ax
    mov si, offset entry
    mov di, offset short_name
    mov cx, 11
scan_compare:
    lodsb
    cmp al, 'a'
    jb scan_compare_upper
    cmp al, 'z'
    ja scan_compare_upper
    sub al, 32
scan_compare_upper:
    cmp al, [di]
    jne scan_different
    inc di
    loop scan_compare
    pop ax
    mov word ptr [writer_error], 2
    stc
    ret
scan_different:
    pop ax
    jmp scan_advance
scan_free:
    cmp word ptr [available_slot], 0xffff
    jne scan_advance
    call meta_no_lfn
    jc scan_error /* do not allocate behind an orphan VFAT entry */
    mov [available_slot], ax
scan_advance:
    inc ax
    jmp scan_next
scan_end_marker:
    cmp word ptr [available_slot], 0xffff
    jne scan_done
    call meta_no_lfn
    jc scan_error
    mov [available_slot], ax
scan_done:
    mov word ptr [writer_error], 4
    clc
    ret
scan_error:
    stc
    ret

meta_mkdir:
    mov ax, [available_slot]
    cmp ax, 0xffff
    jne mkdir_slot_ready
    cmp word ptr [cwd], 0
    je mkdir_full
    call grow_directory
    jc meta_error
    mov ax, [slots_end]
    mov bx, [spc]
    shl bx, 4
    add [slots_end], bx
mkdir_slot_ready:
    call meta_read_entry
    jc meta_error
    call capture_slot
    call allocate_cluster
    jc meta_error
    mov [new_cluster], ax
    /* Stage dot records in the reusable C04 buffer, zero every sector. */
    call cluster_sector
    mov si, offset zero_sector
    mov cx, [spc]
mkdir_zero:
    call write_sector
    jc meta_error
    add ax, 1
    adc dx, 0
    loop mkdir_zero
    mov si, offset zero_sector
    mov di, offset write_buffer
    mov cx, 256
    rep movsw
    mov di, offset write_buffer
    mov al, ' '
    mov cx, 11
    rep stosb
    mov di, offset write_buffer+32
    mov cx, 11
    rep stosb
    mov byte ptr [write_buffer], '.'
    mov word ptr [write_buffer+32], 0x2e2e
    mov byte ptr [write_buffer+11], 0x10
    mov byte ptr [write_buffer+43], 0x10
    mov ax, [new_cluster]
    mov [write_buffer+26], ax
    mov bx, [cwd]
    mov [write_buffer+58], bx
    call cluster_sector
    mov si, offset write_buffer
    call write_sector
    jc meta_error
    mov di, offset writer_entry
    xor ax, ax
    mov cx, 16
    rep stosw
    mov si, offset short_name
    mov di, offset writer_entry
    mov cx, 11
    rep movsb
    mov byte ptr [writer_entry+11], 0x10
    mov ax, [new_cluster]
    mov [writer_entry+26], ax
    /* Native clock uses packed FAT time/date in the main data segment. */
    push es
    mov ax, [main_segment]
    add ax, 0x1f31
    mov es, ax
    mov ax, es:[0x0b0e]
    mov [writer_entry+22], ax
    mov ax, es:[0x0b10]
    mov [writer_entry+24], ax
    pop es
    call meta_end_marker
    jc meta_error
    call meta_commit
    jc meta_error
    mov word ptr [new_cluster], 0
    jmp meta_success
mkdir_full:
    mov word ptr [writer_error], 3
    jmp meta_error

/* Parent entry is removed before its validated empty chain is released. */
meta_remove:
    mov ax, [writer_before+26]
    call build_chain
    jc meta_error
    call check_empty
    jc meta_error
    mov byte ptr [writer_entry], 0xe5
    call meta_commit
    jc meta_error
    mov ax, [writer_before+26]
    call free_file_chain
    jc meta_error
    jmp meta_success

/* Scan ALL physical slots, including after 00: conservative empty policy.
 * Only the exact first '.' and '..' entries, E5 and zero slots are allowed.
 */
check_empty:
    xor bx, bx
empty_cluster:
    mov ax, [staging_chain+bx]
    call cluster_sector
    mov cx, [spc]
empty_sector:
    mov byte ptr [cache_valid], 0
    call read_sector
    jc empty_bad
    mov si, offset sector_buffer
    mov di, 16
empty_slot:
    cmp bx, 0
    jne empty_other
    cmp cx, [spc]
    jne empty_other
    cmp si, offset sector_buffer
    je empty_dot
    cmp si, offset sector_buffer+32
    je empty_dotdot
empty_other:
    cmp byte ptr [si], 0
    je empty_advance
    cmp byte ptr [si], 0xe5
    je empty_advance
    mov word ptr [writer_error], 5
    stc
    ret
empty_dot:
    cmp word ptr [si], 0x202e
    jne empty_bad
    push ax
    mov ax, [writer_before+26]
    jmp empty_dot_cluster
empty_dotdot:
    cmp word ptr [si], 0x2e2e
    jne empty_bad
    push ax
    mov ax, [cwd]
empty_dot_cluster:
    cmp ax, [si+26]
    pop ax
    jne empty_bad
    cmp byte ptr [si+11], 0x10
    jne empty_bad
    cmp word ptr [si+20], 0
    jne empty_bad
    cmp word ptr [si+28], 0
    jne empty_bad
    cmp word ptr [si+30], 0
    jne empty_bad
    push cx
    push si
    add si, 2
    mov cx, 9
empty_dot_spaces:
    cmp byte ptr [si], ' '
    jne empty_dot_bad
    inc si
    loop empty_dot_spaces
    pop si
    pop cx
    jmp empty_advance
empty_dot_bad:
    pop si
    pop cx
    jmp empty_bad
empty_advance:
    add si, 32
    dec di
    jnz empty_slot
    add ax, 1
    adc dx, 0
    dec cx
    jnz empty_sector
    add bx, 2
    mov ax, bx
    shr ax, 1
    cmp ax, [staging_count]
    jb empty_cluster
    clc
    ret
empty_bad:
    mov word ptr [writer_error], 4
    stc
    ret

/* Read-modify-write a parent slot and synchronize only ROOT's native cache.
 * The C04 commit re-reads and compares all 32 original bytes before publish.
 */
meta_commit:
    call meta_check_volume
    jc commit_bad
    call commit_writer_entry
    jc commit_bad
    mov ax, [writer_lba]
    mov dx, [writer_lba+2]
    call sync_root
    clc
    ret
commit_bad:
    mov byte ptr [write_fault], 1
    mov word ptr [writer_error], 4
    stc
    ret

meta_end_marker:
    cmp byte ptr [writer_before], 0
    jne end_marker_done
    mov ax, [writer_slot]
    inc ax
    cmp ax, [slots_end]
    jae end_marker_done
    call meta_read_entry
    jc end_marker_bad
    call meta_pin_slot
    /* CWD reader and ROOT reader both leave this sector in sector_buffer. */
    mov bx, [slot_offset]
    mov byte ptr [sector_buffer+bx], 0
    mov ax, [slot_lba]
    mov dx, [slot_lba+2]
    mov si, offset sector_buffer
    call write_sector
    jc end_marker_bad
    call sync_root
end_marker_done:
    clc
    ret
end_marker_bad:
    mov word ptr [writer_error], 4
    stc
    ret

/* AX:DX committed ROOT LBA; sector_buffer still contains committed bytes. */
sync_root:
    pusha
    push es
    cmp word ptr [cwd], 0
    jne sync_root_done
    or dx, dx
    jnz sync_root_done
    push 0xf000
    pop es
    cmp byte ptr [drive], 0
    jne sync_root_disk
    sub ax, [write_root_sector]
    shl ax, 9
    add ax, [floppy_root]
    mov di, ax
    jmp sync_root_copy
sync_root_disk:
    sub ax, [write_root_sector]
    cmp ax, es:[0xfda1]
    jne sync_root_done
    mov di, 0xfda5
sync_root_copy:
    mov si, offset sector_buffer
    mov cx, 256
    rep movsw
sync_root_done:
    pop es
    popa
    ret

/* ROOT-capable equivalent of C04 check_volume, preserving captured BPB. */
meta_check_volume:
    pusha
    push es
    cmp byte ptr [volume_pinned], 1
    jne meta_volume_bad
    mov ax, [cwd]
    cmp ax, [menu_cwd]
    jne meta_volume_bad
    call media_check
    jc meta_volume_bad
    mov ax, [cwd]
    cmp ax, [menu_cwd]
    jne meta_volume_bad
    mov byte ptr [cache_valid], 0
    xor ax, ax
    xor dx, dx
    call read_sector
    jc meta_volume_bad
    push ds
    pop es
    mov si, offset volume_boot
    mov di, offset sector_buffer
    mov cx, 256
    repe cmpsw
    jne meta_volume_bad
    pop es
    popa
    clc
    ret
meta_volume_bad:
    mov byte ptr [write_fault], 1
    pop es
    popa
    stc
    ret

/* A separately named copy of the C04 geometry/BPB validation is included
 * by the builder. Its only behavioral change skips CWD map comparison in
 * ROOT; the original C04 write path is never patched or replaced.
 */
/* Begin preflight.inc */
meta_preflight:
    mov word ptr [writer_error], 4
    cmp byte ptr [write_fault], 0
    jne .Lpreflight_failed
    call meta_check_volume
    jc .Lpreflight_failed
    call geometry
    jc .Lpreflight_failed
    cmp word ptr [volume_boot+11], 512
    jne .Lpreflight_failed
    cmp byte ptr [volume_boot+16], 2
    jne .Lpreflight_failed
    xor ax, ax
    mov al, [volume_boot+13]
    cmp ax, [spc]
    jne .Lpreflight_failed
    mov ax, [volume_boot+14]
    cmp ax, [fat_sector]
    jne .Lpreflight_failed
    or ax, ax
    jz .Lpreflight_failed
    mov ax, [volume_boot+22]
    cmp ax, [fat_sectors]
    jne .Lpreflight_failed
    or ax, ax
    jz .Lpreflight_failed
    add ax, [fat_sector]
    jc .Lpreflight_failed
    mov [second_fat], ax
    add ax, [fat_sectors]
    jc .Lpreflight_failed
    mov [write_root_sector], ax
    mov bx, [volume_boot+17]
    cmp bx, [root_entries]
    jne .Lpreflight_failed
    add bx, 15
    jc .Lpreflight_failed
    shr bx, 4
    add ax, bx
    jc .Lpreflight_failed
    cmp ax, [data_sector]
    jne .Lpreflight_failed
    xor dx, dx
    mov ax, [volume_boot+19]
    or ax, ax
    jnz .Lpreflight_total
    mov ax, [volume_boot+32]
    mov dx, [volume_boot+34]
.Lpreflight_total:
    mov [volume_sectors], ax
    mov [volume_sectors+2], dx
    sub ax, [data_sector]
    sbb dx, 0
    jc .Lpreflight_failed
    cmp dx, [spc]
    jae .Lpreflight_failed
    div word ptr [spc]
    add ax, 2
    jc .Lpreflight_failed
    cmp ax, [cluster_limit]
    jne .Lpreflight_failed
    mov ax, [cluster_limit]
    dec ax
    call fat_position
    jc .Lpreflight_failed
    cmp bx, 511
    jne .Lpreflight_capacity
    inc ax
    cmp ax, [fat_sectors]
    jae .Lpreflight_failed
.Lpreflight_capacity:
    cmp byte ptr [drive], 0
    jne .Lpreflight_disk
    mov ax, [write_root_sector]
    mov cx, 512
    mul cx
    or dx, dx
    jnz .Lpreflight_failed
    cmp ax, [floppy_root]
    jne .Lpreflight_failed
    push es
    push 0xf000
    pop es
    cmp byte ptr es:[0xf890], 0
    pop es
    je .Lpreflight_ready
    mov word ptr [writer_error], 1
    jmp .Lpreflight_failed
.Lpreflight_disk:
    mov ax, [root_sector]
    cmp ax, [write_root_sector]
    jne .Lpreflight_failed
    cmp byte ptr [fat_bits], 12
    jne .Lpreflight_ready
    /* Native FAT12 cache begins at E000 and must end before F800. */
    cmp word ptr [fat_sectors], 12
    ja .Lpreflight_failed
.Lpreflight_ready:
    /* Refuse a stale map if the directory chain changed since navigation. */
    mov ax, [cwd]
    or ax, ax
    jnz .Lmeta_chain_check
    mov word ptr [chain_count], 0
    jmp .Lmeta_preflight_ok
.Lmeta_chain_check:
    call build_chain
    jc .Lpreflight_failed
    mov cx, [staging_count]
    cmp cx, [chain_count]
    jne .Lpreflight_failed
    push es
    push ds
    pop es
    mov si, offset staging_chain
    mov di, offset chain
    repe cmpsw
    pop es
    jne .Lpreflight_failed
.Lmeta_preflight_ok:
    mov word ptr [alloc_hint], 2
    clc
    ret
.Lpreflight_failed:
    stc
    ret


/* End preflight.inc */
meta_code_end:
.align 2
load_tail: .word 0xe1c3,0
load_callbacks: .word 0xe107,0x3332,0x44c6,0xfad3,0x0ec0,0xe98f
menu_valid: .byte 0
menu_drive: .byte 0
operation: .byte 0
.align 2
menu_cwd: .word 0
menu_partition: .long 0
result: .word 0
first_slot: .word 0
slots_end: .word 0
available_slot: .word 0xffff
target_slot: .word 0xffff
new_cluster: .word 0
selected_name: .space 20
proposed_name: .space 16
short_name: .space 11
.balign 16
c05_end:

.endif /* directory_management */
/* directory_label: assembly unit 7. */
.if MOD_UNIT == 7
/* C07: append-only helpers in the existing C04/C05 code segment.
 * Folder names occupy the same 20 bytes as before. FAT short names need at
 * most 12 characters, so bytes 15..19 can hold <DIR> without truncation.
 * Ordinary files keep their native 16-character basename and extension.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
.org 0x3740
c07_start:

/* Section-relative aliases keep near branches within the shared CS. */
.set old_load_folder, c07_start - 0x3740 + 0x01d7
.set old_load_native, c07_start - 0x3740 + 0x0226
.set old_filter_folder, c07_start - 0x3740 + 0x0240
.set old_filter_native, c07_start - 0x3740 + 0x0245
.set old_directory_finish, c07_start - 0x3740 + 0x0924
.equ name, 0x22b4
.equ selected_name, 0x36bc

/* DS is the filesystem extension's segment, as in expand_entry. */
directory_marker:
    mov word ptr [name+15], 0x443c  /* <D */
    mov word ptr [name+17], 0x5249  /* IR */
    mov byte ptr [name+19], '>'
    jmp old_directory_finish

/* DS is the native main data segment. No registers are clobbered. */
load_folder:
    cmp word ptr [0x78c9+15], 0x443c
    jne load_native
    cmp word ptr [0x78c9+17], 0x5249
    jne load_native
    cmp byte ptr [0x78c9+19], '>'
    jne load_native
    jmp old_load_folder
load_native:
    jmp old_load_native

/* Keep ES:SI and all registers intact; ZF=1 admits directories under
 * every native file-type filter. The native path computes its own ZF. */
filter_folder:
    cmp word ptr es:[si+15], 0x443c
    jne filter_native
    cmp word ptr es:[si+17], 0x5249
    jne filter_native
    cmp byte ptr es:[si+19], '>'
    jne filter_native
    jmp old_filter_folder
filter_native:
    jmp old_filter_native

/* RENAME/DELETE retain C05's prohibition on the synthetic parent row. */
selection_folder:
    cmp byte ptr cs:[selected_name], '.'
    je selection_bad
    cmp word ptr cs:[selected_name+15], 0x443c
    jne selection_bad
    cmp word ptr cs:[selected_name+17], 0x5249
    jne selection_bad
    cmp byte ptr cs:[selected_name+19], '>'
    jne selection_bad
    clc
    ret
selection_bad:
    stc
    ret
c07_code_end:
.balign 16, 0
c07_end:

.endif /* directory_label */
/* directory_context_and_program_display: assembly unit 8. */
.if MOD_UNIT == 8
.intel_syntax noprefix
.code16
.arch i186
.text
segment_start:
/* Share C02's segment. The original C07 file remains in place. */
.org 0x4ee0
.global fixes_start, fixes_end, transpose_number, reloc_signed_draw
.global folder_commit_name, reloc_commit_name
.global preserve_ui_mount
.global fs_allow_floppy_completion
.macro folder_call target
    .byte 0xe8
    .word \target - (. - segment_start - 0x1710 + 2)
.endm
.macro folder_jump target
    .byte 0xe9
    .word \target - (. - segment_start - 0x1710 + 2)
.endm
fixes_start:
transpose_number:
    /* The native editor draws only the cursor/entry overlay. Its caller
       must draw the current signed value before asking for that overlay. */
    push 140
    push 25
    mov al, byte ptr cs:[0x398]
    cbw
    cwd
    push dx
    push ax
    push 2
    .byte 0x9a
    .word 0x0218
reloc_signed_draw:
    .word 0x0b7c
    push cs
    .byte 0xe8
    .word 0x0265 - (. - segment_start + 2)
    retf
/* Entered with C05's CS (0x2521 relative), not C02's CS. Commit the native
   text editor before NEW/RENAME reads its destination. DELETE has no editor. */
folder_commit_name:
    cmp byte ptr cs:[0x36a8], 2
    je .Lexecute
    pusha
    push ds
    push es
    .byte 0x9a
    .word 0x33ba
reloc_commit_name:
    .word 0x0b7c
    pop es
    pop ds
    popa
.Lexecute:
    push ds
    push es
    pusha
    .byte 0xe9
    .word 0x2d85 - (. - segment_start - 0x1710 + 2)
/* Native disk-page refresh remounts through EXE E82E even on LOAD/SAVE
   switches. Keep a valid directory only for that exact same-drive caller.
   Other reset requests, failed writers and changed media keep C04 behavior. */
preserve_ui_mount:
    cmp bl, 1
    jne .Lreset
    cmp word ptr cs:[0x2250], 0
    je .Lreset
    cmp word ptr cs:[0x1708], 0 /* writer_state and write_fault */
    jne .Lreset
    push bp
    mov bp, sp
    cmp word ptr ss:[bp+8], 0xe82e
    jne .Lcaller_bad
    push ax
    mov ax, cs:[0x2204]
    cmp ss:[bp+10], ax
    pop ax
    jne .Lcaller_bad
    pop bp
    folder_call 0x0bc9 /* check_volume before mount clears media status */
    jc .Lreset
    pop ds
    pop ax
    popf
    /* Original interrupt frame, as in C04's service_media. */
    push bp
    mov bp, sp
    push ds
    push cs
    pop ds
    cld
    sti
    mov byte ptr [0x16fc], 1
    folder_call 0x0432 /* call_original; preserve native mount output */
    mov byte ptr [0x16fc], 0
    pushf
    pusha
    push es
    jc .Lmounted_bad
    push word ptr [0x226a]
    push word ptr [0x2268]
    folder_call 0x0497 /* geometry */
    pop bx
    pop dx
    jc .Lmounted_bad
    cmp bx, [0x2268]
    jne .Lmounted_bad
    cmp dx, [0x226a]
    jne .Lmounted_bad
    folder_call 0x0bc9 /* check_volume after native mount */
    jc .Lmounted_bad
    mov word ptr [0x2256], 0xffff
    mov byte ptr [0x224e], 0
    jmp .Lmounted_done
.Lmounted_bad:
    folder_call 0x0475 /* reset_context */
    mov byte ptr [0x1709], 1
.Lmounted_done:
    pop es
    popa
    popf
    folder_jump 0x0421 /* finish interrupt with native flags/results */
.Lcaller_bad:
    pop bp
.Lreset:
    folder_call 0x0475
    folder_jump 0x03c7 /* original reset-pass tail */
/* INT 2C/12 is the FDC interrupt-completion notification, not a user
   filesystem request. Native EXE 10F90 passes BH=0; service 11980 sets
   F000:F8FC. A live writer must not block this or change the active drive. */
fs_allow_floppy_completion:
    pushf
    push ax
    push ds
    push cs
    pop ds
    cmp bl, 0x12
    jne .Lordinary_fs
    folder_jump 0x03bc /* native pass-through, intact interrupt frame */
.Lordinary_fs:
    folder_jump 0x0254 /* resume after displaced entry prologue */
fixes_end:

.endif /* directory_context_and_program_display */
/* directory_windows: assembly unit 11. */
.if MOD_UNIT == 11
/* C09: native modal frames for the existing folder-management dialogs.
 * Appended after the complete C08 R2 file. Share C05's existing CS.
 * Filesystem operations, callbacks and the native name editor stay intact.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
segment_start:
.org 0x3e84
.global extension_start, code_end, extension_end
.global frame_menu, frame_new, frame_rename, frame_delete, frame_result
.global draw_frame, folder_resource, new_resource, rename_resource, delete_resource

.macro frame_entry name, resource, continuation
\name:
    push bp
    mov bp, \resource - segment_start
    call draw_frame
    pop bp
    /* Continue after the displaced inline title, not inside its text. */
    .byte 0xe9
    .word \continuation - (. - segment_start + 2)
.endm

extension_start:
frame_entry frame_menu, folder_resource, 0x2b34
frame_entry frame_new, new_resource, 0x2c4e
frame_entry frame_rename, rename_resource, 0x2c63
frame_entry frame_delete, delete_resource, 0x2cfa
frame_entry frame_result, folder_resource, 0x2dba

draw_frame:
    pushf
    pusha
    push ds
    push es
    push cs
    pop es
    /* Native INT 2E consumes an ES:BP resource. Command 22 draws the
     * system's own double frame and title bar, just as OPEN WINDOW does. */
    int 0x2e
    pop es
    pop ds
    popa
    popf
    ret
code_end:

.macro modal_resource name, title
\name:
    .byte 0x22,12,2,224,58
    .asciz "\title"
    .byte 2,0 /* select the primary plane for the existing body/softkeys */
.endm

modal_resource folder_resource, "FOLDER MANAGEMENT"
modal_resource new_resource, "NEW FOLDER"
modal_resource rename_resource, "RENAME FOLDER"
modal_resource delete_resource, "DELETE EMPTY FOLDER?"
.balign 4,0
extension_end:

.endif /* directory_windows */
/* file_list: assembly unit 12. */
.if MOD_UNIT == 12
/* C10: FILE LIST F3 OPEN for the highlighted <DIR> entry.
 * Append to C09, sharing C04/C05's CS. Only the startup call IP changes
 * in the old SYS. The exact native FILE LIST draw entry is hooked in RAM.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
segment_start:
.org 0x3f34
.global extension_start, extension_end, code_end, install_file_list
.global list_draw_entry, list_draw_core, capture_row, draw_open_button, open_folder
.global row_name, row_valid, native_draw_return, state_end

.macro old_call target
    push cs
    .byte 0xe8
    .word \target - (. - segment_start + 2)
.endm
.macro main_near fileoff
    push bp
    push cs
    push main_return_\@ - segment_start
    push 0x046b /* native RETF gate after a native near RET */
    push word ptr cs:[0x2204] /* main_segment, established by C04 */
    push (\fileoff - 0x0e00)
    retf
main_return_\@:
    pop bp
.endm
.macro selected_row index, y
    mov al, \index
    call capture_row
    int 0x2b
inline_begin_\@:
    .byte 0x1a,64,\y
    .word 0x78c9
inline_end_\@:
.endm
.macro label text, style
    int 0x2b
inline_begin_\@:
    .byte 0x68,3,\style
    .asciz "\text"
inline_end_\@:
.endm

extension_start:
install_file_list:
    old_call 0x2a10 /* retain C05 install, C04 filesystem and native init */
    pushf
    pusha
    push ds
    push es
    cmp byte ptr cs:[0x224c],1
    jne .Linstall_done
    mov ax,word ptr cs:[0x2204]
    mov es,ax
    mov word ptr cs:[native_draw_return-segment_start+2],ax
    /* EXE F29A = main:E49A, either pristine entry or this exact hook. */
    cmp byte ptr es:[0xe49a],0xea
    je .Lexisting_hook
    cmp word ptr es:[0xe49a],0xd3e8
    jne .Linstall_done
    cmp word ptr es:[0xe49c],0xcd02
    jne .Linstall_done
    cmp byte ptr es:[0xe49e],0x2b
    jne .Linstall_done
    jmp .Linstall_hook
.Lexisting_hook:
    cmp word ptr es:[0xe49b],list_draw_entry-segment_start
    jne .Linstall_done
    mov ax,cs
    cmp word ptr es:[0xe49d],ax
    jne .Linstall_done
.Linstall_hook:
    cli
    mov byte ptr es:[0xe49a],0xea
    mov word ptr es:[0xe49b],list_draw_entry-segment_start
    mov es:[0xe49d],cs
.Linstall_done:
    pop es
    pop ds
    popa
    popf
    retf

/* The native caller expects a near RET in its own CS. The entry hook is a
 * far JMP, so jump back to the untouched native RET at EXE F303. */
list_draw_entry:
    call list_draw_core
    jmp far ptr cs:[native_draw_return-segment_start]

list_draw_core:
    pushf
    pusha
    push ds
    push es
    cld
    mov byte ptr cs:[row_valid-segment_start],0
    main_near 0xf570 /* original media-status check */
    int 0x2b
inline_begin_clear:
    .byte 0x60,64,11,120,40
inline_end_clear:
    /* Keep the exact native five-row enumeration/rewind sequence. Capture
     * the name while its row is drawn: 78C9 normally refers to the top row,
     * whereas 78C1 selects any of the five visible rows. No extra scans. */
    selected_row 0,11
    main_near 0xf163
    jc rows_done
    selected_row 1,19
    main_near 0xf163
    jc rewind_one
    selected_row 2,27
    main_near 0xf163
    jc rewind_two
    selected_row 3,35
    main_near 0xf163
    jc rewind_three
    selected_row 4,43
    main_near 0xf163
    jc rewind_four
    main_near 0xf1c4
rewind_four:
    main_near 0xf1c4
rewind_three:
    main_near 0xf1c4
rewind_two:
    main_near 0xf1c4
rewind_one:
    main_near 0xf1c4
rows_done:
    mov al,byte ptr [0x78c1]
    mov ah,8
    mul ah
    add al,10
    mov ch,al
    mov cl,61
    mov dl,125
    mov dh,9
    int 0x2b
inline_begin_highlight:
    .byte 0x84
inline_end_highlight:
    call draw_open_button
    pop es
    pop ds
    popa
    popf
    ret

/* AL = the row about to be drawn. Snapshot at most one 20-byte entry. */
capture_row:
    pushf
    pusha
    push es
    cmp al,byte ptr [0x78c1]
    jne .Lcapture_done
    cmp byte ptr [0x78af],0
    je .Lcapture_done
    cmp word ptr [0x78c9+15],0x443c
    jne .Lcapture_done
    cmp word ptr [0x78c9+17],0x5249
    jne .Lcapture_done
    cmp byte ptr [0x78c9+19],'>'
    jne .Lcapture_done
    push cs
    pop es
    mov si,0x78c9
    mov di,row_name-segment_start
    mov cx,20
    cld
    rep movsb
    mov byte ptr cs:[row_valid-segment_start],1
.Lcapture_done:
    pop es
    popa
    popf
    ret

draw_open_button:
    /* Clear both label and callback for ordinary files or an empty list. */
    mov word ptr [0x0d8c],0x0ec0 /* native no-op */
    mov ax,word ptr cs:[0x2204]
    mov word ptr [0x0d8e],ax
    cmp byte ptr cs:[row_valid-segment_start],1
    jne .Lhide_open
    label "OPEN",1
    mov word ptr [0x0d8c],open_folder-segment_start
    mov [0x0d8e],cs
    ret
.Lhide_open:
    label " ",0
    ret

/* Native dispatch calls this different-CS button callback FAR. */
open_folder:
    pushf
    pusha
    push ds
    push es
    /* Re-evaluate the current highlight at the press, so a queued cursor
     * event cannot make a previously drawn/cached folder the wrong target. */
    call list_draw_core
    cmp byte ptr cs:[row_valid-segment_start],1
    jne .Lopen_done
    mov byte ptr cs:[row_valid-segment_start],0
    push cs
    pop es
    mov si,row_name-segment_start
    mov bh,byte ptr [0x78a8]
    mov bl,0x7e
    mov ax,0x5646
    int 0x2c /* existing validated folder navigation, including '..' */
    pushf
    /* The lookup may move the enumerator even on failure. Rebuild the list
     * from the current (successfully changed or retained) directory. */
    main_near 0xf13e
    main_near 0xf208
    call list_draw_core
    int 0x52
    popf
    jnc .Lopen_done
    int 0x2b
inline_begin_error:
    .byte 0x20
    .asciz "Folder unavailable"
inline_end_error:
.Lopen_done:
    pop es
    pop ds
    popa
    popf
    retf
code_end:
.balign 2,0
native_draw_return: .word 0xe503,0
row_valid: .byte 0
row_name: .space 20,0
state_end:
.balign 4,0
extension_end:

.endif /* file_list */
/* directory_allocation: assembly unit 13. */
.if MOD_UNIT == 13
/* C11: reserve up to 32 contiguous floppy FAT12 clusters per mirrored page
 * commit. No uncommitted FAT cache, no new data buffer, no published slack.
 * DS=CS, same private C04 segment. Other volume geometries use the old writer.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
segment_start:
/* Begin old_symbols.inc */
.set old_writer_prepare_sector, 0x144c
.set old_preserve_end_marker, 0x1582
.set old_fat_position, 0x0d78
.set old_stage_fat_sector, 0x0f50
.set old_write_sector, 0x0e89
.set old_sync_native_fat, 0x0f92
.set old_fat_set, 0x0ff6
.set old_fat_raw, 0x07b6
.set old_valid_cluster, 0x082d
.set old_writer_first, 0x1730
.set old_writer_last, 0x1732
.set old_writer_sector, 0x1734
.set old_writer_state, 0x1708
.set old_write_fault, 0x1709
.set old_writer_error, 0x170a
.set old_drive, 0x224d
.set old_fat_bits, 0x224f
.set old_spc, 0x2258
.set old_cluster_limit, 0x2260
.set old_alloc_hint, 0x1714
.set old_fat_sector, 0x225c
.set old_fat_sectors, 0x225e
.set old_fat_buffer, 0x1a00

/* End old_symbols.inc */
.org 0x41ec
.global extension_start, code_end, state_end, extension_end
.global prepare_fast, close_trim, page_get, page_set, commit_page
.global pool_next, pool_end, page_lba, run_first, run_end
.macro old_call target
    .byte 0xe8
    .word \target - (. - segment_start + 2)
.endm
extension_start:
/* CF=0 only for the precisely scoped fast path. */
eligible:
    cmp byte ptr [old_drive],0
    jne .Lnot_eligible
    cmp byte ptr [old_fat_bits],12
    jne .Lnot_eligible
    cmp word ptr [old_spc],1
    jne .Lnot_eligible
    cmp byte ptr [old_writer_state],1
    jne .Lnot_eligible
    clc
    ret
.Lnot_eligible:
    stc
    ret

prepare_fast:
    pusha
    call eligible
    jc .Lfallback
    cmp word ptr [old_writer_last],0
    jne .Lhave_last
    mov word ptr [pool_next-segment_start],0
    jmp .Lreserve
.Lhave_last:
    cmp word ptr [old_writer_sector],1
    jb .Lready
    mov ax,[pool_next-segment_start]
    or ax,ax
    jz .Lreserve
    cmp ax,[pool_end-segment_start]
    ja .Lreserve
    mov bx,[old_writer_last]
    inc bx
    cmp ax,bx
    jne .Lbad
    inc word ptr [pool_next-segment_start]
    jmp .Luse_cluster
.Lreserve:
    /* Search once from the allocation hint, wrapping at most once. */
    mov cx,[old_cluster_limit]
    sub cx,2
    mov bx,[old_alloc_hint]
    cmp bx,2
    jb .Lscan_reset
    cmp bx,[old_cluster_limit]
    jb .Lscan
.Lscan_reset:
    mov bx,2
.Lscan:
    mov ax,bx
    old_call old_fat_raw
    jc .Lbad
    or ax,ax
    jz .Lfound
    inc bx
    cmp bx,[old_cluster_limit]
    jb .Lscan_next
    mov bx,2
.Lscan_next:
    loop .Lscan
    mov word ptr [old_writer_error],3
    popa
    stc
    ret
.Lfound:
    mov [run_first-segment_start],bx
    mov [old_alloc_hint],bx
    mov ax,bx
    old_call old_fat_position
    jc .Lbad
    /* Cross-sector packed entries retain the proven two-page path. */
    cmp bx,511
    je .Lfallback
    add ax,[old_fat_sector]
    mov [page_lba-segment_start],ax
    mov di,old_fat_buffer
    old_call old_stage_fat_sector
    jc .Lbad
    mov si,[run_first-segment_start]
    mov cx,32
.Lcount_run:
    mov ax,si
    cmp ax,[old_cluster_limit]
    jae .Lcount_done
    old_call old_fat_position
    jc .Lbad
    cmp bx,511
    je .Lcount_done
    add ax,[old_fat_sector]
    cmp ax,[page_lba-segment_start]
    jne .Lcount_done
    mov ax,si
    call page_get
    or ax,ax
    jnz .Lcount_done
    inc si
    loop .Lcount_run
.Lcount_done:
    cmp si,[run_first-segment_start]
    je .Lbad
    dec si
    mov [run_end-segment_start],si
    mov si,[run_first-segment_start]
.Llink_run:
    mov ax,si
    mov dx,si
    inc dx
    cmp si,[run_end-segment_start]
    jne .Llink_value
    mov dx,0x0fff
.Llink_value:
    call page_set
    inc si
    cmp si,[run_end-segment_start]
    jbe .Llink_run
    /* Link the existing tail in the same write if it occupies this page.
       Otherwise reserve the new chain first, then update the old tail. */
    mov byte ptr [external_link-segment_start],0
    mov ax,[old_writer_last]
    or ax,ax
    jz .Lcommit_run
    old_call old_fat_position
    jc .Lbad
    cmp bx,511
    je .Lexternal_link
    add ax,[old_fat_sector]
    cmp ax,[page_lba-segment_start]
    jne .Lexternal_link
    mov ax,[old_writer_last]
    call page_get
    cmp ax,0x0ff8
    jb .Lbad
    mov ax,[old_writer_last]
    mov dx,[run_first-segment_start]
    call page_set
    jmp .Lcommit_run
.Lexternal_link:
    mov byte ptr [external_link-segment_start],1
.Lcommit_run:
    call commit_page
    jc .Lbad
    cmp byte ptr [external_link-segment_start],0
    je .Lrun_committed
    mov ax,[old_writer_last]
    mov dx,[run_first-segment_start]
    old_call old_fat_set
    jc .Lbad
.Lrun_committed:
    mov ax,[run_end-segment_start]
    mov [pool_end-segment_start],ax
    inc ax
    mov [old_alloc_hint],ax
    mov ax,[run_first-segment_start]
    mov [pool_next-segment_start],ax
    inc word ptr [pool_next-segment_start]
.Luse_cluster:
    cmp word ptr [old_writer_first],0
    jne .Lset_last
    mov [old_writer_first],ax
.Lset_last:
    mov [old_writer_last],ax
    mov word ptr [old_writer_sector],0
.Lready:
    popa
    clc
    ret
.Lfallback:
    mov word ptr [pool_next-segment_start],0
    popa
    old_call old_writer_prepare_sector
    ret
.Lbad:
    mov byte ptr [old_write_fault],1
    mov word ptr [old_writer_error],4
    popa
    stc
    ret

/* Called after the last data-sector flush, before publishing a directory
 * entry. Validate the whole unused reservation, then truncate in one page.
 * No unused reserved cluster is left reachable from a completed file.
 */
close_trim:
    pusha
    call eligible
    jc .Ltrim_done
    cmp word ptr [old_writer_last],0
    je .Ltrim_done
    mov ax,[pool_next-segment_start]
    or ax,ax
    jz .Ltrim_done
    cmp ax,[pool_end-segment_start]
    ja .Ltrim_done
    mov si,[old_writer_last]
    mov bx,si
    inc bx
    cmp ax,bx
    jne .Lbad
    mov ax,si
    old_call old_fat_position
    jc .Lbad
    cmp bx,511
    je .Lbad
    add ax,[old_fat_sector]
    mov [page_lba-segment_start],ax
    mov di,old_fat_buffer
    old_call old_stage_fat_sector
    jc .Lbad
.Ltrim_check:
    mov ax,si
    old_call old_fat_position
    jc .Lbad
    cmp bx,511
    je .Lbad
    add ax,[old_fat_sector]
    cmp ax,[page_lba-segment_start]
    jne .Lbad
    mov ax,si
    call page_get
    mov dx,si
    inc dx
    cmp si,[pool_end-segment_start]
    jne .Ltrim_expected
    mov dx,0x0fff
.Ltrim_expected:
    cmp ax,dx
    jne .Lbad
    inc si
    cmp si,[pool_end-segment_start]
    jbe .Ltrim_check
    mov ax,[old_writer_last]
    mov dx,0x0fff
    call page_set
    mov si,[pool_next-segment_start]
.Ltrim_clear:
    mov ax,si
    xor dx,dx
    call page_set
    inc si
    cmp si,[pool_end-segment_start]
    jbe .Ltrim_clear
    call commit_page
    jc .Lbad
.Ltrim_done:
    mov word ptr [pool_next-segment_start],0
    popa
    old_call old_preserve_end_marker
    ret

/* Callers validate that this packed FAT12 entry fits the staged page.
 * GET: AX cluster -> AX value; all other registers preserved.
 * SET: AX cluster, DX value; all registers preserved; retain adjacent nibble.
 */
page_get:
    push bx
    push dx
    mov dx,ax
    mov bx,ax
    shr bx,1
    add bx,ax
    and bx,511
    mov ax,[old_fat_buffer+bx]
    test dx,1
    jz .Lget_even
    shr ax,4
.Lget_even:
    and ax,0x0fff
    pop dx
    pop bx
    ret
page_set:
    pusha
    mov bx,ax
    shr bx,1
    add bx,ax
    and bx,511
    test ax,1
    mov ax,[old_fat_buffer+bx]
    jz .Lset_even
    and ax,0x000f
    shl dx,4
    jmp .Lset_merge
.Lset_even:
    and ax,0xf000
.Lset_merge:
    or ax,dx
    mov [old_fat_buffer+bx],ax
    popa
    ret

/* Keep the existing mirror-first, primary-second and native-cache contract. */
commit_page:
    pusha
    mov ax,[page_lba-segment_start]
    add ax,[old_fat_sectors]
    xor dx,dx
    mov si,old_fat_buffer
    old_call old_write_sector
    jc .Lcommit_bad
    mov ax,[page_lba-segment_start]
    old_call old_write_sector
    jc .Lcommit_bad
    old_call old_sync_native_fat
    popa
    clc
    ret
.Lcommit_bad:
    popa
    stc
    ret
code_end:
.align 2
pool_next: .word 0
pool_end: .word 0
page_lba: .word 0
run_first: .word 0
run_end: .word 0
external_link: .byte 0
state_end:
.align 2
extension_end:

.endif /* directory_allocation */
/* file_load: assembly unit 17. */
.if MOD_UNIT == 17
/* C16: F3 OPEN stays visible. Directory navigation retains C10 behavior;
 * ordinary files use native FILE LIST CLOSE followed by native LOAD DO IT.
 * Append-only payload in the existing C04 CS, inside C15's reservation.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
segment_start:
/* Begin bindings.inc */
.equ ORIGIN,0x560c
.equ LIST_DRAW_CORE,0x3fa4
.equ ROW_VALID,0x41c6
.equ OPEN_FOLDER,0x4155

/* End bindings.inc */
.org ORIGIN
.global extension_start, extension_end, code_end, draw_open, open_entry
.global inline_begin_label, inline_end_label

.macro retained_call target
    .byte 0xe8
    .word \target - (. - segment_start + 2)
.endm
.macro main_near fileoff
    push bp
    push cs
    push main_return_\@ - segment_start
    push 0x046b
    push word ptr cs:[0x2204]
    push (\fileoff - 0x0e00)
    retf
main_return_\@:
    pop bp
.endm

extension_start:
draw_open:
    int 0x2b
inline_begin_label:
    .byte 0x68,3,1
    .asciz "OPEN"
inline_end_label:
    mov word ptr [0x0d8c],open_entry-segment_start
    mov [0x0d8e],cs
    ret

/* Different-CS button callbacks must RETF. The draw helper is a near call
 * that preserves registers and redraws the current highlight/cached <DIR>.
 */
open_entry:
    pushf
    pusha
    push ds
    push es
    retained_call LIST_DRAW_CORE
    cmp byte ptr cs:[ROW_VALID],1
    jne open_file
    pop es
    pop ds
    popa
    popf
    /* Existing handler revalidates the folder and retains the open list,
     * '..' navigation and the existing error display/recovery paths.
     */
    .byte 0xe9
    .word OPEN_FOLDER - (. - segment_start + 2)

open_file:
    cmp byte ptr [0x78af],0
    je open_done
    /* CLOSE walks the highlighted row (78C1), updates the selected file,
     * closes the modal and installs LOAD's normal callback set. Calling
     * DO IT before this would load the top visible row instead.
     */
    main_near 0xf322
    /* Same main:E98F path as F6 on LOAD, including the C04 filesystem hook,
     * media checks, file-type dispatch and all native confirmation dialogs.
     */
    main_near 0xf78f
open_done:
    pop es
    pop ds
    popa
    popf
    retf
code_end:
.balign 4,0
extension_end:

.endif /* file_load */
/* scsi_directory: assembly unit 19. */
.if MOD_UNIT == 19
/* C17 R2: retain the directory across native disk-page refresh and partition
 * reselection. Runs in the existing C04 segment; never synthesizes disk I/O.
 * Entry stack is exactly C04 reset-pass: saved DS, AX, flags, INT frame.
 */
.intel_syntax noprefix
.code16
.arch i186
.text
segment_start:
.macro old_call target
    .byte 0xe8
    .word \target - (. - segment_start + 2)
.endm
.macro old_jump target
    .byte 0xe9
    .word \target - (. - segment_start + 2)
.endm
/* Begin layout.inc */
.equ ORIGIN, 0xcdf0

/* End layout.inc */
.org ORIGIN
.global preserve_context, allow_native_name, code_end, module_end
.equ cwd, 0x2250
.equ drive, 0x224d
.equ partition, 0x2268
.equ writer_state, 0x1708
.equ write_fault, 0x1709
.equ io_active, 0x16fc
.equ main_segment, 0x2204
.equ reset_context, 0x0475
.equ check_volume, 0x0bc9
.equ geometry, 0x0497
.equ call_original, 0x0432
.equ finish, 0x0421
.equ reset_tail, 0x03c7

preserve_context:
    cmp bl, 1
    je .Lcandidate
    cmp bl, 0x17
    jne .Lreset
.Lcandidate:
    cmp word ptr cs:[cwd], 0
    je .Lreset
    cmp word ptr cs:[writer_state], 0 /* state and fault */
    jne .Lreset
    push bp
    mov bp, sp
    push ax
    mov ax, cs:[main_segment]
    cmp ss:[bp+10], ax
    pop ax
    jne .Lcaller_bad
    cmp bl, 1
    jne .Lpartition_caller
    cmp word ptr ss:[bp+8], 0xe82e
    jne .Lcaller_bad
    /* The caller's data segment owns the currently selected partition. */
    push ax
    push es
    mov es, ss:[bp+2]
    mov al, es:[0x78b0]
    mov cs:[selected_partition-segment_start], al
    pop es
    pop ax
    jmp .Lcaller_ok
.Lpartition_caller:
    cmp word ptr ss:[bp+8], 0xe8d0
    jne .Lcaller_bad
.Lcaller_ok:
    mov cs:[request_kind-segment_start], bl
    pop bp
    old_call check_volume
    jc .Lreset
    pop ds
    pop ax
    popf
    push bp
    mov bp, sp
    push ds
    push cs
    pop ds
    cld
    sti
    mov byte ptr [io_active], 1
    old_call call_original
    mov byte ptr [io_active], 0
    pushf
    pusha
    push es
    jc .Lbad
    cmp byte ptr [request_kind-segment_start], 1
    jne .Lvalidate
    cmp byte ptr [drive], 0
    je .Lvalidate
    cmp byte ptr [drive], 9
    jae .Lbad
    /* Native mount selects A. Restore B..Z before comparing the pinned
     * volume. Keep the original mount's output registers for its caller. */
    cmp al, 0x13 /* MPC2000 partition table */
    je .Lrestore_partition
    cmp al, 0x14 /* compatible DOS partition table */
    jne .Lvalidate
.Lrestore_partition:
    mov al, [selected_partition-segment_start]
    cmp al, dl
    jae .Lbad
    mov bh, [drive]
    mov bl, 0x17
    mov byte ptr [io_active], 1
    old_call call_original
    mov byte ptr [io_active], 0
    jc .Lbad
.Lvalidate:
    push word ptr [partition+2]
    push word ptr [partition]
    old_call geometry
    pop bx
    pop dx
    jc .Lbad
    cmp bx, [partition]
    jne .Ldifferent_partition
    cmp dx, [partition+2]
    jne .Ldifferent_partition
    old_call check_volume
    jc .Lbad
    mov word ptr [0x2256], 0xffff
    mov byte ptr [0x224e], 0
    jmp .Ldone
.Ldifferent_partition:
    /* A deliberate A/B selection must enter the new partition at ROOT. */
    cmp byte ptr [request_kind-segment_start], 0x17
    jne .Lbad
    old_call reset_context
    jmp .Ldone
.Lbad:
    old_call reset_context
    mov byte ptr [write_fault], 1
.Ldone:
    pop es
    popa
    popf
    old_jump finish
.Lcaller_bad:
    pop bp
.Lreset:
    old_call reset_context
    old_jump reset_tail

/* The CREATE scanner already compared the full native 16+dot+3 name.
 * Equal first-eight bytes with a different native suffix are valid, e.g.
 * SOUND030.SND and SOUND030C.SND. Do not relax VFAT/protected entry guards. */
allow_native_name:
    test byte ptr [0x2294+11], 0x1f
    jnz .Lname_blocked
    old_call 0x12b1 /* slot_without_lfn; restores the scanned entry */
    jc .Lname_error
    old_jump 0x139c /* CREATE scan: next entry */
.Lname_blocked:
    mov word ptr [0x170a], 2
.Lname_error:
    old_jump 0x1445 /* writer_service_error */
.balign 2, 0x90
code_end:
request_kind: .byte 0
selected_partition: .byte 0
module_end:

.endif /* scsi_directory */
