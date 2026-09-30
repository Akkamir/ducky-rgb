# Ducky RGB v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS app (menu bar + window) that manages the Ducky One 2 SF lighting with presets and per-key colours, backed by a firmware v2 that stores the active setup in flash.

**Architecture:** Firmware v2 (QMK keymap `hostrgb`) adds a stable raw HID protocol (base effect, per-key overlay, save) and persists the setup with QMK wear leveling on the NUC123 internal flash. The app is a Swift package: `DuckyCore` (protocol, HID transport, client, layout, presets, observable controller; UI-free and unit-tested with a simulated keyboard) and `DuckyRGB` (SwiftUI `MenuBarExtra` + `Window`), bundled into `Ducky RGB.app` by a script.

**Tech Stack:** QMK/ChibiOS (C), Python 3 + hidapi (CLI), Swift 6.3 toolchain in Swift 5 language mode (tools-version 5.10), SwiftUI, Observation, IOKit HID, ServiceManagement, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-30-ducky-rgb-app-design.md`

**Code extraction convention:** every file body in this plan is preceded by `<!-- file: <path relative to repo root> -->`. Executors may extract blocks with `scripts/extract_plan_files.py` (Task 0) instead of retyping.

## Global Constraints

- Keyboard: Ducky One 2 SF DKON1967ST ISO, 68 LEDs, USB `445B:07AE`, raw HID usage page `0xFF60`, usage `0x61`, 32-byte reports.
- Protocol v2 exactly as spec section 3 (commands `0x01`-`0x04`, `0x10`-`0x17`, statuses 0-3, payload from byte 2).
- Overlay block: `version(1) | base_on(1) | mask(9) | rgb(68x3) | checksum(2)` = 217 bytes (`EECONFIG_USER_DATA_SIZE 217`); checksum = 16-bit sum of the preceding bytes.
- Effect ids 1-14 exactly as spec table.
- Brightness capped by `RGB_MATRIX_MAXIMUM_BRIGHTNESS` 200; overlay colours scaled by `val / 255`.
- App: macOS 14+, bundle id `com.akkamir.ducky-rgb`, name "Ducky RGB", presets in `~/Library/Application Support/Ducky RGB/presets.json`, auto-save 2 s after the last change.
- UI copy in French; code, comments, commit messages in English.
- Git: firmware on submodule branch `ducky-sf-rgb-v2`, app on `app-v1`; commits signed with the repo-local noreply email; never commit `backup/`, `NOTES.md`, `CLAUDE.local.md`.
- Firmware binary must stay below 0x10800 bytes (last 2 KB of the 68 KB APROM hold the wear-leveling store).

## Review Focus

1. A burst of edits (dragging a slider, painting across keys) must produce exactly one flash write, 2 s after the last edit: `LightingControllerTests.testBurstOfChangesSavesOnce`.
2. Keyboard unplugged, replugged, or still on firmware v1: the app must say so and send nothing, then resynchronise from the keyboard on reconnect: `testOutdatedFirmwareBlocksControl`, `testReconnectRefreshesState`.
3. Out-of-range overlay/effect arguments must be rejected with status 2, never written out of bounds: `test_set_overlay_rejects_overflow` (CLI fake mirrors firmware checks) and firmware bounds checks in Task 1.
4. A corrupt or missing `presets.json` must not crash or erase anything silently: the store keeps built-ins, sets `loadError` and moves the bad file aside: `PresetStoreTests.testCorruptFileIsSetAside`.
5. An interrupted exchange (reply of an older command arriving late) must not be taken as the answer to a new command: `IOKitHIDTransport.exchange` skips mismatched replies; `KeyboardClientTests.testMismatchedReplyIsRejected` pins the decoder side.

---

### Task 0: Plan extraction helper

**Files:**
- Create: `scripts/extract_plan_files.py`

- [ ] **Step 1: Write the helper**

<!-- file: scripts/extract_plan_files.py -->
```python
#!/usr/bin/env python3
"""Write the code blocks of an implementation plan to disk.

Usage: extract_plan_files.py PLAN.md PATH [PATH ...]
Each block must be preceded by a line `<!-- file: PATH -->`; PATH is relative to the repo root.
"""
import pathlib
import re
import sys

plan, wanted = pathlib.Path(sys.argv[1]).read_text(), set(sys.argv[2:])
root = pathlib.Path(__file__).resolve().parent.parent
pattern = re.compile(r"<!-- file: (\S+) -->\n```[^\n]*\n(.*?)\n```\n", re.S)
found = {m.group(1): m.group(2) for m in pattern.finditer(plan)}
missing = wanted - found.keys()
if missing:
    sys.exit(f"not in plan: {sorted(missing)}")
for rel in sorted(wanted):
    target = root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(found[rel] + "\n")
    print("wrote", rel)
```

- [ ] **Step 2: Check it lists nothing missing for a known path**

Run: `python3 scripts/extract_plan_files.py docs/superpowers/plans/2026-09-30-ducky-rgb-app.md scripts/extract_plan_files.py`
Expected: `wrote scripts/extract_plan_files.py`

- [ ] **Step 3: Commit**

```bash
git add scripts/extract_plan_files.py docs/superpowers/plans/2026-09-30-ducky-rgb-app.md
git commit -m "Add implementation plan and plan extraction helper"
```

---

### Task 1: Firmware v2 (persistence + protocol)

Work in `firmware/qmk_firmware`, branch `ducky-sf-rgb-v2`. Paths below are relative to the ducky-rgb repo root.

**Files:**
- Modify: `firmware/qmk_firmware/keyboards/ducky/one2sf/1967st/halconf.h`
- Modify: `firmware/qmk_firmware/keyboards/ducky/one2sf/1967st/mcuconf.h`
- Create: `firmware/qmk_firmware/keyboards/ducky/one2sf/1967st/iso/keymaps/hostrgb/hostrgb_protocol.h`
- Create: `firmware/qmk_firmware/keyboards/ducky/one2sf/1967st/iso/keymaps/hostrgb/hostrgb_protocol.c`
- Replace: `firmware/qmk_firmware/keyboards/ducky/one2sf/1967st/iso/keymaps/hostrgb/keymap.c`
- Replace: `firmware/qmk_firmware/keyboards/ducky/one2sf/1967st/iso/keymaps/hostrgb/config.h`
- Replace: `firmware/qmk_firmware/keyboards/ducky/one2sf/1967st/iso/keymaps/hostrgb/rules.mk`

**Interfaces:**
- Produces: protocol v2 on the wire (spec section 3); consumed by Task 2 (CLI) and Task 6 (Swift client).

- [ ] **Step 1: Enable the embedded flash driver**

In `halconf.h`, add before `#include_next <halconf.h>`:

```c
#define HAL_USE_EFL TRUE // internal flash, backing store for wear-leveled EEPROM
```

In `mcuconf.h`, add after `#define NUC123_GPT_USE_TIMER0 TRUE`:

```c
#define NUC123_EFL_ACCESS_APROM TRUE // LDROM and CONFIG stay inaccessible: the bootloader cannot be touched
```

- [ ] **Step 2: Write the protocol header**

<!-- file: firmware/qmk_firmware/keyboards/ducky/one2sf/1967st/iso/keymaps/hostrgb/hostrgb_protocol.h -->
```c
// Copyright 2026 Akkamir
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

// Loads the saved overlay; call from keyboard_post_init_user.
void hostrgb_init(void);

// Writes an empty overlay; call from eeconfig_init_user (first boot or EEPROM reset).
void hostrgb_reset_storage(void);
```

- [ ] **Step 3: Write the protocol implementation**

<!-- file: firmware/qmk_firmware/keyboards/ducky/one2sf/1967st/iso/keymaps/hostrgb/hostrgb_protocol.c -->
```c
// Copyright 2026 Akkamir
// SPDX-License-Identifier: GPL-2.0-or-later

/*
 * Host RGB protocol v2 over raw HID (32-byte reports, usage page 0xFF60 / usage 0x61).
 * Request: byte 0 = command, arguments from byte 1. Reply: byte 0 = command, byte 1 = status,
 * payload from byte 2.
 *
 * Layers, highest first: host mode (live frames from the CLI, never saved), overlay (per-key
 * colours, saved in the user EEPROM block), base effect (rgb_matrix config, saved natively).
 * rgb_matrix only calls the indicator hooks while it is enabled, so "base off" is our own flag:
 * LEDs without a custom colour are painted black instead of disabling rgb_matrix.
 */

#include QMK_KEYBOARD_H
#include <stddef.h>
#include <string.h>
#include "raw_hid.h"
#include "eeconfig.h"
#include "hostrgb_protocol.h"

#define PROTOCOL_VERSION 2
#define OVERLAY_VERSION 1
#define HOST_LEDS_PER_REPORT 9
#define OVERLAY_PER_REPORT 7
#define EFFECTS_PER_REPORT 28

enum status {
    STATUS_OK              = 0,
    STATUS_UNKNOWN_COMMAND = 1,
    STATUS_BAD_ARGUMENT    = 2,
    STATUS_FLASH_ERROR     = 3, // reserved: QMK's EEPROM API does not report write failures
};

enum command {
    CMD_PING          = 0x01,
    CMD_MODE          = 0x02,
    CMD_SET           = 0x03,
    CMD_FILL          = 0x04,
    CMD_GET_INFO      = 0x10,
    CMD_GET_EFFECTS   = 0x11,
    CMD_GET_STATE     = 0x12,
    CMD_SET_BASE      = 0x13,
    CMD_GET_OVERLAY   = 0x14,
    CMD_SET_OVERLAY   = 0x15,
    CMD_CLEAR_OVERLAY = 0x16,
    CMD_SAVE          = 0x17,
};

// Stable ids exposed to the host; QMK mode numbers depend on which effects are compiled in.
static const struct {
    uint8_t id;
    uint8_t mode;
} effects[] = {
    {1, RGB_MATRIX_SOLID_COLOR},
    {2, RGB_MATRIX_BREATHING},
    {3, RGB_MATRIX_GRADIENT_LEFT_RIGHT},
    {4, RGB_MATRIX_CYCLE_ALL},
    {5, RGB_MATRIX_CYCLE_LEFT_RIGHT},
    {6, RGB_MATRIX_RAINBOW_MOVING_CHEVRON},
    {7, RGB_MATRIX_HUE_WAVE},
    {8, RGB_MATRIX_PIXEL_RAIN},
    {9, RGB_MATRIX_DIGITAL_RAIN},
    {10, RGB_MATRIX_SOLID_REACTIVE_SIMPLE},
    {11, RGB_MATRIX_SPLASH},
    {12, RGB_MATRIX_MULTISPLASH},
    {13, RGB_MATRIX_TYPING_HEATMAP},
    {14, RGB_MATRIX_BAND_SAT},
};
#define EFFECT_COUNT ARRAY_SIZE(effects)

typedef struct __attribute__((packed)) {
    uint8_t  version;
    uint8_t  base_on; // 0: LEDs without a custom colour stay dark
    uint8_t  mask[(RGB_MATRIX_LED_COUNT + 7) / 8];
    uint8_t  rgb[RGB_MATRIX_LED_COUNT][3];
    uint16_t checksum;
} overlay_t;

_Static_assert(sizeof(overlay_t) == EECONFIG_USER_DATA_SIZE, "EECONFIG_USER_DATA_SIZE must match overlay_t");

static overlay_t overlay;
static bool      dirty;
static bool      host_mode;
static uint8_t   host_colors[RGB_MATRIX_LED_COUNT][3];

static uint16_t overlay_checksum(const overlay_t *block) {
    const uint8_t *bytes = (const uint8_t *)block;
    uint16_t       sum   = 0;
    for (size_t i = 0; i < offsetof(overlay_t, checksum); i++) {
        sum += bytes[i];
    }
    return sum;
}

static void overlay_clear(uint8_t base_on) {
    memset(&overlay, 0, sizeof(overlay));
    overlay.version = OVERLAY_VERSION;
    overlay.base_on = base_on;
}

static bool overlay_has(uint8_t led) {
    return overlay.mask[led / 8] & (1 << (led % 8));
}

static void overlay_set(uint8_t led, bool custom, const uint8_t rgb[3]) {
    if (custom) {
        overlay.mask[led / 8] |= (1 << (led % 8));
        memcpy(overlay.rgb[led], rgb, 3);
    } else {
        overlay.mask[led / 8] &= ~(1 << (led % 8));
        memset(overlay.rgb[led], 0, 3);
    }
}

static uint8_t overlay_count(void) {
    uint8_t count = 0;
    for (uint8_t led = 0; led < RGB_MATRIX_LED_COUNT; led++) {
        count += overlay_has(led);
    }
    return count;
}

void hostrgb_reset_storage(void) {
    overlay_clear(1);
    overlay.checksum = overlay_checksum(&overlay);
    eeconfig_update_user_datablock(&overlay, 0, sizeof(overlay));
}

void hostrgb_init(void) {
    eeconfig_read_user_datablock(&overlay, 0, sizeof(overlay));
    if (overlay.version != OVERLAY_VERSION || overlay.checksum != overlay_checksum(&overlay)) {
        overlay_clear(1);
    }
    dirty = false;
}

static uint8_t effect_id_for_mode(uint8_t mode) {
    for (uint8_t i = 0; i < EFFECT_COUNT; i++) {
        if (effects[i].mode == mode) return effects[i].id;
    }
    return 0;
}

static int16_t mode_for_effect_id(uint8_t id) {
    for (uint8_t i = 0; i < EFFECT_COUNT; i++) {
        if (effects[i].id == id) return effects[i].mode;
    }
    return -1;
}

static uint8_t handle_command(uint8_t *data, uint8_t length) {
    uint8_t args[32]; // replies overwrite the request in place
    memcpy(args, data, length);
    memset(&data[1], 0, length - 1);
    uint8_t *out = &data[2];

    switch (args[0]) {
        case CMD_PING:
            out[0] = PROTOCOL_VERSION;
            out[1] = RGB_MATRIX_LED_COUNT;
            return STATUS_OK;

        case CMD_MODE:
            host_mode = args[1] != 0;
            if (host_mode) rgb_matrix_enable_noeeprom();
            return STATUS_OK;

        case CMD_SET: {
            uint8_t first = args[1], count = args[2];
            if (count > HOST_LEDS_PER_REPORT || first + count > RGB_MATRIX_LED_COUNT) return STATUS_BAD_ARGUMENT;
            memcpy(host_colors[first], &args[3], count * 3);
            return STATUS_OK;
        }

        case CMD_FILL:
            for (uint8_t led = 0; led < RGB_MATRIX_LED_COUNT; led++) {
                memcpy(host_colors[led], &args[1], 3);
            }
            return STATUS_OK;

        case CMD_GET_INFO:
            out[0] = PROTOCOL_VERSION;
            out[1] = RGB_MATRIX_LED_COUNT;
            out[2] = EFFECT_COUNT;
            out[3] = 1; // setup persisted in flash
            return STATUS_OK;

        case CMD_GET_EFFECTS: {
            uint8_t first = args[1];
            if (first > EFFECT_COUNT) return STATUS_BAD_ARGUMENT;
            uint8_t count = MIN(EFFECTS_PER_REPORT, EFFECT_COUNT - first);
            out[0]        = first;
            out[1]        = count;
            for (uint8_t i = 0; i < count; i++) {
                out[2 + i] = effects[first + i].id;
            }
            return STATUS_OK;
        }

        case CMD_GET_STATE: {
            hsv_t hsv = rgb_matrix_get_hsv();
            out[0]    = overlay.base_on;
            out[1]    = effect_id_for_mode(rgb_matrix_get_mode());
            out[2]    = hsv.h;
            out[3]    = hsv.s;
            out[4]    = hsv.v;
            out[5]    = rgb_matrix_get_speed();
            out[6]    = host_mode;
            out[7]    = overlay_count();
            out[8]    = dirty;
            return STATUS_OK;
        }

        case CMD_SET_BASE: {
            int16_t mode = mode_for_effect_id(args[2]);
            if (mode < 0) return STATUS_BAD_ARGUMENT;
            overlay.base_on = args[1] != 0;
            rgb_matrix_enable_noeeprom();
            rgb_matrix_mode_noeeprom(mode);
            rgb_matrix_sethsv_noeeprom(args[3], args[4], args[5]);
            rgb_matrix_set_speed_noeeprom(args[6]);
            dirty = true;
            return STATUS_OK;
        }

        case CMD_GET_OVERLAY: {
            uint8_t first = args[1];
            if (first >= RGB_MATRIX_LED_COUNT) return STATUS_BAD_ARGUMENT;
            uint8_t count = MIN(OVERLAY_PER_REPORT, RGB_MATRIX_LED_COUNT - first);
            out[0]        = first;
            out[1]        = count;
            for (uint8_t i = 0; i < count; i++) {
                out[2 + 4 * i] = overlay_has(first + i);
                memcpy(&out[3 + 4 * i], overlay.rgb[first + i], 3);
            }
            return STATUS_OK;
        }

        case CMD_SET_OVERLAY: {
            uint8_t first = args[1], count = args[2];
            if (count > OVERLAY_PER_REPORT || first + count > RGB_MATRIX_LED_COUNT) return STATUS_BAD_ARGUMENT;
            for (uint8_t i = 0; i < count; i++) {
                const uint8_t *entry = &args[3 + 4 * i];
                overlay_set(first + i, entry[0] & 1, &entry[1]);
            }
            dirty = true;
            return STATUS_OK;
        }

        case CMD_CLEAR_OVERLAY:
            overlay_clear(overlay.base_on);
            dirty = true;
            return STATUS_OK;

        case CMD_SAVE:
            overlay.checksum = overlay_checksum(&overlay);
            eeconfig_update_user_datablock(&overlay, 0, sizeof(overlay));
            eeconfig_update_rgb_matrix(&rgb_matrix_config);
            dirty = false;
            return STATUS_OK;

        default:
            return STATUS_UNKNOWN_COMMAND;
    }
}

void raw_hid_receive(uint8_t *data, uint8_t length) {
    data[1] = handle_command(data, length);
    raw_hid_send(data, length);
}

static inline uint8_t scale(uint8_t channel, uint8_t value) {
    return (uint16_t)channel * value / 255;
}

bool rgb_matrix_indicators_advanced_user(uint8_t led_min, uint8_t led_max) {
    if (host_mode) {
        for (uint8_t led = led_min; led < led_max; led++) {
            rgb_matrix_set_color(led, host_colors[led][0], host_colors[led][1], host_colors[led][2]);
        }
        return false;
    }
    const uint8_t value = rgb_matrix_get_val();
    for (uint8_t led = led_min; led < led_max; led++) {
        if (overlay_has(led)) {
            rgb_matrix_set_color(led, scale(overlay.rgb[led][0], value), scale(overlay.rgb[led][1], value), scale(overlay.rgb[led][2], value));
        } else if (!overlay.base_on) {
            rgb_matrix_set_color(led, 0, 0, 0);
        }
    }
    return false;
}
```

