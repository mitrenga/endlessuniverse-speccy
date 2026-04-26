; ============================================================
; endless — animation, typewriter, and data
;
; Loaded silently at 0xC200 by LD_BYTES in stub.bin (image bytes
; reveal first into VRAM, then anim bytes land in RAM at the tail
; of the same tape block). The stub jumps to ANIM_START once the
; load completes successfully.
; ============================================================

    ORG     0xC200

; ============================================================
; ANIM_START — post-load setup, then TYPEWRITER + MAIN_ANIM
; ============================================================
ANIM_START:
    ; Hide rows 0..9 by setting attributes to 0x00 (INK=PAPER=BLACK)
    ; so the BASIC `PRINT` text and the pixel wipe are both invisible.
    LD      A, 0x00
    CALL    FILL_TOP_ATTR

    ; Wipe pixel block 0 (0x4000..0x47FF, char rows 0..7) — clears
    ; leftovers from the BASIC `PRINT` lines while preserving the
    ; freshly-loaded image in blocks 1 and 2.
    LD      HL, 0x4000
    LD      DE, 0x4001
    LD      BC, 0x07FF
    LD      (HL), 0
    LDIR

    ; Wipe char rows 8..9 (the empty band above the image). Their
    ; pixels live in block 1 interleaved with rows 10..15, so we
    ; can't LDIR-clear them in one shot. Each iteration clears 64 B
    ; at 0x4800 + x*0x100 (rows 8..9 share a single scanline slot).
    LD      HL, 0x4800
    LD      B, 8
GAP_CLEAR:
    PUSH    BC
    LD      D, H
    LD      E, L
    INC     DE
    LD      (HL), 0
    LD      BC, 0x3F
    LDIR
    POP     BC
    INC     H
    LD      L, 0
    DJNZ    GAP_CLEAR

    ; Restore attributes for rows 0..9 to 0x44 (BRIGHT|INK_GREEN,
    ; PAPER_BLACK). Pixels are now zero, so the area becomes black.
    LD      A, 0x44
    CALL    FILL_TOP_ATTR

    ; ATTR_T = 0x44 so RST 0x10 prints text in bright green on black
    LD      (0x5C8F), A

    CALL    TYPEWRITER      ; never returns: falls through to MAIN_ANIM

; ============================================================
; FILL_TOP_ATTR — fill rows 0..9 of the attribute area
; (0x5800..0x593F, 320 B) with the byte in A.
; ============================================================
FILL_TOP_ATTR:
    LD      HL, 0x5800
    LD      DE, 0x5801
    LD      (HL), A
    LD      BC, 0x13F
    LDIR
    RET

; ============================================================
; TYPEWRITER — print MSG character by character with a blinking
;              cursor and a short keyboard-style click per char.
; ============================================================
TYPEWRITER:
    LD      HL, MSG
TW_LOOP:
    LD      A, (HL)
    AND     A
    JR      Z, TW_END
    INC     HL
    CP      22
    JR      NZ, TW_CHAR

    LD      A, (HL)
    LD      (CURR_ROW), A
    INC     HL
    LD      A, (HL)
    LD      (CURR_COL), A
    INC     HL
    LD      A, 22
    RST     0x10
    LD      A, (CURR_ROW)
    RST     0x10
    LD      A, (CURR_COL)
    RST     0x10
    LD      B, 8
    CALL    WAIT_FRAMES
    JR      TW_LOOP

TW_CHAR:
    LD      (TW_CBUF), A
    LD      A, (0x5C78)
    AND     0x10
    LD      A, '_'
    JR      Z, TW_SHOW_CUR
    LD      A, ' '
TW_SHOW_CUR:
    CALL    AT_PRINT
    LD      B, 5
    CALL    WAIT_FRAMES
    LD      A, (TW_CBUF)
    CALL    AT_PRINT
    LD      A, (CURR_COL)
    INC     A
    LD      (CURR_COL), A
    CALL    CHAR_SOUND
    JR      TW_LOOP

TW_END:
    LD      A, 0xFF
    LD      (0x5C90), A

; ============================================================
; MAIN_ANIM — infinite frame loop:
;   1. Wait for the next 50 Hz frame
;   2. Toggle the cursor at (CURR_ROW, CURR_COL) when bit 4 of
;      FRAMES flips (~320 ms blink period)
;   3. Step or launch each of 6 meteors
;   4. Step or spawn each of 3 twinkling stars
; ============================================================
MAIN_ANIM:
    LD      A, (0x5C78)
MA_WAIT:
    LD      C, A
MA_WSAME:
    LD      A, (0x5C78)
    CP      C
    JR      Z, MA_WSAME

    AND     0x10
    LD      B, A
    LD      A, (PREV_CUR)
    CP      B
    LD      A, B
    LD      (PREV_CUR), A
    JR      Z, MA_NOCUR
    AND     A
    LD      A, '_'
    JR      NZ, MA_CURDRAW
    LD      A, ' '
