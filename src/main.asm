option casemap:none

includelib kernel32.lib

; This program uses no high-level MASM sugar (no PROC parameter lists, no
; LOCAL, no INVOKE): every call site sets up RCX/RDX/R8/R9 by hand and
; reserves the 32-byte shadow space the x64 calling convention requires.
; Internal procs follow the same convention as Win32 calls: argument N in
; the Nth of RCX,RDX,R8,R9 (full 64-bit register for pointers/handles, the
; 32-bit sub-register for DWORDs), return value in EAX.

SCR_W           EQU 80
HEIGHT          EQU 25
PLAY_HEIGHT     EQU 21
CAT_W           EQU 7
INPUT_BUF_COUNT EQU 32
BEDX            EQU 3
BEDY            EQU 15

STD_OUTPUT_HANDLE_VAL EQU -11
STD_INPUT_HANDLE_VAL  EQU -10
ENABLE_EXTENDED_FLAGS EQU 80h
ENABLE_MOUSE_INPUT    EQU 10h
KEY_EVENT             EQU 1
MOUSE_EVENT           EQU 2
MOUSE_MOVED           EQU 1
TRUE                  EQU 1

; INPUT_RECORD (x64): WORD EventType @0, 2 bytes padding, 16-byte union @4.
; KEY_EVENT_RECORD:   bKeyDown@4  uChar(AsciiChar)@14
; MOUSE_EVENT_RECORD: dwMousePosition.X@4 .Y@6  dwButtonState@8  dwEventFlags@16

EXTERN GetStdHandle:PROC
EXTERN SetConsoleMode:PROC
EXTERN GetConsoleMode:PROC
EXTERN SetConsoleTitleA:PROC
EXTERN SetConsoleScreenBufferSize:PROC
EXTERN SetConsoleWindowInfo:PROC
EXTERN SetConsoleCursorInfo:PROC
EXTERN WriteConsoleOutputA:PROC
EXTERN GetNumberOfConsoleInputEvents:PROC
EXTERN ReadConsoleInputA:PROC
EXTERN Sleep:PROC
EXTERN ExitProcess:PROC

.data

titleStr        BYTE "asmcat", 0
catLine0        BYTE " /\_/\ ", 0
catLine1Open    BYTE "( o.o )", 0
catLine1Blink   BYTE "( -.- )", 0
catLine2        BYTE " > ^ < ", 0
statusPrefix1   BYTE "Hunger:", 0
statusPrefix2   BYTE "Happiness:", 0
statusPrefix3   BYTE "Play:", 0
onStr           BYTE "ON ", 0
offStr          BYTE "OFF", 0
helpStr         BYTE "[Click] ball  [F] feed  [P] play  [S] sleep  [Q] quit", 0
sleepZStr       BYTE "z Z z", 0
bedStr          BYTE "(_____)", 0

.data?

hOut            QWORD ?
hIn             QWORD ?
oldMode         DWORD ?
screenBuffer    BYTE (SCR_W * HEIGHT * 4) DUP(?)
inputBuf        BYTE (INPUT_BUF_COUNT * 20) DUP(?)

catX            DWORD ?
catY            DWORD ?
hasTarget       DWORD ?
targetX         DWORD ?
targetY         DWORD ?
pursuing        DWORD ?   ; 0=none 1=ball 2=food 3=going to bed
isSleeping      DWORD ?

ballActive      DWORD ?
ballX           DWORD ?
ballY           DWORD ?
ballTX          DWORD ?
ballTY          DWORD ?

foodActive      DWORD ?
foodX           DWORD ?
foodY           DWORD ?

hunger          DWORD ?
happiness       DWORD ?
playMode        DWORD ?
lastMouseX      DWORD ?
lastMouseY      DWORD ?
prevLeftDown    DWORD ?
tickCount       DWORD ?
running         DWORD ?

.code

; eax = clamp(ecx, edx, r8d)
clampi PROC
    mov eax, ecx
    cmp eax, edx
    jge clampi_chkhi
    mov eax, edx
clampi_chkhi:
    cmp eax, r8d
    jle clampi_ret
    mov eax, r8d
clampi_ret:
    ret
clampi ENDP

; itoa_u(ecx=value, rdx=bufPtr) -> eax=length. Leaf, no calls.
itoa_u PROC
    sub rsp, 16
    mov r10, rdx
    mov eax, ecx
    xor r9d, r9d
    mov r11d, 10
