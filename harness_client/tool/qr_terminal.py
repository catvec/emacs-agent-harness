#!/usr/bin/env python3
"""Draw a QR code in a terminal, without a third-party QR library.

`tool/qr_install.sh' shows the Wi-Fi pairing code for adb wireless debugging
with this, so installing on a phone needs neither a USB cable nor the
`qrencode' package.  `--pairing' prints the service name and password for that
code (the name is longer than a Wi-Fi SSID, so a camera cannot use the code as
a network).  The encoder follows ISO/IEC 18004 in byte mode, error
correction levels L, M, Q and H, versions 1 to 40; the terminal renderer uses
Unicode half blocks (or `##' with --ascii), and --png writes the same symbol as
a PNG for an image viewer.
"""

from __future__ import annotations

import argparse
import os
import secrets
import shutil
import string
import struct
import subprocess
import sys
import tempfile
import zlib

Level = str

LEVELS = {"L": 0, "M": 1, "Q": 2, "H": 3}
LEVEL_BITS = {"L": 1, "M": 0, "Q": 3, "H": 2}


def pairing_credentials(name: str | None = None) -> tuple[str, str]:
    """Return the service name and password for an adb QR pairing code.

    Android stores the code in the Wi-Fi QR format, but the S: field is an mDNS
    service name and P: is the pairing password, not a Wi-Fi SSID and key.  A
    generated name is longer than a Wi-Fi SSID (32 bytes) so a camera app that
    reads the code as a network cannot join it; an mDNS instance name may be up
    to 63 bytes, and the wireless debugging scanner passes it through intact.
    """
    alphabet = string.ascii_letters + string.digits
    if not name:
        name = "studio-" + "".join(secrets.choice(alphabet) for _ in range(32))
    password = "".join(secrets.choice(alphabet) for _ in range(21))
    return name, password


