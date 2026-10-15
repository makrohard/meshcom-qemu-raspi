# Gate 1 round 5, DESIGN v5: s5 runner — second file (Appendix C)

Part of `gate1-DESIGN-s5.md`; the same redaction classes apply. Our files at the prototype commit 6641a6f5 (the design changes them as the plan says) and the scripts the design changes, verbatim.

### overlay/variants/qemu-headless/platformio.ini (6641a6f5)

```
; Private QEMU-only headless target for running MeshCom under classic-ESP32 QEMU.
; Classic ESP32 (esp32dev), the normal MeshCom application platform/framework
; (inherited from [esp32]). NOT SafeBoot.
;
; The ONLY behavioural change vs a normal classic build is gated on the
; compile-time marker QEMU_HEADLESS (radio/BLE/display/battery/PMU/button runtime
; init suppressed; networking via the project-local OpenETH driver instead of
; Wi-Fi). No other target is affected by this file.
;
; The main MeshCom web UI uses CommonWebServer (WiFiServer over lwIP), so no
; AsyncTCP/ESPAsyncWebServer dependency is required here.

[env:qemu-headless]
extends = esp32
board = esp32dev
monitor_speed = 115200

; Single-application layout so the app boots directly under QEMU (no SafeBoot).
board_build.partitions = variants/qemu-headless/partitions-qemu.csv

lib_ignore =
	AceButton
	ETHClass2
	Ethernet
	Adafruit TCA8418
	epdiy
	es7210
	ESP32-audioI2S
	GxEPD2
	lvgl
	SensorLibTDECKpro
	TFT_eSPI
	TinyGSM
	XPowersLib

lib_deps =
	${libs.lib_deps}
	${esp32libs.lib_deps}
	; Display library is pulled by the common build; display init is skipped at runtime.
	olikraus/U8g2@^2.36.5

build_flags =
	${esp32.build_flags}
	${common.build_flags}
	-D BOARD_E22="qemu-headless"
	-D QEMU_HEADLESS=1
	-I variants/${this.__env__}

; --- Opt-in QEMU external-radio target (M13b) -------------------------------
; The qemu-headless target (OpenETH networking; no radio/Wi-Fi/BLE/display/PMU)
; PLUS the firmware's EXTERNAL_RADIO TCP transport, so the REAL MeshCom firmware
; connects to a meshcom-loraham-bridge over the QEMU guest->host route (<host-addr>).
; The default [env:qemu-headless] target above is completely unaffected.
;
; The bridge endpoint and HMAC password are supplied LOCALLY at build time via
; environment variables (NEVER committed):
;     export XR_HOST=<host-addr> XR_PORT=7000 XR_PASSWORD=<secret>
;     scripts/build.sh --env qemu-headless-extradio
; With XR_HOST/XR_PORT unset the firmware's transport stays idle; with no
; XR_PASSWORD it runs open (the bridge requires HMAC, so set one).
;
; Network readiness uses the STRONG override in
; src/qemu/qemu_external_radio_ready.cpp, which gates the connection on STRICT,
; event-backed OpenETH IP connectivity (qemuNetworkReadyEvent()): true only after a
; genuine IP_EVENT_ETH_GOT_IP and cleared on Ethernet loss — never true unconditionally
; and never satisfied by the transparent SLIRP static fallback. The firmware's
; Wi-Fi-specific 30s checkWifiPing watchdog is compiled out in EVERY qemu-headless env
; (QEMU_HEADLESS-gated patch hunk): there is no Wi-Fi under QEMU, so it could only churn
; the web/network lifecycle, close the shared UDP socket and trip the XR readiness gate.
; The default [env:qemu-headless] keeps its SLIRP fallback.
[env:qemu-headless-extradio]
extends = env:qemu-headless
build_flags =
	${env:qemu-headless.build_flags}
	-I variants/qemu-headless
	-D EXTERNAL_RADIO=1
	-D EXTERNAL_RADIO_HOST=\"${sysenv.XR_HOST}\"
	-D EXTERNAL_RADIO_PORT=${sysenv.XR_PORT}
	-D EXTERNAL_RADIO_PASSWORD=\"${sysenv.XR_PASSWORD}\"

; --- Opt-in QEMU virtual-GPS targets (P2) ----------------------------------
; Enable the REAL MeshCom GPS path (gps_functions.cpp / TinyGPSPlus), fed
; line-oriented NMEA over the emulated UART1 (a Unix socket wired by run.sh; fed
; by scripts/gps-relay.py from host gpsd or a synthetic fixture). The default
; [env:qemu-headless] and [env:qemu-headless-extradio] targets are unaffected.
;
; Flags (GPS exists only where these are set; TinyGPSPlus is already inherited):
;   QEMU_GPS            QEMU-only init branch in gps_functions.cpp: bypasses the
;                       hardware bring-up (reset GPIO, baud auto-detect, UBX/PCAS
;                       writes) and enables bGPSON, leaving the byte-by-byte
;                       receive loop and fix/HDOP/sat/age logic unchanged.
;   MESHCOM_QEMU_GPSTEST transition-only [GPSTEST] diagnostic (no coordinates) for
;                       scripts/test-gps.sh; never in default/physical/extradio.
;   GPS_RX_PIN/TX_PIN   SYNTHETIC, non-physical pins (16/17 free on esp32dev);
;                       GPSSerial.begin() just needs args — no GPS HW in QEMU.
;   GPS_BAUDRATE_SETFIX cosmetic over a socket UART (QEMU has no baud).
[env:qemu-headless-gpsd]
extends = env:qemu-headless
build_flags =
	${env:qemu-headless.build_flags}
	-I variants/qemu-headless
	-D ENABLE_GPS
	-D ENABLE_UBLOX
	-D QEMU_GPS=1
	-D MESHCOM_QEMU_GPSTEST=1
	-D GPS_RX_PIN=16
	-D GPS_TX_PIN=17
	-D GPS_BAUDRATE_SETFIX=9600

; The integrated GPS + external-radio profile intentionally OMITS
; MESHCOM_QEMU_GPSTEST: the [GPSTEST] diagnostics belong only to the test profile
; above (qemu-headless-gpsd), keeping this XR-capable profile clean.
[env:qemu-headless-extradio-gpsd]
extends = env:qemu-headless-extradio
build_flags =
	${env:qemu-headless-extradio.build_flags}
	-I variants/qemu-headless
	-D ENABLE_GPS
	-D ENABLE_UBLOX
	-D QEMU_GPS=1
	-D GPS_RX_PIN=16
	-D GPS_TX_PIN=17
	-D GPS_BAUDRATE_SETFIX=9600
```

### overlay/variants/qemu-headless/configuration.h (6641a6f5)

