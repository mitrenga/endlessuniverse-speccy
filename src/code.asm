; ============================================================
; endless — ZX Spectrum 48K tape loader with reveal-from-bottom effect
;
; Memory layout:
;   0xC000+        : this loader code + data
;   TABLE..+13824  : runtime address table (filled by GEN_TABLE)
;   Stack          : below RAMTOP=0xBFFF (set by BASIC `CLEAR 49151`)
;
; Boot flow:
;   1. BASIC  `LOAD "" CODE` loads us at 0xC000
;   2. BASIC  `RANDOMIZE USR 49152` jumps to START
;   3. START  pre-clears VRAM, builds the address table, runs SMLOADER
;             (which writes each tape byte to the address pulled from the
;             table, producing the bottom-up reveal effect)
;   4. After loading, fill in attributes for the top 10 char rows
;             (rows 0..9 — not present in the tape payload)
;   5. Run TYPEWRITER to print MSG with a blinking cursor and clicks
;   6. Fall through to MAIN_ANIM — meteors + twinkling stars forever
; ============================================================

    ORG     0xC000

; ============================================================
; START — entry point from BASIC's `RANDOMIZE USR 49152`
; ============================================================
START:
    DI

    ; Clear pixel area 0x4000..0x57FF (6144 bytes) to 0
    LD      HL, 0x4000
    LD      DE, 0x4001
    LD      BC, 0x17FF
    LD      (HL), 0
    LDIR

    ; Generate the 6912 x 2 B address table just past the code
    LD      DE, TABLE
    CALL    GEN_TABLE

    ; Run the modified ROM-style tape loader; each byte gets routed
    ; to the VRAM address pulled from TABLE (see LOAD_BYTE below).
    LD      IX, TABLE
    LD      DE, 6912        ; patched at build time to actual payload size
    LD      A, 0xFF
    SCF
    CALL    SMLOADER

    EI

    ; Fill attributes for the top 10 char rows (0x5800..0x593F)
    ; with 0x44 = BRIGHT | INK_GREEN, PAPER_BLACK.
    ;   Rows 0..7 : text overlay area
    ;   Rows 8..9 : empty band above the image (strips 8/9 are skipped
    ;               by the build, so their attr bytes never arrive)
    LD      HL, 0x5800
    LD      DE, 0x5801
    LD      BC, 0x13F
    LD      (HL), 0x44
    LDIR

    ; ATTR_T = 0x44 so RST 0x10 prints text in bright green on black
    LD      A, 0x44
    LD      (0x5C8F), A

    CALL    TYPEWRITER      ; never returns: falls through to MAIN_ANIM

; ============================================================
; TYPEWRITER — print MSG character by character with a blinking
;              cursor and a short keyboard-style click per char.
; AT control bytes (22, row, col) reposition the print head.
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

    ; AT sequence: read row and col from MSG, send AT via RST 0x10,
    ; then wait ~160 ms before printing the next line.
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
    LD      B, 8                ; ~160 ms gap between lines
    CALL    WAIT_FRAMES
    JR      TW_LOOP

TW_CHAR:
    ; Show cursor (or blank, ~320 ms blink driven by FRAMES bit 4)
    ; for ~100 ms, then print the actual character and advance.
    LD      (TW_CBUF), A
    LD      A, (0x5C78)         ; FRAMES low byte
    AND     0x10
    LD      A, '_'              ; cursor ON
    JR      Z, TW_SHOW_CUR
    LD      A, ' '              ; cursor OFF
TW_SHOW_CUR:
    CALL    AT_PRINT
    LD      B, 5                ; ~100 ms
    CALL    WAIT_FRAMES
    LD      A, (TW_CBUF)
    CALL    AT_PRINT            ; overwrite cursor with the actual char
    LD      A, (CURR_COL)
    INC     A
    LD      (CURR_COL), A
    CALL    CHAR_SOUND
    JR      TW_LOOP

TW_END:
    ; One-time init for MAIN_ANIM:
    ;   MASK_T = 0xFF means RST 0x10 keeps the existing cell attribute.
    ;   Cursor cells stay 0x44 (green); star cells stay 0x47 (bright white).
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

    ; Cursor blink: redraw only when bit 4 of FRAMES flipped
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
    ; --- Meteors: 6 x 11-byte structs ---
    LD      IX, METEOR_ARRAY
    LD      B, 6