itoa_divloop:
    xor edx, edx
    div r11d
    add dl, '0'
    mov byte ptr [rsp+r9], dl
    inc r9d
    test eax, eax
    jnz itoa_divloop
    mov eax, r9d
    mov rdx, r10
itoa_revloop:
    dec r9d
    mov cl, byte ptr [rsp+r9]
    mov [rdx], cl
    inc rdx
    test r9d, r9d
    jnz itoa_revloop
    mov byte ptr [rdx], 0
    add rsp, 16
    ret
itoa_u ENDP

; draw_char(ecx=x, edx=y, r8d=ch, r9d=attr). Leaf.
draw_char PROC
    cmp ecx, 0
    jl dc_exit
    cmp ecx, SCR_W
    jge dc_exit
    cmp edx, 0
    jl dc_exit
    cmp edx, HEIGHT
    jge dc_exit
    mov eax, edx
    imul eax, SCR_W
    add eax, ecx
    shl eax, 2
    lea r10, screenBuffer
    add r10, rax
    mov byte ptr [r10], r8b
    mov byte ptr [r10+1], 0
    mov word ptr [r10+2], r9w
dc_exit:
    ret
draw_char ENDP

; draw_string(ecx=x, edx=y, r8=strPtr, r9d=attr)
; frame: [0,32) shadow  [32]x  [36]y  [40]strPtr  [48]attr  [52]curX
draw_string PROC
    sub rsp, 56
    mov [rsp+32], ecx
    mov [rsp+36], edx
    mov [rsp+40], r8
    mov [rsp+48], r9d
    mov eax, [rsp+32]
    mov [rsp+52], eax
ds_loop:
    mov rax, [rsp+40]
    movzx r10d, byte ptr [rax]
    test r10d, r10d
    jz ds_done
    mov ecx, [rsp+52]
    mov edx, [rsp+36]
    mov r8d, r10d
    mov r9d, [rsp+48]
    call draw_char
    mov rax, [rsp+40]
    inc rax
    mov [rsp+40], rax
    mov eax, [rsp+52]
    inc eax
    mov [rsp+52], eax
    jmp ds_loop
ds_done:
    add rsp, 56
    ret
draw_string ENDP

; clear_screen(). Leaf.
clear_screen PROC
    lea r10, screenBuffer
    mov eax, SCR_W*HEIGHT
clr_loop:
    mov byte ptr [r10], 20h
    mov byte ptr [r10+1], 0
    mov word ptr [r10+2], 0007h
    add r10, 4
    dec eax
    jnz clr_loop
    ret
clear_screen ENDP

; flush_screen(). Calls WriteConsoleOutputA(hOut, &screenBuffer, bufSize, bufCoord, &writeRegion)
; frame: [0,32) shadow  [32] 5th-arg slot  [40] writeRegion(8: L,T,R,B words)  [48] bufSize  [52] bufCoord
flush_screen PROC
    sub rsp, 56
    mov word ptr [rsp+40], 0
    mov word ptr [rsp+42], 0
    mov word ptr [rsp+44], SCR_W-1
    mov word ptr [rsp+46], HEIGHT-1
    mov dword ptr [rsp+48], SCR_W or (HEIGHT shl 16)
    mov dword ptr [rsp+52], 0

    lea rax, [rsp+40]
    mov [rsp+32], rax

    mov rcx, hOut
    lea rdx, screenBuffer
    mov r8d, [rsp+48]
    mov r9d, [rsp+52]
    call WriteConsoleOutputA
    add rsp, 56
    ret
flush_screen ENDP

; draw_status(). Reads global stats, draws them.
; frame: [0,32) shadow  [32] numbuf[12]
draw_status PROC
    sub rsp, 56

    mov ecx, 1
    mov edx, 22
    lea r8, statusPrefix1
    mov r9d, 07h
    call draw_string

    mov ecx, hunger
    lea rdx, [rsp+32]
    call itoa_u
    mov ecx, 9
    mov edx, 22
    lea r8, [rsp+32]
    mov r9d, 0Fh
    call draw_string

    mov ecx, 14
    mov edx, 22
    lea r8, statusPrefix2
    mov r9d, 07h
    call draw_string

    mov ecx, happiness
    lea rdx, [rsp+32]
    call itoa_u
    mov ecx, 25
    mov edx, 22
    lea r8, [rsp+32]
    mov r9d, 0Fh
    call draw_string

    mov ecx, 30
    mov edx, 22
    lea r8, statusPrefix3
    mov r9d, 07h
    call draw_string

    mov eax, playMode
    test eax, eax
    jz ds_off
    mov ecx, 36
    mov edx, 22
    lea r8, onStr
    mov r9d, 0Ah
    call draw_string
    jmp ds_help
