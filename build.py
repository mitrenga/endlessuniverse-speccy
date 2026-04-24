#!/usr/bin/env python3
"""
endless - ZX Spectrum 48K tape loader builder
Builds a TZX tape image with scroll-reveal loading effect

Usage:
    python build.py [--image path/to/image.png] [--output endless.tzx]
"""

import struct
import subprocess
import sys
import os
import argparse
from PIL import Image
import numpy as np

# ── Paths ─────────────────────────────────────────────────────────────────────
DIR      = os.path.dirname(os.path.abspath(__file__))
SRC_DIR  = os.path.join(DIR, 'src')
BUILD_DIR= os.path.join(DIR, 'build')

# ── ZX helpers ────────────────────────────────────────────────────────────────
def zx_checksum(data):
    cs = 0
    for b in data: cs ^= b
    return cs

def tape_data(data):
    cs = zx_checksum(b'\xFF' + data)
    return b'\xFF' + data + bytes([cs])

def tape_header(block_type, filename, length, param1=0, param2=0x8000):
    name = (filename + ' ' * 10)[:10].encode('ascii')
    hdr  = bytes([block_type]) + name + struct.pack('<H', length) + struct.pack('<H', param1) + struct.pack('<H', param2)
    cs   = zx_checksum(b'\x00' + hdr)
    return b'\x00' + hdr + bytes([cs])

def tzx_std(data, pause_ms=1000):
    return bytes([0x10]) + struct.pack('<H', pause_ms) + struct.pack('<H', len(data)) + data

def num(n):
    return bytes([0x0E,0x00,0x00,n&0xFF,(n>>8)&0xFF,0x00])

def pxaddr(y):
    return 0x4000 | ((y&0xC0)<<5) | ((y&0x07)<<8) | ((y&0x38)<<2)

def build_addr_table():
    """
    Return 6912 VRAM addresses in the same order as the Z80 GEN_TABLE
    routine produces. The i-th entry is the destination of the i-th byte
    received from tape. The order is bottom-up by character row, with
    attributes preceding pixels within each row.
    """
    table = []
    for strip in range(23, -1, -1):
        for x in range(31, -1, -1):
            table.append(0x5800 + strip * 32 + x)
        for scan in range(7, -1, -1):
            hi      = 0x40 | (strip & 0x18) | scan
            lo_base = (strip & 0x07) << 5
            for x in range(31, -1, -1):
                table.append((hi << 8) | (lo_base | x))
    assert len(table) == 6912
    assert table[0]    == 0x5AFF
    assert table[31]   == 0x5AE0
    assert table[32]   == 0x57FF
    assert table[6911] == 0x4000
    return table

def order_vram_payload(vram_bytes, addr_table):
    """Reorder 6912 VRAM bytes per the address table (tape transmission order)."""
    payload = bytearray(6912)
    for i, dest_addr in enumerate(addr_table):
        payload[i] = vram_bytes[dest_addr - 0x4000]
    return bytes(payload)

# ── BASIC tokenizer ───────────────────────────────────────────────────────────
ZX_TOKENS = {
    'DEF FN':0xCE,'OPEN #':0xD3,'CLOSE #':0xD4,'GO TO':0xEC,'GO SUB':0xED,
    'RND':0xA5,'INKEY$':0xA6,'PI':0xA7,'FN':0xA8,'POINT':0xA9,'SCREEN$':0xAA,
    'ATTR':0xAB,'AT':0xAC,'TAB':0xAD,'VAL$':0xAE,'CODE':0xAF,'VAL':0xB0,
    'LEN':0xB1,'SIN':0xB2,'COS':0xB3,'TAN':0xB4,'ASN':0xB5,'ACS':0xB6,
    'ATN':0xB7,'LN':0xB8,'EXP':0xB9,'INT':0xBA,'SQR':0xBB,'SGN':0xBC,
    'ABS':0xBD,'PEEK':0xBE,'IN':0xBF,'USR':0xC0,'STR$':0xC1,'CHR$':0xC2,
    'NOT':0xC3,'BIN':0xC4,'OR':0xC5,'AND':0xC6,'LINE':0xCA,'THEN':0xCB,
    'TO':0xCC,'STEP':0xCD,'CAT':0xCF,'FORMAT':0xD0,'MOVE':0xD1,'ERASE':0xD2,
    'MERGE':0xD5,'VERIFY':0xD6,'BEEP':0xD7,'CIRCLE':0xD8,'INK':0xD9,
    'PAPER':0xDA,'FLASH':0xDB,'BRIGHT':0xDC,'INVERSE':0xDD,'OVER':0xDE,
    'OUT':0xDF,'LPRINT':0xE0,'LLIST':0xE1,'STOP':0xE2,'READ':0xE3,'DATA':0xE4,
    'RESTORE':0xE5,'NEW':0xE6,'BORDER':0xE7,'CONTINUE':0xE8,'DIM':0xE9,
    'REM':0xEA,'FOR':0xEB,'INPUT':0xEE,'LOAD':0xEF,'LIST':0xF0,'LET':0xF1,
    'PAUSE':0xF2,'NEXT':0xF3,'POKE':0xF4,'PRINT':0xF5,'PLOT':0xF6,'RUN':0xF7,
    'SAVE':0xF8,'RANDOMIZE':0xF9,'IF':0xFA,'CLS':0xFB,'DRAW':0xFC,
    'CLEAR':0xFD,'RETURN':0xFE,'COPY':0xFF,
}
_SORTED_TOKENS = sorted(ZX_TOKENS.items(), key=lambda x: -len(x[0]))