MA_MLOOP:
    PUSH    BC
    LD      A, (IX+0)           ; STATE: 0=waiting, 1=active
    AND     A
    JR      NZ, MA_ACTIVE
    LD      A, (IX+1)           ; TIMER (waiting countdown)
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

    ; --- Stars: 3 x 4-byte structs {STATE, TIMER, ROW, COL} ---
    ; STATE 0   = waiting; TIMER counts down to next light-up
    ; STATE 1..7 = animation frame; sprite picked from STAR_SEQ[state-1]
    LD      IX, STAR_ARRAY
    LD      B, 3
MA_SLOOP:
    PUSH    BC
    LD      A, (IX+0)
    AND     A
    JR      NZ, MA_S_ACTIVE

    ; STATE 0 (waiting) — countdown TIMER
    LD      A, (IX+1)
    DEC     A
    LD      (IX+1), A
    JR      NZ, MA_S_NEXT

    ; TIMER expired: pick a position, draw sprite 0, enter state 1
    CALL    FIND_STAR_POS       ; B=row, C=col
    LD      (IX+2), B
    LD      (IX+3), C
    LD      HL, STAR_SPRITES    ; sprite 0 (STAR_SEQ[0] = 0)
    CALL    DRAW_SPRITE
    LD      (IX+0), 1
    LD      (IX+1), 3           ; 3 frames per anim step (~60 ms)
    JR      MA_S_NEXT

MA_S_ACTIVE:
    ; STATE 1..7 — countdown TIMER
    LD      A, (IX+1)
    DEC     A
    LD      (IX+1), A
    JR      NZ, MA_S_NEXT

    ; TIMER expired: state 7 ends the animation, otherwise advance.
    LD      A, (IX+0)
    CP      7
    JR      Z, MA_S_LAST

    ; State 1..6 -> advance and draw the next sprite from STAR_SEQ.
    ;   index into STAR_SEQ = current state (= new_state - 1).
    LD      E, A
    LD      D, 0
    LD      HL, STAR_SEQ
    ADD     HL, DE
    INC     A
    LD      (IX+0), A           ; new state 2..7
    LD      A, (HL)             ; sprite index 0..3
    ADD     A, A                ; *2
    ADD     A, A                ; *4
    ADD     A, A                ; *8 (bytes per sprite)
    LD      L, A
    LD      H, 0
    LD      DE, STAR_SPRITES
    ADD     HL, DE              ; HL = STAR_SPRITES + idx*8
    CALL    DRAW_SPRITE
    LD      (IX+1), 3
    JR      MA_S_NEXT

MA_S_LAST:
    ; State 7 expired: erase the cell, return to waiting with a
    ; random off-time of 15..78 frames (~300..1560 ms).
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
;   In : HL = pointer to 8 bytes of sprite data
;        IX+2 = char row (cy), IX+3 = char column (col)
;   Out: 8 pixel bytes written; cell attribute is left unchanged
;   Trashes: AF, BC, DE, HL  (IX preserved)
; Address math:
;   Hi (scan 0) = 0x40 | (cy & 0x18)
;   Lo          = ((cy & 7) << 5) | col
;   Each scan line is at +0x100, so INC H steps to the next scan.
; Works for cy = 0..23.
; ============================================================
DRAW_SPRITE:
    EX      DE, HL              ; DE = sprite ptr

    ; Compute HL = pixel address for (cy, col, scan 0)
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
    INC     H                   ; advance to the next scan line
    DJNZ    DS_LOOP
    RET

; Sprite data: 4 frames x 8 bytes
STAR_SPRITES:
    DEFB 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00  ; 0: single pixel
    DEFB 0x00, 0x00, 0x00, 0x10, 0x38, 0x10, 0x00, 0x00  ; 1: small cross
    DEFB 0x00, 0x00, 0x10, 0x38, 0x7C, 0x38, 0x10, 0x00  ; 2: medium cross
    DEFB 0x00, 0x10, 0x10, 0x38, 0xFE, 0x38, 0x10, 0x10  ; 3: large cross