ds_off:
    mov ecx, 36
    mov edx, 22
    lea r8, offStr
    mov r9d, 0Ch
    call draw_string
ds_help:
    mov ecx, 1
    mov edx, 23
    lea r8, helpStr
    mov r9d, 08h
    call draw_string

    add rsp, 56
    ret
draw_status ENDP

; render_frame()
; frame: [0,32) shadow  [32] blinkOn  [36] y1  [40] y2
render_frame PROC
    sub rsp, 56
    call clear_screen

    mov ecx, BEDX
    mov edx, BEDY+3
    lea r8, bedStr
    mov r9d, 08h
    call draw_string

    mov eax, foodActive
    test eax, eax
    jz rf_food_done
    mov ecx, foodX
    mov edx, foodY
    mov r8d, 40h
    mov r9d, 0Ch
    call draw_char
rf_food_done:

    mov eax, ballActive
    test eax, eax
    jz rf_ball_done
    mov ecx, ballX
    mov edx, ballY
    mov r8d, 6Fh
    mov r9d, 0Eh
    call draw_char
rf_ball_done:

    mov eax, tickCount
    xor edx, edx
    mov ecx, 40
    div ecx
    cmp edx, 3
    jl rf_blink
    mov dword ptr [rsp+32], 0
    jmp rf_drawcat
rf_blink:
    mov dword ptr [rsp+32], 1
rf_drawcat:
    mov eax, isSleeping
    test eax, eax
    jz rf_noforce
    mov dword ptr [rsp+32], 1
rf_noforce:
    mov eax, catY
    inc eax
    mov [rsp+36], eax
    mov eax, catY
    add eax, 2
    mov [rsp+40], eax

    mov ecx, catX
    mov edx, catY
    lea r8, catLine0
    mov r9d, 0Bh
    call draw_string

    mov eax, [rsp+32]
    test eax, eax
    jnz rf_use_blink
    mov ecx, catX
    mov edx, [rsp+36]
    lea r8, catLine1Open
    mov r9d, 0Bh
    call draw_string
    jmp rf_line2
rf_use_blink:
    mov ecx, catX
    mov edx, [rsp+36]
    lea r8, catLine1Blink
    mov r9d, 0Bh
    call draw_string
rf_line2:
    mov ecx, catX
    mov edx, [rsp+40]
    lea r8, catLine2
    mov r9d, 0Bh
    call draw_string

    mov eax, isSleeping
    test eax, eax
    jz rf_no_zzz
    mov ecx, catX
    add ecx, 5
    mov edx, catY
    dec edx
    lea r8, sleepZStr
    mov r9d, 0Bh
    call draw_string
rf_no_zzz:

    call draw_status
    call flush_screen
    add rsp, 56
    ret
render_frame ENDP

; set_target(ecx=x, edx=y)
; frame: [0,32) shadow  [32] argX  [36] argY
set_target PROC
    sub rsp, 40
    mov [rsp+32], ecx
    mov [rsp+36], edx

    mov ecx, [rsp+32]
    sub ecx, 3
    mov edx, 0
    mov r8d, SCR_W-CAT_W
    call clampi
    mov targetX, eax

    mov ecx, [rsp+36]
    sub ecx, 1
    mov edx, 0
    mov r8d, PLAY_HEIGHT-3
    call clampi
    mov targetY, eax

    mov hasTarget, 1
    add rsp, 40
    ret
set_target ENDP

; throw_ball(ecx=x, edx=y)
; frame: [0,32) shadow  [32] argX  [36] argY
throw_ball PROC
    mov eax, ballActive
    test eax, eax
    jnz tb_done_noframe

    sub rsp, 40
    mov [rsp+32], ecx
    mov [rsp+36], edx

    mov isSleeping, 0
    mov eax, pursuing
    cmp eax, 3
    jne tb_notbed
    mov pursuing, 0
    mov hasTarget, 0
