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

Auto-build expectation: every change in `src/code.asm`,
`src/loader.bas` or `build.py` should be followed by `python3 build.py`
and a one-line size report (loader / payload / TZX).

## Key files

- `src/code.asm`     — Z80 assembler source
- `src/loader.bas`   — BASIC bootstrap
- `build.py`         — TZX + WAV builder
- `build/endless.tzx` — emulator output
- `build/endless.wav` — physical Spectrum output

## Dependencies

- `z80asm` (Bas Wijnen's Z80 cross-assembler)
- Python 3 + Pillow + NumPy

## Loader architecture

### BASIC bootstrap (`src/loader.bas`)
```
10 CLEAR 49151
20 BORDER 0: PAPER 0: INK 0: CLS
30 LOAD "" CODE       → loader at 0xC000
40 RANDOMIZE USR 49152
```

### Loader (`src/code.asm`, ORG 0xC000)
Boot sequence inside `START`:
1. `DI` and pre-clear pixel area `0x4000..0x57FF`.
2. `GEN_TABLE` builds the 6912 × 2 B address table at `TABLE`
   (just past the code, ~13.5 kB, never transmitted on tape).
3. `SMLOADER` loads the screen payload. The custom `LOAD_BYTE` pulls
   the destination address from the table at `IX`, so each byte lands
   at its final VRAM address — the bottom-up reveal is a side effect
   of the table's order.
4. Fill attributes for rows 0..9 with `0x44` (BRIGHT | INK_GREEN).
5. `TYPEWRITER` prints `MSG` with a blinking `_` cursor and a click.
6. Falls into `MAIN_ANIM`: per-frame cursor blink + meteor step
   (6 meteors) + star step (3 twinkling stars).

### Tape payload format
Only the bottom 14 strips (char rows 10..23) of the screen travel on
tape. Strips 0..7 (text area) plus strips 8..9 (empty band) are not
transmitted; the loader fills their attributes at run time. The
remaining 14 × 288 = 4032 bytes are reordered to match `GEN_TABLE`,
then trailing zeros are trimmed.

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

## Testing

JSSpeccy 3: <https://jsspeccy.zxdemo.org/> — drop `build/endless.tzx`
on the window. For real hardware, play `build/endless.wav` into the
EAR input.

## Common problems

- `z80asm: command not found` → install via `brew install z80asm` or
  `apt install z80asm`.
- `ModuleNotFoundError: PIL` → `pip install Pillow`.
- Image not visible → confirm `src/screen.png` exists in `src/`.
- `Invalid colour` while text is typing → meteors must not run during
  TYPEWRITER. We attempted concurrent meteor + typewriter animation
  once and the BASIC error reliably appeared mid-text; the user
  identified meteor pixel writes as the trigger, so the layers are
  kept strictly sequential (typewriter first, meteor + star animation
  only after `TW_END`).
