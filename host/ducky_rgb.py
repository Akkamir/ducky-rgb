#!/usr/bin/env python3
"""ducky-rgb: drive the Ducky One 2 SF LEDs (QMK `hostrgb` keymap) from macOS over raw HID.

Protocol (32-byte reports, byte 0 = command, reply byte 1 = status):
  0x01 PING               -> [0x01, 0, version, led_count]
  0x02 MODE on            host colours replace the firmware effect (0 = back to the effect)
  0x03 SET first n rgb*n  up to 9 LEDs per report
  0x04 FILL r g b
"""
import argparse
import colorsys
import math
import sys
import time

import hid

from font3x5 import text_columns

VID, PID = 0x445B, 0x07AE
USAGE_PAGE, USAGE = 0xFF60, 0x61
REPORT_SIZE = 32
CMD_PING, CMD_MODE, CMD_SET, CMD_FILL = 0x01, 0x02, 0x03, 0x04
MAX_LEDS_PER_REPORT = (REPORT_SIZE - 3) // 3

# LED index order = rgb_matrix layout order in iso/keyboard.json. Names are QWERTY positions.
KEYS = [
    ("esc", 0, 0), ("1", 15, 0), ("2", 29, 0), ("3", 44, 0), ("4", 59, 0), ("5", 73, 0),
    ("6", 88, 0), ("7", 103, 0), ("8", 118, 0), ("9", 132, 0), ("0", 147, 0),
    ("minus", 162, 0), ("equal", 176, 0), ("backspace", 198, 0), ("delete", 224, 0),
    ("tab", 4, 16), ("q", 22, 16), ("w", 37, 16), ("e", 51, 16), ("r", 66, 16), ("t", 81, 16),
    ("y", 95, 16), ("u", 110, 16), ("i", 125, 16), ("o", 140, 16), ("p", 154, 16),
    ("lbracket", 169, 16), ("rbracket", 184, 16), ("pageup", 224, 16),
    ("caps", 6, 32), ("a", 26, 32), ("s", 40, 32), ("d", 55, 32), ("f", 70, 32), ("g", 84, 32),
    ("h", 99, 32), ("j", 114, 32), ("k", 129, 32), ("l", 143, 32), ("semicolon", 158, 32),
    ("quote", 173, 32), ("hash", 187, 32), ("enter", 204, 24), ("pagedown", 224, 32),
    ("lshift", 2, 48), ("iso_backslash", 18, 48), ("z", 33, 48), ("x", 48, 48), ("c", 62, 48),
    ("v", 77, 48), ("b", 92, 48), ("n", 106, 48), ("m", 121, 48), ("comma", 136, 48),
    ("dot", 151, 48), ("slash", 165, 48), ("rshift", 187, 48), ("up", 209, 48),
    ("lctrl", 2, 64), ("lgui", 20, 64), ("lalt", 39, 64), ("space", 94, 64), ("ralt", 147, 64),
    ("fn", 162, 64), ("rctrl", 178, 64), ("left", 195, 64), ("down", 209, 64), ("right", 224, 64),
]
INDEX = {name: i for i, (name, _, _) in enumerate(KEYS)}
# Physical key rectangles (x, y, w, h) in key units, same order as KEYS (ISO layout).
GEOMETRY = [
    (0, 0, 1, 1), (1, 0, 1, 1), (2, 0, 1, 1), (3, 0, 1, 1), (4, 0, 1, 1), (5, 0, 1, 1),
    (6, 0, 1, 1), (7, 0, 1, 1), (8, 0, 1, 1), (9, 0, 1, 1), (10, 0, 1, 1), (11, 0, 1, 1),
    (12, 0, 1, 1), (13, 0, 2, 1), (15.25, 0, 1, 1), (0, 1, 1.5, 1), (1.5, 1, 1, 1), (2.5, 1, 1, 1),
    (3.5, 1, 1, 1), (4.5, 1, 1, 1), (5.5, 1, 1, 1), (6.5, 1, 1, 1), (7.5, 1, 1, 1), (8.5, 1, 1, 1),
    (9.5, 1, 1, 1), (10.5, 1, 1, 1), (11.5, 1, 1, 1), (12.5, 1, 1, 1), (15.25, 1, 1, 1), (0, 2, 1.75, 1),
    (1.75, 2, 1, 1), (2.75, 2, 1, 1), (3.75, 2, 1, 1), (4.75, 2, 1, 1), (5.75, 2, 1, 1), (6.75, 2, 1, 1),
    (7.75, 2, 1, 1), (8.75, 2, 1, 1), (9.75, 2, 1, 1), (10.75, 2, 1, 1), (11.75, 2, 1, 1), (12.75, 2, 1, 1),
    (13.75, 1, 1.25, 2), (15.25, 2, 1, 1), (0, 3, 1.25, 1), (1.25, 3, 1, 1), (2.25, 3, 1, 1), (3.25, 3, 1, 1),
    (4.25, 3, 1, 1), (5.25, 3, 1, 1), (6.25, 3, 1, 1), (7.25, 3, 1, 1), (8.25, 3, 1, 1), (9.25, 3, 1, 1),
    (10.25, 3, 1, 1), (11.25, 3, 1, 1), (12.25, 3, 2, 1), (14.25, 3, 1, 1), (0, 4, 1.25, 1), (1.25, 4, 1.25, 1),
    (2.5, 4, 1.25, 1), (3.75, 4, 6.25, 1), (10, 4, 1, 1), (11, 4, 1, 1), (12, 4, 1.25, 1), (13.25, 4, 1, 1),
    (14.25, 4, 1, 1), (15.25, 4, 1, 1),
]
KEYBOARD_WIDTH = 16.25
# Switch matrix (row, col) of each LED, same order as KEYS. Rows 0-3 have one key per column, so
# the matrix is a crisp 15 x 5 pixel grid (rows are staggered, so text leans slightly).
MATRIX = [(0, c) for c in range(15)] + [(1, c) for c in (*range(13), 14)] + [(2, c) for c in range(15)] \
    + [(3, c) for c in range(14)] + [(4, c) for c in (0, 1, 2, 5, 9, 10, 11, 12, 13, 14)]