MA_CURDRAW:
    CALL    AT_PRINT

MA_NOCUR:
    LD      IX, METEOR_ARRAY
    LD      B, 6
MA_MLOOP:
    PUSH    BC
    LD      A, (IX+0)
    AND     A
    JR      NZ, MA_ACTIVE
    LD      A, (IX+1)
    AND     A
    JR      Z, MA_LAUNCH
    DEC     A
    LD      (IX+1), A
    JR      MA_NEXT
MA_LAUNCH:
    CALL    INIT_METEOR
    JR      MA_NEXT
MA_ACTIVE:
    CALL    METEOR_STEP
MA_NEXT:
    POP     BC
    LD      DE, 11
    ADD     IX, DE
    DJNZ    MA_MLOOP

    LD      IX, STAR_ARRAY
    LD      B, 3
MA_SLOOP:
    PUSH    BC
    LD      A, (IX+0)
    AND     A
    JR      NZ, MA_S_ACTIVE

    LD      A, (IX+1)
    DEC     A
    LD      (IX+1), A
    JR      NZ, MA_S_NEXT

    CALL    FIND_STAR_POS
    LD      (IX+2), B
    LD      (IX+3), C
    LD      HL, STAR_SPRITES
    CALL    DRAW_SPRITE
    LD      (IX+0), 1
    LD      (IX+1), 3
    JR      MA_S_NEXT

MA_S_ACTIVE:
    LD      A, (IX+1)
    DEC     A
    LD      (IX+1), A
    JR      NZ, MA_S_NEXT

    LD      A, (IX+0)
    CP      7
    JR      Z, MA_S_LAST

    LD      E, A
    LD      D, 0
    LD      HL, STAR_SEQ
    ADD     HL, DE
    INC     A
    LD      (IX+0), A
    LD      A, (HL)
    ADD     A, A
    ADD     A, A
    ADD     A, A
    LD      L, A
    LD      H, 0
    LD      DE, STAR_SPRITES
    ADD     HL, DE
    CALL    DRAW_SPRITE
    LD      (IX+1), 3
    JR      MA_S_NEXT

MA_S_LAST:
    LD      HL, STAR_BLANK
    CALL    DRAW_SPRITE
    LD      (IX+0), 0
    CALL    RAND
    AND     0x3F
    ADD     A, 15
    LD      (IX+1), A

MA_S_NEXT:
    POP     BC
    LD      DE, 4
    ADD     IX, DE
    DJNZ    MA_SLOOP

    JP      MAIN_ANIM

; ============================================================
; DRAW_SPRITE — write an 8x8 sprite into a VRAM cell.
;   In : HL = sprite ptr, IX+2 = cy, IX+3 = col
; ============================================================
DRAW_SPRITE:
    EX      DE, HL

    LD      A, (IX+2)
    AND     0x18
    OR      0x40
    LD      H, A
    LD      A, (IX+2)
    AND     0x07
    RLCA
    RLCA
    RLCA
    RLCA
    RLCA
    LD      C, A
    LD      A, (IX+3)
    OR      C
    LD      L, A

    LD      B, 8
DS_LOOP:
    LD      A, (DE)
    LD      (HL), A
    INC     DE
    INC     H
    DJNZ    DS_LOOP
    RET

STAR_SPRITES:
    DEFB 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00
    DEFB 0x00, 0x00, 0x00, 0x10, 0x38, 0x10, 0x00, 0x00
    DEFB 0x00, 0x00, 0x10, 0x38, 0x7C, 0x38, 0x10, 0x00
    DEFB 0x00, 0x10, 0x10, 0x38, 0xFE, 0x38, 0x10, 0x10

STAR_SEQ:
    DEFB 0, 1, 2, 3, 2, 1, 0

STAR_BLANK:
    DEFB 0, 0, 0, 0, 0, 0, 0, 0

; ============================================================
; AT_PRINT — print A at (CURR_ROW, CURR_COL).
; ============================================================
AT_PRINT:
    PUSH    AF
    LD      A, 22
    RST     0x10
    LD      A, (CURR_ROW)
    RST     0x10
    LD      A, (CURR_COL)
    RST     0x10
    POP     AF
    RST     0x10
    RET

; ============================================================
; WAIT_FRAMES — busy-wait B 50 Hz frames (~20 ms each).
; ============================================================
WAIT_FRAMES:
    LD      A, (0x5C78)
WF_NEXT:
    LD      C, A
WF_SAME:
    LD      A, (0x5C78)
    CP      C
    JR      Z, WF_SAME
    DJNZ    WF_NEXT
    RET

