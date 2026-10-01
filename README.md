# ducky-rgb

Control the lights of a **Ducky One 2 SF** keyboard from your Mac: pick colours and effects, paint
individual keys, save your favourite looks, and let the keyboard dance to the music you play.

Out of the box, this keyboard's lights can only be changed with key combinations on the keyboard
itself; there is no Mac app, and the keyboard ignores the computer. This project gives it a new
brain (open-source firmware) that listens to the Mac, plus a small Mac app to drive it.

## What you get

- **A menu bar app**: presets in one click, on/off, brightness, speed, effect.
- **A keyboard editor**: choose a background effect, then paint any key in any colour.
- **Presets**: built-in looks (rainbow, soft white breathing, night, gaming WASD keys, ocean
  heatmap...) and your own.
- **Music mode**: the keyboard becomes an equaliser that follows whatever your Mac plays, headphones
  included, with five colour palettes. When the music stops, your normal lighting fades back in.
- **Typing heatmaps**: keys light up as you type them.
- **Claude Code status lights**: Delete, Page Up and Page Down show up to three Claude Code sessions
  (idle, thinking, waiting for you, answered, error), on top of any lighting; Fn + the key brings that
  session's Terminal tab to the front.
- **It sticks**: your lighting is stored inside the keyboard, so it stays the same after unplugging,
  on any computer, even with the app closed.

## Is it for me?

| You need | Details |
|---|---|
| A Ducky One 2 SF, model **DKON1967ST**, **ISO** layout | The model number is on the label under the keyboard. ISO = the European layout with a tall Enter key (UK, French AZERTY, German...). The ANSI (US) version is not supported yet. |
| A Mac with **macOS 14.2** or later | Music mode relies on a macOS 14.2 feature. |
| About 15 minutes and some comfort with the Terminal | You install two tools and copy a few commands. |
| Optional: a Windows PC | Only to go back to Ducky's original firmware one day. |

**Is it safe?** Updating the keyboard replaces its main program, never the tiny recovery program
(bootloader) that runs before it. If anything goes wrong, you can always start over by holding **D**
while plugging the keyboard in, and Ducky's official updater brings back the original firmware.
As with any firmware change, you do it at your own risk.

## Getting started

### 1. Install the tools

Install the Xcode Command Line Tools (for the app) and Rust (for the flashing tool), then the
flashing tool itself:

```sh
xcode-select --install
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
cargo install --git https://github.com/elfmimi/nu-isp-rs --rev 9c763dd nu-isp-cli
```

### 2. Put the new firmware on the keyboard

```sh
git clone https://github.com/Akkamir/ducky-rgb
cd ducky-rgb
```

1. Unplug the keyboard.
2. Hold the **D** key, plug the keyboard back in, then release **D**. The keyboard stops typing:
   it is waiting for its new firmware.
3. Run:

   ```sh
   nu-isp-cli flash builds/ducky_one2sf_1967st_iso_hostrgb.bin
   ```

4. After a few seconds the keyboard restarts and types normally again.

Good to know: macOS sees the updated keyboard as a new device, so modifier key remaps made in System
Settings (for example Cmd and Option swapped) must be done again.

### 3. Install the app

```sh
cd app
scripts/bundle.sh
open "build/Ducky RGB.app"
```

A keyboard icon appears in the menu bar. Drag `app/build/Ducky RGB.app` to your Applications folder
to keep it. The first time you turn on music mode, macOS asks for permission to capture system
audio: accept it. If your menu bar is full (MacBooks with a notch hide the extra icons), turn on
"Afficher l'icône dans le Dock" in the app's settings, or open the app from the Dock.

### 4. Optional: Claude Code status lights

In the app window, open **Agents**, click **Installer** (adds hooks to `~/.claude/settings.json`, keeping
a copy of the original as `settings.json.ducky-backup`), then **Autoriser Terminal** and accept the
macOS prompt. If you move the app, click **Réinstaller**.

## Using it

- **Menu bar icon**: presets, on/off, brightness, speed, effect, and music mode (on/off, palette).
- **"Ouvrir l'éditeur…"** (Open editor): the background effect and its colour, then a brush and an
  eraser to paint keys. The colour setting says what it changes for the chosen effect.
- **Presets**: apply, rename, duplicate, delete, or save the current look as a new preset.
- **Saving**: changes show on the keyboard at once and are stored in the keyboard two seconds later.
- **Music mode** takes over the lights only while sound plays. After 3 seconds of silence, while the
  editor is open, or when you quit the app, your saved lighting fades back in. Music mode never
  changes what is stored in the keyboard.
- **Agents**: every running Claude Code session is listed. Sessions take Delete, Page Up and Page Down
  in the order they start; pick another key or "Aucune" to rearrange. Colours: white idle, blue
  thinking (breathing), orange waiting for your approval or answer (breathing), green answered and not
  read yet, red error. Fn + the key opens the session's Terminal.app tab (for a background session, the
  tab running `claude attach`). The lights go off a few seconds after the app quits.

The app is in French for now.

### Going back to Ducky's original firmware

Run Ducky's official updater on a Windows PC (hold D, plug in, click OK):
`https://cdn.shopify.com/s/files/1/0728/4382/1295/files/Ducky_One2_SF_V1.12.exe`
(SHA-256 `b58cd7dd7ee87e3962b317627baa9c7416d448c2280df0ec70b5177700998ee5`).

## Known limitations

