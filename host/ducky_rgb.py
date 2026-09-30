#!/usr/bin/env python3
"""ducky-rgb: drive the Ducky One 2 SF LEDs (QMK `hostrgb` keymap) from macOS over raw HID.

Protocol (32-byte reports, byte 0 = command, reply byte 1 = status):
  0x01 PING               -> [0x01, 0, version, led_count]
  0x02 MODE on            host colours replace the firmware effect (0 = back to the effect)
  0x03 SET first n rgb*n  up to 9 LEDs per report
  0x04 FILL r g b
"""
import argparse
import sys

import hid

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
        reply = self.dev.read(REPORT_SIZE, 1000)
        if not reply or reply[0] != payload[0] or reply[1] != 0:
            raise RuntimeError(f"commande 0x{payload[0]:02x} refusée ou sans réponse : {reply}")
        return reply

    def ping(self):
        reply = self.command(CMD_PING)
        return reply[2], reply[3]

    def host_mode(self, on):
        self.command(CMD_MODE, int(on))

    def fill(self, rgb):
        self.host_mode(True)
        self.command(CMD_FILL, *rgb)

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
    elif args.cmd == "effects":
        kb.host_mode(False)


if __name__ == "__main__":
    main()
