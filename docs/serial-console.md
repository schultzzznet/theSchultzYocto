# Serial console access to the Raspberry Pi

Needed for anything that happens before the network/SSH is up — U-Boot,
kernel boot, a bad image that never gets far enough to answer `ssh`. HDMI+
keyboard works too, but this project is headless by design, so serial is
the practical option.

## Hardware

**The Pi's UART is 3.3V TTL logic, not RS232.** Never connect a real RS232
serial cable/port directly — the voltage (±12V) will damage the GPIO. You
need a **USB-to-TTL serial adapter**, 3.3V.

### Option 1: buy one

A generic "USB to TTL serial adapter, 3.3V" is $6-10. FTDI-chipset ones are
the most plug-and-play on macOS (shows up as `/dev/cu.usbserial-*`, no
driver install). CP2102 (`/dev/cu.SLAB_USBtoUART*`) and CH340
(`/dev/cu.wchusbserial*`/`/dev/cu.usbserial-*`) also work.

### Option 2: repurpose a spare ESP32/ESP8266 dev board

These already have the same USB-serial chip onboard, and — unlike a classic
Arduino Uno/Nano — they're natively **3.3V logic**, the same as the Pi, so
there's no voltage mismatch to worry about.

The trick: hold the microcontroller itself in permanent hardware reset so
it never runs any code or drives its own TX pin, leaving only the onboard
USB-serial *chip* (a separate IC) active as a dumb passthrough:

- ESP32 boards: jumper **EN → GND**
- ESP8266 (NodeMCU/Wemos D1 Mini) boards: jumper **RST → GND**

No firmware, no PlatformIO, nothing to flash — this is a pure hardware
trick. (If you want the ESP32 to instead *actively* bridge the console over
WiFi rather than being tethered to a Mac via USB, see
[tools/esp32-serial-bridge/](../tools/esp32-serial-bridge/) — genuinely
different approach, different wiring, real firmware involved.)

### Option 3 (needs care): spare Arduino Uno/Nano

Same onboard-USB-serial-chip trick (ground `RESET` instead of `EN`), but
standard Uno/Nano boards are **5V logic** — wiring that directly into the
Pi's non-5V-tolerant GPIO risks damaging it. Only do this with a confirmed
3.3V board variant, or add a simple 2-resistor voltage divider on the line
going into the Pi.

## Raspberry Pi GPIO header

Standard 40-pin header, same on Pi 3B/3B+/4/5. Pin 1 is the corner closest
to the SD card slot. Only the first 5 rows matter for this:

```
        3.3V  [ 1] [ 2]  5V
   GPIO2/SDA  [ 3] [ 4]  5V
   GPIO3/SCL  [ 5] [ 6]  GND         <- UART ground
       GPIO4  [ 7] [ 8]  GPIO14/TXD  <- Pi transmits here
         GND  [ 9] [10]  GPIO15/RXD  <- Pi receives here
```

## Wiring reference

Two different schemes have come up for this project — same crossover logic
(their RX to the Pi's TX, their TX to the Pi's RX) but different pins:

**Direct passthrough** (disabled ESP32/ESP8266 or dedicated USB adapter):

| Adapter/board | Pi 3 B+ |
|---|---|
| GND | pin 6 (GND) |
| TX (or TX0) | pin 10 (RXD) — crossed |
| RX (or RX0) | pin 8 (TXD) — crossed |
| `EN`/`RST` → `GND` jumper | (holds the chip inert, ESP32/ESP8266 only) |

**esp32-serial-bridge** (active WiFi bridge firmware, see
[tools/esp32-serial-bridge/](../tools/esp32-serial-bridge/)):

| ESP32 | Pi 3 B+ |
|---|---|
| GND | pin 6 (GND) |
| GPIO16 (RX2) | pin 8 (TXD) — crossed |
| GPIO17 (TX2) | pin 10 (RXD) — crossed |
| *(no EN jumper — this one needs to run its own firmware)* | |

## Connecting from the Mac

Find the device:

```sh
ls /dev/cu.usbserial-* /dev/cu.wchusbserial* /dev/cu.SLAB_USBtoUART* 2>/dev/null
system_profiler SPUSBDataType | grep -B2 -iE "CP210|CH340|FTDI|Silicon Labs"
```

Interactive terminal (`Ctrl-A` then `K`, `y` to quit `screen`):

```sh
screen /dev/cu.usbserial-XXXX 115200
```

Simple raw log-style monitoring instead (what actually got used in this
project — plays nicer with tools that just want to watch/capture output
rather than take over the terminal):

```sh
stty -f /dev/cu.usbserial-XXXX 115200 cs8 -cstopb -parenb raw
cat /dev/cu.usbserial-XXXX
```

WiFi bridge instead of a physical cable (after flashing
`tools/esp32-serial-bridge/`):

```sh
nc pi-serial-bridge.local 8880
```