- [ ] **Step 4: Replace the keymap (layout unchanged, protocol moved out)**

<!-- file: firmware/qmk_firmware/keyboards/ducky/one2sf/1967st/iso/keymaps/hostrgb/keymap.c -->
```c
// Copyright 2019 /u/KeepItUnder
// SPDX-License-Identifier: GPL-2.0-or-later

#include QMK_KEYBOARD_H
#include "hostrgb_protocol.h"

enum Layer {
    _QWERTY,
    _FUNCTION,
    _COLOUR
};

const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {

    [_QWERTY] = LAYOUT(
        QK_GESC, KC_1,    KC_2,    KC_3,    KC_4,    KC_5,    KC_6,    KC_7,    KC_8,    KC_9,    KC_0,    KC_MINS, KC_EQL,  KC_BSPC, KC_DEL,
        KC_TAB,  KC_Q,    KC_W,    KC_E,    KC_R,    KC_T,    KC_Y,    KC_U,    KC_I,    KC_O,    KC_P,    KC_LBRC, KC_RBRC,          KC_PGUP,
        KC_CAPS, KC_A,    KC_S,    KC_D,    KC_F,    KC_G,    KC_H,    KC_J,    KC_K,    KC_L,    KC_SCLN, KC_QUOT, KC_NUHS, KC_ENT,  KC_PGDN,
        KC_LSFT, KC_NUBS, KC_Z,    KC_X,    KC_C,    KC_V,    KC_B,    KC_N,    KC_M,    KC_COMM, KC_DOT,  KC_SLSH, KC_RSFT, KC_UP,
        KC_LCTL, KC_LGUI, KC_LALT,                            KC_SPC,                    KC_RALT, MO(1),   KC_RCTL, KC_LEFT, KC_DOWN, KC_RGHT
    ),

    [_FUNCTION] = LAYOUT(
        KC_GRV,  KC_F1,   KC_F2,   KC_F3,   KC_F4,   KC_F5,   KC_F6,   KC_F7,   KC_F8,   KC_F9,   KC_F10,  KC_F11,  KC_F12,  KC_DEL,  _______,
        _______, MS_BTN1, MS_UP,   MS_BTN2, MS_WHLU, _______, KC_INS,  _______, KC_UP,   KC_PAUS, KC_PGUP, KC_HOME, KC_PSCR,          KC_HOME,
        _______, MS_LEFT, MS_DOWN, MS_RGHT, MS_WHLD, _______, KC_SCRL, KC_LEFT, KC_DOWN, KC_RGHT, KC_PGDN, KC_END,  _______, _______, KC_END,
        _______, _______, RM_TOGG, RM_NEXT, RM_HUEU, RM_HUED, RM_SATU, RM_SATD, KC_MUTE, KC_VOLD, KC_VOLU, _______, _______, _______,
        _______, _______, _______,                            QK_BOOT,                   MO(2),   _______, _______, _______, _______, _______
    ),

    [_COLOUR] = LAYOUT(
        _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______,
        _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______,          _______,
        _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______, _______,
        _______, _______, RM_TOGG, RM_NEXT, RM_HUEU, RM_HUED, RM_SATU, RM_SATD, _______, _______, _______, _______, _______, _______,
        _______, _______, _______,                            _______,                   _______, _______, _______, _______, _______, _______
    ),

};

// Alt + Esc types the grave key ("@" on a French Mac layout), like the stock Ducky firmware.
const key_override_t alt_esc_grave = ko_make_basic(MOD_MASK_ALT, QK_GESC, KC_GRV);

const key_override_t *key_overrides[] = {
    &alt_esc_grave,
};

void keyboard_post_init_user(void) {
    hostrgb_init();
}

void eeconfig_init_user(void) {
    hostrgb_reset_storage();
}
```

- [ ] **Step 5: Replace config.h and rules.mk**

<!-- file: firmware/qmk_firmware/keyboards/ducky/one2sf/1967st/iso/keymaps/hostrgb/config.h -->
```c
// Copyright 2019 /u/KeepItUnder
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#define GRAVE_ESC_GUI_OVERRIDE
#define MK_3_SPEED
#define MK_C_OFFSET_UNMOD   400    /* Cursor offset per movement (unmodified) */
#define MK_C_INTERVAL_UNMOD  5     /* Time between cursor movements (unmodified) */
#define MK_W_OFFSET_UNMOD   100    /* Scroll steps per scroll action (unmodified) */
#define MK_W_INTERVAL_UNMOD 10     /* Time between scroll steps (unmodified) */

// The NUC123 USB LLD gives each logical endpoint separate IN and OUT hardware buffers,
// so raw HID can use one endpoint number for both directions.
#define USB_ENDPOINTS_ARE_REORDERABLE

// Saved overlay block, see overlay_t in hostrgb_protocol.c.
#define EECONFIG_USER_DATA_SIZE 217

// Wear-leveled EEPROM in the last 2 KB of the APROM.
#define WEAR_LEVELING_BACKING_SIZE 2048
#define WEAR_LEVELING_LOGICAL_SIZE 1024

// Effects exposed by the protocol (keyboard.json already enables breathing, cycle_all,
// cycle_left_right, rainbow_moving_chevron and band_sat).
#define RGB_MATRIX_KEYPRESSES
#define RGB_MATRIX_FRAMEBUFFER_EFFECTS
#define ENABLE_RGB_MATRIX_GRADIENT_LEFT_RIGHT
#define ENABLE_RGB_MATRIX_HUE_WAVE
#define ENABLE_RGB_MATRIX_PIXEL_RAIN
#define ENABLE_RGB_MATRIX_DIGITAL_RAIN
#define ENABLE_RGB_MATRIX_SOLID_REACTIVE_SIMPLE
#define ENABLE_RGB_MATRIX_SPLASH
#define ENABLE_RGB_MATRIX_MULTISPLASH
#define ENABLE_RGB_MATRIX_TYPING_HEATMAP
#define RGB_MATRIX_DEFAULT_MODE RGB_MATRIX_CYCLE_LEFT_RIGHT
```

<!-- file: firmware/qmk_firmware/keyboards/ducky/one2sf/1967st/iso/keymaps/hostrgb/rules.mk -->
```make
RAW_ENABLE = yes
KEYBOARD_SHARED_EP = yes # NUC123 (AN) exposes only 2 endpoints: keyboard shares one so raw HID gets the other
KEY_OVERRIDE_ENABLE = yes
SRC += hostrgb_protocol.c
EEPROM_DRIVER = wear_leveling
WEAR_LEVELING_DRIVER = embedded_flash
```

- [ ] **Step 6: Build**

Run: `cd firmware/qmk_firmware && qmk compile -kb ducky/one2sf/1967st/iso -km hostrgb`
Expected: `[OK]` for linking. If the build stops on the flash size detection of the wear-leveling EFL backend, add `#define WEAR_LEVELING_EFL_FLASH_SIZE 0x11000` (NUC123SD4AN0 APROM size from `hal_lld.h`) to the keymap `config.h` and rebuild.

- [ ] **Step 7: Verify size, persistence objects and protocol symbols**

Run:
```bash
cd firmware/qmk_firmware
arm-none-eabi-size .build/ducky_one2sf_1967st_iso_hostrgb.elf
ls .build/obj_ducky_one2sf_1967st_iso_hostrgb | grep -E "wear_leveling|eeprom_(wear|transient)"
arm-none-eabi-nm .build/ducky_one2sf_1967st_iso_hostrgb.elf | grep -E " (raw_hid_receive|hostrgb_init|rgb_matrix_indicators_advanced_user|EFLD1)$"
```
Expected: `text + data` < 67584 (0x10800); a `wear_leveling` object and no `eeprom_transient`; all four symbols present.

- [ ] **Step 8: Commit (submodule)**

```bash
cd firmware/qmk_firmware
git add keyboards/ducky/one2sf/1967st
git commit -m "ducky/one2sf/1967st: persist lighting in flash, host RGB protocol v2"
```

---

### Task 2: CLI support for protocol v2

**Files:**
- Modify: `host/ducky_rgb.py`
- Create: `host/test_ducky_rgb.py`