GRID_COLUMNS = 15
# Straightened grid: 16 one-key-wide columns on the physical layout; a key reads every pixel whose
# centre lies under it. Halves the Caps row stagger; the Tab row keeps its half-key offset.
STRAIGHT_COLUMNS = 16
STRAIGHT_SOURCES = [
    [(row, col) for row in range(int(y), int(y + h)) for col in range(STRAIGHT_COLUMNS) if x <= col + 0.5 < x + w]
    for x, y, w, h in GEOMETRY
]
# Grid pixels read by keys that do not sit on a single grid cell.
GRID_SOURCES = {INDEX["enter"]: [(1, 13), (2, 13)], INDEX["space"]: [(4, 6)]}
STRAIGHT_SOURCES[INDEX["space"]] = [(4, 6)]
NAMED_COLORS = {
    "black": "000000", "white": "ffffff", "red": "ff0000", "green": "00ff00", "blue": "0000ff",
    "yellow": "ffff00", "cyan": "00ffff", "magenta": "ff00ff", "orange": "ff8000", "purple": "8000ff",
}


def parse_color(text):
    hexa = NAMED_COLORS.get(text.lower(), text.lstrip("#"))
    if len(hexa) != 6:
        raise argparse.ArgumentTypeError(f"couleur invalide : {text!r} (attendu #rrggbb ou un nom)")
    return tuple(int(hexa[i : i + 2], 16) for i in (0, 2, 4))


def parse_keys(text):
    names = text.split(",") if "," in text or text.lower() in INDEX else list(text)
    unknown = [n for n in names if n.lower() not in INDEX]
    if unknown:
        raise argparse.ArgumentTypeError(f"touches inconnues : {unknown}. Connues : {', '.join(INDEX)}")
    return [INDEX[n.lower()] for n in names]