```
/*
 * QEMU-headless variant configuration.
 *
 * A minimal CLASSIC-ESP32 application profile used ONLY for running MeshCom in
 * official ESP32 QEMU. It keeps just enough radio plumbing for the firmware to
 * COMPILE (SX126x chip selection + LoRa control pins), but deliberately enables
 * NO sensors, NO GPS, NO display, NO PMU. At runtime, QEMU_HEADLESS guards in
 * esp32_main.cpp prevent radio/BLE/display/battery/PMU/button initialisation, so
 * none of this hardware is actually driven (there is no such hardware in QEMU).
 *
 * Radio pin definitions are taken from the classic E22 (az-delivery-devkit-v4)
 * application profile so the RadioLib SX1268 module object constructs cleanly;
 * the radio is never brought up under QEMU.
 *
 * This file does NOT change any real board: it only applies to the private
 * qemu-headless target.
 */
#pragma once

#include <Arduino.h>
#include <configuration_global.h>

// --- Radio chip selection (compile-time only; radio.begin() is skipped in QEMU) ---
#define MODUL_HARDWARE EBYTE_E22
#define RF_FREQUENCY 433.175000
#define LORA_APRS_FREQUENCY 433.775000
#define SX126X  // RadioLib SX1268 family

// LoRa control pins (classic E22 / generic ESP32 DevKitC mapping)
#define LORA_RST  27
#define LORA_DIO0 26 // BUSY
#define LORA_DIO1 33
#define LORA_CS   5
#define E22_RXEN  14
#define E22_TXEN  13
#define BOARD_LED 2

#define SX1268_CS   LORA_CS
#define SX1268_IRQ  LORA_DIO1
#define SX1268_RST  LORA_RST
#define SX1268_GPIO LORA_DIO0

// LoRa parameters (used only for settings defaults; no RF in QEMU)
#define LORA_PREAMBLE_LENGTH DEFAULT_PREAMPLE_LENGTH
#define LORA_CR 6
#define LORA_BANDWIDTH 250
#define LORA_SF 11
// 17 dBm: the external-radio path reports this power to the LoRaHAM daemon, which
// accepts 2..17 dBm on SX127x boards and rejects a CONFIGURE outside it — 17 is the
// PA_BOOST maximum, and below 2 the chip drives RFO instead, which is not the pin the
// antenna is on. (Until daemon 1.0.0 the range was 0..20 and this was 20; a firmware
// built at 20 cannot configure an SX127x daemon at all.) The node's power (--txpower,
// stored in NVS; this value by default) goes to the bridge at every XR connect and on a
// change. Irrelevant to non-XR QEMU profiles (radio is disabled there).
#define TX_POWER_MAX 17
#define TX_POWER_MIN 2
#define TX_OUTPUT_POWER 17
#define CURRENT_LIMIT 140
#define WAIT_TX 5

// I2C pins (bus is initialised but no I2C peripherals are present/queried in QEMU)
#define I2C_SDA 21
#define I2C_SCL 22

#define BUTTON_PIN 12

// Upstream's opt-outs for boards without a battery divider / a usable BLE controller (icssw-org dev,
// PR #1166): QEMU emulates neither, so the firmware skips battery measurement and the whole NimBLE stack.
#define DISABLE_BATTERY
#define DISABLE_BLE

// Upstream's Ethernet mode (node_netmode == 1) opens the web, net-console and startNetwork() gates
// without Wi-Fi. Its W5500 driver (src/esp32/esp32_eth.cpp) is compiled but never reached: the OpenETH
// code in src/qemu/ reports the IP before setup() calls startNetwork(). The pins are placeholders.
#define HAS_ETHERNET
#define ETH_CS_PIN    15
#define ETH_INT_PIN   4
#define ETH_RST_PIN   25
#define ETH_SCLK_PIN  18
#define ETH_MISO_PIN  19
#define ETH_MOSI_PIN  23
// startNetwork() (udp_functions.cpp) names the W5500 object `neth` under HAS_ETHERNET, but upstream
// declares and defines it only for its two Ethernet boards. Declared here, defined in src/qemu/.
#ifdef __cplusplus
#include "esp32/esp32_eth.h"
extern EspETH neth;
#endif

// Upstream's neighbour matrix (src/nbr_matrix.h, since v4.40a) requires this value; upstream
// variants get it from src/configuration_default.h, included last. This variant states the one
// value instead: that file switches the fleet's sensor flags on (and older revisions lack it).
// The value is the fleet default, calibrated for this variant's SF11 / BW 250 / CR 4/6.
#ifndef LORA_SNR_STABLE_MIN_DB
#define LORA_SNR_STABLE_MIN_DB (-16)
#endif

// NOTE: intentionally NOT defined for the headless QEMU profile:
//   ENABLE_GPS, ENABLE_BMX280, ENABLE_BMP390, ENABLE_AHT20, ENABLE_SHT21,
//   ENABLE_BMX680, ENABLE_MCP23017, ENABLE_INA226, ENABLE_MC811, ENABLE_RTC,
//   USE_BATT, HAS_TFT, OLED/display defines, XPOWERS_CHIP_* (PMU).
```

### overlay/variants/qemu-headless/partitions-qemu.csv (6641a6f5)

```
# QEMU-headless single-application partition layout.
# No SafeBoot chain: the application boots directly from 0x10000 so a simple
# merged flash image (bootloader@0x1000, partition-table@0x8000, boot_app0@0xe000,
# app@0x10000) runs under QEMU. The partition is named "app" to match the base
# board_build.app_partition_name. 4 MB total.
# Name,   Type, SubType, Offset,   Size,     Flags
nvs,      data, nvs,     0x9000,   0x5000,
otadata,  data, ota,     0xe000,   0x2000,
app,      app,  ota_0,   0x10000,  0x300000,
spiffs,   data, spiffs,  0x310000, 0xE0000,
coredump, data, coredump,0x3F0000, 0x10000,
```

### overlay/variants/qemu-headless/ETHClass2.h (6641a6f5)

```
/*
 * ETHClass2.h — QEMU stand-in for the W5500 driver library that upstream's Ethernet mode calls
 * (src/esp32/esp32_eth.cpp, EspETH::initethDHCP / initethfixIP). It keeps the names and maps them to
 * the OpenETH netif that src/qemu/qemu_network.cpp brings up, so upstream's own hand-over code runs
 * against the emulated network: no SPI, no W5500. Found first on the include path (-I variants/…).
 */
#pragma once

#include <Arduino.h>
#include <IPAddress.h>
#include <driver/spi_common.h>   // spi_host_device_t / SPI3_HOST, as the real library provides

typedef enum { ETH_PHY_W5500 } eth_phy_type_t;

class ETHClass2 {
public:
    // The W5500 signature (phy, addr, cs, irq, rst, spi host, sck, miso, mosi); the pins are ignored.
    bool begin(eth_phy_type_t type, int32_t phy_addr, int cs, int irq, int rst, spi_host_device_t spi_host, int sck, int miso, int mosi);
    bool begin();
    bool linkUp();
    // A static address is not supported under QEMU: user networking assigns the guest address by DHCP.
    bool config(IPAddress local_ip, IPAddress gateway, IPAddress subnet, IPAddress dns1 = IPAddress());
    IPAddress localIP();
    IPAddress gatewayIP();
    IPAddress subnetMask();
    IPAddress dnsIP();
};

extern ETHClass2 ETH;
```

### overlay/variants/qemu-headless/EthernetUdp.h (6641a6f5)