; Animation sequence: forward then reverse (sprite index per state 1..7)
STAR_SEQ:
    DEFB 0, 1, 2, 3, 2, 1, 0

; All-zero sprite used to erase a cell at the end of the animation
STAR_BLANK:
    DEFB 0, 0, 0, 0, 0, 0, 0, 0

; ============================================================
; AT_PRINT — print the character in A at (CURR_ROW, CURR_COL).
;   CURR_COL is NOT advanced; the caller does that explicitly.
;   Goes through ROM RST 0x10, so the cell attribute follows
;   ATTR_T / MASK_T conventions of the print routine.
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
;   Trashes A, B, C.
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
;   Mimics the "key click" tone of the BASIC keyboard.
; ============================================================
CHAR_SOUND:
    LD      D, 0x00             ; speaker state
    LD      B, 2                ; 2 half-periods = one cycle
CS_LOOP:
    LD      A, D
    XOR     0x10                ; toggle speaker bit
    LD      D, A
    OUT     (0xFE), A
    LD      E, 106              ; delay sized for ~1 kHz
CS_DLY:
    DEC     E
    JR      NZ, CS_DLY
    DJNZ    CS_LOOP
    XOR     A
    OUT     (0xFE), A           ; silence speaker
    RET

; ============================================================
; Meteor struct: 11 bytes per meteor.
;   0=STATE 1=TIMER 2=X 3=Y
;   4=DIRX  5=PERX  6=CNTX
;   7=DIRY  8=PERY  9=CNTY
;  10=LEN
; STATE: 0=waiting (TIMER counts down), 1=active (LEN counts down)
; ============================================================

; ============================================================
; INIT_METEOR — pick a random spawn edge and direction.
;   In : IX = pointer to meteor struct
;   Out: meteor STATE = 1, fully initialised
; Spawn distribution (RAND byte split into 4 quadrants):
;   0..63   -> top    (Y=0,  random DIRX)
;   64..127 -> bottom (Y=79, random DIRX)
;   128..191-> left   (X=0,   random Y in 0..79, DIRX=+1)
;   192..255-> right  (X=255, random Y in 0..79, DIRX=-1)
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
    LD      (IX+4), 0xFF        ; DIRX = -1
    JR      IM_DIR
IM_LEFT:
    LD      (IX+2), 0
    CALL    RAND_Y
    LD      (IX+3), A
    LD      (IX+4), 0x01        ; DIRX = +1
    JR      IM_DIR
IM_TOP:
    CALL    RAND
    LD      (IX+2), A           ; X = random
    LD      (IX+3), 0           ; Y = 0
    CALL    RAND
    AND     0x01
    JR      NZ, IM_TOP_L
    LD      (IX+4), 0x01        ; DIRX = +1
    JR      IM_DIR
IM_TOP_L:
    LD      (IX+4), 0xFF        ; DIRX = -1
    JR      IM_DIR
IM_BOTTOM:
    CALL    RAND
    LD      (IX+2), A           ; X = random
    LD      (IX+3), 79          ; Y = 79 (bottom edge of the new 80px area)
    CALL    RAND
    AND     0x01
    JR      NZ, IM_BOT_L
    LD      (IX+4), 0x01        ; DIRX = +1
    JR      IM_DIR
IM_BOT_L:
    LD      (IX+4), 0xFF        ; DIRX = -1

IM_DIR:
    ; Pick a random direction byte from DIR_TABLE (55 entries)
IM_PICK:
    CALL    RAND
    AND     0x3F
    CP      55
    JR      NC, IM_PICK
    LD      HL, DIR_TABLE
    LD      E, A
    LD      D, 0
    ADD     HL, DE
    LD      A, (HL)             ; bit6=DIRY, bits5-3=PERY, bits2-0=PERX-1
    LD      C, A

    ; Decode PERX (bits 2-0) -> 1..5
    AND     0x07
    INC     A
    LD      (IX+5), A
    LD      A, 1
    LD      (IX+6), A           ; CNTX = 1

    ; Decode PERY (bits 5-3) -> 0..5
    LD      A, C
    RRCA
    RRCA
    RRCA
    AND     0x07
    LD      (IX+8), A
    LD      A, 1
    LD      (IX+9), A           ; CNTY = 1

    ; Decode DIRY: 0 if PERY==0, else +1 / -1 from bit 6
    LD      A, (IX+8)
    AND     A
    JR      Z, IM_DIRY_NONE
    LD      A, C
    AND     0x40
    JR      Z, IM_DIRY_DOWN
    LD      A, 0xFF             ; up
    JR      IM_DIRY_SET
