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
[1] Assembling loader...
[2] Parsing BASIC...
[3] Converting image...
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
├── CLAUDE.md            ← project notes for Claude Code
├── VRAM_LOADER_TASK.md  ← spec for the runtime address-table approach
├── build.py             ← top-level builder
├── src/
│   ├── code.asm         ← Z80 source
│   ├── loader.bas       ← BASIC bootstrap
│   └── screen.png       ← source image (256 × 192 after resize)
└── build/
    ├── code.bin         ← assembled loader
    ├── endless.tzx      ← TZX for emulators
    └── endless.wav      ← WAV for real hardware
```

## Technical notes

### BASIC bootstrap (`src/loader.bas`)
```
10 CLEAR 49151
20 BORDER 0: PAPER 0: INK 0: CLS
30 LOAD "" CODE
40 RANDOMIZE USR 49152
```

### Loader binary (`src/code.asm`)
- ORG `0xC000` (49152)
- Assembled binary is ~1.4 kB (code, sprites, state, message, tables).
- An additional 13.5 kB runtime address table lives just past the
  code, filled by `GEN_TABLE` at boot — it never travels on tape.

### Tape blocks (in order)
1. BASIC header + program
2. Code header + the loader binary
3. Screen payload — only strips 23..10 (rows 10..23) reordered per
   the GEN_TABLE sequence, with trailing zeros trimmed off.

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