```
/*
 * EthernetUdp.h — QEMU stand-in: upstream's Ethernet code keeps its own EthernetUDP socket
 * (src/esp32/esp32_eth.h). Under QEMU that socket is an ordinary lwIP socket on the OpenETH netif.
 */
#pragma once

#include <WiFiUdp.h>

class EthernetUDP : public WiFiUDP {};
```

### overlay/src/qemu/qemu_network.cpp (6641a6f5, unchanged since main)

```
/*
 * qemu_network.cpp — QEMU-only OpenCores Ethernet (OpenETH) network bring-up.
 *
 * Entire translation unit is gated on QEMU_HEADLESS so it contributes nothing to
 * normal MeshCom builds (and never references the project-local OpenETH driver
 * there). See qemu_network.h.
 */
#ifdef QEMU_HEADLESS

#include "qemu/qemu_network.h"

#include "esp_eth.h"
#include "esp_eth_mac.h"
#include "esp_netif.h"
#include "esp_event.h"
#include "esp_mac.h"

// Project-local OpenETH MAC constructor (vendored ESP-IDF v4.4.7 driver object).
#include "openeth_compat.h"

static volatile bool s_got_ip = false;
// STRICT, event-only readiness: set true ONLY from a genuine IP_EVENT_ETH_GOT_IP and
// cleared on Ethernet loss (DISCONNECTED/STOP/LOST_IP). Unlike s_got_ip it is NEVER set
// by the static SLIRP fallback, so the external-radio transport gate
// (externalRadioNetworkReady -> qemuNetworkReadyEvent) reflects real OpenETH IP
// connectivity only. The default qemu-headless paths keep using s_got_ip/qemuNetworkReady().
static volatile bool s_got_ip_event = false;
static bool s_started = false;
static uint32_t s_start_ms = 0;
static bool s_static_applied = false;
static esp_eth_handle_t s_eth_handle = nullptr;
static esp_eth_netif_glue_handle_t s_eth_glue = nullptr;
static esp_netif_t *s_eth_netif = nullptr;
static esp_netif_ip_info_t s_ip_info = {};

static void eth_event_handler(void *, esp_event_base_t, int32_t event_id, void *)
{
    switch (event_id) {
    case ETHERNET_EVENT_CONNECTED:
        Serial.println("[QEMU]...OpenETH link connected");
        // Belt-and-suspenders: ensure the DHCP client is running on the eth netif,
        // in case the glue auto-start did not run in this (non-Wi-Fi) Arduino context.
        if (s_eth_netif) {
            esp_err_t de = esp_netif_dhcpc_start(s_eth_netif);
            Serial.printf("[QEMU]...dhcpc_start -> 0x%x (0=started, 0x%x=already-running)\n",
                          (int)de, ESP_ERR_ESP_NETIF_DHCP_ALREADY_STARTED);
        }
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        Serial.println("[QEMU]...OpenETH link disconnected");
        // Genuine link loss: clear the strict event-readiness so the external-radio
        // transport's gate drops and it stops safely (recovers on the next GOT_IP).
        s_got_ip_event = false;
        break;
    case ETHERNET_EVENT_START:
        Serial.println("[QEMU]...OpenETH driver started");
        break;
    case ETHERNET_EVENT_STOP:
        Serial.println("[QEMU]...OpenETH driver stopped");
        s_got_ip_event = false;
        break;
    default:
        break;
    }
}

static void got_ip_event_handler(void *, esp_event_base_t, int32_t, void *event_data)
{
    ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
    s_ip_info = event->ip_info;
    Serial.printf("[QEMU]...OpenETH GOT_IP ip=" IPSTR " mask=" IPSTR " gw=" IPSTR "\n",
                  IP2STR(&s_ip_info.ip), IP2STR(&s_ip_info.netmask), IP2STR(&s_ip_info.gw));
    s_got_ip = true;
    // Genuine IP event: this is the ONLY place strict event-readiness becomes true.
    s_got_ip_event = true;
}

// Genuine loss of a usable IPv4 lease (DHCP lease lost / link down). Clears strict
// event-readiness; the external-radio transport gate drops and recovers on the next GOT_IP.
static void lost_ip_event_handler(void *, esp_event_base_t, int32_t, void *)
{
    Serial.println("[QEMU]...OpenETH LOST_IP (usable IPv4 lease lost)");
    s_got_ip_event = false;
}

bool qemuNetworkStart()
{
    if (s_started)
        return true;

    esp_err_t e = esp_netif_init();
    if (e != ESP_OK && e != ESP_ERR_INVALID_STATE) {
        Serial.printf("[QEMU]...esp_netif_init failed: %d\n", (int)e);
        return false;
    }
    e = esp_event_loop_create_default();
    if (e != ESP_OK && e != ESP_ERR_INVALID_STATE) {
        Serial.printf("[QEMU]...esp_event_loop_create_default failed: %d\n", (int)e);
        return false;
    }

    esp_netif_inherent_config_t base_cfg = ESP_NETIF_INHERENT_DEFAULT_ETH();
    esp_netif_config_t netif_cfg = { &base_cfg, nullptr, ESP_NETIF_NETSTACK_DEFAULT_ETH };
    esp_netif_t *netif = esp_netif_new(&netif_cfg);
    if (!netif) {
        Serial.println("[QEMU]...esp_netif_new returned null");
        return false;
    }
    s_eth_netif = netif;

    eth_mac_config_t mac_config = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_config = ETH_PHY_DEFAULT_CONFIG();
    phy_config.autonego_timeout_ms = 100; // per the official OpenETH example

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_config);
    esp_eth_phy_t *phy = esp_eth_phy_new_dp83848(&phy_config);
    if (!mac || !phy) {
        Serial.println("[QEMU]...could not create OpenETH MAC / DP83848 PHY");
        return false;
    }

    esp_eth_config_t config = ETH_DEFAULT_CONFIG(mac, phy);
    if (esp_eth_driver_install(&config, &s_eth_handle) != ESP_OK) {
        Serial.println("[QEMU]...esp_eth_driver_install failed");
        return false;
    }

    // Fixed locally-administered MAC for deterministic behaviour under QEMU.
    uint8_t eth_mac_addr[6] = { 0x02, 0x00, 0x00, 0x4D, 0x32, 0x01 };
    esp_eth_ioctl(s_eth_handle, ETH_CMD_S_MAC_ADDR, eth_mac_addr);

    s_eth_glue = esp_eth_new_netif_glue(s_eth_handle);
    esp_netif_attach(netif, s_eth_glue);

    esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID, &eth_event_handler, nullptr);
    esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP, &got_ip_event_handler, nullptr);
    esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_LOST_IP, &lost_ip_event_handler, nullptr);

    Serial.println("[QEMU]...starting OpenETH (esp_eth_start)");
    if (esp_eth_start(s_eth_handle) != ESP_OK) {
        Serial.println("[QEMU]...esp_eth_start failed");
        return false;
    }

    s_started = true;
    s_start_ms = millis();
    return true;
}

// QEMU-only fallback: if OpenETH DHCP does not produce a lease within the timeout,
// apply the known SLIRP static address so the PoC services can still be exercised.
// This is transparent (logged) and does NOT hide the DHCP outcome: the UART shows
// whether GOT_IP fired or the static fallback was used.
#define QEMU_DHCP_TIMEOUT_MS 8000
static void qemuMaybeApplyStatic()
{
    if (s_got_ip || s_static_applied || !s_started || !s_eth_netif)
        return;
    if (millis() - s_start_ms < QEMU_DHCP_TIMEOUT_MS)
        return;

    s_static_applied = true;
    esp_netif_dhcpc_stop(s_eth_netif);
    esp_netif_ip_info_t ip = {};
    esp_netif_str_to_ip4("<guest-addr>", &ip.ip);
    esp_netif_str_to_ip4("255.255.255.0", &ip.netmask);
    esp_netif_str_to_ip4("<host-addr>", &ip.gw);
    if (esp_netif_set_ip_info(s_eth_netif, &ip) == ESP_OK) {
        s_ip_info = ip;
        s_got_ip = true;
        Serial.println("[QEMU]...DHCP did NOT complete within 8s; applied SLIRP static <guest-addr>/24 gw <host-addr> (fallback)");
    } else {
        Serial.println("[QEMU]...static IP fallback failed");
    }
}

bool qemuNetworkReady()
{
    if (!s_got_ip)
        qemuMaybeApplyStatic();
    return s_got_ip;
}

// STRICT, event-backed readiness for the external-radio transport. True ONLY after a
// genuine IP_EVENT_ETH_GOT_IP and false again on Ethernet loss. Deliberately does NOT
// consult/apply the static SLIRP fallback, so a fallback is never accepted as real
// OpenETH IP readiness for the XR link. Used by the EXTERNAL_RADIO override only.
bool qemuNetworkReadyEvent()
{
    return s_got_ip_event;
}

bool qemuNetworkGetIp(IPAddress &ip, IPAddress &gateway, IPAddress &mask)
{
    if (!s_got_ip)
        return false;
    ip = IPAddress(s_ip_info.ip.addr);
    gateway = IPAddress(s_ip_info.gw.addr);
    mask = IPAddress(s_ip_info.netmask.addr);
    return true;
}

void qemuNetworkStop()
{
    if (!s_started)
        return;
    esp_eth_stop(s_eth_handle);
    s_started = false;
    s_got_ip = false;
    s_got_ip_event = false;
}

#endif // QEMU_HEADLESS
```

