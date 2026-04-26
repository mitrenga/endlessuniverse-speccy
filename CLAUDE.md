# CLAUDE.md — endless intro (ZX Spectrum 48K)

## Project
Title-screen intro for the upcoming retro-style game ENDLESS UNIVERSE,
built around a custom tape loader that reveals the image bottom-up
during loading. After load: typewriter overlay, then an infinite scene
with meteors arriving from all four edges and twinkling stars in the
sky. Build outputs both `.tzx` (emulator) and `.wav` (real hardware
via the EAR input).

## Build

```bash
python3 build.py
python3 build.py --image src/screen.png --output build/endless.tzx
```

Auto-build expectation: every change in `src/stub.asm`, `src/anim.asm`,
`src/loader.bas` or `build.py` should be followed by `python3 build.py`
and a one-line size report (stub / anim / payload / TZX).

## Key files

- `src/stub.asm`      — tape loader (Z80, ORG 0xC000, ≤512 B)
- `src/anim.asm`      — typewriter + meteor/star + data (Z80, ORG 0xC200)
- `src/loader.bas`    — BASIC bootstrap
- `build.py`          — TZX + WAV builder, patches stub placeholders
- `build/endless.tzx` — emulator output
- `build/endless.wav` — physical Spectrum output

## Dependencies

- `z80asm` (Bas Wijnen's Z80 cross-assembler — note: no `EQU` support,
  use literal addresses instead)
- Python 3 + Pillow + NumPy

## Architecture (two-stage loader)

The intro is split into a tiny stub (loaded by BASIC) and a larger
anim+data blob (loaded silently by the stub's `LD_BYTES` as the tail
of the same tape block that delivers the image). `LD_BYTES` is a
verbatim copy of ZX 48K ROM `LD-BYTES` (0x0556) with one modification:
the byte-store inside the inner loop is replaced by a lookup through
a runtime address table. That table can route each byte anywhere —
VRAM (image, visible reveal) or RAM at `ANIM_ORG` (anim code, silent).

### Memory layout (above RAMTOP=0xBFFF, set by BASIC `CLEAR 49151`)
```
0xC000..0xC13E   stub.bin     (319 B,  POKEd from REM body by BASIC)
0xC200..0xC686   anim.bin     (1159 B, ANIM_ORG; loaded via LD_BYTES)
0xC800..0xFE00   TABLE        (13824 B, built at runtime by GEN_TABLE)
```
Sizes shown are current. Stub must stay ≤512 B (below 0xC200), anim
must stay ≤1536 B (below 0xC800). `build.py` asserts both bounds.

### BASIC bootstrap (`src/loader.bas` + build-time injections)
The author-edited source has only the visible parts (PRINT/BEEP);
`build.py` prepends a REM line containing the stub bytes verbatim
and appends the POKE+USR lines. The full tokenised program is:
```
0   REM <319 raw stub bytes>            ← prepended by build.py
10  CLEAR 49151
20  BORDER 0: PAPER 0: INK 4: BRIGHT 1: CLS
30..60  PRINT AT … "ENDLESS UNIVERSE IS LOADING…"
70  INK 0
80  FOR a=0 TO 12 STEP 2: BEEP .1,a: NEXT a
90  LET s=PEEK 23635+256*PEEK 23636+5    ← appended by build.py
95  FOR i=0 TO <stub_size-1>: POKE 49152+i,PEEK (s+i): NEXT i
100 RANDOMIZE USR 49152
```
The PRINT lines are visible during BASIC LOAD and the POKE phase;
they get wiped (invisibly, via the attr-hide trick) by anim startup.