**Interfaces:**
- Consumes: protocol v2 (Task 1).
- Produces: `Keyboard.info()`, `.state()`, `.effects(count)`, `.set_base(...)`, `.overlay()`, `.set_overlay(colors)`, `.clear_overlay()`, `.save()`; subcommands `info`, `state`, `base`, `paint`, `unpaint`, `clear-overlay`, `save` for hardware validation.

- [ ] **Step 1: Write the failing tests**

<!-- file: host/test_ducky_rgb.py -->
```python
"""Protocol v2 tests against a simulated keyboard that mirrors the firmware checks."""
import unittest

import ducky_rgb as d


class FakeKeyboard:
    """Implements the firmware side of protocol v2 (hostrgb_protocol.c) for tests."""

    def __init__(self):
        self.effects = list(range(1, 15))
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
        self.assertEqual(kb.info(), {"version": 2, "leds": 68, "effects": 14, "persistent": True})
        self.assertEqual(kb.effects(14), list(range(1, 15)))

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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd host && ../.venv/bin/python -m unittest test_ducky_rgb -v`
Expected: FAIL with `AttributeError: 'Keyboard' object has no attribute 'info'`

- [ ] **Step 3: Add the v2 methods to `Keyboard` (after `set_leds`)**

```python
    CMD_GET_INFO, CMD_GET_EFFECTS, CMD_GET_STATE, CMD_SET_BASE = 0x10, 0x11, 0x12, 0x13
    CMD_GET_OVERLAY, CMD_SET_OVERLAY, CMD_CLEAR_OVERLAY, CMD_SAVE = 0x14, 0x15, 0x16, 0x17
    BASE_FIELDS = ("enabled", "effect", "hue", "sat", "val", "speed")

    def info(self):
        p = self.command(self.CMD_GET_INFO)[2:]
        return {"version": p[0], "leds": p[1], "effects": p[2], "persistent": bool(p[3])}

    def effects(self, count):
        ids = []
        while len(ids) < count:
            p = self.command(self.CMD_GET_EFFECTS, len(ids))[2:]
            if p[1] == 0:
                break
            ids += p[2:2 + p[1]]
        return ids

    def state(self):
        p = self.command(self.CMD_GET_STATE)[2:]
        base = dict(zip(self.BASE_FIELDS, p[:6]))
        base["enabled"] = bool(base["enabled"])
        return {"base": base, "host_mode": bool(p[6]), "custom_leds": p[7], "dirty": bool(p[8])}

    def set_base(self, enabled, effect, hue, sat, val, speed):
        self.command(self.CMD_SET_BASE, int(enabled), effect, hue, sat, val, speed)

    def overlay(self, leds=68):
        colors = []
        while len(colors) < leds:
            p = self.command(self.CMD_GET_OVERLAY, len(colors))[2:]
            for i in range(p[1]):
                e = p[2 + 4 * i:6 + 4 * i]
                colors.append(tuple(e[1:]) if e[0] & 1 else None)
        return colors

    def set_overlay(self, colors):
        for first in range(0, len(colors), 7):
            chunk = colors[first:first + 7]
            args = [c for color in chunk for c in ((1, *color) if color else (0, 0, 0, 0))]
            self.command(self.CMD_SET_OVERLAY, first, len(chunk), *args)

    def clear_overlay(self):
        self.command(self.CMD_CLEAR_OVERLAY)

    def save(self):
        self.command(self.CMD_SAVE)
```

- [ ] **Step 4: Add the subcommands**

In `main()`, before `sub.add_parser("off", ...)`:

```python
    sub.add_parser("info", help="protocole v2 : version, LEDs, effets, persistance")
    sub.add_parser("state", help="protocole v2 : réglage courant du clavier")
    p = sub.add_parser("base", help="protocole v2 : régler le fond (les champs omis sont conservés)")
    p.add_argument("--effect", type=int)
    p.add_argument("--hue", type=int)
    p.add_argument("--sat", type=int)
    p.add_argument("--val", type=int)
    p.add_argument("--speed", type=int)
    p.add_argument("--on", dest="enabled", action="store_true", default=None)
    p.add_argument("--off", dest="enabled", action="store_false")
    p = sub.add_parser("paint", help="protocole v2 : couleur personnalisée sur des touches")
    p.add_argument("names", type=parse_keys)
    p.add_argument("color", type=parse_color)
    p = sub.add_parser("unpaint", help="protocole v2 : rendre des touches au fond")
    p.add_argument("names", type=parse_keys)
    sub.add_parser("clear-overlay", help="protocole v2 : effacer toutes les couleurs personnalisées")
    sub.add_parser("save", help="protocole v2 : enregistrer le réglage dans le clavier")
```

In the dispatch chain, before `elif args.cmd == "effects":`:

```python
    elif args.cmd == "info":
        print(kb.info())
    elif args.cmd == "state":
        print(kb.state())
    elif args.cmd == "base":
        base = kb.state()["base"]
        for field in Keyboard.BASE_FIELDS:
            value = getattr(args, field)
            if value is not None:
                base[field] = value
        kb.set_base(**base)
    elif args.cmd in ("paint", "unpaint"):
        colors = kb.overlay()
        for i in args.names:
            colors[i] = args.color if args.cmd == "paint" else None
        kb.set_overlay(colors)
    elif args.cmd == "clear-overlay":
        kb.clear_overlay()
    elif args.cmd == "save":
        kb.save()
```

`--on` / `--off` set `enabled`; omitted fields keep the keyboard's current value.

- [ ] **Step 5: Run the tests**

Run: `cd host && ../.venv/bin/python -m unittest test_ducky_rgb -v`
Expected: 5 tests OK.

- [ ] **Step 6: Commit**

```bash
git add host/ducky_rgb.py host/test_ducky_rgb.py
git commit -m "CLI: protocol v2 commands (info, state, base, overlay, save) with tests"
```

---

### Task 3: Swift package, protocol, effects, colours

**Files:**
- Create: `app/Package.swift`
- Create: `app/Sources/DuckyCore/Protocol.swift`
- Create: `app/Sources/DuckyCore/Effects.swift`
- Create: `app/Sources/DuckyCore/Color.swift`
- Create: `app/Sources/DuckyRGB/DuckyRGBApp.swift` (placeholder entry point, replaced in Task 9)
- Create: `app/Tests/DuckyCoreTests/ProtocolTests.swift`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `Command`, `Status`, `RGB` (`init(_:_:_:)`, `init(hue:saturation:value:)`, `scaled(by:)`, `.black`), `BaseSettings(enabled:effectID:hue:saturation:brightness:speed:)`, `KeyboardInfo`, `KeyboardState`, `DuckyError`, `DuckyProtocol.request(_:_:)`, `.payload(of:for:)`, `.setBase(_:)`, `.setOverlay(first:colors:)`, `.decodePing/_Info/_Effects/_State/_Overlay`, `Effect`, `EffectCatalog.all/.name(for:)`.

- [ ] **Step 1: Package manifest, gitignore and a placeholder executable**

<!-- file: app/Package.swift -->
```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DuckyRGB",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DuckyRGB", targets: ["DuckyRGB"])],
    targets: [
        .target(name: "DuckyCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "DuckyRGB", dependencies: ["DuckyCore"]),
        .testTarget(name: "DuckyCoreTests", dependencies: ["DuckyCore"]),
    ]
)
```

<!-- file: app/Sources/DuckyRGB/DuckyRGBApp.swift -->
```swift
import DuckyCore

print("Ducky RGB placeholder")
```

Append to `.gitignore`:

```
app/.build/
app/build/
```

- [ ] **Step 2: Write the failing protocol tests**

<!-- file: app/Tests/DuckyCoreTests/ProtocolTests.swift -->
```swift
import XCTest
@testable import DuckyCore

final class ProtocolTests: XCTestCase {
    func testRequestIsPaddedTo32Bytes() {
        let report = DuckyProtocol.request(.getOverlay, [7])
        XCTAssertEqual(report.count, 32)
        XCTAssertEqual(Array(report.prefix(3)), [0x14, 7, 0])
    }

    func testPayloadRejectsErrorStatusAndWrongCommand() {
        var reply = [UInt8](repeating: 0, count: 32)
        reply[0] = 0x13
        reply[1] = 2
        XCTAssertThrowsError(try DuckyProtocol.payload(of: reply, for: .setBase)) { error in
            XCTAssertEqual(error as? DuckyError, .status(.setBase, .badArgument))
        }
        reply[1] = 0
        XCTAssertThrowsError(try DuckyProtocol.payload(of: reply, for: .save)) { error in
            XCTAssertEqual(error as? DuckyError, .malformedReply)
        }
        XCTAssertEqual(try DuckyProtocol.payload(of: reply, for: .setBase).count, 30)
    }

    func testSetBaseEncoding() {
        let base = BaseSettings(enabled: false, effectID: 5, hue: 10, saturation: 20, brightness: 30, speed: 40)
        XCTAssertEqual(Array(DuckyProtocol.setBase(base).prefix(7)), [0x13, 0, 5, 10, 20, 30, 40])
    }

    func testSetOverlayEncoding() {
        let report = DuckyProtocol.setOverlay(first: 14, colors: [RGB(1, 2, 3), nil])
        XCTAssertEqual(Array(report.prefix(11)), [0x15, 14, 2, 1, 1, 2, 3, 0, 0, 0, 0])
    }

    func testDecodeStateAndOverlay() throws {
        let state = try DuckyProtocol.decodeState([1, 4, 10, 20, 30, 40, 1, 3, 1] + zeros(21))
        XCTAssertEqual(state.base, BaseSettings(enabled: true, effectID: 4, hue: 10, saturation: 20, brightness: 30, speed: 40))
        XCTAssertTrue(state.hostMode)
        XCTAssertEqual(state.customizedCount, 3)
        XCTAssertTrue(state.dirty)

        let overlay = try DuckyProtocol.decodeOverlay([63, 2, 1, 9, 8, 7, 0, 0, 0, 0] + zeros(20))
        XCTAssertEqual(overlay.first, 63)
        XCTAssertEqual(overlay.colors, [RGB(9, 8, 7), nil])
    }

    func testDecodeRejectsOversizedCounts() {
        XCTAssertThrowsError(try DuckyProtocol.decodeOverlay([0, 8] + zeros(28)))
        XCTAssertThrowsError(try DuckyProtocol.decodeEffects([0, 29] + zeros(28)))
    }

    func testHSVConversionMatchesPrimaryColours() {
        XCTAssertEqual(RGB(hue: 0, saturation: 255, value: 255), RGB(255, 0, 0))
        XCTAssertEqual(RGB(hue: 85, saturation: 255, value: 255), RGB(0, 255, 0))
        XCTAssertEqual(RGB(hue: 0, saturation: 0, value: 200), RGB(200, 200, 200))
        XCTAssertEqual(RGB(200, 100, 50).scaled(by: 128), RGB(100, 50, 25))
    }

    func testEffectCatalogNames() {
        XCTAssertEqual(EffectCatalog.all.count, 14)
        XCTAssertEqual(EffectCatalog.name(for: 1), "Couleur unie")
        XCTAssertEqual(EffectCatalog.name(for: 99), "Effet 99")
    }

    private func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd app && swift test --filter ProtocolTests`
Expected: FAIL, compile errors (`cannot find 'DuckyProtocol' in scope`).

- [ ] **Step 4: Implement protocol, effects and colours**