def parse_basic_file(path):
    """Parse text ZX BASIC source into bytecode"""
    lines = []
    with open(path) as f:
        for raw in f:
            raw = raw.strip()
            if not raw or raw.startswith('#'):
                continue
            parts = raw.split(None, 1)
            linenum = int(parts[0])
            rest = parts[1] if len(parts) > 1 else ''
            content = bytearray()
            i = 0
            while i < len(rest):
                if rest[i] == ' ':
                    i += 1
                    continue
                if rest[i] == '"':
                    j = rest.find('"', i + 1)
                    j = j if j != -1 else len(rest) - 1
                    content += rest[i:j+1].encode('ascii')
                    i = j + 1
                    continue
                matched = False
                for kw, token in _SORTED_TOKENS:
                    if rest[i:i+len(kw)].upper() == kw:
                        content.append(token)
                        i += len(kw)
                        matched = True
                        break
                if matched:
                    continue
                if rest[i].isdigit():
                    j = i
                    while j < len(rest) and rest[j].isdigit():
                        j += 1
                    n = int(rest[i:j])
                    content += rest[i:j].encode('ascii')
                    content += num(n)
                    i = j
                    continue
                content += rest[i:i+1].encode('ascii')
                i += 1
            content.append(0x0D)
            lines.append(struct.pack('>H', linenum) + struct.pack('<H', len(content)) + bytes(content))
    return b''.join(lines)