; ============================================================
; CHAR_SOUND — short ~1 kHz click via the speaker bit on port 0xFE.
; ============================================================
CHAR_SOUND:
    LD      D, 0x00
    LD      B, 2
CS_LOOP:
    LD      A, D
    XOR     0x10
    LD      D, A
    OUT     (0xFE), A
    LD      E, 106
CS_DLY:
    DEC     E
    JR      NZ, CS_DLY
    DJNZ    CS_LOOP
    XOR     A
    OUT     (0xFE), A
    RET

; ============================================================
; INIT_METEOR — pick a random spawn edge and direction.
; ============================================================
INIT_METEOR:
    CALL    RAND
    CP      64
    JR      C, IM_TOP
    CP      128
    JR      C, IM_BOTTOM
    CP      192
    JR      C, IM_LEFT
IM_RIGHT:
    LD      (IX+2), 255
    CALL    RAND_Y
    LD      (IX+3), A
    LD      (IX+4), 0xFF
    JR      IM_DIR
IM_LEFT:
    LD      (IX+2), 0
    CALL    RAND_Y
    LD      (IX+3), A
    LD      (IX+4), 0x01
    JR      IM_DIR
IM_TOP:
    CALL    RAND
    LD      (IX+2), A
    LD      (IX+3), 0
    CALL    RAND
    AND     0x01
    JR      NZ, IM_TOP_L
    LD      (IX+4), 0x01
    JR      IM_DIR
IM_TOP_L:
    LD      (IX+4), 0xFF
    JR      IM_DIR
IM_BOTTOM:
    CALL    RAND
    LD      (IX+2), A
    LD      (IX+3), 79
    CALL    RAND
    AND     0x01
    JR      NZ, IM_BOT_L
    LD      (IX+4), 0x01
    JR      IM_DIR
IM_BOT_L:
    LD      (IX+4), 0xFF

IM_DIR:
IM_PICK:
    CALL    RAND
    AND     0x3F
    CP      55
    JR      NC, IM_PICK
    LD      HL, DIR_TABLE
    LD      E, A
    LD      D, 0
    ADD     HL, DE
    LD      A, (HL)
    LD      C, A

    AND     0x07
    INC     A
    LD      (IX+5), A
    LD      A, 1
    LD      (IX+6), A

    LD      A, C
    RRCA
    RRCA
    RRCA
    AND     0x07
    LD      (IX+8), A
    LD      A, 1
    LD      (IX+9), A

    LD      A, (IX+8)
    AND     A
    JR      Z, IM_DIRY_NONE
    LD      A, C
    AND     0x40
    JR      Z, IM_DIRY_DOWN
    LD      A, 0xFF
    JR      IM_DIRY_SET
IM_DIRY_DOWN:
    LD      A, 0x01
    JR      IM_DIRY_SET
IM_DIRY_NONE:
    XOR     A
IM_DIRY_SET:
    LD      (IX+7), A

    AND     A
    JR      Z, IM_LEN
    CP      0xFF
    JR      Z, IM_CHK_TOP
    LD      A, (IX+3)
    CP      79
    JR      NZ, IM_LEN
    LD      A, 0xFF
    LD      (IX+7), A
    JR      IM_LEN
IM_CHK_TOP:
    LD      A, (IX+3)
    AND     A
    JR      NZ, IM_LEN
    LD      A, 1
    LD      (IX+7), A

IM_LEN:
    CALL    RAND
    AND     0x3F
    ADD     A, 80
    LD      (IX+10), A
    LD      C, (IX+2)
    LD      B, (IX+3)
    CALL    PIXEL_XOR_SAFE
    LD      (IX+0), 1
    RET

; ============================================================
; METEOR_STEP — DDA-style movement of an active meteor.
; ============================================================
METEOR_STEP:
    LD      C, (IX+2)
    LD      B, (IX+3)
    CALL    PIXEL_XOR_SAFE

    LD      A, (IX+6)
    DEC     A
    LD      (IX+6), A
    JR      NZ, MS_X_DONE
    LD      A, (IX+5)
    LD      (IX+6), A
    LD      A, (IX+2)
    LD      B, A
    LD      A, (IX+4)
    ADD     A, B
    LD      (IX+2), A
MS_X_DONE:

    LD      A, (IX+8)
    AND     A
    JR      Z, MS_Y_DONE
    LD      A, (IX+9)
    DEC     A
    LD      (IX+9), A
    JR      NZ, MS_Y_DONE
    LD      A, (IX+8)
    LD      (IX+9), A
    LD      A, (IX+3)
    LD      B, A
    LD      A, (IX+7)
    ADD     A, B
    LD      (IX+3), A