<!-- file: app/Sources/DuckyCore/Protocol.swift -->
```swift
import Foundation

/// Raw HID commands of the hostrgb firmware (spec section 3).
public enum Command: UInt8, Sendable {
    case ping = 0x01, hostMode = 0x02, hostSet = 0x03, hostFill = 0x04
    case getInfo = 0x10, getEffects = 0x11, getState = 0x12, setBase = 0x13
    case getOverlay = 0x14, setOverlay = 0x15, clearOverlay = 0x16, save = 0x17
}

public enum Status: UInt8, Sendable {
    case ok = 0, unknownCommand = 1, badArgument = 2, flashError = 3
}

public enum DuckyError: Error, Equatable, Sendable {
    case notConnected
    case timeout
    case malformedReply
    case status(Command, Status)
    case outdatedFirmware(version: Int)
}

/// The saved background layer: a QMK rgb_matrix effect and its parameters.
public struct BaseSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var effectID: UInt8
    public var hue: UInt8
    public var saturation: UInt8
    public var brightness: UInt8
    public var speed: UInt8

    public init(enabled: Bool = true, effectID: UInt8 = 1, hue: UInt8 = 0, saturation: UInt8 = 255, brightness: UInt8 = 200, speed: UInt8 = 128) {
        self.enabled = enabled
        self.effectID = effectID
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.speed = speed
    }
}

public struct KeyboardInfo: Equatable, Sendable {
    public let version: Int
    public let ledCount: Int
    public let effectCount: Int
    public let persistent: Bool
}

public struct KeyboardState: Equatable, Sendable {
    public let base: BaseSettings
    public let hostMode: Bool
    public let customizedCount: Int
    public let dirty: Bool
}

public enum DuckyProtocol {
    public static let reportSize = 32
    public static let version = 2
    public static let overlayPerReport = 7
    public static let effectsPerReport = 28

    public static func request(_ command: Command, _ args: [UInt8] = []) -> [UInt8] {
        precondition(args.count < reportSize, "too many arguments")
        let report = [command.rawValue] + args
        return report + [UInt8](repeating: 0, count: reportSize - report.count)
    }

    /// Checks a reply and returns its payload (bytes 2 and up).
    public static func payload(of reply: [UInt8], for command: Command) throws -> [UInt8] {
        guard reply.count >= 2, reply[0] == command.rawValue, let status = Status(rawValue: reply[1]) else {
            throw DuckyError.malformedReply
        }
        guard status == .ok else { throw DuckyError.status(command, status) }
        return Array(reply.dropFirst(2))
    }

    public static func setBase(_ base: BaseSettings) -> [UInt8] {
        request(.setBase, [base.enabled ? 1 : 0, base.effectID, base.hue, base.saturation, base.brightness, base.speed])
    }

    public static func setOverlay(first: Int, colors: [RGB?]) -> [UInt8] {
        precondition(colors.count <= overlayPerReport, "at most \(overlayPerReport) LEDs per report")
        var args: [UInt8] = [UInt8(first), UInt8(colors.count)]
        for color in colors {
            args += color.map { [1, $0.r, $0.g, $0.b] } ?? [0, 0, 0, 0]
        }
        return request(.setOverlay, args)
    }

    public static func decodePing(_ p: [UInt8]) throws -> (version: Int, ledCount: Int) {
        guard p.count >= 2 else { throw DuckyError.malformedReply }
        return (Int(p[0]), Int(p[1]))
    }

    public static func decodeInfo(_ p: [UInt8]) throws -> KeyboardInfo {
        guard p.count >= 4 else { throw DuckyError.malformedReply }
        return KeyboardInfo(version: Int(p[0]), ledCount: Int(p[1]), effectCount: Int(p[2]), persistent: p[3] != 0)
    }

    public static func decodeEffects(_ p: [UInt8]) throws -> (first: Int, ids: [UInt8]) {
        guard p.count >= 2 else { throw DuckyError.malformedReply }
        let count = Int(p[1])
        guard count <= effectsPerReport, p.count >= 2 + count else { throw DuckyError.malformedReply }
        return (Int(p[0]), Array(p[2..<2 + count]))
    }

    public static func decodeState(_ p: [UInt8]) throws -> KeyboardState {
        guard p.count >= 9 else { throw DuckyError.malformedReply }
        let base = BaseSettings(enabled: p[0] != 0, effectID: p[1], hue: p[2], saturation: p[3], brightness: p[4], speed: p[5])
        return KeyboardState(base: base, hostMode: p[6] != 0, customizedCount: Int(p[7]), dirty: p[8] != 0)
    }

    public static func decodeOverlay(_ p: [UInt8]) throws -> (first: Int, colors: [RGB?]) {
        guard p.count >= 2 else { throw DuckyError.malformedReply }
        let count = Int(p[1])
        guard count <= overlayPerReport, p.count >= 2 + 4 * count else { throw DuckyError.malformedReply }
        let colors: [RGB?] = (0..<count).map { i in
            let e = Array(p[(2 + 4 * i)..<(6 + 4 * i)])
            return e[0] & 1 == 1 ? RGB(e[1], e[2], e[3]) : nil
        }
        return (Int(p[0]), colors)
    }
}
```

<!-- file: app/Sources/DuckyCore/Effects.swift -->
```swift
/// Effects compiled into the hostrgb firmware, by stable protocol id (spec section 2).
public struct Effect: Identifiable, Hashable, Sendable {
    public let id: UInt8
    public let name: String
}

public enum EffectCatalog {
    public static let all: [Effect] = [
        Effect(id: 1, name: "Couleur unie"),
        Effect(id: 2, name: "Respiration"),
        Effect(id: 3, name: "Dégradé"),
        Effect(id: 4, name: "Cycle de couleurs"),
        Effect(id: 5, name: "Arc-en-ciel"),
        Effect(id: 6, name: "Chevrons"),
        Effect(id: 7, name: "Vague de teinte"),
        Effect(id: 8, name: "Pluie de pixels"),
        Effect(id: 9, name: "Pluie Matrix"),
        Effect(id: 10, name: "Réaction à la frappe"),
        Effect(id: 11, name: "Onde"),
        Effect(id: 12, name: "Ondes multiples"),
        Effect(id: 13, name: "Heatmap de frappe"),
        Effect(id: 14, name: "Bande de saturation"),
    ]

    public static func name(for id: UInt8) -> String {
        all.first { $0.id == id }?.name ?? "Effet \(id)"
    }

    /// Catalog entries for the ids a keyboard reports, keeping unknown ids visible.
    public static func effects(for ids: [UInt8]) -> [Effect] {
        ids.map { id in Effect(id: id, name: name(for: id)) }
    }
}
```

<!-- file: app/Sources/DuckyCore/Color.swift -->
```swift
import Foundation

public struct RGB: Codable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = RGB(0, 0, 0)

    /// QMK-style HSV, every component 0-255.
    public init(hue: UInt8, saturation: UInt8, value: UInt8) {
        let h = Double(hue) / 256 * 6
        let s = Double(saturation) / 255
        let v = Double(value) / 255
        let f = h - floor(h)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let rgb: (Double, Double, Double)
        switch Int(h) % 6 {
        case 0: rgb = (v, t, p)
        case 1: rgb = (q, v, p)
        case 2: rgb = (p, v, t)
        case 3: rgb = (p, q, v)
        case 4: rgb = (t, p, v)
        default: rgb = (v, p, q)
        }
        func byte(_ x: Double) -> UInt8 { UInt8((x * 255).rounded()) }
        self.init(byte(rgb.0), byte(rgb.1), byte(rgb.2))
    }

    /// Dims the colour the way the firmware applies brightness to custom keys.
    public func scaled(by value: UInt8) -> RGB {
        func s(_ c: UInt8) -> UInt8 { UInt8(UInt16(c) * UInt16(value) / 255) }
        return RGB(s(r), s(g), s(b))
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `cd app && swift test --filter ProtocolTests`
Expected: 8 tests pass. (`RGB(hue: 85, ...)`: h = 85/256*6 = 1.992, sector 1, q = 1-0.992 ≈ 0.008 → rounds to 2; if this assertion fails with `RGB(2, 255, 0)`, change the test expectation to `RGB(2, 255, 0)`: QMK's 0-255 hue does not land exactly on 120°.)

- [ ] **Step 6: Commit**

```bash
git add app/Package.swift app/Sources app/Tests .gitignore
git commit -m "App: Swift package with protocol v2 codec, effect catalog and colours"
```

---

### Task 4: Keyboard layout and static preview

**Files:**
- Create: `app/Sources/DuckyCore/KeyboardLayout.swift`
- Create: `app/Sources/DuckyCore/LightingPreview.swift`
- Create: `app/Tests/DuckyCoreTests/LayoutTests.swift`

**Interfaces:**
- Consumes: `RGB`, `BaseSettings` (Task 3).
- Produces: `KeyInfo(id:name:legend:x:y:width:height:)`, `KeyboardLayout.keys/.ledCount/.width/.height/.index(named:)/.key(atX:y:)`, `LightingPreview.colors(base:overlay:) -> [RGB]`.

- [ ] **Step 1: Write the failing tests**

<!-- file: app/Tests/DuckyCoreTests/LayoutTests.swift -->
```swift
import XCTest
@testable import DuckyCore

final class LayoutTests: XCTestCase {
    func testSixtyEightKeysWithSequentialLEDIndices() {
        XCTAssertEqual(KeyboardLayout.keys.count, 68)
        XCTAssertEqual(KeyboardLayout.keys.map(\.id), Array(0..<68))
        XCTAssertEqual(KeyboardLayout.index(named: "enter"), 42)
        XCTAssertEqual(KeyboardLayout.keys[1].legend, "&")
        XCTAssertEqual(KeyboardLayout.keys[16].legend, "A")
    }

    func testHitTesting() {
        XCTAssertEqual(KeyboardLayout.key(atX: 0.5, y: 0.5)?.name, "esc")
        XCTAssertEqual(KeyboardLayout.key(atX: 14.2, y: 1.5)?.name, "enter")
        XCTAssertEqual(KeyboardLayout.key(atX: 14.2, y: 2.5)?.name, "enter")
        XCTAssertEqual(KeyboardLayout.key(atX: 7, y: 4.5)?.name, "space")
        XCTAssertNil(KeyboardLayout.key(atX: 15.1, y: 0.5))
    }

    func testPreviewLayers() {
        var overlay = [RGB?](repeating: nil, count: 68)
        overlay[0] = RGB(200, 100, 50)
        let base = BaseSettings(enabled: true, effectID: 1, hue: 0, saturation: 255, brightness: 128)
        let colors = LightingPreview.colors(base: base, overlay: overlay)
        XCTAssertEqual(colors[0], RGB(100, 50, 25))
        XCTAssertEqual(colors[1], RGB(hue: 0, saturation: 255, value: 128))

        var off = base
        off.enabled = false
        XCTAssertEqual(LightingPreview.colors(base: off, overlay: overlay)[1], .black)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && swift test --filter LayoutTests`
Expected: FAIL, `cannot find 'KeyboardLayout' in scope`.

- [ ] **Step 3: Implement layout and preview**

<!-- file: app/Sources/DuckyCore/KeyboardLayout.swift -->
```swift
/// One key of the Ducky One 2 SF ISO: LED index, QWERTY position name, AZERTY legend,
/// physical rectangle in key units (from the QMK iso/keyboard.json layout).
public struct KeyInfo: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let legend: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
}

public enum KeyboardLayout {
    public static let ledCount = 68
    public static let width = 16.25
    public static let height = 5.0

    private static let names = ("esc 1 2 3 4 5 6 7 8 9 0 minus equal backspace delete "
        + "tab q w e r t y u i o p lbracket rbracket pageup "
        + "caps a s d f g h j k l semicolon quote hash enter pagedown "
        + "lshift iso_backslash z x c v b n m comma dot slash rshift up "
        + "lctrl lgui lalt space ralt fn rctrl left down right").split(separator: " ").map(String.init)

    private static let legends = [
        "Échap", "&", "é", "\"", "'", "(", "-", "è", "_", "ç", "à", ")", "=", "⌫", "Suppr",
        "⇥", "A", "Z", "E", "R", "T", "Y", "U", "I", "O", "P", "^", "$", "⇞",
        "⇪", "Q", "S", "D", "F", "G", "H", "J", "K", "L", "M", "ù", "*", "↩", "⇟",
        "⇧", "<", "W", "X", "C", "V", "B", "N", ",", ";", ":", "!", "⇧", "↑",
        "Ctrl", "⌘", "⌥", "", "⌥", "Fn", "Ctrl", "←", "↓", "→",
    ]

    private static let geometry: [(Double, Double, Double, Double)] = [
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

    public static let keys: [KeyInfo] = (0..<ledCount).map { i in
        let (x, y, w, h) = geometry[i]
        return KeyInfo(id: i, name: names[i], legend: legends[i], x: x, y: y, width: w, height: h)
    }

    public static func index(named name: String) -> Int? {
        keys.first { $0.name == name }?.id
    }

    /// The key under a point expressed in key units.
    public static func key(atX x: Double, y: Double) -> KeyInfo? {
        keys.first { $0.contains(x: x, y: y) }
    }
}
```

<!-- file: app/Sources/DuckyCore/LightingPreview.swift -->
```swift
/// Static approximation of what the keyboard shows: custom keys dimmed by the brightness, other
/// keys in the base colour (animated effects are represented by their base colour).
public enum LightingPreview {
    public static func colors(base: BaseSettings, overlay: [RGB?]) -> [RGB] {
        let background = base.enabled ? RGB(hue: base.hue, saturation: base.saturation, value: base.brightness) : .black
        return overlay.map { $0?.scaled(by: base.brightness) ?? background }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter LayoutTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/DuckyCore/KeyboardLayout.swift app/Sources/DuckyCore/LightingPreview.swift app/Tests/DuckyCoreTests/LayoutTests.swift
git commit -m "App: keyboard layout with AZERTY legends and static lighting preview"
```

---

### Task 5: Presets and preset store

**Files:**
- Create: `app/Sources/DuckyCore/Preset.swift`
- Create: `app/Sources/DuckyCore/PresetStore.swift`
- Create: `app/Tests/DuckyCoreTests/PresetStoreTests.swift`

**Interfaces:**
- Consumes: `BaseSettings`, `RGB`, `KeyboardLayout` (Tasks 3-4).
- Produces: `Preset(id:name:base:overlay:builtIn:)` with `overlayColors() -> [RGB?]`, `matches(base:overlay:) -> Bool`, `Preset.builtIns`; `@MainActor @Observable PresetStore(fileURL:)` with `all`, `userPresets`, `loadError`, `add(_:)`, `rename(id:to:)`, `duplicate(id:) -> Preset?`, `delete(id:)`, `PresetStore.standard()`.

- [ ] **Step 1: Write the failing tests**

<!-- file: app/Tests/DuckyCoreTests/PresetStoreTests.swift -->
```swift
import XCTest
@testable import DuckyCore

@MainActor
final class PresetStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var file: URL { directory.appendingPathComponent("presets.json") }

    func testStartsWithBuiltInsOnly() {
        let store = PresetStore(fileURL: file)
        XCTAssertEqual(store.all.map(\.name), Preset.builtIns.map(\.name))
        XCTAssertNil(store.loadError)
    }

    func testUserPresetsSurviveReload() {
        var overlay = [RGB?](repeating: nil, count: 68)
        overlay[17] = RGB(255, 0, 0)
        let store = PresetStore(fileURL: file)
        store.add(Preset(name: "Mien", base: BaseSettings(effectID: 2), overlay: overlay))
        let reloaded = PresetStore(fileURL: file)
        XCTAssertEqual(reloaded.userPresets.count, 1)
        XCTAssertEqual(reloaded.userPresets[0].name, "Mien")
        XCTAssertEqual(reloaded.userPresets[0].overlayColors(), overlay)
    }

    func testRenameDuplicateDelete() throws {
        let store = PresetStore(fileURL: file)
        let preset = Preset(name: "A", base: BaseSettings(), overlay: [])
        store.add(preset)
        store.rename(id: preset.id, to: "B")
        let copy = try XCTUnwrap(store.duplicate(id: preset.id))
        XCTAssertEqual(copy.name, "B (copie)")
        store.delete(id: preset.id)
        XCTAssertEqual(store.userPresets.map(\.name), ["B (copie)"])
    }

    func testBuiltInsCannotBeDeletedOrRenamed() {
        let store = PresetStore(fileURL: file)
        let builtIn = Preset.builtIns[0]
        store.delete(id: builtIn.id)
        store.rename(id: builtIn.id, to: "X")
        XCTAssertEqual(store.all.first?.name, builtIn.name)
        XCTAssertNotNil(store.duplicate(id: builtIn.id))
    }

    func testCorruptFileIsSetAside() throws {
        try Data("not json".utf8).write(to: file)
        let store = PresetStore(fileURL: file)
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.all.count, Preset.builtIns.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".corrupt"))
    }

