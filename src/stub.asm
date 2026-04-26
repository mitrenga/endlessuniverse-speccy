; ============================================================
; endless — loader stub (loaded by BASIC at 0xC000)
;
; Memory layout:
;   0xC000..0xC1FF : this stub (≤512 B reserved)
;   0xC200..       : animation/typewriter code (loaded silently
;                    by LD_BYTES as the tail of the tape block,
;                    after the 14-strip image data has revealed)
;   0xC800..0xFE00 : runtime address table (built by GEN_TABLE)
;   Stack          : below RAMTOP=0xBFFF (BASIC `CLEAR 49151`)
;
; Boot flow:
;   1. BASIC POKEs this stub from REM line 0 into 0xC000
;   2. BASIC `RANDOMIZE USR 49152` → jumps to START
;   3. START builds the table, appends RAM destinations for the
;      animation tail, runs LD_BYTES, then either JP ANIM_ORG (on
;      successful load) or LOAD_FAILED (red border + HALT, on
;      checksum mismatch).
; ============================================================

    ORG     0xC000

; ANIM_ORG  = 0xC200  (where anim.bin lands; build.py keeps this in sync)
; TABLE     = 0xC800  (runtime address table built by GEN_TABLE)

; ============================================================
; START — entry point from BASIC's `RANDOMIZE USR 49152`
; ============================================================
START:
    DI

    ; Build the 6912 × 2 B bottom-up VRAM address table.
    LD      DE, 0xC800          ; TABLE
    CALL    GEN_TABLE

    ; Append RAM destinations (sequential addresses ANIM_ORG..)
    ; for the animation bytes that follow the image on tape.
    ; HL operand = TABLE + 2*image_size, BC operand = anim_size —
    ; both are patched by build.py.
    LD      HL, 0xC800          ; TABLE + 2*image_size, patched
    LD      DE, 0xC200          ; ANIM_ORG
    LD      BC, 0               ; anim_size, patched
APPEND_LOOP:
    LD      (HL), E
    INC     HL
    LD      (HL), D
    INC     HL
    INC     DE
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, APPEND_LOOP

    ; Run the ROM-style tape loader.
    ; DE operand = image_size + anim_size, patched by build.py.
    LD      IX, 0xC800          ; TABLE
    LD      DE, 0               ; total tape bytes, patched
    LD      A, 0xFF
    SCF
    CALL    LD_BYTES

    JR      NC, LOAD_FAILED     ; checksum failure

    EI
    JP      0xC200              ; ANIM_ORG

LOAD_FAILED:
    LD      A, 2                ; red border = checksum failure
    OUT     (0xFE), A
    HALT