### overlay/src/qemu/qemu_network.h (6641a6f5)

```
/*
 * qemu_network.h — QEMU-only OpenCores Ethernet (OpenETH) network bring-up.
 *
 * This is a narrow, QEMU-only interface. It is compiled and used ONLY when
 * QEMU_HEADLESS is defined (the qemu-headless PlatformIO target). On all normal
 * MeshCom targets this header declares nothing and the implementation is empty,
 * so real-board behaviour is completely unchanged.
 *
 * It brings up the OpenCores Ethernet (OpenETH) MAC through the standard
 * ESP-IDF Ethernet / esp_netif / lwIP path, using the project-local
 * lib/openeth_compat driver and the framework DP83848
 * PHY. No Wi-Fi is ever started. Readiness becomes true only after
 * IP_EVENT_ETH_GOT_IP (event-driven, non-blocking).
 */
#pragma once

#ifdef QEMU_HEADLESS

#include <Arduino.h>

// Start OpenETH (idempotent). Non-blocking: returns immediately after starting
// the driver; readiness is signalled later via qemuNetworkReady().
bool qemuNetworkStart();

// True once the QEMU PoC network is usable: after IP_EVENT_ETH_GOT_IP, OR after the
// transparent SLIRP static fallback (see qemuMaybeApplyStatic). Used by the default
// qemu-headless services (web UI / net-console / udp) in both environments.
bool qemuNetworkReady();

// STRICT, event-backed readiness: true ONLY after a genuine IP_EVENT_ETH_GOT_IP and
// cleared on Ethernet loss (DISCONNECTED/STOP/LOST_IP). NEVER satisfied by the static
// SLIRP fallback. This is the predicate the external-radio transport gates on, so the
// XR link only comes up on real OpenETH IP connectivity.
bool qemuNetworkReadyEvent();

// Copies the current IPv4 address/gateway/mask. Returns false if not ready.
bool qemuNetworkGetIp(IPAddress &ip, IPAddress &gateway, IPAddress &mask);

// Stop the OpenETH driver (not used in normal startup; provided for completeness).
void qemuNetworkStop();

#endif // QEMU_HEADLESS
```

### overlay/src/qemu/qemu_external_radio_ready.cpp (6641a6f5)

```
/*
 * qemu_external_radio_ready.cpp — QEMU-only STRONG override of the firmware's
 * weak externalRadioNetworkReady() seam.
 *
 * Compiled ONLY in the opt-in QEMU external-radio build (both QEMU_HEADLESS and
 * EXTERNAL_RADIO defined). It reports readiness true ONLY when the OpenETH
 * interface has actually obtained an IPv4 address via a genuine IP_EVENT_ETH_GOT_IP
 * (qemuNetworkReadyEvent()) — i.e. real guest IP connectivity, NEVER unconditionally
 * and NEVER from the transparent SLIRP static fallback. Readiness is cleared again on
 * genuine Ethernet loss (DISCONNECTED/STOP/LOST_IP), so the transport stops safely and
 * reconnects only when a real IP returns. This keeps the firmware's connection gate
 * honest under emulation: the external radio transport connects to the bridge only once
 * the guest can route to the host (<host-addr>), exactly as the weak Wi-Fi default intends
 * on real hardware.
 *
 * This file is part of the meshcom-qemu-raspi overlay (copied into the workspace
 * by apply-overlay.sh). It lives only in the QEMU harness, never in the firmware
 * repository. On any non-QEMU or non-external-radio build it is empty, so the
 * firmware's weak default (Wi-Fi/STA readiness) is used unchanged.
 */
#if defined(QEMU_HEADLESS) && defined(EXTERNAL_RADIO)

#include "qemu/qemu_network.h"

// Strong (non-weak) definition: at link time this overrides the weak default
// defined in src/esp32/external_radio_glue.cpp. Signature must match exactly.
bool externalRadioNetworkReady(void* /*ctx*/)
{
    // STRICT, event-backed: real OpenETH IP only (never the static SLIRP fallback),
    // cleared on Ethernet loss. The XR transport's own poll() reconnects when it returns.
    return qemuNetworkReadyEvent();
}

#endif // QEMU_HEADLESS && EXTERNAL_RADIO
```

### overlay/src/qemu/qemu_eth_standin.cpp (6641a6f5)

```
/*
 * qemu_eth_standin.cpp — the ETHClass2 stand-in (variants/qemu-headless/ETHClass2.h) on top of
 * qemu_network.cpp. QEMU_HEADLESS only.
 */
#ifdef QEMU_HEADLESS

#include "qemu/qemu_network.h"
#include <ETHClass2.h>

ETHClass2 ETH;

bool ETHClass2::begin(eth_phy_type_t, int32_t, int, int, int, spi_host_device_t, int, int, int) { return qemuNetworkStart(); }
bool ETHClass2::begin() { return qemuNetworkStart(); }
bool ETHClass2::linkUp() { return qemuNetworkReady(); }

bool ETHClass2::config(IPAddress, IPAddress, IPAddress, IPAddress)
{
    Serial.println("[QEMU]...static IP not supported; the address comes from DHCP");
    return false;
}

static IPAddress part(int which)
{
    IPAddress ip, gw, mask;
    if (!qemuNetworkGetIp(ip, gw, mask))
        return IPAddress();
    return which == 0 ? ip : which == 1 ? gw : mask;
}

IPAddress ETHClass2::localIP() { return part(0); }
IPAddress ETHClass2::gatewayIP() { return part(1); }
IPAddress ETHClass2::subnetMask() { return part(2); }
IPAddress ETHClass2::dnsIP() { return part(1); }   // QEMU user networking forwards DNS through the gateway side

#endif // QEMU_HEADLESS
```