    func testMatches() {
        let preset = Preset.builtIns[0]
        XCTAssertTrue(preset.matches(base: preset.base, overlay: preset.overlayColors()))
        var other = preset.base
        other.speed &+= 1
        XCTAssertFalse(preset.matches(base: other, overlay: preset.overlayColors()))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && swift test --filter PresetStoreTests`
Expected: FAIL, `cannot find 'PresetStore' in scope`.

- [ ] **Step 3: Implement presets and the store**

<!-- file: app/Sources/DuckyCore/Preset.swift -->
```swift
import Foundation

/// A lighting setup: a base effect plus optional per-key colours.
public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public struct CustomKey: Codable, Hashable, Sendable {
        public var index: Int
        public var color: RGB
    }

    public var id: UUID
    public var name: String
    public var base: BaseSettings
    public var customKeys: [CustomKey]
    public var builtIn: Bool

    public init(id: UUID = UUID(), name: String, base: BaseSettings, overlay: [RGB?], builtIn: Bool = false) {
        self.id = id
        self.name = name
        self.base = base
        self.customKeys = overlay.enumerated().compactMap { index, color in color.map { CustomKey(index: index, color: $0) } }
        self.builtIn = builtIn
    }

    public func overlayColors(ledCount: Int = KeyboardLayout.ledCount) -> [RGB?] {
        var colors = [RGB?](repeating: nil, count: ledCount)
        for key in customKeys where colors.indices.contains(key.index) {
            colors[key.index] = key.color
        }
        return colors
    }

    public func matches(base other: BaseSettings, overlay: [RGB?]) -> Bool {
        base == other && overlayColors(ledCount: overlay.count) == overlay
    }
}

extension Preset {
    private static func overlay(_ keys: [String: RGB]) -> [RGB?] {
        var colors = [RGB?](repeating: nil, count: KeyboardLayout.ledCount)
        for (name, color) in keys {
            if let index = KeyboardLayout.index(named: name) { colors[index] = color }
        }
        return colors
    }

    private static func builtInID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "D0C1A000-0000-4000-8000-%012d", n))!
    }

    public static let builtIns: [Preset] = {
        let red = RGB(255, 0, 0), orange = RGB(255, 120, 0), white = RGB(255, 255, 255)
        return [
            Preset(id: builtInID(1), name: "Arc-en-ciel",
                   base: BaseSettings(enabled: true, effectID: 5, hue: 0, saturation: 255, brightness: 200, speed: 128),
                   overlay: [], builtIn: true),
            Preset(id: builtInID(2), name: "Respiration blanche",
                   base: BaseSettings(enabled: true, effectID: 2, hue: 0, saturation: 0, brightness: 200, speed: 80),
                   overlay: [], builtIn: true),
            Preset(id: builtInID(3), name: "Nuit",
                   base: BaseSettings(enabled: true, effectID: 1, hue: 0, saturation: 255, brightness: 50, speed: 128),
                   overlay: [], builtIn: true),
            Preset(id: builtInID(4), name: "Jeu ZQSD",
                   base: BaseSettings(enabled: true, effectID: 1, hue: 170, saturation: 255, brightness: 110, speed: 128),
                   overlay: overlay(["w": red, "a": red, "s": red, "d": red,
                                     "up": orange, "left": orange, "down": orange, "right": orange]),
                   builtIn: true),
            Preset(id: builtInID(5), name: "Focus",
                   base: BaseSettings(enabled: false, effectID: 1, hue: 0, saturation: 0, brightness: 120, speed: 128),
                   overlay: overlay(["esc": white]), builtIn: true),
        ]
    }()
}
```

<!-- file: app/Sources/DuckyCore/PresetStore.swift -->
```swift
import Foundation
import Observation

/// Built-in presets plus the user's presets, saved as JSON.
@MainActor
@Observable
public final class PresetStore {
    private struct File: Codable {
        var version = 1
        var presets: [Preset]
    }