class Keyboard:
    def __init__(self):
        path = next(
            (d["path"] for d in hid.enumerate(VID, PID) if d["usage_page"] == USAGE_PAGE and d["usage"] == USAGE),
            None,
        )
        if path is None:
            sys.exit("Ducky introuvable : firmware QMK hostrgb flashé et clavier branché ?")
        self.dev = hid.device()
        self.dev.open_path(path)

    def command(self, *payload):
        self.dev.write(b"\x00" + bytes(payload).ljust(REPORT_SIZE, b"\x00"))
        deadline = time.monotonic() + 1.0
        while True:
            remaining = int((deadline - time.monotonic()) * 1000)
            reply = self.dev.read(REPORT_SIZE, remaining) if remaining > 0 else None
            if not reply:
                raise RuntimeError(f"commande 0x{payload[0]:02x} sans réponse")
            if reply[0] == payload[0]:
                break  # earlier replies belong to a command interrupted before its read
        if reply[1] != 0:
            raise RuntimeError(f"commande 0x{payload[0]:02x} refusée : {reply}")
        return reply

    def ping(self):
        reply = self.command(CMD_PING)
        return reply[2], reply[3]

    def host_mode(self, on):
        self.command(CMD_MODE, int(on))

    def fill(self, rgb):
        self.host_mode(True)
        self.command(CMD_FILL, *rgb)

    def send_frame(self, frame):
        """frame: one (r, g, b) per LED; host mode must already be on."""
        for first in range(0, len(frame), MAX_LEDS_PER_REPORT):
            chunk = frame[first : first + MAX_LEDS_PER_REPORT]
            self.command(CMD_SET, first, len(chunk), *[c for rgb in chunk for c in rgb])

    def set_leds(self, colors):
        """colors: {led_index: (r, g, b)}; consecutive indices are batched per report."""
        self.host_mode(True)
        indices = sorted(colors)
        start = 0
        while start < len(indices):
            end = start + 1
            while (
                end < len(indices)
                and indices[end] == indices[end - 1] + 1
                and end - start < MAX_LEDS_PER_REPORT
            ):
                end += 1
            run = indices[start:end]
            flat = [c for i in run for c in colors[i]]
            self.command(CMD_SET, run[0], len(run), *flat)
            start = end


def text_frame(columns, offset, color_at):
    """Light each key by the share of its rectangle covered by lit text pixels.

    Text pixel (column c, row r) covers x in [c - offset, c - offset + 1) and y in [r, r + 1), in
    key units. Wide keys (space, enter) light fully once one whole pixel falls inside them.
    """
    frame = []
    for x, y, w, h in GEOMETRY:
        covered = 0.0
        for row in range(int(y), int(y + h)):
            for c in range(math.floor(x + offset), math.ceil(x + w + offset)):
                if 0 <= c < len(columns) and columns[c][row]:
                    covered += max(0.0, min(x + w, c - offset + 1) - max(x, c - offset))
        level = min(1.0, covered / (min(w, 1) * min(h, 1)))
        frame.append(tuple(round(v * level) for v in color_at(x + w / 2)))
    return frame


def grid_frame(columns, offset, color_at, wrap=False, straight=False):
    """Crisp rendering: text column c sits on grid column c - offset; keys are fully on or off.
    With wrap, the text repeats end to end like a ribbon."""

    def pixel(row, col):
        c = col + offset
        if wrap:
            return columns[c % len(columns)][row]
        return 0 <= c < len(columns) and columns[c][row]

    frame = []
    for i, (x, _, w, _) in enumerate(GEOMETRY):
        sources = STRAIGHT_SOURCES[i] if straight else GRID_SOURCES.get(i, [MATRIX[i]])
        lit = any(pixel(row, col) for row, col in sources)
        frame.append(tuple(round(v) for v in color_at(x + w / 2)) if lit else (0, 0, 0))
    return frame