; ============================================================
; LD_BYTES — copy of ZX Spectrum 48K ROM LD-BYTES (0x0556) with:
;   * the byte-store modified to route through the address table
;     at IX (2 B per entry, little-endian),
;   * the C-init mask flipped from 0x02 to 0x07 so the pilot-tone
;     border blinks white/black instead of red/cyan,
;   * a per-bit ADD 3 / AND 7 colour cycle written to the border
;     in LDB_8_BITS for the data-decode visual.
;
; Everything else (LD_EDGE_1 / LD_EDGE_2 timing, the 0xC6 / 0xCB /
; 0xD4 thresholds, checksum gate, flag handling) is byte-for-byte ROM.
;
; Entry:
;   AF' carries flag-byte info (set by `EX AF, AF'` below)
;   IX  = pointer to address table
;   DE  = number of data bytes (NOT counting flag/checksum)
;   CF  = 1 (load mode)
; Exit:
;   CF  = 1 success, 0 failure
; ============================================================
LD_BYTES:
    INC     D
    EX      AF, AF'             ; preserve flag info in AF'
    DEC     D

    LD      A, 0x0F              ; white border, MIC off
    OUT     (0xFE), A

    IN      A, (0xFE)
    RRA
    AND     0x20
    OR      0x07                 ; white border (CPL → black on every edge)
    LD      C, A                 ; initial polarity sample
    CP      A                    ; ZF=1
LDB_RET_ERR:
    RET     NZ                   ; not taken initially

LDB_LOOK_H:
    CALL    LD_EDGE_1
    JR      NC, LDB_LOOK_H
    LD      HL, 0x0415           ; ~1 ms settling delay
LDB_DLY:
    DJNZ    LDB_DLY
    DEC     HL
    LD      A, H
    OR      L
    JR      NZ, LDB_DLY
    CALL    LD_EDGE_2
    JR      NC, LDB_LOOK_H

LDB_LEADER:
    LD      B, 0x9C
    CALL    LD_EDGE_2
    JR      NC, LDB_LOOK_H
    LD      A, 0xC6
    CP      B
    JR      NC, LDB_LOOK_H
    INC     H
    JR      NZ, LDB_LEADER

LDB_SYNC:
    LD      B, 0xC9
    CALL    LD_EDGE_1
    JR      NC, LDB_LOOK_H       ; timeout → restart pilot search
    LD      A, B
    CP      0xD4
    JR      NC, LDB_SYNC
    CALL    LD_EDGE_1            ; sync2 edge (B carries from sync1)
    RET     NC

    LD      A, C
    XOR     0x03                 ; toggle MIC + border bits
    LD      C, A
    LD      H, 0x00              ; checksum init
    LD      B, 0xB0
    JR      LDB_MARKER

LDB_LOOP:
    EX      AF, AF'
    JR      NZ, LDB_FLAG         ; first byte = flag, don't store

    ; --- Modified store: route this byte through the address table ---
    PUSH    BC                   ; save B (counter), C (polarity)
    LD      C, (IX+0)            ; lo byte of destination from table
    LD      B, (IX+1)            ; hi byte of destination
    LD      A, L                 ; the just-decoded data byte
    LD      (BC), A              ; write to VRAM/RAM
    POP     BC
    INC     IX                   ; advance table pointer (2 B per entry)
    INC     IX
    DEC     DE
    JR      LDB_NEXT

LDB_FLAG:
    XOR     A                    ; A=0, ZF=1 (signals "flag byte handled")
LDB_NEXT:
    EX      AF, AF'              ; AF' now (0, ZF=1) for subsequent bytes
    LD      B, 0xB2
LDB_MARKER:
    LD      L, 1                 ; bit pattern sentinel
LDB_8_BITS:
    CALL    LD_EDGE_2
    RET     NC                   ; timeout in mid-load
    LD      A, 0xCB
    CP      B
    RL      L
    LD      B, 0xB0
    PUSH    AF                   ; save CF (= bit just shifted in)
    LD      A, (BORDER_VAL)      ; cycle border per bit on top of LD_EDGE_1's
    ADD     A, 3                 ; white/black flicker — gives the data
    AND     0x07                 ; phase a multi-colour shimmer
    LD      (BORDER_VAL), A
    OR      0x08                 ; preserve MIC bit during load
    OUT     (0xFE), A
    POP     AF
    JR      NC, LDB_8_BITS       ; loop until L's sentinel reaches CF
    LD      A, H
    XOR     L
    LD      H, A                 ; checksum update
    LD      A, D
    OR      E
    JR      NZ, LDB_LOOP         ; more bytes?
    LD      A, H
    CP      0x01                 ; H=0 → CF=1 (success)
    RET

; ============================================================
; LD_EDGE_2 / LD_EDGE_1 — verbatim copy of ZX Spectrum 48K ROM
; LD-EDGE-2 (0x05E3) and LD-EDGE-1 (0x05E7).
;
; LD_EDGE_1 finds one signal edge within timeout (B counter).
; LD_EDGE_2 finds two consecutive edges.
;
; Sample loop is 59 T-states per iter (matching ROM thresholds
; exactly) and includes a SPACE-key break check that returns NC
; if the user holds CAPS+SPACE during loading.
; ============================================================
LD_EDGE_2:
    CALL    LD_EDGE_1
    RET     NC

LD_EDGE_1:
    LD      A, 0x16              ; pre-delay constant
LDE_DELAY:
    DEC     A
    JR      NZ, LDE_DELAY
    AND     A                    ; clear CF

LDE_SAMPLE:
    INC     B
    RET     Z                    ; B overflowed → timeout (NC)
    LD      A, 0x7F              ; keyboard half-row B/N/M/Sym/Space
    IN      A, (0xFE)
    RRA                          ; bit 0 (SPACE) → CF
    RET     NC                   ; SPACE pressed → break (NC)
    XOR     C
    AND     0x20                 ; bit 5 = EAR after RRA
    JR      Z, LDE_SAMPLE
    LD      A, C
    CPL                          ; flip polarity
    LD      C, A
    AND     0x07                 ; isolate border colour bits
    OR      0x08                 ; OR with MIC bit (always set during load)
    OUT     (0xFE), A            ; flicker border + MIC
    SCF
    RET

; ============================================================
; GEN_TABLE — build the 6912 × 2 B address table at DE.
;   In : DE = destination
;   Out: DE advanced by 13824, table populated
;   Trashes: AF, BC, HL
; Order (first entry → 0x5AFF, last entry → 0x4000):
;   for strip S = 23 downto 0:
;     for x = 31 downto 0:                      attribute byte
;     for scan = 7 downto 0:
;       for x = 31 downto 0:                    pixel byte
; ============================================================
GEN_TABLE:
    LD      B, 24

GT_STRIP:
    LD      A, B
    DEC     A
    LD      C, A
    LD      (GT_STRIP_V), A

    AND     0x07
    RLCA
    RLCA
    RLCA
    RLCA
    RLCA
    OR      0x1F
    LD      L, A

    LD      A, C
    AND     0x18
    RRA
    RRA
    RRA
    OR      0x58
    LD      H, A

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

    LD      A, C
    AND     0x07
    RLCA
    RLCA
    RLCA
    RLCA
    RLCA
    OR      0x1F
    LD      (GT_LOBASE), A

    LD      C, 8

GT_SCAN:
    LD      A, (GT_LOBASE)
    LD      L, A

    LD      A, (GT_STRIP_V)
    AND     0x18
    ADD     A, C
    DEC     A
    OR      0x40
    LD      H, A

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
    JR      NZ, GT_SCAN

    DJNZ    GT_STRIP
    RET

; GEN_TABLE temporaries
GT_STRIP_V: DEFB    0
GT_LOBASE:  DEFB    0

; LDB_8_BITS per-bit border cycle state
BORDER_VAL: DEFB    0

    END     START