IM_DIRY_DOWN:
    LD      A, 0x01             ; down
    JR      IM_DIRY_SET
IM_DIRY_NONE:
    XOR     A                   ; horizontal — no Y movement
IM_DIRY_SET:
    LD      (IX+7), A

    ; Edge correction:
    ;   Y=0  + DIRY=-1 (up)   -> flip DIRY to +1
    ;   Y=79 + DIRY=+1 (down) -> flip DIRY to -1
    AND     A
    JR      Z, IM_LEN           ; DIRY=0 (horizontal): nothing to fix
    CP      0xFF
    JR      Z, IM_CHK_TOP       ; DIRY=-1 -> check Y=0
    ; DIRY=+1 (down) -> check Y=79
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
    ; Pick lifetime LEN = 80..143 frames, draw initial pixel, mark active
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
;   In : IX = meteor struct (STATE must be 1)
;   Erases current pixel, advances X (every PERX frames) and
;   Y (every PERY frames), draws the new pixel. When LEN hits
;   zero, erases the final pixel and resets STATE = 0 (waiting)
;   with a random pause until the next launch.
; ============================================================
METEOR_STEP:
    LD      C, (IX+2)
    LD      B, (IX+3)
    CALL    PIXEL_XOR_SAFE      ; erase old position

    ; Advance X every PERX frames
    LD      A, (IX+6)           ; CNTX
    DEC     A
    LD      (IX+6), A
    JR      NZ, MS_X_DONE
    LD      A, (IX+5)           ; PERX
    LD      (IX+6), A           ; reset CNTX
    LD      A, (IX+2)
    LD      B, A
    LD      A, (IX+4)           ; DIRX
    ADD     A, B
    LD      (IX+2), A
MS_X_DONE:

    ; Advance Y every PERY frames (only when PERY != 0)
    LD      A, (IX+8)           ; PERY
    AND     A
    JR      Z, MS_Y_DONE
    LD      A, (IX+9)           ; CNTY
    DEC     A
    LD      (IX+9), A
    JR      NZ, MS_Y_DONE
    LD      A, (IX+8)
    LD      (IX+9), A           ; reset CNTY
    LD      A, (IX+3)
    LD      B, A
    LD      A, (IX+7)           ; DIRY
    ADD     A, B
    LD      (IX+3), A
MS_Y_DONE:

    LD      C, (IX+2)
    LD      B, (IX+3)
    CALL    PIXEL_XOR_SAFE      ; draw new position

    LD      A, (IX+10)          ; LEN
    DEC     A
    LD      (IX+10), A
    RET     NZ

    ; End of flight: erase final pixel, schedule next launch
    LD      C, (IX+2)
    LD      B, (IX+3)
    CALL    PIXEL_XOR_SAFE
    LD      (IX+0), 0           ; STATE = waiting
    CALL    RAND
    AND     0x3F
    ADD     A, 15
    LD      (IX+1), A           ; TIMER = 15..78 frames
    RET

; ============================================================
; PIXEL_XOR_SAFE — XOR a single pixel into VRAM.
;   In : B = Y (0..79 only — higher Y values silently no-op),
;        C = X (0..255)
;   Trashes: AF, B, H, L
; Address math:
;   Hi = 0x40 | ((Y & 0xC0) >> 3) | (Y & 7)
;   Lo = ((Y & 0x38) << 2) | (X >> 3)
;   bit mask = 0x80 >> (X & 7)
; ============================================================
PIXEL_XOR_SAFE:
    LD      A, B
    CP      80
    RET     NC
