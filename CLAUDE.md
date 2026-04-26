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
anim+data blob (loaded silently by the stub's custom SMLOADER as the
tail of the same tape block that delivers the image). The address
table `LOAD_BYTE` consults can route bytes anywhere — VRAM (image,
visible reveal) or RAM at `ANIM_ORG` (anim code, silent).

### Memory layout (above RAMTOP=0xBFFF, set by BASIC `CLEAR 49151`)
```
0xC000..0xC129   stub.bin     (298 B,  loaded by BASIC `LOAD "" CODE`)
0xC200..0xC686   anim.bin     (1159 B, ANIM_ORG; loaded via SMLOADER)
0xC800..0xFE00   TABLE        (13824 B, built at runtime by GEN_TABLE)
```
Sizes shown are current. Stub must stay ≤512 B (below 0xC200), anim
must stay ≤1536 B (below 0xC800). `build.py` asserts both bounds.

### BASIC bootstrap (`src/loader.bas`)
```
10 CLEAR 49151
20 BORDER 0: PAPER 0: INK 4: BRIGHT 1: CLS
22..28 PRINT AT … "ENDLESS UNIVERSE IS LOADING…"
29 FOR a=0 TO 12 STEP 2: BEEP .1,a: NEXT a
30 LOAD "" CODE
40 RANDOMIZE USR 49152
```
The PRINT lines are visible during the BASIC LOAD CODE phase and get
wiped (invisibly, via the attr-hide trick) by anim's startup code.

### Stub (`src/stub.asm`, ORG 0xC000)
Boot sequence inside `START`:
1. `DI`.
2. `GEN_TABLE` builds the 6912 × 2 B bottom-up VRAM address table at
   `TABLE` (0xC800).
3. Append loop overwrites table entries from offset `2*image_size`
   onwards with sequential RAM addresses (`ANIM_ORG`..`ANIM_ORG+anim_size-1`),
   so the bytes following the image on tape route into RAM rather than VRAM.
4. `SMLOADER` reads `image_size + anim_size` bytes from tape, routing
   each through the table.
5. `EI`, then `JP ANIM_ORG` (= 0xC200, the start of anim.bin).

`build.py` patches three operands inside the stub:
- `[0x08-0x09]` LD HL → `TABLE + 2*image_size`
- `[0x0E-0x0F]` LD BC → `anim_size`
- `[0x1F-0x20]` LD DE → `image_size + anim_size`

(z80asm has no `EQU`, so the stub uses literal `0xC200` / `0xC800`
where the constants would normally go.)

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

### Tape payload format
Only the bottom 14 strips (char rows 10..23) of the screen travel on
tape, reordered to match `GEN_TABLE`'s bottom-up sequence and with
trailing zeros trimmed (the wipe at `ANIM_START` blanks any remaining
zero bytes). After the trimmed image bytes, `anim.bin` is appended
verbatim — same tape data block, same checksum, same SMLOADER call.

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

`parse_basic_file` tokenizes ZX BASIC source to bytecode. It handles:
- Reserved words via `ZX_TOKENS` (longest-prefix match).
- Strings (verbatim ASCII).
- Integer literals → text + `0x0E` + 5-byte short-form value (`num`).
- Float literals like `.1` or `0.5` → text + `0x0E` + 5-byte FP form
  (`zx_float`, normalises mantissa to [0.5, 1) and biases exponent by 0x80).

## Testing

JSSpeccy 3: <https://jsspeccy.zxdemo.org/> — drop `build/endless.tzx`
on the window. For real hardware, play `build/endless.wav` into the
EAR input.

In emulators, **use tape loading mode** (the loader.bas hint says so):
the bottom-up reveal effect only happens when SMLOADER actually runs,
not when an emulator snapshot-loads CODE blocks instantly.

## Common problems

- `z80asm: command not found` → install via `brew install z80asm` or
  `apt install z80asm`.
- `ModuleNotFoundError: PIL` → `pip install Pillow`.
- Image not visible → confirm `src/screen.png` exists in `src/`.
- `stub.bin overflows ANIM_ORG` → stub grew past 512 B; either shrink
  the loader or move `ANIM_ORG` upward (and update `build.py`'s
  literal in `stub.asm`).
- `anim.bin overflows TABLE_ORG` → anim grew past 1536 B; shrink it
  or move `TABLE_ORG` upward (the runtime table needs 13824 B above
  `TABLE_ORG`, so don't push it past `0xCA00`).
- `LD HL/BC/DE offset shifted` assertion → the START code in
  `stub.asm` was edited and the patchable instructions moved;
  recompute the offsets and update the asserts in `build.py`.
- `Invalid colour` while text is typing → meteors must not run during
  TYPEWRITER. We attempted concurrent meteor + typewriter animation
  once and the BASIC error reliably appeared mid-text; the user
  identified meteor pixel writes as the trigger, so the layers are
  kept strictly sequential (typewriter first, meteor + star animation
  only after `TW_END`).