    public private(set) var userPresets: [Preset] = []
    public private(set) var loadError: String?
    public var all: [Preset] { Preset.builtIns + userPresets }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    public static func standard() -> PresetStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PresetStore(fileURL: support.appendingPathComponent("Ducky RGB/presets.json"))
    }

    public func load() {
        loadError = nil
        guard let data = try? Data(contentsOf: fileURL) else {
            userPresets = []
            return
        }
        do {
            userPresets = try JSONDecoder().decode(File.self, from: data).presets.filter { !$0.builtIn }
        } catch {
            userPresets = []
            let aside = URL(fileURLWithPath: fileURL.path + ".corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            loadError = "Fichier de presets illisible, mis de côté : \(aside.lastPathComponent)"
        }
    }

    public func add(_ preset: Preset) {
        var preset = preset
        preset.builtIn = false
        userPresets.append(preset)
        persist()
    }

    public func rename(id: UUID, to name: String) {
        guard let i = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets[i].name = name
        persist()
    }

    @discardableResult
    public func duplicate(id: UUID) -> Preset? {
        guard let source = all.first(where: { $0.id == id }) else { return nil }
        let copy = Preset(name: "\(source.name) (copie)", base: source.base, overlay: source.overlayColors())
        add(copy)
        return copy
    }

    public func delete(id: UUID) {
        userPresets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(File(presets: userPresets)).write(to: fileURL, options: .atomic)
            loadError = nil
        } catch {
            loadError = "Impossible d'enregistrer les presets : \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter PresetStoreTests`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/DuckyCore/Preset.swift app/Sources/DuckyCore/PresetStore.swift app/Tests/DuckyCoreTests/PresetStoreTests.swift
git commit -m "App: presets with built-ins and a JSON preset store"
```

---

### Task 6: Transport abstraction, keyboard client and simulated keyboard

**Files:**
- Create: `app/Sources/DuckyCore/HIDTransport.swift`
- Create: `app/Sources/DuckyCore/KeyboardClient.swift`
- Create: `app/Tests/DuckyCoreTests/FakeKeyboard.swift`
- Create: `app/Tests/DuckyCoreTests/KeyboardClientTests.swift`

**Interfaces:**
- Consumes: `DuckyProtocol`, `Command`, `Status`, `DuckyError`, `BaseSettings`, `RGB` (Task 3).
- Produces: `protocol HIDTransport: AnyObject, Sendable { var isConnected: Bool; var onConnectionChange: (@Sendable (Bool) -> Void)?; func start(); func exchange(_ report: [UInt8], timeout: TimeInterval) throws -> [UInt8] }`; `final class KeyboardClient(transport:)` with `ping()`, `info()`, `effects(count:)`, `state()`, `setBase(_:)`, `overlay(ledCount:)`, `setOverlay(_:only:)`, `clearOverlay()`, `save()`, `setHostMode(_:)`; test double `FakeKeyboard(version:effectIDs:connected:)` with `base`, `overlay`, `savedBase`, `savedOverlay`, `hostMode`, `commands()`, `setConnected(_:)`, `failNext(_:with:)`.

- [ ] **Step 1: Write the transport protocol**

<!-- file: app/Sources/DuckyCore/HIDTransport.swift -->
```swift
import Foundation

/// A connection to the keyboard's raw HID interface.
public protocol HIDTransport: AnyObject, Sendable {
    var isConnected: Bool { get }
    /// Called on the main queue when the keyboard appears or disappears.
    var onConnectionChange: (@Sendable (Bool) -> Void)? { get set }
    func start()
    /// Sends a 32-byte report and returns the reply to the same command. Blocks: never call it
    /// on the main thread.
    func exchange(_ report: [UInt8], timeout: TimeInterval) throws -> [UInt8]
}
```

- [ ] **Step 2: Write the simulated keyboard (test target)**

<!-- file: app/Tests/DuckyCoreTests/FakeKeyboard.swift -->
```swift
import Foundation
@testable import DuckyCore

/// Simulates the hostrgb firmware (protocol v2) for tests.
final class FakeKeyboard: HIDTransport, @unchecked Sendable {
    var onConnectionChange: (@Sendable (Bool) -> Void)?

    private let lock = NSLock()
    private var connected: Bool
    private var log: [Command] = []
    private var failures: [Command: Status] = [:]

    let version: UInt8
    let effectIDs: [UInt8]
    var base = BaseSettings()
    var overlay = [RGB?](repeating: nil, count: 68)
    var savedBase: BaseSettings?
    var savedOverlay: [RGB?]?
    var hostMode = false
    var dirty = false

    init(version: UInt8 = 2, effectIDs: [UInt8] = Array(1...14), connected: Bool = true) {
        self.version = version
        self.effectIDs = effectIDs
        self.connected = connected
    }

    var isConnected: Bool { lock.withLock { connected } }

    func start() {}

    func setConnected(_ value: Bool) {
        lock.withLock { connected = value }
        let callback = onConnectionChange
        DispatchQueue.main.async { callback?(value) }
    }

    func commands() -> [Command] { lock.withLock { log } }

    /// Makes the next occurrence of `command` fail with `status`.
    func failNext(_ command: Command, with status: Status) {
        lock.withLock { failures[command] = status }
    }

    func exchange(_ report: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        try lock.withLock {
            guard connected else { throw DuckyError.notConnected }
            var out = [UInt8](repeating: 0, count: 32)
            out[0] = report[0]
            func reply(_ payload: [UInt8] = []) -> [UInt8] {
                for (i, byte) in payload.enumerated() { out[2 + i] = byte }
                return out
            }
            func fail(_ status: Status) -> [UInt8] {
                out[1] = status.rawValue
                return out
            }
            guard let command = Command(rawValue: report[0]) else { return fail(.unknownCommand) }
            log.append(command)
            if let status = failures.removeValue(forKey: command) { return fail(status) }
            if version < 2 && report[0] >= 0x10 { return fail(.unknownCommand) }
            let a = report
            switch command {
            case .ping:
                return reply([version, 68])
            case .hostMode:
                hostMode = a[1] != 0
                return reply()
            case .hostSet, .hostFill:
                return reply()
            case .getInfo:
                return reply([2, 68, UInt8(effectIDs.count), 1])
            case .getEffects:
                let first = Int(a[1])
                guard first <= effectIDs.count else { return fail(.badArgument) }
                let ids = Array(effectIDs[first..<min(effectIDs.count, first + 28)])
                return reply([UInt8(first), UInt8(ids.count)] + ids)
            case .getState:
                return reply([base.enabled ? 1 : 0, base.effectID, base.hue, base.saturation, base.brightness, base.speed,
                              hostMode ? 1 : 0, UInt8(overlay.compactMap { $0 }.count), dirty ? 1 : 0])
            case .setBase:
                guard effectIDs.contains(a[2]) else { return fail(.badArgument) }
                base = BaseSettings(enabled: a[1] != 0, effectID: a[2], hue: a[3], saturation: a[4], brightness: a[5], speed: a[6])
                dirty = true
                return reply()
            case .getOverlay:
                let first = Int(a[1])
                guard first < 68 else { return fail(.badArgument) }
                let count = min(7, 68 - first)
                var payload: [UInt8] = [UInt8(first), UInt8(count)]
                for color in overlay[first..<first + count] {
                    payload += color.map { [1, $0.r, $0.g, $0.b] } ?? [0, 0, 0, 0]
                }
                return reply(payload)
            case .setOverlay:
                let first = Int(a[1]), count = Int(a[2])
                guard count <= 7, first + count <= 68 else { return fail(.badArgument) }
                for i in 0..<count {
                    let e = Array(a[(3 + 4 * i)..<(7 + 4 * i)])
                    overlay[first + i] = e[0] & 1 == 1 ? RGB(e[1], e[2], e[3]) : nil
                }
                dirty = true
                return reply()
            case .clearOverlay:
                overlay = [RGB?](repeating: nil, count: 68)
                dirty = true
                return reply()
            case .save:
                savedBase = base
                savedOverlay = overlay
                dirty = false
                return reply()
            }
        }
    }
}
```

- [ ] **Step 3: Write the failing client tests**

<!-- file: app/Tests/DuckyCoreTests/KeyboardClientTests.swift -->
```swift
import XCTest
@testable import DuckyCore

final class KeyboardClientTests: XCTestCase {
    func testInfoStateAndEffectsPaging() throws {
        let fake = FakeKeyboard(effectIDs: Array(1...30))
        let client = KeyboardClient(transport: fake)
        XCTAssertEqual(try client.ping().version, 2)
        XCTAssertEqual(try client.info(), KeyboardInfo(version: 2, ledCount: 68, effectCount: 30, persistent: true))
        XCTAssertEqual(try client.effects(count: 30), Array(1...30))
        XCTAssertEqual(fake.commands().filter { $0 == .getEffects }.count, 2)
        XCTAssertEqual(try client.state().base, BaseSettings())
    }

    func testOverlayRoundTripAndChangedChunksOnly() throws {
        let fake = FakeKeyboard()
        let client = KeyboardClient(transport: fake)
        var colors = [RGB?](repeating: nil, count: 68)
        colors[0] = RGB(1, 2, 3)
        colors[67] = RGB(4, 5, 6)
        try client.setOverlay(colors)
        XCTAssertEqual(fake.commands().filter { $0 == .setOverlay }.count, 10)
        XCTAssertEqual(try client.overlay(ledCount: 68), colors)

        colors[20] = RGB(7, 7, 7)
        let before = fake.commands().count
        try client.setOverlay(colors, only: [20])
        XCTAssertEqual(Array(fake.commands().dropFirst(before)), [.setOverlay])
        XCTAssertEqual(fake.overlay[20], RGB(7, 7, 7))
    }

    func testStatusErrorsPropagate() {
        let fake = FakeKeyboard()
        let client = KeyboardClient(transport: fake)
        XCTAssertThrowsError(try client.setBase(BaseSettings(effectID: 99))) { error in
            XCTAssertEqual(error as? DuckyError, .status(.setBase, .badArgument))
        }
    }

    func testMismatchedReplyIsRejected() {
        let reply = DuckyProtocol.request(.getState)
        XCTAssertThrowsError(try DuckyProtocol.payload(of: reply, for: .save))
    }

    func testDisconnectedKeyboardThrows() {
        let client = KeyboardClient(transport: FakeKeyboard(connected: false))
        XCTAssertThrowsError(try client.ping()) { error in
            XCTAssertEqual(error as? DuckyError, .notConnected)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `cd app && swift test --filter KeyboardClientTests`
Expected: FAIL, `cannot find 'KeyboardClient' in scope`.

- [ ] **Step 5: Implement the client**

<!-- file: app/Sources/DuckyCore/KeyboardClient.swift -->
```swift
import Foundation

/// Protocol v2 operations over a transport. Blocking: use it from a background queue.
public final class KeyboardClient: @unchecked Sendable {
    public let transport: HIDTransport
    public var timeout: TimeInterval = 1.0

    public init(transport: HIDTransport) {
        self.transport = transport
    }

    @discardableResult
    private func send(_ report: [UInt8]) throws -> [UInt8] {
        guard let command = Command(rawValue: report[0]) else { throw DuckyError.malformedReply }
        let reply = try transport.exchange(report, timeout: timeout)
        return try DuckyProtocol.payload(of: reply, for: command)
    }

    public func ping() throws -> (version: Int, ledCount: Int) {
        try DuckyProtocol.decodePing(send(DuckyProtocol.request(.ping)))
    }

    public func info() throws -> KeyboardInfo {
        try DuckyProtocol.decodeInfo(send(DuckyProtocol.request(.getInfo)))
    }

    public func effects(count: Int) throws -> [UInt8] {
        var ids: [UInt8] = []
        while ids.count < count {
            let page = try DuckyProtocol.decodeEffects(send(DuckyProtocol.request(.getEffects, [UInt8(ids.count)])))
            guard !page.ids.isEmpty else { break }
            ids += page.ids
        }
        return ids
    }

    public func state() throws -> KeyboardState {
        try DuckyProtocol.decodeState(send(DuckyProtocol.request(.getState)))
    }

    public func setBase(_ base: BaseSettings) throws {
        try send(DuckyProtocol.setBase(base))
    }

    public func overlay(ledCount: Int) throws -> [RGB?] {
        var colors: [RGB?] = []
        while colors.count < ledCount {
            let page = try DuckyProtocol.decodeOverlay(send(DuckyProtocol.request(.getOverlay, [UInt8(colors.count)])))
            guard !page.colors.isEmpty else { break }
            colors += page.colors
        }
        return colors
    }

    /// Writes the overlay in reports of 7 LEDs; with `only`, skips reports without a changed LED.
    public func setOverlay(_ colors: [RGB?], only changed: Set<Int>? = nil) throws {
        for first in stride(from: 0, to: colors.count, by: DuckyProtocol.overlayPerReport) {
            let range = first..<min(first + DuckyProtocol.overlayPerReport, colors.count)
            if let changed, !range.contains(where: changed.contains) { continue }
            try send(DuckyProtocol.setOverlay(first: first, colors: Array(colors[range])))
        }
    }

    public func clearOverlay() throws {
        try send(DuckyProtocol.request(.clearOverlay))
    }

    public func save() throws {
        try send(DuckyProtocol.request(.save))
    }

    public func setHostMode(_ on: Bool) throws {
        try send(DuckyProtocol.request(.hostMode, [on ? 1 : 0]))
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `cd app && swift test --filter KeyboardClientTests`
Expected: 5 tests pass.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/DuckyCore/HIDTransport.swift app/Sources/DuckyCore/KeyboardClient.swift app/Tests/DuckyCoreTests/FakeKeyboard.swift app/Tests/DuckyCoreTests/KeyboardClientTests.swift
git commit -m "App: HID transport abstraction, protocol v2 client and simulated keyboard"
```

---

### Task 7: Lighting controller

**Files:**
- Create: `app/Sources/DuckyCore/LightingController.swift`
- Create: `app/Tests/DuckyCoreTests/LightingControllerTests.swift`

**Interfaces:**
- Consumes: `HIDTransport`, `KeyboardClient`, `Preset`, `Effect`/`EffectCatalog`, `KeyboardLayout.ledCount`.
- Produces: `@MainActor @Observable final class LightingController(transport:saveDelay:)` with read-only `connection: Connection` (`.disconnected`, `.outdatedFirmware(version:)`, `.connected`), `saveState: SaveState` (`.saved`, `.pending`, `.failed(String)`), `hostMode`, `base`, `overlay: [RGB?]`, `effects: [Effect]`, `info: KeyboardInfo?`, `lastError: String?`, `canControl: Bool`; methods `start()`, `refresh()`, `setBase(_:)`, `paint(_:color:)`, `fill(_:)`, `clearOverlay()`, `apply(_:)`, `releaseHostMode()`.

- [ ] **Step 1: Write the failing tests**

<!-- file: app/Tests/DuckyCoreTests/LightingControllerTests.swift -->
```swift
import XCTest
@testable import DuckyCore

@MainActor
final class LightingControllerTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func started(_ fake: FakeKeyboard, saveDelay: TimeInterval = 0.1) async -> LightingController {
        let controller = LightingController(transport: fake, saveDelay: saveDelay)
        controller.start()
        await waitUntil { controller.connection != .disconnected }
        return controller
    }

    func testConnectReadsKeyboardState() async {
        let fake = FakeKeyboard()
        fake.base = BaseSettings(effectID: 7, hue: 42)
        fake.overlay[3] = RGB(9, 9, 9)
        let controller = await started(fake)
        XCTAssertEqual(controller.connection, .connected)
        XCTAssertEqual(controller.base.effectID, 7)
        XCTAssertEqual(controller.overlay[3], RGB(9, 9, 9))
        XCTAssertEqual(controller.effects.count, 14)
        XCTAssertEqual(controller.info?.persistent, true)
    }

    func testOutdatedFirmwareBlocksControl() async {
        let fake = FakeKeyboard(version: 1)
        let controller = await started(fake)
        XCTAssertEqual(controller.connection, .outdatedFirmware(version: 1))
        XCTAssertFalse(controller.canControl)
        let before = fake.commands().count
        controller.setBase(BaseSettings(effectID: 2))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.commands().count, before)
    }

    func testBurstOfChangesSavesOnce() async {
        let fake = FakeKeyboard()
        let controller = await started(fake, saveDelay: 0.2)
        for speed in UInt8(1)...5 {
            controller.setBase(BaseSettings(effectID: 1, speed: speed))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(controller.saveState, .pending)
        await waitUntil { controller.saveState == .saved }
        XCTAssertEqual(fake.commands().filter { $0 == .setBase }.count, 5)
        XCTAssertEqual(fake.commands().filter { $0 == .save }.count, 1)
        XCTAssertEqual(fake.savedBase?.speed, 5)
    }

    func testApplyPresetWritesBaseAndOverlay() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        let preset = Preset.builtIns.first { $0.name == "Jeu ZQSD" }!
        controller.apply(preset)
        XCTAssertTrue(preset.matches(base: controller.base, overlay: controller.overlay))
        await waitUntil { controller.saveState == .saved && fake.savedOverlay != nil }
        XCTAssertEqual(fake.savedBase, preset.base)
        XCTAssertEqual(fake.savedOverlay, preset.overlayColors())
    }

    func testPaintEraseAndClear() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        controller.paint([0, 1], color: RGB(255, 0, 0))
        controller.paint([1], color: nil)
        await waitUntil { fake.overlay[0] != nil }
        XCTAssertEqual(controller.overlay[0], RGB(255, 0, 0))
        XCTAssertNil(controller.overlay[1])
        controller.clearOverlay()
        await waitUntil { fake.overlay[0] == nil }
        XCTAssertTrue(controller.overlay.allSatisfy { $0 == nil })
    }

    func testReconnectRefreshesState() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        fake.setConnected(false)
        await waitUntil { controller.connection == .disconnected }
        fake.base = BaseSettings(effectID: 9)
        fake.setConnected(true)
        await waitUntil { controller.connection == .connected && controller.base.effectID == 9 }
        XCTAssertEqual(controller.base.effectID, 9)
    }

    func testRejectedCommandIsReported() async {
        let fake = FakeKeyboard()
        let controller = await started(fake)
        fake.failNext(.setBase, with: .badArgument)
        controller.setBase(BaseSettings(effectID: 3))
        await waitUntil { controller.lastError != nil }
        XCTAssertNotNil(controller.lastError)
    }

    func testReleaseHostMode() async {
        let fake = FakeKeyboard()
        fake.hostMode = true
        let controller = await started(fake)
        XCTAssertTrue(controller.hostMode)
        controller.releaseHostMode()
        await waitUntil { !fake.hostMode }
        XCTAssertFalse(controller.hostMode)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app && swift test --filter LightingControllerTests`
Expected: FAIL, `cannot find 'LightingController' in scope`.

- [ ] **Step 3: Implement the controller**

<!-- file: app/Sources/DuckyCore/LightingController.swift -->
```swift
import Foundation
import Observation

/// App-facing state of the keyboard. Edits apply to the keyboard immediately; one save is sent
/// `saveDelay` seconds after the last edit. HID work runs on a serial queue, in call order.
@MainActor
@Observable
public final class LightingController {
    public enum Connection: Equatable, Sendable {
        case disconnected
        case outdatedFirmware(version: Int)
        case connected
    }

    public enum SaveState: Equatable, Sendable {
        case saved
        case pending
        case failed(String)
    }

    public private(set) var connection: Connection = .disconnected
    public private(set) var saveState: SaveState = .saved
    public private(set) var hostMode = false
    public private(set) var base = BaseSettings()
    public private(set) var overlay = [RGB?](repeating: nil, count: KeyboardLayout.ledCount)
    public private(set) var effects: [Effect] = []
    public private(set) var info: KeyboardInfo?
    public private(set) var lastError: String?

    public var canControl: Bool { connection == .connected }

    private let transport: HIDTransport
    private let client: KeyboardClient
    private let queue = DispatchQueue(label: "ducky-rgb.hid")
    private let saveDelay: TimeInterval
    private var editGeneration = 0

    public init(transport: HIDTransport, saveDelay: TimeInterval = 2) {
        self.transport = transport
        self.client = KeyboardClient(transport: transport)
        self.saveDelay = saveDelay
    }

    public func start() {
        transport.onConnectionChange = { [weak self] connected in
            Task { @MainActor in self?.connectionChanged(connected) }
        }
        transport.start()
        if transport.isConnected { connectionChanged(true) }
    }

    private func connectionChanged(_ connected: Bool) {
        if connected {
            refresh()
        } else {
            connection = .disconnected
            saveState = .saved
            info = nil
        }
    }

    private struct Snapshot: Sendable {
        let version: Int
        let info: KeyboardInfo?
        let effectIDs: [UInt8]
        let state: KeyboardState?
        let overlay: [RGB?]
    }

    private nonisolated static func readSnapshot(_ client: KeyboardClient) throws -> Snapshot {
        let ping = try client.ping()
        guard ping.version >= DuckyProtocol.version else {
            return Snapshot(version: ping.version, info: nil, effectIDs: [], state: nil, overlay: [])
        }
        let info = try client.info()
        return Snapshot(version: ping.version, info: info, effectIDs: try client.effects(count: info.effectCount),
                        state: try client.state(), overlay: try client.overlay(ledCount: info.ledCount))
    }

    /// Re-reads everything from the keyboard.
    public func refresh() {
        queue.async { [client] in
            let result = Result { try Self.readSnapshot(client) }
            Task { @MainActor [weak self] in self?.apply(snapshot: result) }
        }
    }

    private func apply(snapshot result: Result<Snapshot, Error>) {
        switch result {
        case .failure(let error):
            report(error)
        case .success(let snapshot):
            guard let info = snapshot.info, let state = snapshot.state else {
                connection = .outdatedFirmware(version: snapshot.version)
                return
            }
            self.info = info
            effects = EffectCatalog.effects(for: snapshot.effectIDs)
            base = state.base
            hostMode = state.hostMode
            overlay = snapshot.overlay
            saveState = state.dirty ? .pending : .saved
            lastError = nil
            connection = .connected
            if state.dirty { scheduleSave() }
        }
    }

    public func setBase(_ new: BaseSettings) {
        guard canControl, new != base else { return }
        base = new
        edit { try $0.setBase(new) }
    }

    /// Sets (or erases, with nil) the custom colour of the given LEDs.
    public func paint(_ indices: [Int], color: RGB?) {
        guard canControl else { return }
        var changed = Set<Int>()
        for i in indices where overlay.indices.contains(i) && overlay[i] != color {
            overlay[i] = color
            changed.insert(i)
        }
        guard !changed.isEmpty else { return }
        let colors = overlay
        edit { try $0.setOverlay(colors, only: changed) }
    }

    public func fill(_ color: RGB) {
        paint(Array(overlay.indices), color: color)
    }

    public func clearOverlay() {
        guard canControl else { return }
        overlay = [RGB?](repeating: nil, count: overlay.count)
        edit { try $0.clearOverlay() }
    }

    public func apply(_ preset: Preset) {
        guard canControl else { return }
        base = preset.base
        overlay = preset.overlayColors(ledCount: overlay.count)
        let newBase = base, colors = overlay
        let custom = Set(colors.indices.filter { colors[$0] != nil })
        edit { client in
            try client.setBase(newBase)
            try client.clearOverlay()
            try client.setOverlay(colors, only: custom)
        }
    }

    /// Takes the LEDs back from the CLI's live mode.
    public func releaseHostMode() {
        guard canControl else { return }
        hostMode = false
        queue.async { [client] in
            do { try client.setHostMode(false) } catch {
                Task { @MainActor [weak self] in self?.report(error) }
            }
        }
    }

    private func edit(_ work: @escaping @Sendable (KeyboardClient) throws -> Void) {
        queue.async { [client] in
            do { try work(client) } catch {
                Task { @MainActor [weak self] in self?.report(error) }
            }
        }
        scheduleSave()
    }

    private func scheduleSave() {
        editGeneration += 1
        let generation = editGeneration
        saveState = .pending
        let delay = UInt64(saveDelay * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.saveIfLatest(generation)
        }
    }

    private func saveIfLatest(_ generation: Int) {
        guard generation == editGeneration, canControl else { return }
        queue.async { [client] in
            let result = Result { try client.save() }
            Task { @MainActor [weak self] in
                guard let self, generation == self.editGeneration else { return }
                switch result {
                case .success: self.saveState = .saved
                case .failure(let error):
                    self.saveState = .failed(Self.describe(error))
                    self.report(error)
                }
            }
        }
    }

    private func report(_ error: Error) {
        lastError = Self.describe(error)
        if case DuckyError.notConnected = error { connection = .disconnected }
    }

    public nonisolated static func describe(_ error: Error) -> String {
        switch error as? DuckyError {
        case .notConnected: return "Clavier non connecté"
        case .timeout: return "Le clavier ne répond pas"
        case .malformedReply: return "Réponse inattendue du clavier"
        case .status(let command, let status): return "Commande \(command) refusée (\(status))"
        case .outdatedFirmware(let version): return "Firmware v\(version) à mettre à jour"
        case nil: return error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter LightingControllerTests`
Expected: 8 tests pass.

- [ ] **Step 5: Run the whole suite and commit**

Run: `cd app && swift test`
Expected: all tests pass.

```bash
git add app/Sources/DuckyCore/LightingController.swift app/Tests/DuckyCoreTests/LightingControllerTests.swift
git commit -m "App: observable lighting controller with live edits and debounced save"
```

---

### Task 8: IOKit HID transport

**Files:**
- Create: `app/Sources/DuckyCore/IOKitHIDTransport.swift`

**Interfaces:**
- Consumes: `HIDTransport`, `DuckyError` (Tasks 3, 6).
- Produces: `public final class IOKitHIDTransport: HIDTransport` with `init()`; matches VID `0x445B`, PID `0x07AE`, usage page `0xFF60`, usage `0x61`.

- [ ] **Step 1: Implement the transport**

<!-- file: app/Sources/DuckyCore/IOKitHIDTransport.swift -->
```swift
import Foundation
import IOKit.hid

/// Raw HID connection through IOHIDManager. Device callbacks run on the main run loop; `exchange`
/// blocks a background thread until the matching reply arrives.
public final class IOKitHIDTransport: HIDTransport, @unchecked Sendable {
    public static let vendorID = 0x445B
    public static let productID = 0x07AE
    public static let usagePage = 0xFF60
    public static let usage = 0x61

    public var onConnectionChange: (@Sendable (Bool) -> Void)?
    public var isConnected: Bool { lock.withLock { device != nil } }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let lock = NSLock()
    private var device: IOHIDDevice?
    private var inbox: [[UInt8]] = []
    private let arrival = DispatchSemaphore(value: 0)
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var started = false

    public init() {}

    deinit {
        inputBuffer.deallocate()
    }

    public func start() {
        guard !started else { return }
        started = true
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
            kIOHIDPrimaryUsagePageKey: Self.usagePage,
            kIOHIDPrimaryUsageKey: Self.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<IOKitHIDTransport>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<IOKitHIDTransport>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func attach(_ newDevice: IOHIDDevice) {
        guard IOHIDDeviceOpen(newDevice, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(newDevice, inputBuffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<IOKitHIDTransport>.fromOpaque(context).takeUnretainedValue().receive(bytes)
        }, context)
        lock.withLock { device = newDevice }
        onConnectionChange?(true)
    }

    private func detach(_ oldDevice: IOHIDDevice) {
        let removed = lock.withLock { () -> Bool in
            guard let current = device, CFEqual(current, oldDevice) else { return false }
            device = nil
            return true
        }
        if removed { onConnectionChange?(false) }
    }

    private func receive(_ report: [UInt8]) {
        lock.withLock { inbox.append(report) }
        arrival.signal()
    }

    public func exchange(_ report: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        precondition(!Thread.isMainThread, "exchange blocks; call it off the main thread")
        guard let device = lock.withLock({ self.device }) else { throw DuckyError.notConnected }
        lock.withLock { inbox.removeAll() }
        while arrival.wait(timeout: .now()) == .success {}
        let status = report.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, buffer.baseAddress!, buffer.count)
        }
        guard status == kIOReturnSuccess else { throw DuckyError.notConnected }
        let deadline = DispatchTime.now() + timeout
        while true {
            guard arrival.wait(timeout: deadline) == .success else { throw DuckyError.timeout }
            let reply = lock.withLock { inbox.isEmpty ? nil : inbox.removeFirst() }
            // Replies to an earlier command that timed out can still arrive: skip them.
            if let reply, reply.first == report.first { return reply }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd app && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Smoke-test against the keyboard (any firmware)**

Create a throwaway check in the scratchpad (not committed) that pings the keyboard through the transport. With the current v1 firmware the expected output is `ping: version 1, 68 LEDs`; with no keyboard, `notConnected` after 1 s.

```swift
// scratch: app/.build/smoke/main.swift — run with `swift run` from a temp package depending on DuckyCore
import DuckyCore
import Foundation
let transport = IOKitHIDTransport()
transport.start()
DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
    do {
        let ping = try KeyboardClient(transport: transport).ping()
        print("ping: version \(ping.version), \(ping.ledCount) LEDs")
    } catch { print("error:", error) }
    exit(0)
}
RunLoop.main.run()
```

- [ ] **Step 4: Commit**

```bash
git add app/Sources/DuckyCore/IOKitHIDTransport.swift
git commit -m "App: IOKit raw HID transport with hotplug and stale-reply filtering"
```

---

### Task 9: SwiftUI app (menu bar + window)

**Files:**
- Replace: `app/Sources/DuckyRGB/DuckyRGBApp.swift`
- Create: `app/Sources/DuckyRGB/SharedViews.swift`
- Create: `app/Sources/DuckyRGB/MenuContent.swift`
- Create: `app/Sources/DuckyRGB/MainWindow.swift`
- Create: `app/Sources/DuckyRGB/EditorView.swift`
- Create: `app/Sources/DuckyRGB/KeyboardCanvas.swift`
- Create: `app/Sources/DuckyRGB/PresetsView.swift`
- Create: `app/Sources/DuckyRGB/SettingsView.swift`

**Interfaces:**
- Consumes: `LightingController`, `PresetStore`, `Preset`, `EffectCatalog`, `KeyboardLayout`, `LightingPreview`, `IOKitHIDTransport`, `RGB`, `BaseSettings`.
- Produces: the `Ducky RGB` executable (UI only; verified by building and by the manual checklist in Task 10).

- [ ] **Step 1: App entry point and shared model**

<!-- file: app/Sources/DuckyRGB/DuckyRGBApp.swift -->
```swift
import AppKit
import DuckyCore
import SwiftUI

@MainActor
final class AppModel {
    static let shared = AppModel()
    let controller = LightingController(transport: IOKitHIDTransport())
    let presets = PresetStore.standard()
}

enum DockIcon {
    static let key = "showDockIcon"

    static func apply(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            DockIcon.apply(UserDefaults.standard.bool(forKey: DockIcon.key))
            AppModel.shared.controller.start()
        }
    }
}

@main
struct DuckyRGBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model.controller)
                .environment(model.presets)
        } label: {
            Image(systemName: "keyboard")
        }
        .menuBarExtraStyle(.window)

        Window("Ducky RGB", id: MainWindow.id) {
            MainWindow()
                .environment(model.controller)
                .environment(model.presets)
        }
        .defaultSize(width: 980, height: 640)
    }
}
```

- [ ] **Step 2: Shared views (status, host banner, base controls, colour bridges, name prompt)**

<!-- file: app/Sources/DuckyRGB/SharedViews.swift -->
```swift
import AppKit
import DuckyCore
import SwiftUI

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255, opacity: 1)
    }
}