PIXEL_XOR:
    LD      A, B
    AND     0xC0                ; Y & 0xC0 (bank bits 7-6)
    RRCA
    RRCA
    RRCA                        ; >> 3 (carry=0 after AND, safe)
    LD      H, A
    LD      A, B
    AND     0x07
    OR      H
    OR      0x40
    LD      H, A                ; Hi = 0x40 | ((Y&0xC0)>>3) | (Y&7)

    LD      A, B
    AND     0x38
    ADD     A, A                ; (Y & 0x38) << 1
    ADD     A, A                ; (Y & 0x38) << 2
    LD      L, A

    LD      A, C
    RRCA
    RRCA
    RRCA
    AND     0x1F
    OR      L
    LD      L, A                ; Lo = ((Y & 0x38) << 2) | (X >> 3)

    LD      A, C
    AND     0x07                ; bit position 0..7, sets Z if 0
    LD      B, A
    LD      A, 0x80
    JR      Z, PX_DO            ; offset 0 -> mask = 0x80 directly
PX_SHR:
    RRCA
    DJNZ    PX_SHR
PX_DO:
    XOR     (HL)
    LD      (HL), A
    RET

; ============================================================
; RAND — return a pseudo-random byte in A.
;   Uses the refresh register R as the entropy source, mixed
;   with a running seed in RND_SEED. Cheap and reasonably
;   unpredictable for visual effects.
; ============================================================
RAND:
    LD      A, R
    LD      HL, RND_SEED
    ADD     A, (HL)
    LD      (HL), A
    RET

; ============================================================
; RAND_Y — uniform random Y in 0..79 via rejection sampling.
;   Used by meteor LEFT / RIGHT spawn.
; ============================================================
RAND_Y:
    CALL    RAND
    AND     0x7F                ; 0..127
    CP      80
    JR      NC, RAND_Y          ; retry if >= 80
    RET

; ============================================================
; FIND_STAR_POS — pick a random cell in rows 10..14 (the "sky")
;   whose attribute is 0x47 (BRIGHT|INK_WHITE) — the marker the
;   build script applies to empty cells in non-occupied columns.
;   Out: B = row (10..14), C = col (0..31)
;   Trashes: AF, DE, HL
; Rejection rate ~30..40% for the typical input image.
; ============================================================
FIND_STAR_POS:
FSP_LOOP:
    CALL    RAND
    AND     0x07                ; 0..7
    CP      5
    JR      NC, FSP_LOOP        ; retry if >= 5
    ADD     A, 10               ; row = 10..14
    LD      B, A
    CALL    RAND
    AND     0x1F                ; col = 0..31
    LD      C, A
    ; attr addr = 0x5800 + row*32 + col
    ;   Hi = 0x58 | ((row & 0x18) >> 3)
    ;   Lo = ((row & 7) << 5) | col
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
; SMLOADER — modified ROM-style tape loader.
;   Loads DE bytes from tape, but instead of writing them to a
;   contiguous range it pulls each destination address from the
;   address table at IX (2 bytes per entry, little-endian).
;   That gives the bottom-up reveal effect without any per-byte
;   address computation in the loader itself.
; ============================================================
SMLOADER:
    INC     D
    EX      AF, AF'
    DEC     D
    IN      A, (0xFE)
    AND     0x40
    LD      C, A
    CP      A
RET_ERR:
    RET     NZ
LOAD_START:
    CALL    DETECT_EDGE
    JR      NC, LOAD_START
    LD      HL, 0x0415
DLY:
    DJNZ    DLY
    DEC     HL
    LD      A, H
    OR      L
    JR      NZ, DLY
    CALL    DETECT_2E
    JR      NC, RET_ERR
LEAD_IN:
    LD      B, 0x9C
    CALL    DETECT_2E
    JR      NC, RET_ERR
    LD      A, 0xC6
    CP      B
    JR      NC, LOAD_START
    INC     H
    JR      NZ, LEAD_IN
SYNC1:
    LD      B, 0xC9
    CALL    DETECT_EDGE
    JR      NC, RET_ERR
    LD      A, B
    CP      0xD4
    JR      NC, SYNC1
SYNC2:
    CALL    DETECT_EDGE
    RET     NC
    LD      B, 0xB0
    JR      PREP8