def scroll_text(kb, text, color, rainbow, speed, loops, fps, smooth, ribbon=False, straight=False):
    columns = text_columns(text)
    if ribbon:
        columns += [[False] * 5] * 2  # gap between repetitions
    start_offset = -KEYBOARD_WIDTH if smooth else -(STRAIGHT_COLUMNS if straight else GRID_COLUMNS)
    kb.host_mode(True)
    frames, started = 0, time.monotonic()
    try:
        loop = 0
        while loops == 0 or loop < loops:
            loop_start = time.monotonic()
            offset = start_offset
            while ribbon or offset <= len(columns):
                frame_start = time.monotonic()
                if rainbow:
                    hue0 = (frame_start - started) * 0.15

                    def color_at(x):
                        r, g, b = colorsys.hsv_to_rgb((hue0 + x / KEYBOARD_WIDTH) % 1.0, 1.0, 1.0)
                        return (r * 255, g * 255, b * 255)
                else:
                    def color_at(x):
                        return color
                if smooth:
                    kb.send_frame(text_frame(columns, offset, color_at))
                else:
                    kb.send_frame(grid_frame(columns, offset, color_at, wrap=ribbon, straight=straight))
                frames += 1
                time.sleep(max(0.0, 1 / fps - (time.monotonic() - frame_start)))
                travelled = (time.monotonic() - loop_start) * speed
                offset = start_offset + (travelled if smooth else math.floor(travelled))
            loop += 1
    except KeyboardInterrupt:
        pass
    finally:
        kb.host_mode(False)
        elapsed = time.monotonic() - started
        print(f"{frames} images en {elapsed:.1f} s ({frames / max(elapsed, 1e-6):.0f} images/s)")


def main():
    parser = argparse.ArgumentParser(prog="ducky-rgb", description="RGB du Ducky One 2 SF (firmware QMK hostrgb)")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ping", help="vérifier la liaison avec le clavier")
    p = sub.add_parser("solid", help="toutes les touches d'une couleur")
    p.add_argument("color", type=parse_color)
    p = sub.add_parser("key", help="une touche (les autres ne changent pas)")
    p.add_argument("name", type=parse_keys)
    p.add_argument("color", type=parse_color)
    p = sub.add_parser("keys", help="plusieurs touches : 'wasd' ou 'esc,enter,space'")
    p.add_argument("names", type=parse_keys)
    p.add_argument("color", type=parse_color)
    p = sub.add_parser("gradient", help="dégradé horizontal de gauche à droite")
    p.add_argument("left", type=parse_color)
    p.add_argument("right", type=parse_color)
    p = sub.add_parser("text", help="texte défilant (Ctrl-C pour arrêter), puis retour aux effets")
    p.add_argument("text")
    p.add_argument("--color", type=parse_color, default=(255, 255, 255))
    p.add_argument("--rainbow", action="store_true", help="arc-en-ciel qui glisse")
    p.add_argument("--speed", type=float, default=4.0, help="colonnes par seconde (défaut 4)")
    p.add_argument("--loops", type=int, default=1, help="nombre de passages, 0 = infini")
    p.add_argument("--fps", type=float, default=40.0)
    p.add_argument("--smooth", action="store_true", help="rendu physique anti-aliasé (plus fluide, moins lisible)")
    p.add_argument("--ribbon", action="store_true", help="ruban continu sans fin (Ctrl-C pour arrêter)")
    p.add_argument("--straight", action="store_true", help="grille calée sur la position physique (moins penché)")
    sub.add_parser("off", help="tout éteindre")
    sub.add_parser("effects", help="rendre la main aux effets du firmware")
    args = parser.parse_args()

    kb = Keyboard()
    if args.cmd == "ping":
        version, count = kb.ping()
        print(f"OK : protocole v{version}, {count} LEDs")
    elif args.cmd == "solid":
        kb.fill(args.color)
    elif args.cmd == "off":
        kb.fill((0, 0, 0))
    elif args.cmd in ("key", "keys"):
        targets = args.name if args.cmd == "key" else args.names
        kb.set_leds({i: args.color for i in targets})
    elif args.cmd == "gradient":
        colors = {}
        for i, (_, x, _) in enumerate(KEYS):
            t = x / 224
            colors[i] = tuple(round(a + (b - a) * t) for a, b in zip(args.left, args.right))
        kb.set_leds(colors)
    elif args.cmd == "text":
        scroll_text(kb, args.text, args.color, args.rainbow, args.speed, args.loops, args.fps, args.smooth, args.ribbon, args.straight)
    elif args.cmd == "effects":
        kb.host_mode(False)


if __name__ == "__main__":
    main()
