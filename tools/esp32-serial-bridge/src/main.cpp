// WiFi <-> UART bridge: exposes whatever's wired to GPIO16/17 (a second,
// independent hardware UART -- NOT the USB/programming one) as a plain TCP
// socket on the network. Built for watching the Raspberry Pi's serial
// console without a USB cable tethering it to a specific machine.
//
// This is a genuinely different approach from the "hold the chip in reset,
// borrow its onboard USB-serial chip" trick -- here the ESP32 is fully
// running its own firmware and using its own separate UART peripheral.

#include <WiFi.h>
#include <ESPmDNS.h>
#include "secrets.h"

constexpr int RXD2 = 16;  // to Pi's TXD
constexpr int TXD2 = 17;  // to Pi's RXD
constexpr unsigned long BAUD = 115200;
constexpr uint16_t BRIDGE_PORT = 8880;
constexpr const char *MDNS_NAME = "pi-serial-bridge"; // -> pi-serial-bridge.local

WiFiServer server(BRIDGE_PORT);
WiFiClient client;

void setup() {
  Serial.begin(115200);
  Serial2.begin(BAUD, SERIAL_8N1, RXD2, TXD2);

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("Connecting to WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(250);
    Serial.print(".");
  }
  Serial.println();
  Serial.print("Connected. IP: ");
  Serial.println(WiFi.localIP());

  if (MDNS.begin(MDNS_NAME)) {
    Serial.printf("mDNS up: %s.local\n", MDNS_NAME);
  }

  server.begin();
  Serial.printf("Bridge listening on port %u\n", BRIDGE_PORT);
  Serial.println("Connect with: nc pi-serial-bridge.local 8880");
}

void loop() {
  if (server.hasClient()) {
    if (client && client.connected()) {
      client.stop(); // a new connection replaces any stale one
    }
    client = server.available();
    Serial.println("Client connected");
  }

  if (client && client.connected()) {
    while (client.available()) {
      Serial2.write(client.read());
    }
    while (Serial2.available()) {
      client.write(Serial2.read());
    }
  }
}