extension RGB {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func byte(_ x: CGFloat) -> UInt8 { UInt8(max(0, min(255, (x * 255).rounded()))) }
        self.init(byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent))
    }

    /// Readable legend colour on top of this key colour.
    var legendColor: Color {
        let luminance = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
        return luminance > 140 ? .black : .white
    }
}

struct StatusHeader: View {
    @Environment(LightingController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text("Ducky One 2 SF").font(.headline)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if let error = controller.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var dotColor: Color {
        switch controller.connection {
        case .disconnected: return .gray
        case .outdatedFirmware: return .orange
        case .connected:
            if case .failed = controller.saveState { return .red }
            return .green
        }
    }

    private var detail: String {
        switch controller.connection {
        case .disconnected: return "Non détecté"
        case .outdatedFirmware(let version): return "Firmware v\(version) : à mettre à jour (protocole v2 requis)"
        case .connected:
            switch controller.saveState {
            case .saved: return "Connecté · enregistré dans le clavier"
            case .pending: return "Connecté · modifications en cours…"
            case .failed(let message): return "Échec d'enregistrement : \(message)"
            }
        }
    }
}

struct HostModeBanner: View {
    @Environment(LightingController.self) private var controller

    var body: some View {
        if controller.hostMode {
            HStack {
                Label("Contrôlé par la CLI", systemImage: "terminal")
                Spacer()
                Button("Reprendre la main") { controller.releaseHostMode() }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.orange.opacity(0.15)))
        }
    }
}

/// Effect, on/off, colour, brightness and speed of the base layer.
struct BaseControls: View {
    @Environment(LightingController.self) private var controller
    private let showsColor: Bool

    init(showsColor: Bool = true) {
        self.showsColor = showsColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Fond allumé", isOn: binding(\.enabled))
            Picker("Effet", selection: binding(\.effectID)) {
                ForEach(controller.effects) { effect in
                    Text(effect.name).tag(effect.id)
                }
            }
            if showsColor {
                ColorPicker("Couleur du fond", selection: baseColor, supportsOpacity: false)
            }
            LabeledContent("Luminosité") {
                Slider(value: level(\.brightness), in: 0...200)
            }
            LabeledContent("Vitesse") {
                Slider(value: level(\.speed), in: 0...255)
            }
        }
        .disabled(!controller.canControl)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<BaseSettings, T>) -> Binding<T> {
        Binding(
            get: { controller.base[keyPath: keyPath] },
            set: { value in
                var base = controller.base
                base[keyPath: keyPath] = value
                controller.setBase(base)
            }
        )
    }

    private func level(_ keyPath: WritableKeyPath<BaseSettings, UInt8>) -> Binding<Double> {
        Binding(
            get: { Double(controller.base[keyPath: keyPath]) },
            set: { value in
                var base = controller.base
                base[keyPath: keyPath] = UInt8(max(0, min(255, value.rounded())))
                controller.setBase(base)
            }
        )
    }

    /// Hue and saturation of the base; brightness stays on its own slider.
    private var baseColor: Binding<Color> {
        Binding(
            get: { Color(RGB(hue: controller.base.hue, saturation: controller.base.saturation, value: 255)) },
            set: { color in
                guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
                var base = controller.base
                base.hue = UInt8(max(0, min(255, (ns.hueComponent * 256).rounded(.down))))
                base.saturation = UInt8(max(0, min(255, (ns.saturationComponent * 255).rounded())))
                controller.setBase(base)
            }
        )
    }
}

struct NamePrompt: View {
    private let title: String
    @Binding private var name: String
    private let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(title: String, name: Binding<String>, onSave: @escaping () -> Void) {
        self.title = title
        self._name = name
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Nom", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave()
        dismiss()
    }
}
```

- [ ] **Step 3: Menu bar content**

<!-- file: app/Sources/DuckyRGB/MenuContent.swift -->
```swift
import AppKit
import DuckyCore
import SwiftUI