LOAD_BYTE:
    EX      AF, AF'
    JR      NZ, TYPE_FLAG

    ; --- Modified store: route this byte through the address table ---
    PUSH    BC                  ; B=timer, C=EAR state (loader internals)
    LD      C, (IX+0)           ; lo byte of destination from table
    LD      B, (IX+1)           ; hi byte of destination
    LD      A, L                ; the just-decoded data byte
    LD      (BC), A             ; write to the VRAM address
    POP     BC
    INC     IX                  ; advance table pointer (2 B per entry)
    INC     IX

    DEC     DE
    JR      SETUP

TYPE_FLAG:
    XOR     A
SETUP:
    EX      AF, AF'
    LD      B, 0xB2
PREP8:
    LD      L, 1
BIT_LOOP:
    CALL    DETECT_2E
    RET     NC
    LD      A, 0xCB
    CP      B
    RL      L
    LD      B, 0xB0
    PUSH    AF
    LD      A, (BORDER_COLOR)
    ADD     A, 3
    AND     7
    OUT     (0xFE), A           ; cycle border colour while loading
    LD      (BORDER_COLOR), A
    POP     AF
    JR      NC, BIT_LOOP
    LD      A, H
    XOR     L
    LD      H, A
    LD      A, D
    OR      E
    JR      NZ, LOAD_BYTE
    LD      A, H
    CP      1
    RET

DETECT_2E:
    CALL    DETECT_EDGE
    RET     NC

DETECT_EDGE:
    LD      A, 24
EDG_DLY:
    DEC     A
    JR      NZ, EDG_DLY
    AND     A

SAMPLE:
    INC     B
    RET     Z
    NOP
    NOP
    IN      A, (0xFE)
    XOR     C
    AND     0x40
    JR      Z, SAMPLE

    ; Edge found — toggle border between black and white
    LD      A, C                ; C = previous EAR state
    AND     A                   ; test C == 0
    LD      A, 0x07             ; white (does not affect flags)
    JR      NZ, SET_BORDER      ; C != 0 -> white
    XOR     A                   ; C == 0 -> black (A = 0)
SET_BORDER:
    OUT     (0xFE), A

    LD      A, C
    CPL
    LD      C, A
    SCF
    RET

BORDER_COLOR:
    DEFB    0

; ============================================================
; GEN_TABLE — build the 6912 x 2 B address table at DE.
;   In : DE = destination
;   Out: DE advanced by 13824, table populated
;   Trashes: AF, BC, HL
; Order (first entry -> 0x5AFF, last entry -> 0x4000):
;   for strip S = 23 downto 0:
;     for x = 31 downto 0:                      attribute byte
;       addr = 0x5800 + S*32 + x
;     for scan = 7 downto 0:
;       for x = 31 downto 0:                    pixel byte
;         Hi = 0x40 | (S & 0x18) | scan
;         Lo = ((S & 7) << 5) | x
; ============================================================
GEN_TABLE:
    LD      B, 24                   ; outer counter; strip = B-1

GT_STRIP:
    LD      A, B
    DEC     A                       ; A = strip (23..0)
    LD      C, A                    ; save strip
    LD      (GT_STRIP_V), A

    ; --- 32 attribute entries (x = 31 downto 0) ---
    ; Lo = ((strip & 7) << 5) | 31 (then DEC HL each iteration)
    AND     0x07
    RLCA
    RLCA
    RLCA
    RLCA
    RLCA
    OR      0x1F
    LD      L, A

    ; Hi = 0x58 | ((strip & 0x18) >> 3)
    LD      A, C
    AND     0x18
    RRA                             ; carry=0 after AND, safe
    RRA
    RRA
    OR      0x58
    LD      H, A                    ; HL = attr addr for x=31

    PUSH    BC
    LD      B, 32
GT_ATTR_X:
    LD      A, L
    LD      (DE), A
    INC     DE
    LD      A, H
    LD      (DE), A
    INC     DE
    DEC     HL
    DJNZ    GT_ATTR_X
    POP     BC

    ; --- pixel entries: stash lo_base for the scan reset ---
    LD      A, C
    AND     0x07
    RLCA
    RLCA
    RLCA
    RLCA
    RLCA
    OR      0x1F
    LD      (GT_LOBASE), A

    LD      C, 8                    ; inner counter; scan = C-1

