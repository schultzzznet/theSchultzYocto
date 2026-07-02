# esp32-serial-bridge

Turns a spare ESP32 into a WiFi-to-serial bridge for watching the Raspberry
Pi's boot console from anywhere on the LAN, instead of being tethered to a
specific machine over USB.

This is a different technique from the "disable the chip, borrow its
onboard USB-serial chip" trick used for the direct-wired setup: here the
ESP32 actually runs firmware and uses its own second hardware UART.

## Wiring

Uses ESP32 UART2 (separate from the USB/programming UART0) — no EN/reset
jumper needed this time, the chip is meant to be running:

| ESP32 | Pi 3 B+ |
|---|---|
| GND | pin 6 (GND) |
| GPIO16 (RX2) | pin 8 (TXD) — crossed |
| GPIO17 (TX2) | pin 10 (RXD) — crossed |

## Setup

```sh
cp include/secrets.h.example include/secrets.h
# edit include/secrets.h with your real WiFi SSID/password
pio run -t upload
pio device monitor    # watch it join WiFi, note the printed IP (once)
```

After that first boot, USB is only needed for power (or use any 5V source) —
the bridge is fully wireless.

## Use

```sh
nc pi-serial-bridge.local 8880
```

(Plain `nc`/`telnet` — mDNS means you don't need to hunt for the DHCP IP.)
Verified working end-to-end 2026-07-02: resolved to a real LAN IP, and
`nc -w 5 pi-serial-bridge.local 8880` showed live kernel console output and
a login prompt from the Pi. Raw `nc` doesn't render ANSI color/escape
codes that colored boot output uses — they show up as garbled bytes. Use a
real terminal (`screen pi-serial-bridge.local 8880` won't work over a plain
TCP port the way it does over a device file; pipe through `nc` into
something that understands escapes, or just tolerate the noise) if that
matters to you.

## Troubleshooting

**`ping`/`nc` can't resolve `pi-serial-bridge.local` ("Unknown host"):**
- Is `secrets.h` actually filled in with your real SSID/password, not still
  the placeholder from `secrets.h.example`? (`cat include/secrets.h`)
- Is the board actually powered and flashed (`pio run -t upload` succeeded)?
- Same WiFi network/VLAN as whatever you're connecting from — mDNS doesn't
  cross subnets or AP client-isolation.
- One-time sanity check: `pio device monitor` right after a power-on/reset —
  the firmware prints the IP it got over serial, so you can confirm it
  joined WiFi at all even before mDNS enters the picture.

**Flashing (`pio run -t upload`) fails / port busy:**
- Something else may still have the port open (e.g. a direct-passthrough
  monitoring session using the same physical USB-serial adapter). Check
  before flashing: `lsof /dev/cu.usbserial-XXXX` — if a PID shows up, stop
  that process/terminal first.

**Don't use this for flashing a whole SD card image:**
- UART2 here runs at 115200 baud (~11 KB/s). A Yocto image is easily
  100+ MB. That's hours over a raw byte-forwarding link with no error
  correction — this bridge is for watching console/boot output and driving
  U-Boot, not bulk data transfer. See
  [docs/serial-console.md](../../docs/serial-console.md) and
  [docs/first-build.md](../../docs/first-build.md) for the real SD card
  flashing flow (`bmaptool`, physical card swap).

## Note

This is an unauthenticated, plaintext TCP bridge — fine for a home LAN, same
posture as the rest of this home lab's internal tools. Don't port-forward it
to the internet.
