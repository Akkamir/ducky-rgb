"""Read-only: report which mode the Ducky keyboard is in. Sends nothing to the device."""
import hid

NORMAL = (0x0416, 0x0123)                   # stock Ducky firmware (One 2 Mini 1861ST / SF 1967ST)
BOOTLOADER = [(0x0416, 0x3F00), (0x0416, 0xA316)]  # Nuvoton ISP_HID (LDROM)

seen = {}
for d in hid.enumerate():
    key = (d["vendor_id"], d["product_id"])
    if key == NORMAL or key in BOOTLOADER:
        seen.setdefault(key, []).append(d)

if not seen:
    print("Aucun Ducky / bootloader Nuvoton détecté.")
for (vid, pid), ds in seen.items():
    d = ds[0]
    mode = "NORMAL (firmware Ducky)" if (vid, pid) == NORMAL else "BOOTLOADER ISP (prêt pour nu-isp-cli info)"
    print(f"{vid:04x}:{pid:04x}  {mode}")
    print(f"  produit : {d['product_string']!r}  fabricant : {d['manufacturer_string']!r}")
    print(f"  série   : {d['serial_number']!r}")
    print(f"  interfaces HID : {sorted({x['interface_number'] for x in ds})}")