- ISO layout only (no `rgb_matrix` layout for the ANSI variant yet).
- Every firmware update erases the lighting stored in the keyboard: apply a preset again afterwards.
- The Fn + key shortcut that normally enters update mode (`QK_BOOT`) only restarts the keyboard; hold
  D while plugging in instead.
- LED power (PD5) is not cut during USB suspend; the LEDs are only blanked.
- Fn + Page Up / Page Down are the agent keys, so Home and End are only on Fn + [ and Fn + ' (QWERTY
  positions).
- Agent status lights follow Claude Code sessions in Terminal.app only, and are hidden while the
  lighting is switched off with Fn + the lighting toggle.

---

# Technical details

## Repository layout

- `firmware/qmk_firmware`: submodule pointing to the `ducky-sf-rgb` branch of a QMK fork, which adds
  an RGB matrix driver for the keyboard's LED drivers and a `hostrgb` keymap with a raw HID protocol
  and a lighting setup saved in flash (wear-leveled EEPROM emulation).
- `builds/`: firmware binaries validated on hardware.
- `app/`: the macOS app (SwiftUI, Swift Package Manager).
- `host/ducky_rgb.py`: a command-line tool speaking the same protocol.
- `tools/detect.py`: reports whether the keyboard is on the stock firmware, in the bootloader, or absent.

Why a new firmware: the stock Ducky firmware accepts no lighting commands from the host (its only
host-to-device report is the 1-byte keyboard LED report).

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
latch); then switch the next row on. The QMK driver runs it from a hardware timer every 512 us
(TIMER1: the NUC123 flash driver clears the TIMER0 clock after every flash write).

The NUC123 (AN) USB driver exposes only two endpoints, so `hostrgb` shares the keyboard endpoint
(`KEYBOARD_SHARED_EP`) and uses a single endpoint number for raw HID IN and OUT.

The saved setup lives in the last 2 KB of the 64 KB APROM (0xF800-0xFFFF). LDROM and CONFIG are never
written.

## Building the firmware

Requires the QMK CLI (`brew install qmk/qmk/qmk && qmk setup`) and `nu-isp-cli` (see above).

```sh
git clone --recursive https://github.com/Akkamir/ducky-rgb
cd ducky-rgb/firmware/qmk_firmware
qmk compile -kb ducky/one2sf/1967st/iso -km hostrgb
# unplug, hold D, plug in: the keyboard enumerates as 0416:3F00
nu-isp-cli flash ducky_one2sf_1967st_iso_hostrgb.bin
```

`nu-isp-cli` only rewrites APROM (including the saved lighting setup); the chip always boots its
LDROM bootloader first, so a bad flash is recoverable by holding D while plugging in.

| Binary in `builds/` | SHA-256 |
|---|---|
| `ducky_one2sf_1967st_iso_hostrgb.bin` (RGB, raw HID protocol v3, saved setup) | `87f7f71eb7c872bd975f8c05cde68b39a1634ce26b7c0de05321a15f3ba2fdbe` |
| `ducky_one2sf_1967st_iso_default.bin` (upstream QMK, no RGB) | `0aa26c0664ba77444df447613c159ad47ac65f7963dbeab94df55d0d7bf003bb` |

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

`info`, `state`, `base`, `paint`, `unpaint`, `clear-overlay` and `save` use the saved-setup commands
of the protocol.

Scrolling text uses a 3x5 font on the 5 key rows at ~38 frames/s. Three renderings were compared on
the board: the default maps text pixels onto the switch matrix (row k-th key = column k), which is the
most readable; letters lean slightly because the rows are staggered. `--straight` samples the physical
key positions instead and `--smooth` anti-aliases by key coverage; both read worse on hardware.

## Raw HID protocol

Protocol v3: 32-byte reports on usage page `0xFF60` / usage `0x61`. Byte 0 is the command, arguments
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
| `0x18` indicators | `[0x18, count, (led, r, g, b, mode)...]` | up to 3 status LEDs above everything (mode 1 = breathing); cleared after 5 s without a refresh |

Host colours and indicators are never saved. Effects 1-14 are QMK's; 15 is the typing heatmap over the
base colour, 16 the typing heatmap over the per-key colours. The keyboard also sends an unsolicited
report `[0x30, 0xA5, slot]` for Fn + Delete / Page Up / Page Down (slots 0-2); `0xA5` is never a
status, so it cannot be mistaken for a reply.

## App internals

`app/` is a Swift package: `DuckyCore` (protocol, IOKit HID transport, layout, presets, lighting
controller, audio analysis and capture) and the `DuckyRGB` SwiftUI executable. Edits are sent at once
and saved 2 s after the last change. Music mode captures system audio with a Core Audio process tap,
analyses 15 log-spaced bands (40 Hz to 16 kHz) with automatic gain, and streams frames through the
host mode at ~30 frames/s; frames are never saved.

Agent status: Claude Code runs `ducky-agent-hook` (bundled in the app) on each hook event; it finds the
Claude process and its terminal, then updates one JSON file per session in
`~/Library/Application Support/Ducky RGB/agents` under a lock. The app also reads Claude's own registry
of running sessions (`~/.claude/sessions`) to list sessions before their first event and drop replaced
ones, and the end of each transcript to notice turns interrupted with Esc (no hook fires then).

```sh
cd app
swift test                 # protocol, layout, presets, controller, audio, agents (simulated keyboard)
scripts/bundle.sh          # builds app/build/Ducky RGB.app (ad hoc signed)
```
