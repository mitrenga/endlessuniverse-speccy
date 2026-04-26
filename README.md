# endless — intro for ENDLESS UNIVERSE (ZX Spectrum 48K)

A title-screen intro for the upcoming retro-style game **ENDLESS UNIVERSE**.
To make the loading itself part of the show, the intro uses a custom
tape loader specially modified so the picture reveals itself character
row by character row from the bottom up — instead of the scrambled
three-band fill of the ROM's standard loader (which writes VRAM in
linear address order and so paints the screen in interleaved scans).

Once the image is fully on screen, a typewriter prints a short
in-universe blurb in the top band, and the scene then runs
indefinitely with shooting stars (meteors) arriving from all four
edges and twinkling background stars filling the sky band above
the foreground.

The build produces both a `.tzx` (for emulators) and a `.wav` (for
loading on real hardware through the EAR input).

## What it does

- The custom loader writes each received byte to an address pulled
  from a runtime-generated table, producing the bottom-up reveal
  effect without per-byte address arithmetic in the loader itself.
- The top 10 character rows (text overlay + empty band above the
  image) are not transmitted at all — their attributes are filled in
  by the loader after the tape data finishes.
- Empty character cells in the "sky" region (rows 10..14) inside
  columns that are clear of image content are flagged with a special
  attribute (BRIGHT|INK_WHITE) so the runtime can spawn twinkling
  stars there without overlapping the foreground.
- During load the border cycles colours; afterwards the typewriter
  prints the title text with a key-click, and the meteor + star
  animations run indefinitely until the player loads the actual game.

## Dependencies

### Python
- Python 3.8+
- Pillow (`pip install Pillow`)
- NumPy (`pip install numpy`)

### Assembler
You need **z80asm** in your `PATH`:

```bash
# macOS
brew install z80asm

# Debian / Ubuntu
sudo apt install z80asm
```

### Emulator (for testing)
- [JSSpeccy 3](https://jsspeccy.zxdemo.org/) — runs in the browser, easiest
- [Fuse](https://fuse-emulator.sourceforge.net/) — desktop, macOS / Linux
- ZEsarUX, ZXSpin, etc.

## Build

```bash
# Default — uses src/screen.png, writes build/endless.tzx + .wav
python build.py

# Custom input image
python build.py --image /path/to/image.png

# Custom output path (the .wav is written alongside, with .wav extension)
python build.py --output /path/to/endless.tzx
```

The build prints the size of every stage:
```
[1] Assembling stub + anim...
[2] Converting image...
[3] Tokenising BASIC...
[4] Building TZX...
[5] Generating WAV for physical Spectrum...
```

## Using the result

### Emulator (`endless.tzx`)
1. Drop `build/endless.tzx` onto the emulator window.
2. Press PLAY on the virtual tape.
3. In BASIC type `LOAD ""`.

### Real hardware (`endless.wav`)
1. Connect your PC / phone audio output to the Spectrum's EAR input.
2. Set the player volume to roughly 50–75% (avoid clipping).
3. On the Spectrum: `LOAD ""`.

## Project layout

```
endless_project/
├── README.md
├── CLAUDE.md            ← project notes (deeper architecture detail)
├── build.py             ← top-level builder (TZX + WAV)
├── src/
│   ├── stub.asm         ← Z80, ORG 0xC000, the tape loader (≤512 B)
│   ├── anim.asm         ← Z80, ORG 0xC200, typewriter + meteor + star
│   ├── loader.bas       ← user-edited PRINT/BEEP lines
│   └── screen.png       ← source image (resized to 256 × 192)
└── build/
    ├── stub.bin         ← assembled tape loader
    ├── anim.bin         ← assembled animation/typewriter/data
    ├── endless.tzx      ← TZX for emulators
    └── endless.wav      ← WAV for real hardware
```

## Technical notes

### Two-stage loader
The Z80 code is split in two:
- **stub** (~300 B at 0xC000) — table generator + tape reader.
- **anim** (~1.2 kB at 0xC200) — typewriter + meteor/star animation + data.

`build.py` embeds the patched stub bytes verbatim into a hidden
**REM line 0** of the BASIC program. BASIC POKEs those bytes from the
REM body (via `PROG+5`) into 0xC000, then `RANDOMIZE USR 49152` jumps
to it. The stub's custom SMLOADER then reads the **single** custom
data block on tape, which carries both the image (visible bottom-up
reveal) and the anim binary (silently lands at 0xC200).

The runtime address table that drives the per-byte routing lives at
0xC800..0xFE00 (13.5 kB), built by `GEN_TABLE`. It never travels on
tape and is overwritten with anim destinations for the second half.

### BASIC bootstrap (`src/loader.bas`)
The on-disk source has only the visible parts (PRINT/BEEP). `build.py`
prepends a `REM` line 0 with the stub bytes and appends the POKE+USR
loop. See `CLAUDE.md` for the full tokenised listing.

### Tape blocks (in order)
1. BASIC header
2. BASIC data (carries the embedded stub in REM line 0), 2 s pause after.
3. Pure tone (TZX 0x12) — ~5 s of extra pilot pulses, gives BASIC's
   POKE loop time to copy the stub into 0xC000 before SMLOADER starts.
4. Custom data block — image bytes (bottom-up reveal) followed by the
   anim binary (silent RAM load), consumed by the stub's SMLOADER.

### ZX VRAM addressing (recap)
- Pixels: `0x4000..0x57FF` (6144 B, scrambled by bank / scan)
- Attrs:  `0x5800..0x5AFF` (768 B, linear: row*32 + col)
- Pixel  addr `= 0x4000 | (y & 0xC0) << 5 | (y & 7) << 8 | (y & 0x38) << 2 | x_byte`

### Star marker
- Empty cells in non-occupied columns of rows 10..14 get attribute
  `0x47` (BRIGHT|INK_WHITE|PAPER_BLACK).
- Image cells whose ink happens to be white use plain `0x07` (no
  BRIGHT) so the marker is unambiguous.

## Common problems

| Symptom | Likely cause |
| --- | --- |
| `z80asm: command not found` | Install via `brew` / `apt` |
| `ModuleNotFoundError: PIL` | `pip install Pillow` |
| Image doesn't appear | Confirm `src/screen.png` exists and is readable |
| `Invalid colour` after typing | Reverted layout — keep typewriter and meteor animation sequential (see CLAUDE.md) |
