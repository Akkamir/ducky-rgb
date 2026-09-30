"""Protocol v2 tests against a simulated keyboard that mirrors the firmware checks."""
import unittest

import ducky_rgb as d


class FakeKeyboard:
    """Implements the firmware side of protocol v2 (hostrgb_protocol.c) for tests."""

    def __init__(self):
        self.effects = list(range(1, 17))
        self.base = [1, 5, 0, 255, 200, 128]
        self.overlay = [None] * 68
        self.saved = None
        self.dirty = False
        self.pending = None

    def write(self, buf):
        req = list(buf[1:])
        out = [req[0], 0] + [0] * 30
        cmd = req[0]

        def bad():
            out[1] = 2

        if cmd == 0x01:
            out[2:4] = [2, 68]
        elif cmd == 0x10:
            out[2:6] = [2, 68, len(self.effects), 1]
        elif cmd == 0x11:
            first = req[1]
            ids = self.effects[first:first + 28]
            out[2:4 + len(ids)] = [first, len(ids)] + ids
        elif cmd == 0x12:
            count = sum(c is not None for c in self.overlay)
            out[2:11] = self.base + [0, count, int(self.dirty)]
        elif cmd == 0x13:
            if req[2] not in self.effects:
                bad()
            else:
                self.base = [int(req[1] != 0)] + req[2:7]
                self.dirty = True
        elif cmd == 0x14:
            first = req[1]
            if first >= 68:
                bad()
            else:
                count = min(7, 68 - first)
                out[2], out[3] = first, count
                for i in range(count):
                    c = self.overlay[first + i]
                    out[4 + 4 * i:8 + 4 * i] = [1, *c] if c else [0, 0, 0, 0]
        elif cmd == 0x15:
            first, count = req[1], req[2]
            if count > 7 or first + count > 68:
                bad()
            else:
                for i in range(count):
                    e = req[3 + 4 * i:7 + 4 * i]
                    self.overlay[first + i] = tuple(e[1:]) if e[0] & 1 else None
                self.dirty = True
        elif cmd == 0x16:
            self.overlay = [None] * 68
            self.dirty = True
        elif cmd == 0x17:
            self.saved = (list(self.base), list(self.overlay))
            self.dirty = False
        else:
            out[1] = 1
        self.pending = out

    def read(self, n, timeout):
        reply, self.pending = self.pending, None
        return reply


def keyboard():
    kb = d.Keyboard.__new__(d.Keyboard)
    kb.dev = FakeKeyboard()
    return kb


class ProtocolV2Test(unittest.TestCase):
    def test_info_and_effects(self):
        kb = keyboard()
        self.assertEqual(kb.info(), {"version": 2, "leds": 68, "effects": 16, "persistent": True})
        self.assertEqual(kb.effects(16), list(range(1, 17)))

    def test_set_base_then_state(self):
        kb = keyboard()
        kb.set_base(enabled=False, effect=2, hue=10, sat=20, val=30, speed=40)
        state = kb.state()
        self.assertEqual(state["base"], {"enabled": False, "effect": 2, "hue": 10, "sat": 20, "val": 30, "speed": 40})
        self.assertTrue(state["dirty"])

    def test_overlay_round_trip_and_save(self):
        kb = keyboard()
        colors = [None] * 68
        colors[0], colors[67] = (255, 0, 0), (0, 0, 255)
        kb.set_overlay(colors)
        self.assertEqual(kb.overlay(), colors)
        kb.save()
        self.assertFalse(kb.state()["dirty"])
        self.assertEqual(kb.dev.saved[1], colors)

    def test_set_overlay_rejects_overflow(self):
        kb = keyboard()
        with self.assertRaises(RuntimeError):
            kb.command(0x15, 65, 7, *([1, 1, 1, 1] * 7))

    def test_unknown_effect_is_rejected(self):
        kb = keyboard()
        with self.assertRaises(RuntimeError):
            kb.set_base(enabled=True, effect=99, hue=0, sat=0, val=0, speed=0)


if __name__ == "__main__":
    unittest.main()
