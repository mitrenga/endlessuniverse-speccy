# Spec: ZX Spectrum VRAM loader with a runtime address table

## What to implement

Load screen data into the ZX Spectrum's video RAM using a custom tape
loading routine. Data is loaded **from the last byte of video RAM
toward the first**; the order matches character strips from the bottom
to the top of the screen. Each byte's destination address is taken
from a **table generated at run time by Z80 code** — the table is not
part of the TZX file.

---

## ZX Spectrum VRAM — addressing

Video RAM occupies `0x4000..0x5AFF` (6912 bytes):

- `0x4000..0x57FF` — pixels (6144 B)
- `0x5800..0x5AFF` — attributes (768 B)

Pixel address for screen row `y` (0..191), byte-column `x_byte` (0..31):

```
addr = 0x4000
     | (y & 0xC0) << 5   ; bank      (y bits 7-6 -> addr bits 12-11)
     | (y & 0x07) << 8   ; scan      (y bits 2-0 -> addr bits 10-8)
     | (y & 0x38) << 2   ; char_row  (y bits 5-3 -> addr bits 7-5)
     | x_byte
```

For strip `S` (0..23, equivalent to character row) and scan `sc` (0..7):

```
Hi byte = 0x40 | (S & 0x18) | sc
Lo byte = (S & 0x07) << 5 | x_byte
addr    = (Hi << 8) | Lo
```

Attribute address for character row `cr` (0..23), column `x_byte` (0..31):

```
addr = 0x5800 + cr * 32 + x_byte
```

---

## Loading order

Bytes arrive in this order (first byte received -> address `0x5AFF`,
last byte received -> address `0x4000`):

```
For each strip S = 23 downto 0:
  32 attributes:   addr = 0x5800 + S*32 + x,   x = 31 downto 0
  8 scan lines:    sc = 7 downto 0:
    32 pixels:     Hi = 0x40 | (S & 0x18) | sc,
                   Lo = (S & 7) << 5 | x,        x = 31 downto 0
```

Total: 24 × (32 + 8 × 32) = 24 × 288 = **6912 bytes**.

> **Note — actual production payload is shorter.** The address table
> is still generated for the full 6912 entries (so the loader can
> route any byte to anywhere), but `build.py` only transmits the
> bottom **14 strips** (character rows 10..23). The top 10 strips
> are skipped:
>
> - Strips 0..7: text overlay area. The loader fills these attribute
>   cells with `0x44` (BRIGHT|INK_GREEN) after tape loading; their
>   pixels stay zero because the loader pre-clears `0x4000..0x57FF`.
> - Strips 8..9: empty band between the title and the image. Same
>   `0x44` fill, same pre-cleared pixels.
>
> Transmitted payload size = 14 × 288 = **4032 bytes**, then any
> trailing zero bytes are trimmed (the loader pre-clears VRAM, so
> trailing zeros at the end of the payload don't need to travel on
> tape). The last bytes of the unmodified payload correspond to scan 0
> of strip 10 (the topmost scan of the image area); for the default
> image only a handful of bytes get trimmed. Final tape data ≈ 4 kB.
>
> Since the loader uses `IX` to walk the table from the beginning and
> `DE` controls the byte count, fewer bytes simply means SMLOADER
> stops earlier — no further changes are needed in the loader.

---

## Address table — runtime generation (Z80)

The `GEN_TABLE` routine runs at loader start, **before** SMLOADER. It
writes 6912 × 2 bytes (little-endian addresses) into RAM immediately
following the machine code. Then, for each received byte, the loader
reads the destination address from the table instead of computing it.

### Inputs / outputs
- `DE` = address to write the table to (just past the code)
- Trashes: `BC`, `HL` (and a couple of byte-sized scratch variables)

### Implementation notes
1. Loops are driven by `DJNZ` or `JR NZ` after `DEC` of an explicit
   counter — never `JR NC` after `DEC`, because `DEC` does not set
   the carry flag.