### overlay/src/qemu/qemu_ethmode.cpp (6641a6f5)

```
/*
 * qemu_ethmode.cpp — QEMU-only: start OpenETH before setup() and report its address to MeshCom.
 *
 * Arduino-ESP32 calls the weak initVariant() before setup(); upstream does not define it, so this strong
 * definition starts the OpenETH driver (qemu_network.cpp) without any change to a MeshCom file.
 *
 * The task below publishes the address the way upstream's own paths do. node_hasIPaddress must be true
 * before setup() reaches startNetwork(): with it false, stock code in Wi-Fi mode (a fresh node, before
 * provisioning) starts the Wi-Fi PHY, which QEMU does not emulate (a panic in register_chipv7_phy).
 * It is published only once the shared UDP socket is open. In Ethernet mode a later clear of the flag
 * reaches upstream's neth.initethDHCP(), which runs against the ETHClass2 stand-in in the variant and so
 * reports the same OpenETH address.
 */
#ifdef QEMU_HEADLESS

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <configuration.h>
#include <esp32/esp32_flash.h>   // meshcom_settings
#include "esp32/esp32_eth.h"
#include "qemu/qemu_network.h"

// startNetwork() names `neth` under HAS_ETHERNET; upstream defines it only for its two Ethernet boards.
// Declared in the variant's configuration.h.
EspETH neth;

extern WiFiUDP Udp;          // udp_functions.cpp
extern bool hasIPaddress;    // udp_functions.cpp

static void qemuEthModeTask(void *)
{
    bool reported = false;
    for (;;) {
        IPAddress ip, gw, mask;
        if (qemuNetworkReady() && qemuNetworkGetIp(ip, gw, mask)) {
            if (!hasIPaddress && Udp.begin(LOCAL_PORT))
                hasIPaddress = true;
            if (hasIPaddress) {
                char ip_s[16];
                snprintf(ip_s, sizeof(ip_s), "%u.%u.%u.%u", ip[0], ip[1], ip[2], ip[3]);
                if (!meshcom_settings.node_hasIPaddress || strcmp(meshcom_settings.node_ip, ip_s) != 0) {
                    snprintf(meshcom_settings.node_ip, sizeof(meshcom_settings.node_ip), "%s", ip_s);
                    snprintf(meshcom_settings.node_gw, sizeof(meshcom_settings.node_gw), "%u.%u.%u.%u", gw[0], gw[1], gw[2], gw[3]);
                    snprintf(meshcom_settings.node_subnet, sizeof(meshcom_settings.node_subnet), "%u.%u.%u.%u", mask[0], mask[1], mask[2], mask[3]);
                    meshcom_settings.node_hasIPaddress = true;
                }
                if (!reported) {
                    Serial.printf("[QEMU]...ethmode: IP %s reported (%lu ms)\n", ip_s, (unsigned long)millis());
                    reported = true;
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

void initVariant(void)
{
    qemuNetworkStart();
    xTaskCreatePinnedToCore(qemuEthModeTask, "qemu_ethmode", 3072, nullptr, 1, nullptr, 1);
}

#endif // QEMU_HEADLESS
```

### scripts/run.sh (6641a6f5)