tb_notbed:

    mov eax, catX
    mov ballX, eax
    mov eax, catY
    add eax, 1
    mov ballY, eax

    mov ecx, [rsp+32]
    mov edx, 0
    mov r8d, SCR_W-1
    call clampi
    mov ballTX, eax

    mov ecx, [rsp+36]
    mov edx, 0
    mov r8d, PLAY_HEIGHT-1
    call clampi
    mov ballTY, eax

    mov ballActive, 1
    add rsp, 40
tb_done_noframe:
    ret
throw_ball ENDP

; do_feed(). No params; reads lastMouseX/Y globals.
do_feed PROC
    mov eax, foodActive
    test eax, eax
    jnz df_done_noframe

    sub rsp, 40
    mov ecx, lastMouseX
    mov edx, 0
    mov r8d, SCR_W-1
    call clampi
    mov foodX, eax

    mov ecx, lastMouseY
    mov edx, 0
    mov r8d, PLAY_HEIGHT-1
    call clampi
    mov foodY, eax

    mov foodActive, 1
    mov isSleeping, 0

    mov eax, pursuing
    cmp eax, 3
    jne df_notbed
    mov pursuing, 0
    mov hasTarget, 0
df_notbed:
    mov eax, pursuing
    test eax, eax
    jnz df_no_target
    mov pursuing, 2
    mov eax, foodX
    mov targetX, eax
    mov eax, foodY
    mov targetY, eax
    mov hasTarget, 1
df_no_target:
    add rsp, 40
df_done_noframe:
    ret
do_feed ENDP

; decay_stats(). Leaf.
decay_stats PROC
    mov eax, hunger
    test eax, eax
    jz ds_h_done
    dec eax
    mov hunger, eax
ds_h_done:
    mov eax, happiness
    test eax, eax
    jz ds_done
    dec eax
    mov happiness, eax
ds_done:
    ret
decay_stats ENDP

; update_ball(). Leaf.
update_ball PROC
    mov eax, ballActive
    test eax, eax
    jz ub_done
    mov eax, ballX
    mov ecx, ballTX
    cmp eax, ecx
    je ub_x_done
    jl ub_x_inc
    dec eax
    jmp ub_x_store
ub_x_inc:
    inc eax
ub_x_store:
    mov ballX, eax
ub_x_done:
    mov eax, ballY
    mov ecx, ballTY
    cmp eax, ecx
    je ub_y_done
    jl ub_y_inc
    dec eax
    jmp ub_y_store
ub_y_inc:
    inc eax
ub_y_store:
    mov ballY, eax
ub_y_done:
    mov eax, ballX
    cmp eax, ballTX
    jne ub_done
    mov eax, ballY
    cmp eax, ballTY
    jne ub_done
    mov pursuing, 1
    mov eax, ballX
    mov targetX, eax
    mov eax, ballY
    mov targetY, eax
    mov hasTarget, 1
ub_done:
    ret
update_ball ENDP

; update_cat(). Leaf.
update_cat PROC
    mov eax, hasTarget
    test eax, eax
    jz uc_done
    mov eax, catX
    mov ecx, targetX
    cmp eax, ecx
    je uc_x_done
    jl uc_x_inc
    dec eax
    jmp uc_x_store
uc_x_inc:
    inc eax
uc_x_store:
    mov catX, eax
uc_x_done:
    mov eax, catY
    mov ecx, targetY
    cmp eax, ecx
    je uc_y_done
    jl uc_y_inc
    dec eax
    jmp uc_y_store
uc_y_inc:
    inc eax
uc_y_store:
    mov catY, eax
uc_y_done:
    mov eax, catX
    cmp eax, targetX
    jne uc_done
    mov eax, catY
    cmp eax, targetY
    jne uc_done

    mov eax, pursuing
    cmp eax, 1
    je uc_catch
    cmp eax, 2
    je uc_eat
    cmp eax, 3
    je uc_sleep
    mov hasTarget, 0
    jmp uc_done
uc_sleep:
    mov pursuing, 0
    mov hasTarget, 0
    mov isSleeping, 1
    jmp uc_done
