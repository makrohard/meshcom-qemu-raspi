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