```
#!/usr/bin/env bash
#
# run.sh — boot the MeshCom QEMU-headless image in the official Espressif QEMU.
#
# Classic ESP32 + OpenCores Ethernet (open_eth) + user-mode networking, with:
#   host 127.0.0.1:18083 -> guest TCP 80   (web UI)
#   host 127.0.0.1:12323 -> guest TCP 2323 (net-console)
# The installed official QEMU binary is used AS-IS (never modified, never patched,
# never installed by this script). QEMU is "soft-pinned": we detect the installed
# version, record it, and warn if it differs from the verified build, but still run
# (forward-compatible). Override the binary with `--qemu <path>` if needed.
# The exact PID and UART log are written under .run/. Foreground; stop.sh stops it.
# QEMU runs on a NODE IMAGE, not on the build output: the node writes its settings (NVS) into the image
# it runs on, and a rebuild or update replaces the build output. scripts/node-image.sh prepares the node
# image from the build before every start and carries the settings into a new build
# (--node-image <path>; default .state/node-flash.bin in this repo).
# The node's MAC, and with it MeshCom's node ID, comes from an efuse image that belongs to the node image
# (<node image>.efuse), created once by scripts/node-efuse.sh.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/.work/MeshCom-Firmware"
RUN="$ROOT/.run"; mkdir -p "$RUN"

# Soft pin: the official Espressif QEMU build this overlay is verified against.
# This is documentation + a warning, NOT a hard requirement (no pinning by install).
KNOWN_GOOD_QEMU="QEMU emulator version 9.2.2"

QEMU_OVERRIDE=""
ENV_NAME="qemu-headless"   # opt-in: --env qemu-headless-extradio for the external-radio target
NODE_IMAGE="$ROOT/.state/node-flash.bin"
while [ $# -gt 0 ]; do
	case "$1" in
		--qemu) QEMU_OVERRIDE="${2:?--qemu needs a path}"; shift 2 ;;
		--env) ENV_NAME="${2:?--env needs a value}"; shift 2 ;;
		--node-image) NODE_IMAGE="${2:?--node-image needs a path}"; shift 2 ;;
		*) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
	esac
done
FLASH="$SRC/.pio/build/$ENV_NAME/flash.bin"
NODE_EFUSE="$NODE_IMAGE.efuse"

# GPS profiles (…-gpsd) get a dedicated host-backed virtual UART1 carrying incoming
# NMEA. Everything else is byte-for-byte unchanged.
GPS=0
case "$ENV_NAME" in *gpsd) GPS=1 ;; esac
GPS_SOCK="$RUN/gps-uart1.sock"

# Locate the official Espressif qemu-system-xtensa (override > PATH > idf_tools).
if [ -n "$QEMU_OVERRIDE" ]; then
	QEMU_BIN="$QEMU_OVERRIDE"
elif command -v qemu-system-xtensa >/dev/null 2>&1; then
	QEMU_BIN="$(command -v qemu-system-xtensa)"
else
	QEMU_BIN="$(find "${IDF_TOOLS_PATH:-$HOME/.espressif}/tools/qemu-xtensa" -path '*/qemu/bin/qemu-system-xtensa' 2>/dev/null | head -1)"
fi
if [ -z "${QEMU_BIN:-}" ] || [ ! -x "$QEMU_BIN" ]; then
	echo "ERROR: official Espressif qemu-system-xtensa not found (try --qemu <path>)." >&2
	echo "       Install via ESP-IDF: python \$IDF_PATH/tools/idf_tools.py install qemu-xtensa" >&2
	exit 1
fi

# Soft-pin check: record version, warn if not the verified build, proceed anyway.
QEMU_VER="$("$QEMU_BIN" --version 2>/dev/null | head -1)"
printf '%s\n%s\n' "$QEMU_BIN" "$QEMU_VER" > "$RUN/qemu.version"
if printf '%s' "$QEMU_VER" | grep -q "$KNOWN_GOOD_QEMU"; then
	echo "[run] QEMU: $QEMU_VER  (matches verified build)"
else
	echo "[run] WARN: installed QEMU is: $QEMU_VER" >&2
	echo "[run] WARN: verified build is $KNOWN_GOOD_QEMU — proceeding anyway (forward-compatible)." >&2
	echo "[run] WARN: for the exact tested build: scripts/build-qemu.sh (esp-develop-9.2.2-20260417 + patches/qemu)" >&2
fi
[ -f "$FLASH" ] || { echo "ERROR: $FLASH not found. Run scripts/build.sh first." >&2; exit 1; }
# One guest per node image: node-image.sh must never rewrite the image under a running QEMU. The lock is
# held on fd 9 for QEMU's whole life (QEMU inherits the descriptor) and is released by the kernel when it
# exits, so a crash leaves nothing stale behind.
mkdir -p "$(dirname "$NODE_IMAGE")"
exec 9>"$NODE_IMAGE.lock"
flock -n 9 || { echo "ERROR: a QEMU guest already runs on $NODE_IMAGE; stop it first (scripts/stop.sh)." >&2; exit 1; }
"$ROOT/scripts/node-image.sh" "$FLASH" "$NODE_IMAGE"
"$ROOT/scripts/node-efuse.sh" "$NODE_EFUSE"
# libslirp is REQUIRED for the QEMU user-net (open_eth). Prefer the ldconfig cache, but fall back to a
# direct file check: a service manager may run this with a minimal PATH that omits /usr/sbin (where
# ldconfig lives), and an off-PATH ldconfig must NOT be read as "library missing" (live finding — it
# false-failed under lhpc's stack-run environment on a Pi Zero 2W). The library being present on disk is
# authoritative regardless of whether ldconfig is reachable.
{ ldconfig -p 2>/dev/null | grep -q 'libslirp\.so\.0'; } \
	|| ls /lib/*/libslirp.so.0 /usr/lib/*/libslirp.so.0 /usr/lib/libslirp.so.0 2>/dev/null | grep -q libslirp || {
	echo "ERROR: libslirp.so.0 missing. Install with: sudo apt-get install -y libslirp0" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
UARTLOG="$RUN/uart-$STAMP.log"
ln -sf "uart-$STAMP.log" "$RUN/uart-latest.log"

# Commas below are intentional inside quoted QEMU option strings.
# shellcheck disable=SC2054
QEMU_CMD=(
	"$QEMU_BIN"
	-nographic
	-no-reboot   # a guest reset exits QEMU (a reset inside qemu-xtensa wedges in the ROM); the caller restarts it
	-machine esp32
	-m 4M
	-drive "file=$NODE_IMAGE,if=mtd,format=raw"
	-drive "file=$NODE_EFUSE,if=none,format=raw,id=efuse"
	-global driver=nvram.esp32.efuse,property=drive,value=efuse
	-nic "user,model=open_eth,hostfwd=tcp:127.0.0.1:18083-:80,hostfwd=tcp:127.0.0.1:12323-:2323"
	-global driver=timer.esp32.timg,property=wdt_disable,value=true
)

if [ "$GPS" = "1" ]; then
	# UART0 stays the console: mon:stdio mux's the monitor + serial0 onto stdio,
	# exactly as -nographic does by default, so the existing UART log is unchanged.
	# UART1 is a dedicated host Unix socket carrying incoming NMEA (QEMU is the
	# server so it boots independently; scripts/gps-relay.py is the client). UART2
	# is explicit null so QEMU does not auto-route it to stdio.
	rm -f "$GPS_SOCK"
	# shellcheck disable=SC2054
	QEMU_CMD+=(
		-serial mon:stdio
		-chardev "socket,id=gps1,path=$GPS_SOCK,server=on,wait=off"
		-serial chardev:gps1
		-serial null
	)
	# Restrict the UART1 socket (and this run's log) to the owner.
	umask 0077
fi

echo "[run] $(printf '%q ' "${QEMU_CMD[@]}")" > "$RUN/qemu-cmdline.txt"
echo "[run] web UI:      http://127.0.0.1:18083/"
echo "[run] net-console: 127.0.0.1:12323"
[ "$GPS" = "1" ] && echo "[run] GPS UART1:    $GPS_SOCK    (feed: scripts/gps-relay.py --uart $GPS_SOCK …)"
echo "[run] UART log:    $UARTLOG    (stop: scripts/stop.sh)"

"${QEMU_CMD[@]}" >> "$UARTLOG" 2>&1 &
QPID=$!
echo "$QPID" > "$RUN/qemu.pid"
echo "[run] QEMU pid $QPID"
wait "$QPID"
```

### scripts/stop.sh (6641a6f5)

```
#!/usr/bin/env bash
#
# stop.sh — stop ONLY the QEMU instance started by run.sh (exact recorded PID).
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIDFILE="$ROOT/.run/qemu.pid"

[ -f "$PIDFILE" ] || { echo "[stop] no $PIDFILE (nothing recorded to stop)."; exit 0; }
PID="$(cat "$PIDFILE")"
[ -n "$PID" ] || { echo "[stop] empty pid file."; exit 0; }

if ! kill -0 "$PID" 2>/dev/null; then
	echo "[stop] pid $PID not running."
	rm -f "$PIDFILE"; exit 0
fi

echo "[stop] SIGTERM to qemu pid $PID"
kill -TERM "$PID" 2>/dev/null || true
for _ in $(seq 1 10); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$PID" 2>/dev/null; then echo "[stop] still alive; SIGKILL"; kill -KILL "$PID" 2>/dev/null || true; fi
rm -f "$PIDFILE"
# QEMU removes its own server socket on a clean exit; remove any leftover after a kill.
rm -f "$ROOT/.run/gps-uart1.sock"
echo "[stop] stopped."
```

### scripts/status.sh (6641a6f5)

```
#!/usr/bin/env bash
#
# status.sh — show whether the QEMU guest is running and its current network/UI state.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/.run"
PIDFILE="$RUN/qemu.pid"

echo "== meshcore-qemu-raspi status =="
[ -f "$RUN/meshcom-source.sha" ] && echo "source : $(cat "$RUN/meshcom-source.sha") ($(cat "$RUN/meshcom-source.timestamp" 2>/dev/null))"
[ -f "$RUN/qemu.version" ] && echo "qemu-v : $(tail -1 "$RUN/qemu.version")"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
	echo "qemu   : RUNNING (pid $(cat "$PIDFILE"))"
else
	echo "qemu   : not running"
fi
UART="$RUN/uart-latest.log"
if [ -f "$UART" ]; then
	echo "net    : $(grep -oE 'GOT_IP ip=[0-9.]+' "$UART" | tail -1 || echo 'no IP yet')"
	echo "web    : $(grep -c 'WEBServer started' "$UART" 2>/dev/null || echo 0)x 'WEBServer started'; net-console: $(grep -c 'Console started on port' "$UART" 2>/dev/null || echo 0)x"
fi
if command -v curl >/dev/null 2>&1; then
	code="$(curl -s --max-time 4 -o /dev/null -w '%{http_code}' http://127.0.0.1:18083/ 2>/dev/null || echo 000)"
	echo "http   : GET http://127.0.0.1:18083/ -> $code"
fi
```