uc_catch:
    mov ballActive, 0
    mov pursuing, 0
    mov hasTarget, 0
    mov eax, happiness
    add eax, 15
    cmp eax, 100
    jle uc_catch_store
    mov eax, 100
uc_catch_store:
    mov happiness, eax
    jmp uc_done
uc_eat:
    mov foodActive, 0
    mov pursuing, 0
    mov hasTarget, 0
    mov eax, hunger
    add eax, 25
    cmp eax, 100
    jle uc_eat_store
    mov eax, 100
uc_eat_store:
    mov hunger, eax
uc_done:
    ret
update_cat ENDP

; update_state()
update_state PROC
    sub rsp, 40
    mov eax, tickCount
    inc eax
    mov tickCount, eax

    mov eax, isSleeping
    test eax, eax
    jnz us_skip_decay

    mov eax, tickCount
    xor edx, edx
    mov ecx, 50
    div ecx
    test edx, edx
    jnz us_skip_decay
    call decay_stats
us_skip_decay:
    call update_ball
    call update_cat
    add rsp, 40
    ret
update_state ENDP

; handle_key(rcx=recPtr)
handle_key PROC
    sub rsp, 40
    mov r10, rcx
    mov eax, dword ptr [r10+4]
    test eax, eax
    jz hk_done
    movzx eax, byte ptr [r10+14]

    cmp eax, 71h        ; 'q'
    je hk_quit
    cmp eax, 51h        ; 'Q'
    je hk_quit
    cmp eax, 66h        ; 'f'
    je hk_feed
    cmp eax, 46h        ; 'F'
    je hk_feed
    cmp eax, 70h        ; 'p'
    je hk_play
    cmp eax, 50h        ; 'P'
    je hk_play
    cmp eax, 73h        ; 's'
    je hk_sleep
    cmp eax, 53h        ; 'S'
    je hk_sleep
    jmp hk_done
hk_quit:
    mov running, 0
    jmp hk_done
hk_feed:
    call do_feed
    jmp hk_done
hk_play:
    mov eax, playMode
    xor eax, 1
    mov playMode, eax
    jmp hk_done
hk_sleep:
    call toggle_sleep
hk_done:
    add rsp, 40
    ret
handle_key ENDP

; toggle_sleep(). No params. Leaf.
toggle_sleep PROC
    mov eax, isSleeping
    test eax, eax
    jnz tsl_wake
    mov eax, pursuing
    cmp eax, 3
    je tsl_cancel
    mov pursuing, 3
    mov targetX, BEDX
    mov targetY, BEDY
    mov hasTarget, 1
    ret
tsl_cancel:
    mov pursuing, 0
    mov hasTarget, 0
    ret
tsl_wake:
    mov isSleeping, 0
    ret
toggle_sleep ENDP

; handle_mouse(rcx=recPtr). rcx is left untouched (only EAX/R9-R11 used as
; scratch) until the moment we deliberately overwrite it to set up a call,
; so [rcx+N] reads of the record stay valid throughout.
handle_mouse PROC
    sub rsp, 40
    movsx eax, word ptr [rcx+4]     ; X
    mov r10d, eax
    movsx eax, word ptr [rcx+6]     ; Y
    mov r11d, eax
    mov lastMouseX, r10d
    mov lastMouseY, r11d

    mov eax, dword ptr [rcx+16]     ; dwEventFlags
    mov r9d, eax
    and eax, MOUSE_MOVED
    jz hm_check_click
    mov eax, playMode
    test eax, eax
    jz hm_check_click
    mov eax, pursuing
    test eax, eax
    jnz hm_check_click
    mov eax, isSleeping
    test eax, eax
    jnz hm_check_click
    mov ecx, r10d
    mov edx, r11d
    call set_target
    jmp hm_done
hm_check_click:
    test r9d, r9d
    jnz hm_done
    mov eax, dword ptr [rcx+8]       ; dwButtonState
    and eax, 1
    mov r8d, prevLeftDown
    cmp eax, r8d
    je hm_update_prev
    mov prevLeftDown, eax
    test eax, eax
    jz hm_done
    mov ecx, r10d
    mov edx, r11d
    call throw_ball
    jmp hm_done
hm_update_prev:
    mov prevLeftDown, eax
hm_done:
    add rsp, 40
    ret
handle_mouse ENDP