struct MenuContent: View {
    @Environment(LightingController.self) private var controller
    @Environment(PresetStore.self) private var presets
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MainSection.storageKey) private var section: MainSection = .editor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeader()
            HostModeBanner()
            Divider()
            Text("Presets").font(.caption).foregroundStyle(.secondary)
            ForEach(presets.all) { preset in
                Button {
                    controller.apply(preset)
                } label: {
                    HStack {
                        Image(systemName: "checkmark")
                            .opacity(preset.matches(base: controller.base, overlay: controller.overlay) ? 1 : 0)
                        Text(preset.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!controller.canControl)
            }
            Divider()
            BaseControls(showsColor: false)
            Divider()
            Button("Ouvrir l'éditeur…") { open(.editor) }
            Button("Réglages…") { open(.settings) }
            Button("Quitter Ducky RGB") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 300)
        .onAppear { if controller.canControl { controller.refresh() } }
    }

    private func open(_ target: MainSection) {
        section = target
        openWindow(id: MainWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 4: Main window with sidebar**

<!-- file: app/Sources/DuckyRGB/MainWindow.swift -->
```swift
import DuckyCore
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case editor, presets, settings

    static let storageKey = "mainSection"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: return "Éditeur"
        case .presets: return "Presets"
        case .settings: return "Réglages"
        }
    }

    var icon: String {
        switch self {
        case .editor: return "paintbrush"
        case .presets: return "square.grid.2x2"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindow: View {
    static let id = "main"
    @Environment(LightingController.self) private var controller
    @AppStorage(MainSection.storageKey) private var section: MainSection = .editor

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: selection) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch section {
            case .editor: EditorView()
            case .presets: PresetsView()
            case .settings: SettingsView()
            }
        }
        .onAppear { if controller.canControl { controller.refresh() } }
    }

    private var selection: Binding<MainSection?> {
        Binding(get: { section }, set: { if let value = $0 { section = value } })
    }
}
```

- [ ] **Step 5: Keyboard canvas**

<!-- file: app/Sources/DuckyRGB/KeyboardCanvas.swift -->
```swift
import DuckyCore
import SwiftUI

/// The keyboard drawn to scale. With `onStroke`, clicking or dragging reports each key once per stroke.
struct KeyboardCanvas: View {
    private let colors: [RGB]
    private let onStroke: ((Int) -> Void)?
    @State private var stroked = Set<Int>()

    init(colors: [RGB], onStroke: ((Int) -> Void)? = nil) {
        self.colors = colors
        self.onStroke = onStroke
    }

    var body: some View {
        GeometryReader { geometry in
            let unit = min(geometry.size.width / KeyboardLayout.width, geometry.size.height / KeyboardLayout.height)
            ZStack(alignment: .topLeading) {
                ForEach(KeyboardLayout.keys) { key in
                    let color = colors.indices.contains(key.id) ? colors[key.id] : .black
                    let frame = rect(for: key, unit: unit)
                    RoundedRectangle(cornerRadius: unit * 0.12)
                        .fill(Color(color))
                        .overlay(RoundedRectangle(cornerRadius: unit * 0.12).stroke(.black.opacity(0.35), lineWidth: 1))
                        .overlay(Text(key.legend).font(.system(size: max(7, unit * 0.28), weight: .medium)).foregroundStyle(color.legendColor))
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .frame(width: unit * KeyboardLayout.width, height: unit * KeyboardLayout.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in hit(value.location, unit: unit) }
                    .onEnded { _ in stroked.removeAll() },
                including: onStroke == nil ? .none : .all
            )
        }
        .aspectRatio(KeyboardLayout.width / KeyboardLayout.height, contentMode: .fit)
    }

    private func rect(for key: KeyInfo, unit: CGFloat) -> CGRect {
        CGRect(x: key.x * unit + 2, y: key.y * unit + 2, width: key.width * unit - 4, height: key.height * unit - 4)
    }

    private func hit(_ point: CGPoint, unit: CGFloat) {
        guard unit > 0, let key = KeyboardLayout.key(atX: point.x / unit, y: point.y / unit), !stroked.contains(key.id) else { return }
        stroked.insert(key.id)
        onStroke?(key.id)
    }
}
```

- [ ] **Step 6: Editor**

<!-- file: app/Sources/DuckyRGB/EditorView.swift -->
```swift
import DuckyCore
import SwiftUI

struct EditorView: View {
    enum Tool: Hashable { case brush, eraser }

    @Environment(LightingController.self) private var controller
    @Environment(PresetStore.self) private var presets
    @State private var tool: Tool = .brush
    @State private var brush = Color.red
    @State private var savingPreset = false
    @State private var presetName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusHeader()
                HostModeBanner()
                GroupBox("Fond") {
                    BaseControls().padding(6)
                }
                GroupBox("Touches personnalisées") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Picker("Outil", selection: $tool) {
                                Label("Pinceau", systemImage: "paintbrush").tag(Tool.brush)
                                Label("Gomme", systemImage: "eraser").tag(Tool.eraser)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                            ColorPicker("Couleur", selection: $brush, supportsOpacity: false)
                            Spacer()
                            Button("Tout remplir") { controller.fill(RGB(brush)) }
                            Button("Tout effacer") { controller.clearOverlay() }
                        }
                        KeyboardCanvas(colors: LightingPreview.colors(base: controller.base, overlay: controller.overlay)) { index in
                            controller.paint([index], color: tool == .brush ? RGB(brush) : nil)
                        }
                        Text("Aperçu statique · effet de fond : \(EffectCatalog.name(for: controller.base.effectID)). Le clavier montre le rendu réel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
                HStack {
                    Spacer()
                    Button("Enregistrer comme preset…") {
                        presetName = ""
                        savingPreset = true
                    }
                }
            }
            .padding(20)
            .disabled(!controller.canControl)
        }
        .sheet(isPresented: $savingPreset) {
            NamePrompt(title: "Nouveau preset", name: $presetName) {
                presets.add(Preset(name: presetName, base: controller.base, overlay: controller.overlay))
            }
        }
    }
}
```

- [ ] **Step 7: Presets**

<!-- file: app/Sources/DuckyRGB/PresetsView.swift -->
```swift
import DuckyCore
import SwiftUI

struct PresetsView: View {
    @Environment(LightingController.self) private var controller
    @Environment(PresetStore.self) private var presets
    @State private var renaming: Preset?
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = presets.loadError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(presets.all) { preset in
                        PresetCard(
                            preset: preset,
                            isActive: preset.matches(base: controller.base, overlay: controller.overlay),
                            canApply: controller.canControl,
                            apply: { controller.apply(preset) }
                        )
                        .contextMenu {
                            Button("Dupliquer") { presets.duplicate(id: preset.id) }
                            if !preset.builtIn {
                                Button("Renommer…") {
                                    newName = preset.name
                                    renaming = preset
                                }
                                Button("Supprimer", role: .destructive) { presets.delete(id: preset.id) }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(item: $renaming) { preset in
            NamePrompt(title: "Renommer le preset", name: $newName) {
                presets.rename(id: preset.id, to: newName)
            }
        }
    }
}

struct PresetCard: View {
    let preset: Preset
    let isActive: Bool
    let canApply: Bool
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeyboardCanvas(colors: LightingPreview.colors(base: preset.base, overlay: preset.overlayColors()))
                .allowsHitTesting(false)
            HStack {
                Text(preset.name).font(.headline)
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Appliquer", action: apply).disabled(!canApply)
            }
            Text(preset.builtIn ? "Fourni · \(EffectCatalog.name(for: preset.base.effectID))" : EffectCatalog.name(for: preset.base.effectID))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
    }
}
```

- [ ] **Step 8: Settings**

<!-- file: app/Sources/DuckyRGB/SettingsView.swift -->
```swift
import DuckyCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(LightingController.self) private var controller
    @AppStorage(DockIcon.key) private var showDockIcon = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Application") {
                Toggle("Lancer à l'ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Afficher l'icône dans le Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, show in DockIcon.apply(show) }
            }
            Section("Clavier") {
                StatusHeader()
                if let info = controller.info {
                    LabeledContent("Protocole", value: "v\(info.version)")
                    LabeledContent("LEDs", value: "\(info.ledCount)")
                    LabeledContent("Effets", value: "\(info.effectCount)")
                    LabeledContent("Mémoire persistante", value: info.persistent ? "Oui" : "Non")
                }
                Button("Relire l'état du clavier") { controller.refresh() }
                    .disabled(controller.connection == .disconnected)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Impossible de modifier l'ouverture de session : \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
```

- [ ] **Step 9: Build and run the tests**

Run: `cd app && swift build && swift test`
Expected: `Build complete!` and all tests pass.

- [ ] **Step 10: Commit**

```bash
git add app/Sources/DuckyRGB
git commit -m "App: menu bar extra and main window (editor, presets, settings)"
```

---

### Task 10: App bundle and end-to-end check

**Files:**
- Create: `app/scripts/bundle.sh`

**Interfaces:**
- Consumes: the `DuckyRGB` product (Task 9).
- Produces: `app/build/Ducky RGB.app` (ad hoc signed).

- [ ] **Step 1: Write the bundle script**

<!-- file: app/scripts/bundle.sh -->
```sh
#!/bin/sh
# Builds "Ducky RGB.app" from the Swift package, ad hoc signed for local use.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product DuckyRGB
BIN="$(swift build -c release --show-bin-path)/DuckyRGB"
APP="build/Ducky RGB.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DuckyRGB"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DuckyRGB</string>
    <key>CFBundleIdentifier</key><string>com.akkamir.ducky-rgb</string>
    <key>CFBundleName</key><string>Ducky RGB</string>
    <key>CFBundleDisplayName</key><string>Ducky RGB</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
```

- [ ] **Step 2: Build the bundle**

Run: `chmod +x app/scripts/bundle.sh && app/scripts/bundle.sh`
Expected: last line `build/Ducky RGB.app`; `codesign -v "app/build/Ducky RGB.app"` exits 0.

- [ ] **Step 3: Launch and check against the connected keyboard**

Run: `open "app/build/Ducky RGB.app"`, then check that the process is alive: `pgrep -fl DuckyRGB`.
With the v1 firmware still on the keyboard, the menu shows "Firmware v1 : à mettre à jour" and controls are disabled. Take a screenshot of the menu if the environment allows it; otherwise rely on the process check and the transport smoke test of Task 8.

- [ ] **Step 4: Commit**

```bash
git add app/scripts/bundle.sh
git commit -m "App: bundle script producing an ad hoc signed Ducky RGB.app"
```

---

### Task 11: Documentation and handoff

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.local.md` (local only, not committed)
- Modify: `NOTES.md` (local only, not committed)

- [ ] **Step 1: README section**

Add after the "CLI" section of `README.md`:

````markdown
## macOS app (v1, firmware v2 required)

`app/` is a native SwiftUI app: a menu bar extra (presets, on/off, brightness, speed, effect) and a
window with a keyboard editor (base effect and per-key colours with brush/eraser), a preset library
and settings (launch at login, Dock icon). Edits reach the keyboard immediately and are saved in the
keyboard's flash 2 s after the last change, so the lighting survives a replug with the app closed.

```sh
cd app
swift test                 # protocol, layout, presets, controller (simulated keyboard)
scripts/bundle.sh          # builds app/build/Ducky RGB.app (ad hoc signed)
open "build/Ducky RGB.app"
```

It needs the firmware v2 `hostrgb` keymap (protocol v2 + wear-leveled EEPROM). The CLI's `info`,
`state`, `base`, `paint`, `unpaint`, `clear-overlay` and `save` commands exercise the same protocol.
````

- [ ] **Step 2: Local notes**

Add to `CLAUDE.local.md` under "Pistes ouvertes" a section "App v1" listing: branches `app-v1` / `ducky-sf-rgb-v2`, firmware v2 built but not flashed, hardware checklist (Task 12), and that `main` must only receive the merge after hardware validation.

- [ ] **Step 3: Commit and push the feature branches**

```bash
git add README.md
git commit -m "Document the macOS app"
git -C firmware/qmk_firmware push -u fork ducky-sf-rgb-v2
git add firmware/qmk_firmware
git commit -m "Point firmware submodule at protocol v2 (branch ducky-sf-rgb-v2)"
git push -u origin app-v1
```

---

### Task 12: Hardware validation (with the user, after their return)

Not automatable: flashing needs the D key held while plugging in.

- [ ] Flash `ducky_one2sf_1967st_iso_hostrgb.bin` (v2) with `nu-isp-cli flash`.
- [ ] CLI: `./ducky-rgb info` → `{'version': 2, 'leds': 68, 'effects': 14, 'persistent': True}`.
- [ ] CLI: `./ducky-rgb base --effect 1 --hue 170 --val 120`, `./ducky-rgb paint wasd red`, `./ducky-rgb save`, unplug, replug, `./ducky-rgb state` shows the same base, and the keyboard shows blue with red ZQSD.
- [ ] Every effect id 1-14 renders (`./ducky-rgb base --effect N`).
- [ ] `./ducky-rgb base --off` keeps painted keys lit and the rest dark.
- [ ] App: apply each built-in preset, paint keys, create a preset, quit the app, replug: same lighting.
- [ ] Merge `app-v1` into `main`, update the submodule pointer on `ducky-sf-rgb` or merge `ducky-sf-rgb-v2`, update README binaries table.