2. Register `L` must be **reset to `lo_base` at the start of each
   scan iteration**, because 32 × `DEC HL` shifts it and the next
   scan would otherwise start from the wrong value.
3. `lo_base` for a given strip = `(S & 7) << 5 | 31`; cache it in a
   memory variable before entering the scan loop.

### Z80 implementation
The actual implementation lives in `src/code.asm` as the
`GEN_TABLE` routine. Two byte-sized scratch variables (`GT_STRIP_V`,
`GT_LOBASE`) hold values across the inner loops to avoid using IX/IY
half-registers (which the assembler we use does not support).

---

## Python equivalent (used at build time to reorder the payload)

The same table is computed in Python so the build script can reorder
the screen payload to match what the Z80 loader expects:

```python
def build_addr_table():
    """
    Return 6912 VRAM addresses in the same order as the Z80 GEN_TABLE
    routine produces. The i-th entry is the destination of the i-th
    byte received from tape.
    """
    table = []
    for strip in range(23, -1, -1):
        # attributes
        for x in range(31, -1, -1):
            table.append(0x5800 + strip * 32 + x)
        # pixels
        for scan in range(7, -1, -1):
            hi      = 0x40 | (strip & 0x18) | scan
            lo_base = (strip & 0x07) << 5
            for x in range(31, -1, -1):
                table.append((hi << 8) | (lo_base | x))
    assert len(table) == 6912
    return table


def order_vram_payload(vram_bytes, addr_table):
    """
    Reorder 6912 bytes of VRAM data per the address table.
    vram_bytes: raw 6912 B in linear pixel + attr layout
                (pixels 0x4000..0x57FF + attrs 0x5800..0x5AFF).
    """
    payload = bytearray(6912)
    for i, dest_addr in enumerate(addr_table):
        payload[i] = vram_bytes[dest_addr - 0x4000]
    return bytes(payload)
```

---

## Loader integration (stub)

The stub started by BASIC (`RANDOMIZE USR <addr>`) must:

1. Call `GEN_TABLE` with `DE` set to the address right after the code.
2. Set `IX` to the same address (start of the table).
3. Set `DE` to the number of bytes to load (≤ 6912).
4. Disable interrupts (`DI`).
5. Call the loading routine.
6. Re-enable interrupts and return (or jump into an animation loop).

```asm
    LD  DE, TABLE
    CALL GEN_TABLE
    LD  IX, TABLE
    LD  DE, 6912               ; placeholder — patched at build time
    DI
    CALL SMLOADER
    EI
    RET                        ; or fall through to your animation
```

In the actual loader the `LD DE, n` instruction is patched by
`build.py` to the trimmed payload length (around 4019 bytes for the
default image), so SMLOADER stops once those bytes arrive.

---

## Storing one byte in the loading routine

Replace the original `LD (IX+0), L` / `INC IX` / `DEC DE` with:

```asm
    PUSH BC                    ; save C=EAR state, B=timer
    LD   C, (IX+0)             ; lo byte of destination, from the table
    LD   B, (IX+1)             ; hi byte of destination
    LD   A, L                  ; the just-decoded data byte
    LD   (BC), A               ; write to the VRAM address
    POP  BC
    INC  IX                    ; advance the table pointer (2 B per entry)
    INC  IX
    DEC  DE                    ; one fewer byte to go
```

---

## Sanity check

Quick Python test to validate the table:

```python
table = build_addr_table()
assert table[0]    == 0x5AFF   # first byte    -> last attribute
assert table[31]   == 0x5AE0   # 32nd byte     -> first attribute of strip 23
assert table[32]   == 0x57FF   # 33rd byte     -> pixel strip 23, scan 7, x=31
assert table[6911] == 0x4000   # last byte     -> first pixel
print("OK")
```

`build.py` performs these assertions every time it builds, so a
regression in the table layout fails the build immediately.