; handle_event(ecx=idx)
handle_event PROC
    sub rsp, 40
    mov eax, ecx
    imul eax, 20
    lea rcx, inputBuf
    add rcx, rax
    movzx eax, word ptr [rcx]
    cmp eax, KEY_EVENT
    je he_key
    cmp eax, MOUSE_EVENT
    je he_mouse
    jmp he_done
he_key:
    call handle_key
    jmp he_done
he_mouse:
    call handle_mouse
he_done:
    add rsp, 40
    ret
handle_event ENDP

; poll_input()
; frame: [0,32) shadow  [32] numEvents  [36] numRead  [40] i
poll_input PROC
    sub rsp, 56
    lea rdx, [rsp+32]
    mov rcx, hIn
    call GetNumberOfConsoleInputEvents

    mov eax, [rsp+32]
    test eax, eax
    jz pi_done
    cmp eax, INPUT_BUF_COUNT
    jle pi_ok
    mov eax, INPUT_BUF_COUNT
pi_ok:
    mov [rsp+32], eax

    mov rcx, hIn
    lea rdx, inputBuf
    mov r8d, [rsp+32]
    lea r9, [rsp+36]
    call ReadConsoleInputA

    mov dword ptr [rsp+40], 0
pi_loop:
    mov eax, [rsp+40]
    cmp eax, [rsp+36]
    jge pi_done
    mov ecx, eax
    call handle_event
    mov eax, [rsp+40]
    inc eax
    mov [rsp+40], eax
    jmp pi_loop
pi_done:
    add rsp, 56
    ret
poll_input ENDP

; game_loop()
game_loop PROC
    sub rsp, 40
gl_top:
    call poll_input
    call update_state
    call render_frame
    mov ecx, 80
    call Sleep
    mov eax, running
    test eax, eax
    jnz gl_top
    add rsp, 40
    ret
game_loop ENDP

; init()
; frame: [0,32) shadow  [32] winRect(8: L,T,R,B words)  [40] curInfo(8: dwSize,bVisible dwords)
init PROC
    sub rsp, 56

    mov ecx, STD_OUTPUT_HANDLE_VAL
    call GetStdHandle
    mov hOut, rax

    mov ecx, STD_INPUT_HANDLE_VAL
    call GetStdHandle
    mov hIn, rax

    mov rcx, hIn
    lea rdx, oldMode
    call GetConsoleMode

    mov rcx, hIn
    mov edx, ENABLE_EXTENDED_FLAGS or ENABLE_MOUSE_INPUT
    call SetConsoleMode

    lea rcx, titleStr
    call SetConsoleTitleA

    mov rcx, hOut
    mov edx, SCR_W or (HEIGHT shl 16)
    call SetConsoleScreenBufferSize

    mov word ptr [rsp+32], 0
    mov word ptr [rsp+34], 0
    mov word ptr [rsp+36], SCR_W-1
    mov word ptr [rsp+38], HEIGHT-1
    mov rcx, hOut
    mov edx, TRUE
    lea r8, [rsp+32]
    call SetConsoleWindowInfo

    mov dword ptr [rsp+40], 25
    mov dword ptr [rsp+44], 0
    mov rcx, hOut
    lea rdx, [rsp+40]
    call SetConsoleCursorInfo

    mov catX, 36
    mov catY, 8
    mov hasTarget, 0
    mov pursuing, 0
    mov isSleeping, 0
    mov ballActive, 0
    mov foodActive, 0
    mov hunger, 80
    mov happiness, 80
    mov playMode, 0
    mov lastMouseX, 40
    mov lastMouseY, 10
    mov prevLeftDown, 0
    mov tickCount, 0
    mov running, 1

    add rsp, 56
    ret
init ENDP

; shutdown()
; frame: [0,32) shadow  [32] curInfo(8: dwSize,bVisible dwords)
shutdown PROC
    sub rsp, 40
    mov rcx, hIn
    mov edx, oldMode
    call SetConsoleMode

    mov dword ptr [rsp+32], 25
    mov dword ptr [rsp+36], 1
    mov rcx, hOut
    lea rdx, [rsp+32]
    call SetConsoleCursorInfo
    add rsp, 40
    ret
shutdown ENDP

main PROC
    sub rsp, 40
    call init
    call game_loop
    call shutdown
    xor ecx, ecx
    call ExitProcess
    add rsp, 40
    ret
main ENDP

END
