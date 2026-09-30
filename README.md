# ducky-rgb

Per-key RGB control of a **Ducky One 2 SF (DKON1967ST)** from macOS.

The stock Ducky firmware accepts no lighting commands from the host (its only host-to-device
report is the 1-byte keyboard LED report), so this project replaces it with QMK:

- `firmware/qmk_firmware`: submodule pointing to the `ducky-sf-rgb` branch of a QMK fork, which adds
  an RGB matrix driver for the keyboard's LED drivers and a `hostrgb` keymap with a raw HID protocol
  and a lighting setup saved in flash;
- `host/ducky_rgb.py`: a small CLI that talks to that keymap over raw HID;
- `app/`: a native macOS app (menu bar + editor, presets, audio-reactive equaliser).

Tested on hardware (ISO board, stock firmware V1.12 replaced): colours, per-key mapping, gradients,
typing, saved setup across replugs, the app and its audio mode.

## Hardware notes

Recovered by disassembling the stock V1.12 firmware (plaintext inside Ducky's updater), cross-checked
against the One 2 Mini firmware and an earlier QMK driver for that board.

| Item | Value |
|---|---|
| MCU | Nuvoton NUC123SD4AN0 (Cortex-M0, 68 KB flash), USB `0416:0123` on stock firmware |
| Bootloader | Nuvoton ISP over HID, `0416:3F00`; hold **D** while plugging in |
| LED drivers | 3 x MBI5043GP, one per colour, 15 channels used |
| Serial data R / G / B | PB14 / PB13 / PB12 |
| DCLK / LE | PD4 / PD3 |
| GCLK | PWM0 on PA12, ~2 MHz |
| LED rows (active high) | PC4, PC5, PB3, PB2, PD8 (the One 2 Mini uses PD9) |
| LED power | PD5, active low |
| LED position | same (row, column) as the switch matrix, 5 x 15 |

Refresh sequence (per row): for each of the 15 columns, shift 16 bits MSB first on the three data
lines with LE high over the last DCLK edge (data latch); then 2 DCLKs, LE high over 3 DCLKs (global
latch); then switch the next row on. The QMK driver runs it from a hardware timer every 512 us (TIMER1 in firmware v2: the NUC123 flash driver clears the TIMER0 clock after every flash write).

The NUC123 (AN) USB driver exposes only two endpoints, so `hostrgb` shares the keyboard endpoint
(`KEYBOARD_SHARED_EP`) and uses a single endpoint number for raw HID IN and OUT.

## Build and flash

Requires the QMK CLI and [`nu-isp-cli`](https://github.com/elfmimi/nu-isp-rs).

```sh
git clone --recursive https://github.com/Akkamir/ducky-rgb
cd ducky-rgb/firmware/qmk_firmware
qmk compile -kb ducky/one2sf/1967st/iso -km hostrgb
# unplug, hold D, plug in: the keyboard enumerates as 0416:3F00
nu-isp-cli flash ducky_one2sf_1967st_iso_hostrgb.bin
```

Flashing rewrites the whole APROM, including the saved lighting setup: re-apply it afterwards.

`builds/` holds the binaries that were validated on hardware:

| File | SHA-256 |
|---|---|
| `ducky_one2sf_1967st_iso_hostrgb.bin` (RGB, raw HID protocol v2, saved setup) | `8273a6d68ce0309c61a7b9f85282dd7b3eac9ddf5f921d9d6bd38b2c7d14ecb1` |
| `ducky_one2sf_1967st_iso_default.bin` (upstream QMK, no RGB) | `0aa26c0664ba77444df447613c159ad47ac65f7963dbeab94df55d0d7bf003bb` |

`nu-isp-cli` only rewrites APROM; the chip always boots its LDROM bootloader first, so a bad flash is
recoverable by holding D while plugging in.

### Back to the stock firmware

Run Ducky's official updater on Windows (hold D, plug in, click OK):
`https://cdn.shopify.com/s/files/1/0728/4382/1295/files/Ducky_One2_SF_V1.12.exe`
(SHA-256 `b58cd7dd7ee87e3962b317627baa9c7416d448c2280df0ec70b5177700998ee5`).

## CLI

```sh
python3 -m venv .venv && .venv/bin/pip install hidapi
./ducky-rgb ping                   # protocol version and LED count
./ducky-rgb solid "#ff0066"
./ducky-rgb key esc white
./ducky-rgb keys wasd red          # key names are QWERTY positions
./ducky-rgb gradient red blue
./ducky-rgb off
./ducky-rgb effects                # hand the LEDs back to the firmware effect
./ducky-rgb text "HELLO"           # scrolling text, then back to the effect
./ducky-rgb text "PD" --ribbon --rainbow --speed 3   # endless ribbon, Ctrl-C to stop
```

Scrolling text uses a 3x5 font on the 5 key rows at ~38 frames/s. Three renderings were compared on
the board: the default maps text pixels onto the switch matrix (row k-th key = column k), which is the
most readable; letters lean slightly because the rows are staggered. `--straight` samples the physical
key positions instead and `--smooth` anti-aliases by key coverage; both read worse on hardware.

`tools/detect.py` reports whether the keyboard is on the stock firmware, in the bootloader, or absent.

### Raw HID protocol

Protocol v2: 32-byte reports on usage page `0xFF60` / usage `0x61`. Byte 0 is the command, arguments
follow; the reply echoes the command with byte 1 = status (0 ok, 1 unknown command, 2 bad argument,
3 flash write failed) and the payload from byte 2.

| Command | Request | Effect |
|---|---|---|
| `0x01` ping | `[0x01]` | payload `version, led_count` |
| `0x02` mode | `[0x02, on]` | 1: host colours replace the lighting; 0: back to it (1.5 s fade-in) |
| `0x03` set | `[0x03, first, count, r, g, b, ...]` | host colours, up to 9 LEDs per report |
| `0x04` fill | `[0x04, r, g, b]` | host colour for every LED |
| `0x10` info | `[0x10]` | payload `version, led_count, effect_count, persistent` |
| `0x11` effects | `[0x11, first]` | payload `first, count, ids...` (up to 28) |
| `0x12` state | `[0x12]` | payload `enabled, effect, h, s, v, speed, host_mode, custom_count, dirty` |
| `0x13` base | `[0x13, enabled, effect, h, s, v, speed]` | base effect, in RAM |
| `0x14` get overlay | `[0x14, first]` | payload `first, count, (flags, r, g, b)...` (up to 7) |
| `0x15` set overlay | `[0x15, first, count, (flags, r, g, b)...]` | per-key colours (flags bit 0 = custom), in RAM |
| `0x16` clear overlay | `[0x16]` | no custom colours, in RAM |
| `0x17` save | `[0x17]` | writes the base and the per-key colours to flash |

Host colours are never saved. Effects 1-14 are QMK's; 15 is the typing heatmap over the base colour,
16 the typing heatmap over the per-key colours. Details: `docs/superpowers/specs/2026-09-30-ducky-rgb-app-design.md`.

## macOS app (v1, firmware v2 required)

`app/` is a native SwiftUI app: a menu bar extra (presets, on/off, brightness, speed, effect) and a
window with a keyboard editor (base effect and per-key colours with brush/eraser), a preset library
and settings (launch at login, Dock icon). Edits reach the keyboard immediately and are saved in the
keyboard's flash 2 s after the last change, so the lighting survives a replug with the app closed.

```sh
cd app
swift test                 # protocol, layout, presets, controller, audio (simulated keyboard)
scripts/bundle.sh          # builds app/build/Ducky RGB.app (ad hoc signed)
open "build/Ducky RGB.app"
```

**Audio mode** (menu bar, macOS 14.2+): while armed and the Mac plays sound (headphones included),
the keyboard shows a 15-band equaliser of the system audio, captured with a Core Audio process tap
(macOS asks for the audio capture permission on first use). Five palettes: classic, ocean, sunset,
neon, fire. After 3 s of silence, while the editor window is active, or when disarmed, the keyboard
shows the saved lighting again. Audio frames go through the host mode and are never saved.

It needs the firmware v2 `hostrgb` keymap (protocol v2 + wear-leveled EEPROM). The CLI's `info`,
`state`, `base`, `paint`, `unpaint`, `clear-overlay` and `save` commands exercise the same protocol.

## Known limitations

- ISO layout only (no `rgb_matrix` layout for the ANSI variant yet).
- LED power (PD5) is not cut during USB suspend; rgb_matrix only blanks the LEDs.
- `QK_BOOT` resets the keyboard instead of entering the bootloader; hold D while plugging in.
- macOS stores modifier remaps per USB VID/PID: QMK uses `445B:07AE`, so remaps made for the stock
  keyboard must be redone.