# ── Assembler ─────────────────────────────────────────────────────────────────
def assemble(src, dst):
    """Assemble Z80 source using z80asm"""
    result = subprocess.run(['z80asm', '-i', src, '-o', dst], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Assembly error:\n{result.stderr}")
        sys.exit(1)
    print(f"  Assembled: {os.path.basename(src)} → {os.path.basename(dst)} ({os.path.getsize(dst)} bytes)")

# ── Image conversion ──────────────────────────────────────────────────────────
ZX_PALETTE = {
    0:(0,0,0),    1:(0,0,215),   2:(215,0,0),   3:(215,0,215),
    4:(0,215,0),  5:(0,215,215), 6:(215,215,0), 7:(215,215,215)
}
ZX_PALETTE_BRIGHT = {
    0:(0,0,0),    1:(0,0,255),   2:(255,0,0),   3:(255,0,255),
    4:(0,255,0),  5:(0,255,255), 6:(255,255,0), 7:(255,255,255)
}

BAYER8 = np.array([
    [ 0,32, 8,40, 2,34,10,42],[48,16,56,24,50,18,58,26],
    [12,44, 4,36,14,46, 6,38],[60,28,52,20,62,30,54,22],
    [ 3,35,11,43, 1,33, 9,41],[51,19,59,27,49,17,57,25],
    [15,47, 7,39,13,45, 5,37],[63,31,55,23,61,29,53,21],
], dtype=float) / 64.0

def convert_image(image_path):
    """Convert image to ZX Spectrum screen format (6912 bytes)"""
    print(f"  Converting image: {image_path}")
    img = Image.open(image_path).convert('RGB')
    orig = np.array(img.resize((256, 192), Image.LANCZOS))
    not_black = ~np.all(orig < 15, axis=2)

    pixel_data = np.zeros((192, 256), dtype=np.uint8)
    attr_data  = np.zeros((24, 32),   dtype=np.uint8)

    for cy in range(24):
        for cx in range(32):
            frac = not_black[cy*8:(cy+1)*8, cx*8:(cx+1)*8].mean()
            if frac < 0.30:
                attr_data[cy, cx] = 0x00
                continue
            cell = orig[cy*8:(cy+1)*8, cx*8:(cx+1)*8].astype(float)
            rv, gv, bv = cell.mean(axis=(0,1))
            was_red  = (rv > 1.5*gv) and (rv > 1.5*bv)
            is_white = (rv > 160 and gv > 160 and bv > 160)
            if was_red:    ink_i, bright = 6, 0
            elif is_white: ink_i, bright = 7, 0
            else:          ink_i, bright = 5, 0
            attr_data[cy, cx] = (bright<<6) | ink_i
            pal = ZX_PALETTE_BRIGHT if bright else ZX_PALETTE
            ink_rgb = np.array(pal[ink_i], dtype=float)
            ink_lum = (ink_rgb[0]*0.299 + ink_rgb[1]*0.587 + ink_rgb[2]*0.114) / 255.0
            for dy in range(8):
                for dx in range(8):
                    pr, pg, pb = orig[cy*8+dy, cx*8+dx].astype(float)
                    lum = (pr*0.299 + pg*0.587 + pb*0.114) / 255.0
                    t = min(1.0, max(0.0, lum/ink_lum if ink_lum > 0 else lum))
                    pixel_data[cy*8+dy, cx*8+dx] = 1 if t > BAYER8[dy, dx] else 0

    # Rows 10..14 ("sky" area): mark empty cells with attr 0x47
    # (BRIGHT|INK_WHITE|PAPER_BLACK). The Z80 FIND_STAR_POS routine
    # searches for this exact marker to place twinkling stars.
    # Excluded: any character column that contains a lit pixel within
    # rows 10..14, so stars never spawn next to image content (the ship).
    # The BRIGHT bit distinguishes the marker from image cells whose
    # ink happens to be white (those use plain 0x07, no BRIGHT).
    col_occupied = pixel_data[10*8:15*8].any(axis=0).reshape(32, 8).any(axis=1)
    for cy in range(10, 15):
        for cx in range(32):
            if col_occupied[cx]:
                continue
            if not pixel_data[cy*8:(cy+1)*8, cx*8:(cx+1)*8].any():
                attr_data[cy, cx] = 0x47

    # Top 8 char rows (strips 0..7): attributes are generated by the
    # loader at run time, so neither pixels nor attrs travel on tape.

    # Build ZX screen (6912 bytes = pixels + attrs)
    screen = bytearray(6912)
    for y in range(192):
        addr = pxaddr(y) - 0x4000
        for x in range(32):
            b = 0
            for bit in range(8):
                b = (b<<1) | int(pixel_data[y, x*8+bit])
            screen[addr+x] = b
    for cy in range(24):
        for cx in range(32):
            screen[6144 + cy*32+cx] = attr_data[cy, cx]

    print(f"  Screen: 6912 bytes (6144 pixels + 768 attrs)")
    return bytes(screen)

# ── TZX builder ───────────────────────────────────────────────────────────────
def build_tzx(loader_bin, screen_data, basic, output_path):
    """Assemble the BASIC + loader + screen blocks into a single TZX file."""
    # Reorder VRAM bytes to match the Z80 GEN_TABLE sequence.
    ordered = order_vram_payload(screen_data, build_addr_table())
    # Skip the top 8 strips (char rows 0..7, text overlay area) plus
    # strips 8 and 9 (empty band above the image). The loader fills
    # those attributes at run time, so they never travel on tape.
    ordered = ordered[:14 * 288]
    # Trim trailing zeros — the loader pre-clears VRAM, so any zero
    # bytes at the end of the payload don't need to be transmitted.
    trimmed = ordered.rstrip(b'\x00')
    load_len = len(trimmed)

    # Patch the loader's `LD DE, n` instruction with the actual payload
    # length. Offset 0x18 is the opcode (0x11), 0x19..0x1A is the operand.
    assert loader_bin[0x18] == 0x11, "LD DE offset mismatch — code.asm changed?"
    patched = bytearray(loader_bin)
    patched[0x19] = load_len & 0xFF
    patched[0x1A] = (load_len >> 8) & 0xFF

    tzx = b'ZXTape!\x1A' + bytes([1, 20])
    tzx += tzx_std(tape_header(0,'endless',len(basic),param1=10,param2=len(basic)), 1000)
    tzx += tzx_std(tape_data(basic), 1000)
    tzx += tzx_std(tape_header(3,'endless',len(patched),param1=0xC000), 1000)
    tzx += tzx_std(tape_data(bytes(patched)), 1000)
    tzx += tzx_std(tape_data(trimmed), 2000)

    with open(output_path, 'wb') as f:
        f.write(tzx)
    saved = 6912 - load_len
    print(f"  Screen: {load_len} bytes ({saved} trailing zeros stripped)")
    print(f"  TZX: {output_path} ({len(tzx)} bytes)")

# ── WAV generator (physical Spectrum tape audio) ──────────────────────────────
def tzx_to_wav(tzx_data, wav_path, sample_rate=44100):
    """
    Render the TZX as a WAV that a real ZX Spectrum can load through the
    EAR input. Only the standard-speed block type (0x10, the only one
    that build_tzx produces) is supported. Pulse durations follow the
    ROM loader timing: pilot 2168T, sync 667/735T, bit 0 = 855T per
    pulse, bit 1 = 1710T per pulse, two pulses per data bit.
    """
    import wave
    CPU_CLOCK = 3500000
    AMP       = 24000

    segments = []           # list of (samples_count, signed_value)
    level    = 1            # +1/-1 multiplier; flips on every pulse

    def pulse(tstates):
        nonlocal level
        n = max(1, round(tstates * sample_rate / CPU_CLOCK))
        segments.append((n, level * AMP))
        level = -level

    def pause(ms):
        n = round(ms * sample_rate / 1000)
        if n > 0:
            segments.append((n, 0))

    pos = 10  # skip 'ZXTape!\x1A' + 2-byte version field
    while pos < len(tzx_data):
        bt = tzx_data[pos]
        if bt != 0x10:
            raise ValueError(f'Unsupported TZX block 0x{bt:02x} at {pos}')
        p_ms   = tzx_data[pos+1] | (tzx_data[pos+2] << 8)
        length = tzx_data[pos+3] | (tzx_data[pos+4] << 8)
        data   = tzx_data[pos+5:pos+5+length]
        pos += 5 + length

        flag = data[0]
        pilot_n = 8063 if flag < 0x80 else 3223  # header vs data block
        for _ in range(pilot_n):
            pulse(2168)
        pulse(667)
        pulse(735)
        for b in data:
            for i in range(7, -1, -1):
                t = 1710 if (b >> i) & 1 else 855
                pulse(t)
                pulse(t)
        pause(p_ms)

    total = sum(n for n, _ in segments)
    samples = np.empty(total, dtype=np.int16)
    p = 0
    for n, v in segments:
        samples[p:p+n] = v
        p += n

    with wave.open(wav_path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(samples.tobytes())

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description='Build endless ZX Spectrum TZX')
    parser.add_argument('--image',  default=os.path.join(SRC_DIR, 'screen.png'),
                        help='Source image (default: src/screen.png)')
    parser.add_argument('--output', default=os.path.join(BUILD_DIR, 'endless.tzx'),
                        help='Output TZX file (default: build/endless.tzx)')
    args = parser.parse_args()

    os.makedirs(BUILD_DIR, exist_ok=True)

    print("=== endless loader build ===")

    # 1. Assemble loader
    src_asm = os.path.join(SRC_DIR, 'code.asm')
    out_bin = os.path.join(BUILD_DIR, 'code.bin')
    print("\n[1] Assembling loader...")
    assemble(src_asm, out_bin)
    loader_bin = open(out_bin, 'rb').read()

    # 2. Parse BASIC
    bas_src = os.path.join(SRC_DIR, 'loader.bas')
    print("\n[2] Parsing BASIC...")
    basic = parse_basic_file(bas_src)
    print(f"  BASIC: {bas_src.split('/')[-1]}, {len(basic)} bytes")

    # 3. Convert image
    print("\n[3] Converting image...")
    screen_data = convert_image(args.image)

    # 4. Build TZX
    print("\n[4] Building TZX...")
    build_tzx(loader_bin, screen_data, basic, args.output)

    # 5. Generate WAV for physical Spectrum
    print("\n[5] Generating WAV for physical Spectrum...")
    wav_path = args.output[:-4] + '.wav' if args.output.endswith('.tzx') else args.output + '.wav'
    with open(args.output, 'rb') as f:
        tzx_data = f.read()
    tzx_to_wav(tzx_data, wav_path)
    size_kb = os.path.getsize(wav_path) / 1024
    print(f"  WAV: {wav_path} ({size_kb:.1f} KB, 44100 Hz 16-bit mono)")

    print(f"\n✓ Done! Load in JSSpeccy or real ZX Spectrum:")
    print(f"  LOAD \"\"")

if __name__ == '__main__':
    main()
