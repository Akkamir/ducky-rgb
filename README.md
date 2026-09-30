# ducky-rgb

Per-key RGB control of a **Ducky One 2 SF (DKON1967ST)** from macOS.

The stock Ducky firmware accepts no lighting commands from the host (its only host-to-device
report is the 1-byte keyboard LED report), so this project replaces it with QMK:

- `firmware/qmk_firmware`: submodule pointing to the `ducky-sf-rgb` branch of a QMK fork, which adds
  an RGB matrix driver for the keyboard's LED drivers and a `hostrgb` keymap with a raw HID protocol;
- `host/ducky_rgb.py`: a small CLI that talks to that keymap over raw HID.

Tested on hardware (ISO board, stock firmware V1.12 replaced): colours, per-key mapping, gradients,
typing.

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
latch); then switch the next row on. The QMK driver runs it from TIMER0 every 512 us.

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

`builds/` holds the binaries that were validated on hardware:

| File | SHA-256 |
|---|---|
| `ducky_one2sf_1967st_iso_hostrgb.bin` (RGB + raw HID) | `c0ca027c07c815b3b0e09d448c368422829eeca6a3218cb95af54e8229091e45` |
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
```

`tools/detect.py` reports whether the keyboard is on the stock firmware, in the bootloader, or absent.

### Raw HID protocol

32-byte reports on usage page `0xFF60` / usage `0x61`. Byte 0 is the command; the reply echoes it
with byte 1 = status (0 ok, `0xFF` error).

| Command | Request | Effect |
|---|---|---|
| `0x01` ping | `[0x01]` | reply `[0x01, 0, version, led_count]` |
| `0x02` mode | `[0x02, on]` | 1: host colours replace the effect; 0: back to the effect |
| `0x03` set | `[0x03, first, count, r, g, b, ...]` | up to 9 LEDs per report |
| `0x04` fill | `[0x04, r, g, b]` | every LED |

Host colours are not persisted: after a replug the keyboard shows its saved effect again.

## Known limitations

- ISO layout only (no `rgb_matrix` layout for the ANSI variant yet).
- LED power (PD5) is not cut during USB suspend; rgb_matrix only blanks the LEDs.
- `QK_BOOT` resets the keyboard instead of entering the bootloader; hold D while plugging in.
- macOS stores modifier remaps per USB VID/PID: QMK uses `445B:07AE`, so remaps made for the stock
  keyboard must be redone.