`PEEK 23635 + 256*PEEK 23636` reads system variable `PROG` (start
of BASIC program in memory); `+5` skips the line 0 header
(2 B line# + 2 B length + 1 B REM token), pointing at the first stub
byte. The POKE loop copies the stub into 0xC000 (~3 s of BASIC
execution time), then `RANDOMIZE USR 49152` jumps to it.

### REM-on-line-0 trick
The stub bytes embedded in the REM contain control codes
(0x10/0x16/…) that crash `LIST` because ROM streams the body through
the PRINT routine. Putting the REM at line 0 hides it from `LIST`
without args (which starts at line 1). `LIST 0` would still error;
this is the same compromise commercial 80s tape loaders accepted.

### Stub (`src/stub.asm`, ORG 0xC000)
Boot sequence inside `START`:
1. `DI`.
2. `GEN_TABLE` builds the 6912 × 2 B bottom-up VRAM address table at
   `TABLE` (0xC800).
3. Append loop overwrites table entries from offset `2*image_size`
   onwards with sequential RAM addresses (`ANIM_ORG`..`ANIM_ORG+anim_size-1`),
   so the bytes following the image on tape route into RAM rather than VRAM.
4. `LD_BYTES` reads `image_size + anim_size` bytes from tape, routing
   each through the table.
5. On checksum mismatch (`CF = 0` after `LD_BYTES`), jump to
   `LOAD_FAILED` — set border to red, `HALT` (signals load failure
   without crashing into garbage anim code).
6. Otherwise `EI`, then `JP ANIM_ORG` (= 0xC200, start of anim.bin).

`build.py` patches three operands inside the stub:
- `[0x08-0x09]` LD HL → `TABLE + 2*image_size`
- `[0x0E-0x0F]` LD BC → `anim_size`
- `[0x1F-0x20]` LD DE → `image_size + anim_size`

(z80asm has no `EQU`, so the stub uses literal `0xC200` / `0xC800`
where the constants would normally go.)

### `LD_BYTES` (`src/stub.asm`)
Verbatim copy of the ZX 48K ROM `LD-BYTES` routine (0x0556) with
labels prefixed `LDB_…` / `LDE_…` to avoid collision. We can't just
`CALL 0x0556` because ROM `LD-BYTES` writes each byte to a contiguous
range starting at `IX`, but we need each byte routed via the table.
The only modification is in `LDB_LOOP`: instead of
`LD (IX+0), L; INC IX`, we read the destination address from
`(IX+0)` / `(IX+1)`, write the byte there, and advance `IX` by 2.

Everything else — pilot detection (`LDB_LEADER`), sync (`LDB_SYNC`),
bit-by-bit decode (`LDB_8_BITS`), checksum check (`H == 0` at end) —
is byte-for-byte ROM. `LD_EDGE_1` / `LD_EDGE_2` (0x05E7 / 0x05E3 in
ROM) are also verbatim, including the 358T pre-delay, the 59T
sample-loop iter, the SPACE-key break check, and the bit-5 EAR
detection (`AND $20` after `RRA`). Matching ROM exactly means our
thresholds (`0xC6`, `0xCB`, `0xD4`) sit in the same calibrated window
as the original loader, so any signal that ROM tolerates we tolerate.

Two cosmetic deviations from ROM:
- `LD_BYTES` initialises C with `OR 0x07` (instead of ROM's `OR 0x02`).
  That makes the bottom-3 colour bits flip between 7 and 0 across
  successive `CPL`s in `LD_EDGE_1`, so the pilot-tone border blinks
  white ↔ black instead of red ↔ cyan.
- `LDB_8_BITS` does an extra `OUT (0xFE), A` once per decoded bit,
  cycling a `BORDER_VAL` byte through the standard `ADD A, 3 ; AND 7`
  sequence (also OR'd with the MIC bit). On top of `LD_EDGE_1`'s
  per-edge white/black flicker that makes the data phase shimmer
  through all 8 colours instead of staying just black/white. The
  per-bit overhead (~80 T-states) is well within the bit-decode
  threshold margin.

The first byte received is the standard ROM flag byte (0xFF for a
data block); `LDB_FLAG` consumes it without storing. The last byte
received is the parity byte; after `LDB_LOOP` decrements `DE` to zero
the routine reads one more byte purely to roll it into `H` for the
final `CP $01` checksum gate. `H` is initialised to `0` explicitly
right before `LDB_MARKER`, so the result doesn't depend on whatever
junk `H` carried in from the caller.

### Anim (`src/anim.asm`, ORG 0xC200)
Entry point `ANIM_START`:
1. Hide rows 0..9 by setting attributes to `0x00` (INK=PAPER=BLACK).
2. Wipe pixel block 0 (`0x4000..0x47FF`, char rows 0..7) — clears the
   BASIC `PRINT` overlay invisibly.
3. Wipe rows 8..9 (the empty band above the image) via an 8-iteration
   LDIR loop — those scanlines are interleaved with rows 10..15 in
   block 1 and can't be cleared in one shot.
4. Restore attributes for rows 0..9 to `0x44` (BRIGHT|INK_GREEN, PAPER_BLACK).
5. Set ATTR_T to `0x44` so RST 0x10 prints in bright green on black.
6. `TYPEWRITER` prints `MSG` with a blinking `_` cursor and a click.
7. Falls into `MAIN_ANIM`: per-frame cursor blink + meteor step
   (6 meteors) + star step (3 twinkling stars).

### Tape structure (TZX blocks)
1. **BASIC header** (0x10, ~5 s pilot)
2. **BASIC data** (0x10, ~2 s pilot, then ~720 B incl. embedded stub),
   **2 s pause** after.
3. **Pure tone** (0x12, 8064 pulses × 2168 T-states = ~5 s extra pilot
   merged into the next block's pilot — this is the "BASIC POKE budget".
   The total pilot `LD_BYTES` sees before sync is ~7 s).
4. **Custom data block** (0x10, image+anim payload, ~2 s pilot + data),
   read by stub's `LD_BYTES`, **not** by ROM LOAD.

### Image+anim payload format
Only the bottom 14 strips (char rows 10..23) of the screen travel on
tape, reordered to match `GEN_TABLE`'s bottom-up sequence and with
trailing zeros trimmed (the wipe at `ANIM_START` blanks any remaining
zero bytes). After the trimmed image bytes, `anim.bin` is appended
verbatim — same tape data block, same checksum, same `LD_BYTES` call.

### Animation layers
- **Cursor** (`_`) blinks at `(CURR_ROW, CURR_COL)`, driven by FRAMES bit 4.
- **Meteors** (6 structs of 11 B) spawn from any of 4 edges via
  `INIT_METEOR`, move via DDA in `METEOR_STEP`, and `XOR` a single
  pixel into VRAM rows Y=0..79 (top 10 character rows).
- **Stars** (3 structs of 4 B) live in the "sky" rows 10..14; each
  cycles through 4 sprites (`STAR_SPRITES`) in the sequence
  `0,1,2,3,2,1,0`, drawing 8 pixel bytes per sprite via `DRAW_SPRITE`.

### Star marker (built by `build.py`)
Empty cells in rows 10..14 inside columns that have no lit pixel in
the same row range receive attribute `0x47` (BRIGHT|INK_WHITE).
`FIND_STAR_POS` rejection-samples on this exact value, so stars
never spawn on top of image content.

### ZX VRAM (recap)
- Pixels: `0x4000..0x57FF` (6144 B, scrambled)
- Attrs:  `0x5800..0x5AFF` (768 B, linear)
- Pixel addr: `0x4000 | (y & 0xC0) << 5 | (y & 7) << 8 | (y & 0x38) << 2 | x_byte`

## BASIC tokenizer notes (`build.py`)

`parse_basic_text` tokenizes ZX BASIC source to bytecode (and
`parse_basic_file` is a thin wrapper that reads from disk first).
It handles:
- Reserved words via `ZX_TOKENS` (longest-prefix match).
- Strings (verbatim ASCII).
- Integer literals → text + `0x0E` + 5-byte short-form value (`num`).
- Float literals like `.1` or `0.5` → text + `0x0E` + 5-byte FP form
  (`zx_float`, normalises mantissa to [0.5, 1) and biases exponent by 0x80).

`basic_rem_line(line_num, raw)` builds a tokenised REM line whose body
is `raw` bytes verbatim; `build.py` calls it with `line_num=0` and the
patched stub.

## TZX builder notes (`build.py`)

- `tzx_std(data, pause_ms)` → block 0x10 (standard speed).
- `tzx_pure_tone(pulse_len_T, count)` → block 0x12 (just N equal-length
  pulses, no pause after — used to extend the pilot of the next block).
- `tzx_to_wav` understands both 0x10 and 0x12 blocks.

## Testing

- **JSSpeccy 3** (<https://jsspeccy.zxdemo.org/>) — drop `endless.tzx`
  on the window. Easiest path, works out of the box.
- **Fuse** — drop `endless.tzx`. **Must** turn off all three loader
  shortcuts in *Options → Peripherals*: "Fast tape loading",
  "Accelerate tape loaders", "Detect tape loaders". With any of them
  on, Fuse's pattern-matcher misidentifies our in-RAM ROM-style loader
  as a known speed loader and feeds bytes faster than the pilot tone
  ends, so the custom block starts being read mid-pilot.
- **Real hardware** — play `endless.wav` into the EAR input,
  volume ~50–75 %, then `LOAD ""`. Fuse's WAV mode is finicky and
  not a primary target; use TZX in Fuse instead.

In emulators, **use tape loading mode** (the loader.bas hint says so):
the bottom-up reveal effect only happens when `LD_BYTES` actually runs,
not when an emulator snapshot-loads CODE blocks instantly.

If the tape goes through but the screen ends up showing only a solid
**red border + halt**, that's the `LOAD_FAILED` indicator — `LD_BYTES`
returned `CF = 0` (checksum mismatch). Most likely cause: an emulator
shortcut as above, or noisy real-HW signal.

## Common problems

- `z80asm: command not found` → install via `brew install z80asm` or
  `apt install z80asm`.
- `ModuleNotFoundError: PIL` → `pip install Pillow`.
- Image not visible → confirm `src/screen.png` exists in `src/`.
- `stub.bin overflows ANIM_ORG` → stub grew past 512 B. Either shrink
  the loader or raise `ANIM_ORG`. The constant lives in **two** places
  that must agree: the Python constant in `build.py` and the hardcoded
  `0xC200` literal(s) in `stub.asm` (the `LD DE, 0xC200` and
  `JP 0xC200` instructions). Bump both.
- `anim.bin overflows TABLE_ORG` → anim grew past 1536 B. Same dual-source
  fix as above for `TABLE_ORG` (the `LD DE, 0xC800` / `LD HL, 0xC800` /
  `LD IX, 0xC800` literals in `stub.asm` plus the Python constant in
  `build.py`). The runtime table needs 13824 B above `TABLE_ORG`, so
  don't push it past `0xCA00`.
- `LD HL/BC/DE offset shifted` assertion → the START code in
  `stub.asm` was edited and the patchable instructions moved;
  recompute the offsets and update the asserts in `build.py`.
- `Invalid colour` while text is typing → meteors must not run during
  TYPEWRITER. We attempted concurrent meteor + typewriter animation
  once and the BASIC error reliably appeared mid-text; the user
  identified meteor pixel writes as the trigger, so the layers are
  kept strictly sequential (typewriter first, meteor + star animation
  only after `TW_END`).
- Solid red border + halt after the tape stops → `LD_BYTES` returned
  `CF = 0`, the parity byte didn't match (= corrupted load). On Fuse,
  flip off "Fast tape loading" / "Accelerate tape loaders" / "Detect
  tape loaders". On real HW, check tape volume / cable noise.
- `R Tape loading error` mid-load (no red border, returns to BASIC) →
  the *ROM* loader (i.e. the BASIC block, not our custom loader) gave
  up. Same emulator-shortcut / signal-quality story applies, just one
  block earlier on the tape.
