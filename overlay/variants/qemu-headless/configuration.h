/*
 * QEMU-headless variant configuration.
 *
 * A classic-ESP32 profile for running stock MeshCom in Espressif's QEMU. It defines what a variant
 * must define for the firmware to compile and boot; no MeshCom file is changed. Under QEMU no radio
 * chip, display, PMU, battery divider or BLE controller exists: with EXTERNAL_RADIO the firmware does
 * not begin a local radio (upstream's own branch); without it radio.begin() finds no chip and the boot
 * continues; the display probe finds nothing on I2C and the firmware runs without one; the PMU code is
 * compiled only for XPOWERS chips, which this variant does not name; DISABLE_BATTERY/DISABLE_BLE below
 * are upstream's opt-outs.
 *
 * Radio pin definitions are the classic E22 (az-delivery-devkit-v4) profile's, so the RadioLib SX1268
 * module object constructs.
 */
#pragma once

#include <Arduino.h>
#include <configuration_global.h>

// --- Radio chip selection (compile time; no chip exists under QEMU) ---
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

// LoRa parameters (the settings defaults; with EXTERNAL_RADIO they configure the bridge's radio)
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
// change. Without the external radio no chip answers, so the value is unused.
#define TX_POWER_MAX 17
#define TX_POWER_MIN 2
#define TX_OUTPUT_POWER 17
#define CURRENT_LIMIT 140
#define WAIT_TX 5

// I2C pins (the display probe runs on them and finds nothing under QEMU)
#define I2C_SDA 21
#define I2C_SCL 22

#define BUTTON_PIN 12

// Upstream's opt-outs for boards without a battery divider / a usable BLE controller (icssw-org dev,
// PR #1166): QEMU emulates neither, so the firmware skips battery measurement and the whole NimBLE stack.
#define DISABLE_BATTERY
#define DISABLE_BLE

// Upstream's neighbour matrix (src/nbr_matrix.h, since v4.40a) requires this value; upstream
// variants get it from src/configuration_default.h, included last. This variant states the one
// value instead: that file switches the fleet's sensor flags on (and older revisions lack it).
// The value is the fleet default, calibrated for this variant's SF11 / BW 250 / CR 4/6.
#ifndef LORA_SNR_STABLE_MIN_DB
#define LORA_SNR_STABLE_MIN_DB (-16)
#endif

// Upstream's Ethernet mode (node_netmode == 1) opens the web, net-console and startNetwork() paths without
// Wi-Fi. Its W5500 calls reach ETHClass2.h in this directory, which reports the OpenETH netif; the pins
// are placeholders.
#define HAS_ETHERNET
#define ETH_CS_PIN    15
#define ETH_INT_PIN   4
#define ETH_RST_PIN   25
#define ETH_SCLK_PIN  18
#define ETH_MISO_PIN  19
#define ETH_MOSI_PIN  23
// startNetwork() (src/udp_functions.cpp) names `neth` under HAS_ETHERNET; upstream declares and defines
// it only for its two Ethernet boards. Declared here, defined in src/qemu/qemu_ethmode.cpp.
#ifdef __cplusplus
#include "esp32/esp32_eth.h"
extern EspETH neth;
#endif

// Not defined for this profile: ENABLE_BMX280, ENABLE_BMP390, ENABLE_AHT20, ENABLE_SHT21,
// ENABLE_BMX680, ENABLE_MCP23017, ENABLE_INA226, ENABLE_MC811, ENABLE_RTC, USE_BATT, HAS_TFT,
// OLED/display defines, XPOWERS_CHIP_* (PMU). ENABLE_GPS comes from platformio.ini.