### scripts/node-image.sh (6641a6f5)

```
#!/usr/bin/env bash
#
# node-image.sh BUILD NODE — prepare the flash image QEMU runs on, so the node keeps its settings.
#
# QEMU writes the node's settings (NVS: every MeshCom setting, the message-id counter, the saved clock)
# into the flash image it runs on. Running on the build output (BUILD) lost all of that at every rebuild
# or update. run.sh therefore runs on NODE, a copy kept outside the build tree, prepared here:
#
#   * no NODE              -> NODE = a copy of BUILD;
#   * BUILD unchanged      -> NODE is used as it is (the sidecar NODE.build-sha256 names the build it
#                             was made from);
#   * BUILD changed        -> NODE = the new BUILD with the old NODE's NVS range (0x9000-0xDFFF) carried
#                             in, when the partition-table sector at 0x8000 is byte-identical in both;
#                             otherwise the new BUILD alone (the settings are reset, one log line).
#
# Bootloader, partition table, otadata and firmware always come from BUILD. Writes never leave a moment
# without a NODE: the old NODE is copied to NODE.prev first (exactly one previous image is kept), the new
# NODE is written to a temp file, synced and renamed over the old one, and only then is the sidecar
# updated. A crash before the sidecar leaves a new NODE with the old sidecar; the next start carries
# again from that NODE, which gives the same image.
#
# Call only while QEMU is not running on NODE (run.sh calls it right before starting QEMU).
set -eu
umask 077   # the node image holds the node's settings, credentials included: owner only

BUILD="${1:?usage: node-image.sh BUILD NODE}"
NODE="${2:?usage: node-image.sh BUILD NODE}"
SIDE="$NODE.build-sha256"
PREV="$NODE.prev"

SECTOR=4096
PT_BLOCK=8      # 0x8000: partition table
NVS_BLOCK=9     # 0x9000
NVS_BLOCKS=5    # 0x9000-0xDFFF (partitions-qemu.csv: nvs 0x9000 size 0x5000)

[ -f "$BUILD" ] || { echo "ERROR: build image not found: $BUILD" >&2; exit 1; }
mkdir -p "$(dirname "$NODE")"

durable() { sync -- "$1"; sync -- "$(dirname "$1")"; }
# Write $2 over $1 atomically: temp file in the same directory, synced, renamed.
install_file() {
	local dest="$1" src="$2" tmp="$1.tmp.$$"
	cp -- "$src" "$tmp"; sync -- "$tmp"; mv -f -- "$tmp" "$dest"; durable "$dest"
}
write_sidecar() {
	local tmp="$SIDE.tmp.$$"
	printf '%s\n' "$1" > "$tmp"; sync -- "$tmp"; mv -f -- "$tmp" "$SIDE"; durable "$SIDE"
}
block() { dd if="$1" bs="$SECTOR" skip="$2" count="$3" status=none; }

BSHA="$(sha256sum -- "$BUILD" | cut -d' ' -f1)"

if [ ! -f "$NODE" ]; then
	install_file "$NODE" "$BUILD"
	write_sidecar "$BSHA"
	echo "[run] node image: created from the build ($NODE)"
	exit 0
fi

if [ -f "$SIDE" ] && [ "$(cat -- "$SIDE")" = "$BSHA" ]; then
	echo "[run] node image: unchanged build, node settings kept ($NODE)"
	exit 0
fi

# The build changed (or the sidecar is missing): keep the old node, then build the new one.
install_file "$PREV" "$NODE"
NEW="$NODE.new.$$"
cp -- "$BUILD" "$NEW"
if cmp -s <(block "$NODE" "$PT_BLOCK" 1) <(block "$BUILD" "$PT_BLOCK" 1); then
	dd if="$NODE" of="$NEW" bs="$SECTOR" skip="$NVS_BLOCK" seek="$NVS_BLOCK" count="$NVS_BLOCKS" \
		conv=notrunc status=none
	msg="new build, node settings carried over"
else
	msg="new build with a different partition table, node settings RESET"
fi
sync -- "$NEW"; mv -f -- "$NEW" "$NODE"; durable "$NODE"
write_sidecar "$BSHA"
echo "[run] node image: $msg ($NODE; previous image kept as $PREV)"
```

### scripts/s5-provision.sh (6641a6f5)

```
#!/usr/bin/env bash
#
# s5-provision.sh — PROTOTYPE: provision the node's persistent settings with stock MeshCom console
# commands over UART0 (no firmware change). Run once after run.sh has prepared the node image and
# recorded .run/qemu-cmdline.txt. The firmware's own auto-reboot after `--netmode eth` ends QEMU
# (-no-reboot), so a clean exit is the expected end.
#
#   --setssid/--setpwd   placeholders: stock esp32setup() turns the web server off when no Wi-Fi
#                        credentials are stored and the AP is off; Ethernet mode never uses them
#   --webserver on, --netconsole on, --gps on, --wifiap off, --netmode eth
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/.run"
CMDLINE="$RUN/qemu-cmdline.txt"
[ -f "$CMDLINE" ] || { echo "ERROR: run scripts/run.sh once first (no $CMDLINE)." >&2; exit 1; }
if [ $# -gt 0 ]; then CMDS=("$@"); else
	CMDS=("--setssid qemu0" "--setpwd qemu0000" "--webserver on" "--netconsole on" "--gps on" "--wifiap off" "--netmode eth")
fi
eval "set -- $(sed 's/^\[run\] //' "$CMDLINE")"
LOG="$RUN/uart-provision-$(date -u +%Y%m%dT%H%M%SZ).log"
: > "$LOG"
feed() {
	local i=0
	until grep -aq 'CLIENT STARTED' "$LOG"; do sleep 1; i=$((i+1)); [ $i -lt 90 ] || return 0; done
	sleep 3
	for c in "${CMDS[@]}"; do
		printf '%s\r\n' "$c"; sleep 1
	done
	sleep 40
}
set +e
feed | timeout 120 "$@" >> "$LOG" 2>&1
rc=${PIPESTATUS[1]}
set -e
echo "[s5] provisioning QEMU exit=$rc (0 = the guest reset ended QEMU; 124 = timeout) log=$LOG"
```

### scripts/s5-gates.sh (6641a6f5)

