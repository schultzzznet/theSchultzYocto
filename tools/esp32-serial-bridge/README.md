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

## Note

This is an unauthenticated, plaintext TCP bridge — fine for a home LAN, same
posture as the rest of this home lab's internal tools. Don't port-forward it
to the internet.