# Error correction codewords per block, by level (L M Q H) then version.
ECC_PER_BLOCK = [
    [None, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [None, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    [None, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [None, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
]

# Error correction blocks, by level (L M Q H) then version.
BLOCKS = [
    [None, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    [None, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    [None, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    [None, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
]


def raw_modules(version: int) -> int:
    """Return the modules of VERSION left for data and error correction."""
    n = (16 * version + 128) * version + 64
    if version >= 2:
        align = version // 7 + 2
        n -= (25 * align - 10) * align - 55
        if version >= 7:
            n -= 36
    return n


def data_codewords(version: int, level: Level) -> int:
    row = LEVELS[level]
    return raw_modules(version) // 8 - ECC_PER_BLOCK[row][version] * BLOCKS[row][version]


def alignment_positions(version: int) -> list[int]:
    if version == 1:
        return []
    count = version // 7 + 2
    size = version * 4 + 17
    step = 26 if version == 32 else 2 * ((version * 4 + count * 2 + 1) // (count * 2 - 2))
    positions = []
    pos = size - 7
    for _ in range(count - 1):
        positions.append(pos)
        pos -= step
    return [6] + positions[::-1]


# GF(256) with the polynomial 0x11D.

EXP = [0] * 512
LOG = [0] * 256
_x = 1
for _i in range(255):
    EXP[_i] = _x
    _x <<= 1
    if _x >= 256:
        _x ^= 0x11D
for _i in range(255):
    EXP[255 + _i] = EXP[_i]
for _i in range(255):
    LOG[EXP[_i]] = _i


def gf_mul(x: int, y: int) -> int:
    if x == 0 or y == 0:
        return 0
    return EXP[LOG[x] + LOG[y]]


def rs_divisor(degree: int) -> list[int]:
    result = [0] * degree
    result[degree - 1] = 1
    root = 1
    for _ in range(degree):
        for j in range(degree):
            result[j] = gf_mul(result[j], root)
            if j + 1 < degree:
                result[j] ^= result[j + 1]
        root = gf_mul(root, 2)
    return result


def rs_ecc(data: list[int], degree: int) -> list[int]:
    divisor = rs_divisor(degree)
    result = [0] * degree
    for byte in data:
        factor = byte ^ result[0]
        result = result[1:] + [0]
        for i in range(degree):
            result[i] ^= gf_mul(divisor[i], factor)
    return result


def codewords(data: bytes, version: int, level: Level) -> list[int]:
    capacity = 8 * data_codewords(version, level)
    bits: list[int] = []

    def add(value: int, width: int) -> None:
        for i in range(width - 1, -1, -1):
            bits.append((value >> i) & 1)

    add(4, 4)  # byte mode
    add(len(data), 8 if version <= 9 else 16)
    for byte in data:
        add(byte, 8)
    add(0, min(4, capacity - len(bits)))
    add(0, (8 - len(bits) % 8) % 8)
    pad = 0xEC
    while len(bits) < capacity:
        add(pad, 8)
        pad = 0x11 if pad == 0xEC else 0xEC
    return [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]


def interleave(data: list[int], version: int, level: Level) -> list[int]:
    row = LEVELS[level]
    blocks = BLOCKS[row][version]
    ecc = ECC_PER_BLOCK[row][version]
    raw = raw_modules(version) // 8
    short_count = blocks - raw % blocks
    short_len = raw // blocks
    data_blocks: list[list[int]] = []
    ecc_blocks: list[list[int]] = []
    at = 0
    for b in range(blocks):
        n = short_len - ecc + (0 if b < short_count else 1)
        block = data[at:at + n]
        at += n
        data_blocks.append(block)
        ecc_blocks.append(rs_ecc(block, ecc))
    out: list[int] = []
    for k in range(short_len - ecc + 1):
        for block in data_blocks:
            if k < len(block):
                out.append(block[k])
    for k in range(ecc):
        for block in ecc_blocks:
            out.append(block[k])
    return out


class Matrix:
    def __init__(self, size: int) -> None:
        self.size = size
        self.modules = [[False] * size for _ in range(size)]
        self.function = [[False] * size for _ in range(size)]

    def set_function(self, x: int, y: int, dark: bool) -> None:
        self.modules[y][x] = dark
        self.function[y][x] = True


def draw_finder(m: Matrix, cx: int, cy: int) -> None:
    for dy in range(-4, 5):
        for dx in range(-4, 5):
            x, y = cx + dx, cy + dy
            if 0 <= x < m.size and 0 <= y < m.size:
                dist = max(abs(dx), abs(dy))
                m.set_function(x, y, dist not in (2, 4))


def draw_alignment(m: Matrix, cx: int, cy: int) -> None:
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            m.set_function(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1)


def format_bits(level: Level, mask: int) -> int:
    data = (LEVEL_BITS[level] << 3) | mask
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    return ((data << 10) | rem) ^ 0x5412


def version_bits(version: int) -> int:
    rem = version
    for _ in range(12):
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
    return (version << 12) | rem


def draw_format(m: Matrix, level: Level, mask: int) -> None:
    bits = format_bits(level, mask)
    size = m.size
    bit = lambda i: bool(bits & (1 << i))  # noqa: E731
    for i in range(6):
        m.set_function(8, i, bit(i))
    m.set_function(8, 7, bit(6))
    m.set_function(8, 8, bit(7))
    m.set_function(7, 8, bit(8))
    for i in range(9, 15):
        m.set_function(14 - i, 8, bit(i))
    for i in range(8):
        m.set_function(size - 1 - i, 8, bit(i))
    for i in range(8, 15):
        m.set_function(8, size - 15 + i, bit(i))
    m.set_function(8, size - 8, True)  # the dark module


def draw_function_patterns(m: Matrix, version: int, level: Level) -> None:
    size = m.size
    for i in range(size):
        m.set_function(6, i, i % 2 == 0)
        m.set_function(i, 6, i % 2 == 0)
    draw_finder(m, 3, 3)
    draw_finder(m, size - 4, 3)
    draw_finder(m, 3, size - 4)
    positions = alignment_positions(version)
    last = len(positions) - 1
    for i in range(len(positions)):
        for j in range(len(positions)):
            if (i, j) in ((0, 0), (0, last), (last, 0)):
                continue
            draw_alignment(m, positions[i], positions[j])
    draw_format(m, level, 0)
    if version >= 7:
        bits = version_bits(version)
        for i in range(18):
            dark = bool(bits & (1 << i))
            a = size - 11 + i % 3
            b = i // 3
            m.set_function(a, b, dark)
            m.set_function(b, a, dark)


def draw_codewords(m: Matrix, words: list[int]) -> None:
    size = m.size
    total = 8 * len(words)
    i = 0
    right = size - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(size):
            for j in range(2):
                x = right - j
                upward = ((right + 1) & 2) == 0
                y = size - 1 - vert if upward else vert
                if not m.function[y][x] and i < total:
                    m.modules[y][x] = bool((words[i >> 3] >> (7 - (i & 7))) & 1)
                    i += 1
        right -= 2


def mask_p(mask: int, x: int, y: int) -> bool:
    if mask == 0:
        return (x + y) % 2 == 0
    if mask == 1:
        return y % 2 == 0
    if mask == 2:
        return x % 3 == 0
    if mask == 3:
        return (x + y) % 3 == 0
    if mask == 4:
        return (x // 3 + y // 2) % 2 == 0
    if mask == 5:
        return (x * y) % 2 + (x * y) % 3 == 0
    if mask == 6:
        return ((x * y) % 2 + (x * y) % 3) % 2 == 0
    return ((x + y) % 2 + (x * y) % 3) % 2 == 0


def apply_mask(m: Matrix, mask: int) -> None:
    for y in range(m.size):
        for x in range(m.size):
            if not m.function[y][x] and mask_p(mask, x, y):
                m.modules[y][x] = not m.modules[y][x]


def finder_count(history: list[int]) -> int:
    n = history[1]
    core = n > 0 and history[2] == n and history[3] == 3 * n and history[4] == n and history[5] == n
    return int(core and history[0] >= 4 * n and history[6] >= n) + \
        int(core and history[6] >= 4 * n and history[0] >= n)


def history_add(run: int, history: list[int], size: int) -> None:
    if history[0] == 0:
        run += size
    history[1:] = history[:-1]
    history[0] = run


def line_penalty(rows: list[list[bool]], size: int, transposed: bool) -> int:
    score = 0
    for line in range(size):
        # Like the Lisp encoder this follows, nil means both "no module seen
        # yet" and "light": a leading light run includes the border and one
        # module, and the first transition adds the leading finder penalty.
        color = None
        run = 0
        history = [0] * 7
        for i in range(size):
            module = rows[i][line] if transposed else rows[line][i]
            if (color is None and module is False) or (color is not None and module is color):
                run += 1
                if run == 5:
                    score += 3
                elif run > 5:
                    score += 1
            else:
                history_add(run, history, size)
                if color is not True:
                    # A pattern that ends where light becomes dark counts,
                    # as does the leading border (`color' is None there).
                    score += 40 * finder_count(history)
                color = module
                run = 1
        if color is True:
            history_add(run, history, size)
            run = 0
        history_add(run + size, history, size)
        score += 40 * finder_count(history)
    return score


def penalty(m: Matrix) -> int:
    size = m.size
    score = line_penalty(m.modules, size, False) + line_penalty(m.modules, size, True)
    dark = 0
    for y in range(size):
        row = m.modules[y]
        for x in range(size):
            if row[x]:
                dark += 1
            if x < size - 1 and y < size - 1:
                c = row[x]
                if c == row[x + 1] == m.modules[y + 1][x] == m.modules[y + 1][x + 1]:
                    score += 3
    total = size * size
    k = (abs(dark * 20 - total * 10) + total - 1) // total - 1
    return score + 10 * max(0, k)


def version_for(length: int, level: Level) -> int:
    for version in range(1, 41):
        needed = 4 + (8 if version <= 9 else 16) + 8 * length
        if needed <= 8 * data_codewords(version, level):
            return version
    raise ValueError("text too long for a QR code")


def encode(text: str, level: Level = "M", mask: int | None = None) -> dict:
    """Encode TEXT as a QR code: size, version, level, mask and modules."""
    if level not in LEVELS:
        raise ValueError("level must be L, M, Q or H")
    data = text.encode("utf-8")
    version = version_for(len(data), level)
    size = version * 4 + 17
    m = Matrix(size)
    draw_function_patterns(m, version, level)
    draw_codewords(m, interleave(codewords(data, version, level), version, level))
    if mask is None:
        best = min(range(8), key=lambda candidate: matrix_penalty(m, candidate, level))
    else:
        best = mask
    apply_mask(m, best)
    draw_format(m, level, best)
    return {"size": size, "version": version, "level": level, "mask": best,
            "modules": m.modules}


def matrix_penalty(m: Matrix, mask: int, level: Level) -> int:
    apply_mask(m, mask)
    draw_format(m, level, mask)
    score = penalty(m)
    apply_mask(m, mask)
    return score


def render(matrix: dict, margin: int = 4, ascii: bool = False, indent: int = 0) -> str:
    """Return the QR code as text: half blocks, or `##' with ASCII."""
    rows = matrix["modules"]
    size = matrix["size"]
    width = size + margin * 2
    lines = []
    if ascii:
        for y in range(width):
            line = [" " * indent]
            for x in range(width):
                dark = 0 <= x - margin < size and 0 <= y - margin < size and rows[y - margin][x - margin]
                line.append("##" if dark else "  ")
            lines.append("".join(line))
        return "\n".join(lines) + "\n"
    for y in range(0, width, 2):
        chars = []
        for x in range(width):
            top = 0 <= x - margin < size and 0 <= y - margin < size and rows[y - margin][x - margin]
            bottom = (0 <= x - margin < size and 0 <= y + 1 - margin < size
                      and rows[y + 1 - margin][x - margin])
            if top and bottom:
                chars.append("\u2588")
            elif top:
                chars.append("\u2580")
            elif bottom:
                chars.append("\u2584")
            else:
                chars.append(" ")
        lines.append(" " * indent + "\033[47;30m" + "".join(chars) + "\033[0m")
    return "\n".join(lines) + "\n"


def png_bytes(matrix: dict, scale: int = 10, margin: int = 4) -> bytes:
    """Return a black-on-white PNG of MATRIX, SCALE pixels per module."""
    if scale < 1:
        raise ValueError("scale must be at least 1")
    if margin < 0:
        raise ValueError("margin must not be negative")
    size = matrix["size"]
    rows = matrix["modules"]
    pixels = (size + margin * 2) * scale
    border = b"\xff" * (margin * scale)
    raw = bytearray()
    blank = b"\x00" + b"\xff" * pixels
    for _ in range(margin * scale):
        raw += blank
    for row in rows:
        line = bytearray(border)
        for dark in row:
            line += (b"\x00" if dark else b"\xff") * scale
        line += border
        scanline = b"\x00" + bytes(line)
        for _ in range(scale):
            raw += scanline
    for _ in range(margin * scale):
        raw += blank

    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", pixels, pixels, 8, 0, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def write_png(matrix: dict, path: str, scale: int = 10, margin: int = 4) -> None:
    with open(path, "wb") as output:
        output.write(png_bytes(matrix, scale, margin))


# Keep the viewer's Popen alive: it is detached and outlives this process, and
# dropping the object while it runs makes subprocess warn when it is collected.
_VIEWERS: list[subprocess.Popen] = []


def open_image(path: str) -> bool:
    """Open a PNG in an image viewer on this desktop, best effort.

    `feh' is small and goes straight to the image; a desktop's default viewer
    through xdg-open is the fallback.  The viewer runs in the background so the
    caller keeps waiting for the phone.
    """
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return False
    commands = []
    feh = shutil.which("feh")
    if feh and os.environ.get("DISPLAY"):
        commands.append([feh, "--auto-zoom", "--scale-down", "--geometry",
                         "800x800", "--title", "Harness QR", path])
    xdg_open = shutil.which("xdg-open")
    if xdg_open:
        commands.append([xdg_open, path])
    for command in commands:
        try:
            process = subprocess.Popen(
                command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True)
            _VIEWERS.append(process)
            return True
        except OSError:
            continue
    return False


def show_image(matrix: dict, scale: int = 20, margin: int = 4) -> str | None:
    """Write a temporary PNG and open it; return its path, or None."""
    fd, path = tempfile.mkstemp(prefix="harness-qr-", suffix=".png")
    os.close(fd)
    try:
        write_png(matrix, path, scale, margin)
    except OSError:
        return None
    return path if open_image(path) else None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Draw a QR code in the terminal (byte mode, versions 1-40).")
    parser.add_argument("text", nargs="?", help="text to encode (default: read stdin)")
    parser.add_argument("--pairing", nargs="?", const="", metavar="NAME",
                        help="print a pairing service NAME and password instead of drawing a code")
    parser.add_argument("--level", default="M", choices=list(LEVELS),
                        help="error correction level (default M)")
    parser.add_argument("--margin", type=int, default=4,
                        help="quiet zone in modules (default 4)")
    parser.add_argument("--ascii", action="store_true",
                        help="draw with ## and spaces instead of half blocks")
    parser.add_argument("--indent", type=int, default=0,
                        help="spaces before every line (default 0)")
    parser.add_argument("--png", metavar="PATH",
                        help="also write a PNG to PATH")
    parser.add_argument("--scale", type=int, default=10,
                        help="pixels per module in the PNG (default 10)")
    parser.add_argument("--open", action="store_true",
                        help="open a large PNG in an image viewer")
    args = parser.parse_args(argv)
    if args.pairing is not None:
        name, password = pairing_credentials(args.pairing or None)
        print(name, password)
        return 0
    text = args.text
    if text is None:
        if sys.stdin.isatty():
            parser.error("no text given")
        text = sys.stdin.read().rstrip("\n")
    if args.margin < 0:
        parser.error("--margin must not be negative")
    if args.scale < 1:
        parser.error("--scale must be positive")
    try:
        qr = encode(text, args.level)
    except ValueError as exc:
        print(f"qr_terminal: {exc}", file=sys.stderr)
        return 1
    sys.stdout.write(render(qr, args.margin, args.ascii, args.indent))
    if args.png:
        try:
            write_png(qr, args.png, args.scale, args.margin)
        except OSError as exc:
            print(f"qr_terminal: cannot write {args.png}: {exc}", file=sys.stderr)
            return 1
    if args.open:
        path = show_image(qr, max(args.scale, 20), args.margin)
        if path:
            print(f"qr_terminal: large QR image: {path}", file=sys.stderr)
        else:
            print("qr_terminal: no image viewer found; use the code above",
                  file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