```
#!/usr/bin/env bash
#
# s5-gates.sh OUTDIR — PROTOTYPE gate run, all in the foreground: the bridge (fake backend), the GPS
# relay (fixture), the node; probe web, net console and the XR link; stop everything.
#   BRIDGE=<meshcom-loraham-bridge binary>  QEMU_BIN=<qemu-system-xtensa>  [XRPW=<password file>]
#   [REPO=<runner checkout>, default this one]  [G4=1: also --reboot, then restart and probe again]
set -u
R=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}; cd "$R"
Q=${QEMU_BIN:?QEMU_BIN=<qemu-system-xtensa>}
O=${1:?OUTDIR}; mkdir -p "$O"
"${BRIDGE:?BRIDGE=<meshcom-loraham-bridge binary>}" --bind 127.0.0.1 --port 7000 --ping-interval-ms 30000 --pong-timeout-ms 90000 ${XRPW:+--password-file "$XRPW"} > "$O/bridge.log" 2>&1 & BP=$!
scripts/run.sh --env qemu-headless-extradio-gpsd --qemu "$Q" > "$O/run.log" 2>&1 & RP=$!
for i in $(seq 1 30); do [ -S .run/gps-uart1.sock ] && break; sleep 1; done
python3 -I scripts/gps-relay.py --mode fixture --fixture fixtures/gps/short_track.nmea --uart .run/gps-uart1.sock --rate "${GPS_RATE:-1}" --loop > "$O/relay.log" 2>&1 & GP=$!
t0=$(date +%s)
for i in $(seq 1 120); do grep -aq 'CLIENT STARTED' .run/uart-latest.log 2>/dev/null && break; sleep 1; done
echo "client-started after $(( $(date +%s)-t0 ))s"
sleep 25
for p in / /info /setup; do
  curl -s -m 20 -o "$O/page$(echo $p | tr / _).html" -D "$O/hdr$(echo $p | tr / _).txt" -w "web $p code=%{http_code} bytes=%{size_download}\n" "http://127.0.0.1:18083$p" || echo "web $p curl-fail"
done
python3 -I - <<'PY' > "$O/console.txt" 2>&1
import socket
s=socket.create_connection(("127.0.0.1",12323),timeout=10); s.settimeout(5)
try: d=s.recv(256)
except Exception as e: d=repr(e).encode()
print("console accepted; first bytes:", len(d), d[:60])
PY
cat "$O/console.txt"
console_cmd() { python3 -I - "$@" <<'PY'
import socket,sys,time
s=socket.create_connection(("127.0.0.1",12323),timeout=10); s.settimeout(3)
try: s.recv(256)
except Exception: pass
s.sendall((sys.argv[1]+"\r\n").encode()); time.sleep(4)
try: d=s.recv(8192)
except Exception as e: d=repr(e).encode()
if len(sys.argv)>2:
    import re
    print("reply-extract:", " | ".join(re.findall(sys.argv[2], d.decode(errors="replace"))))
else: print("reply:", d[:120])
PY
}
xrbytes() { ss -tin '( sport = :7000 )' | grep -oE 'bytes_(sent|received):[0-9]+' | paste -sd' '; }
sleep 10; echo "xr before: $(xrbytes)"; echo "sendpos:"; console_cmd "--sendpos"; sleep 20; echo "xr after:  $(xrbytes)"
echo "page tail: $(tail -c 9 "$O/page_.html" | tr -d '\n')"
echo "info:"; console_cmd "--info" '\.\.\.MESH (?:on|off)|\.\.\.EXTUDP (?:on|off)|Gateway (?:on|off)'
curl -s -m 60 -o "$O/spectrum.html" -w "spectrum code=%{http_code} bytes=%{size_download} secs=%{time_total}\n" "http://127.0.0.1:18083/?page=spectrum" || echo "spectrum curl-fail rc=$?"
curl -s -m 20 -o /dev/null -w "web after spectrum code=%{http_code}\n" http://127.0.0.1:18083/ || echo "web after spectrum curl-fail"
kill -0 $RP 2>/dev/null && echo "after sendpos: qemu alive" || { wait $RP; echo "after sendpos: run.sh/QEMU ended rc=$?"; }
if [ "${G4:-0}" = 1 ]; then
  echo "reboot:"; console_cmd "--reboot"
  for i in $(seq 1 60); do kill -0 $RP 2>/dev/null || break; sleep 1; done
  if kill -0 $RP 2>/dev/null; then echo "G4: QEMU still running 60 s after --reboot"; else wait $RP; echo "G4: run.sh/QEMU ended by itself rc=$? after ${i}s"; fi
  cp -f "$(readlink -f .run/uart-latest.log)" "$O/uart-before-restart.log"
  scripts/run.sh --env qemu-headless-extradio-gpsd --qemu "$Q" > "$O/run2.log" 2>&1 & RP=$!
  for i in $(seq 1 120); do grep -aq 'CLIENT STARTED' .run/uart-latest.log 2>/dev/null && break; sleep 1; done
  sleep 15
  curl -s -m 20 -o /dev/null -w "restart web code=%{http_code} bytes=%{size_download}\n" http://127.0.0.1:18083/
  grep -aE 'RESET_REASON|\[NET\] Ethernet mode|ethmode' .run/uart-latest.log | cut -c1-120
fi
ss -tnp 2>/dev/null | grep -E ':7000\b' | grep -c ESTAB | sed 's/^/bridge estab sockets: /'
sleep 5
cp -f "$(readlink -f .run/uart-latest.log)" "$O/uart.log"
scripts/stop.sh > /dev/null 2>&1; kill $GP $BP 2>/dev/null; wait $RP $GP $BP 2>/dev/null
echo "stopped; qemu left: $(pgrep -c '[q]emu-system-xtensa')"
```

### tests/xr-tap.py (the measuring tap used for B3; proposed as the test helper)

```python
#!/usr/bin/env python3
# xr-tap.py LISTEN_PORT BRIDGE_PORT LOG — forwards one XR connection and logs each frame's direction and type.
import socket, sys, threading
NAMES = {1:"HELLO",2:"HELLO_ACK",3:"AUTH_CHALLENGE",4:"AUTH_RESPONSE",5:"AUTH_RESULT",6:"CONFIGURE",7:"CONFIG_RESULT",
         8:"RX_PACKET",9:"TX_REQUEST",10:"TX_RESULT",11:"PING",12:"PONG",13:"ERROR"}
lport, bport, logp = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
log = open(logp, "a", buffering=1)
def pump(src, dst, tag):
    buf = b""
    while True:
        d = src.recv(4096)
        if not d:
            dst.close(); return
        dst.sendall(d); buf += d
        while len(buf) >= 8:
            if buf[0:2] != b"XR":
                log.write(f"{tag} BADMAGIC\n"); buf = b""; break
            n = int.from_bytes(buf[4:6], "big")
            if len(buf) < 8 + n: break
            extra = (" head=" + buf[8:8 + min(n, 16)].hex()) if buf[3] == 9 else ""
            log.write(f"{tag} {NAMES.get(buf[3], hex(buf[3]))} len={n}{extra}\n"); buf = buf[8 + n:]
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("127.0.0.1", lport)); srv.listen(1)
while True:
    c, _ = srv.accept(); b = socket.create_connection(("127.0.0.1", bport))
    threading.Thread(target=pump, args=(c, b, "node>bridge"), daemon=True).start()
    threading.Thread(target=pump, args=(b, c, "bridge>node"), daemon=True).start()
```