GT_SCAN:
    LD      A, (GT_LOBASE)
    LD      L, A

    ; Hi = 0x40 | (strip & 0x18) | (C-1)
    LD      A, (GT_STRIP_V)
    AND     0x18
    ADD     A, C
    DEC     A
    OR      0x40
    LD      H, A                    ; HL = pixel addr for scan=(C-1), x=31

    PUSH    BC
    LD      B, 32
GT_PIXEL_X:
    LD      A, L
    LD      (DE), A
    INC     DE
    LD      A, H
    LD      (DE), A
    INC     DE
    DEC     HL
    DJNZ    GT_PIXEL_X
    POP     BC

    DEC     C
    JR      NZ, GT_SCAN             ; scan 7..0

    DJNZ    GT_STRIP                ; strip 23..0
    RET

; ============================================================
; Data
; ============================================================

; --- Typewriter message ---
; AT(22) row col is interpreted by TYPEWRITER itself; everything
; else is sent verbatim through RST 0x10.
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

; --- Mutable state ---
CURR_ROW:   DEFB    0           ; current print row (used by AT_PRINT)
CURR_COL:   DEFB    0           ; current print column
TW_CBUF:    DEFB    0           ; TYPEWRITER char buffer across the wait
PREV_CUR:   DEFB    0           ; previous cursor blink state (FRAMES bit 4)
RND_SEED:   DEFB    0xA7        ; running seed mixed by RAND

; GEN_TABLE temporaries (kept here to avoid using IX/IY half-regs)
GT_STRIP_V: DEFB    0           ; current strip cached across attr -> pixel
GT_LOBASE:  DEFB    0           ; lo-base byte reused for each scan reset

; --- Meteor direction table (55 entries, 1 byte each) ---
; Format: bit6=DIRY (0=down,1=up); bits5..3=PERY (0=none, 1..5);
;         bits2..0=PERX-1 (0..4)
DIR_TABLE:
    DEFB 0x00,0x01,0x02,0x03,0x04   ; PERY=0 (horizontal), PERX=1..5
    DEFB 0x08,0x09,0x0A,0x0B,0x0C   ; PERY=1 down, PERX=1..5
    DEFB 0x10,0x11,0x12,0x13,0x14   ; PERY=2 down
    DEFB 0x18,0x19,0x1A,0x1B,0x1C   ; PERY=3 down
    DEFB 0x20,0x21,0x22,0x23,0x24   ; PERY=4 down
    DEFB 0x28,0x29,0x2A,0x2B,0x2C   ; PERY=5 down
    DEFB 0x48,0x49,0x4A,0x4B,0x4C   ; PERY=1 up,   PERX=1..5
    DEFB 0x50,0x51,0x52,0x53,0x54   ; PERY=2 up
    DEFB 0x58,0x59,0x5A,0x5B,0x5C   ; PERY=3 up
    DEFB 0x60,0x61,0x62,0x63,0x64   ; PERY=4 up
    DEFB 0x68,0x69,0x6A,0x6B,0x6C   ; PERY=5 up

; --- Meteor array: 6 x 11 bytes ---
; Initial TIMER stagger (10..60) so meteors launch at different times.
METEOR_ARRAY:
    DEFB 0,10, 0,0, 0,0,0, 0,0,0, 0
    DEFB 0,20, 0,0, 0,0,0, 0,0,0, 0
    DEFB 0,30, 0,0, 0,0,0, 0,0,0, 0
    DEFB 0,40, 0,0, 0,0,0, 0,0,0, 0
    DEFB 0,50, 0,0, 0,0,0, 0,0,0, 0
    DEFB 0,60, 0,0, 0,0,0, 0,0,0, 0

; --- Star array: 3 x 4 bytes {STATE, TIMER, ROW, COL} ---
; Initial TIMER stagger 10/30/50 spreads the first light-ups in time.
STAR_ARRAY:
    DEFB 0, 10, 0, 0
    DEFB 0, 30, 0, 0
    DEFB 0, 50, 0, 0

; ============================================================
; TABLE — runtime-built address table (13824 B), filled by
;         GEN_TABLE. Lives just past the code; consumed by
;         SMLOADER's modified LOAD_BYTE.
; ============================================================
TABLE:

    END     START