MS_Y_DONE:

    LD      C, (IX+2)
    LD      B, (IX+3)
    CALL    PIXEL_XOR_SAFE

    LD      A, (IX+10)
    DEC     A
    LD      (IX+10), A
    RET     NZ

    LD      C, (IX+2)
    LD      B, (IX+3)
    CALL    PIXEL_XOR_SAFE
    LD      (IX+0), 0
    CALL    RAND
    AND     0x3F
    ADD     A, 15
    LD      (IX+1), A
    RET

; ============================================================
; PIXEL_XOR_SAFE — XOR a single pixel into VRAM (Y in 0..79).
; ============================================================
PIXEL_XOR_SAFE:
    LD      A, B
    CP      80
    RET     NC
PIXEL_XOR:
    LD      A, B
    AND     0xC0
    RRCA
    RRCA
    RRCA
    LD      H, A
    LD      A, B
    AND     0x07
    OR      H
    OR      0x40
    LD      H, A

    LD      A, B
    AND     0x38
    ADD     A, A
    ADD     A, A
    LD      L, A

    LD      A, C
    RRCA
    RRCA
    RRCA
    AND     0x1F
    OR      L
    LD      L, A

    LD      A, C
    AND     0x07
    LD      B, A
    LD      A, 0x80
    JR      Z, PX_DO
PX_SHR:
    RRCA
    DJNZ    PX_SHR
PX_DO:
    XOR     (HL)
    LD      (HL), A
    RET

; ============================================================
; RAND — return a pseudo-random byte in A.
; ============================================================
RAND:
    LD      A, R
    LD      HL, RND_SEED
    ADD     A, (HL)
    LD      (HL), A
    RET

; ============================================================
; RAND_Y — uniform random Y in 0..79 via rejection sampling.
; ============================================================
RAND_Y:
    CALL    RAND
    AND     0x7F
    CP      80
    JR      NC, RAND_Y
    RET

; ============================================================
; FIND_STAR_POS — pick a random cell in rows 10..14 (the "sky")
;   whose attribute is 0x47 (BRIGHT|INK_WHITE) — the star marker.
; ============================================================
FIND_STAR_POS:
FSP_LOOP:
    CALL    RAND
    AND     0x07
    CP      5
    JR      NC, FSP_LOOP
    ADD     A, 10
    LD      B, A
    CALL    RAND
    AND     0x1F
    LD      C, A
    LD      A, B
    AND     0x18
    RRCA
    RRCA
    RRCA
    OR      0x58
    LD      H, A
    LD      A, B
    AND     0x07
    RLCA
    RLCA
    RLCA
    RLCA
    RLCA
    OR      C
    LD      L, A
    LD      A, (HL)
    CP      0x47
    JR      NZ, FSP_LOOP
    RET

; ============================================================
; Data
; ============================================================

MSG:
    DEFB    22, 2, 2
    DEFM    "ENDLESS UNIVERSE"
    DEFB    22, 4, 2
    DEFM    "A NEW RETRO-STYLE GAME"
    DEFB    22, 6, 2
    DEFM    "YOU CAN FIND THE GAME AT"
    DEFB    22, 7, 2
    DEFM    "HTTPS://ENDLESSUNIVERSE.FREE"
    DEFB    0

CURR_ROW:   DEFB    0
CURR_COL:   DEFB    0
TW_CBUF:    DEFB    0
PREV_CUR:   DEFB    0
RND_SEED:   DEFB    0xA7

DIR_TABLE:
    DEFB 0x00,0x01,0x02,0x03,0x04
    DEFB 0x08,0x09,0x0A,0x0B,0x0C
    DEFB 0x10,0x11,0x12,0x13,0x14
    DEFB 0x18,0x19,0x1A,0x1B,0x1C
    DEFB 0x20,0x21,0x22,0x23,0x24
    DEFB 0x28,0x29,0x2A,0x2B,0x2C
    DEFB 0x48,0x49,0x4A,0x4B,0x4C
    DEFB 0x50,0x51,0x52,0x53,0x54
    DEFB 0x58,0x59,0x5A,0x5B,0x5C
    DEFB 0x60,0x61,0x62,0x63,0x64
    DEFB 0x68,0x69,0x6A,0x6B,0x6C

METEOR_ARRAY:
    DEFB 0,10, 0,0, 0,0,0, 0,0,0, 0
    DEFB 0,20, 0,0, 0,0,0, 0,0,0, 0
    DEFB 0,30, 0,0, 0,0,0, 0,0,0, 0
    DEFB 0,40, 0,0, 0,0,0, 0,0,0, 0
    DEFB 0,50, 0,0, 0,0,0, 0,0,0, 0
    DEFB 0,60, 0,0, 0,0,0, 0,0,0, 0

STAR_ARRAY:
    DEFB 0, 10, 0, 0
    DEFB 0, 30, 0, 0
    DEFB 0, 50, 0, 0

    END     ANIM_START
