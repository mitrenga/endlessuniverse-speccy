; ============================================================
; endless — loader stub (loaded by BASIC at 0xC000)
;
; Memory layout:
;   0xC000..0xC1FF : this stub (≤512 B reserved)
;   0xC200..       : animation/typewriter code (loaded silently
;                    by SMLOADER as the tail of the tape block,
;                    after the 14-strip image data has revealed)
;   0xC800..0xFE00 : runtime address table (built by GEN_TABLE)
;   Stack          : below RAMTOP=0xBFFF (BASIC `CLEAR 49151`)
;
; Boot flow:
;   1. BASIC `LOAD "" CODE`        → loads this stub at 0xC000
;   2. BASIC `RANDOMIZE USR 49152` → jumps to START
;   3. START builds the table, appends RAM destinations for the
;      animation tail, runs SMLOADER, then JP ANIM_ORG.
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
    ; HL operand = TABLE + 2*image_size (offset into table where
    ; the image entries end), BC operand = anim_size — both are
    ; patched by build.py.
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

    ; Run the modified ROM-style tape loader.
    ; DE operand = image_size + anim_size, patched by build.py.
    LD      IX, 0xC800          ; TABLE
    LD      DE, 0               ; total tape bytes, patched
    LD      A, 0xFF
    SCF
    CALL    SMLOADER

    EI

    JP      0xC200              ; ANIM_ORG

; ============================================================
; SMLOADER — modified ROM-style tape loader.
;   Loads DE bytes from tape, but instead of writing them to a
;   contiguous range it pulls each destination address from the
;   address table at IX (2 bytes per entry, little-endian).
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
    LD      C, (IX+0)
    LD      B, (IX+1)
    LD      A, L
    LD      (BC), A
    POP     BC
    INC     IX
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
    OUT     (0xFE), A
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

    LD      A, C
    AND     A
    LD      A, 0x07
    JR      NZ, SET_BORDER
    XOR     A
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

; GEN_TABLE temporaries (kept here so the whole stub is self-contained)
GT_STRIP_V: DEFB    0
GT_LOBASE:  DEFB    0

    END     START
