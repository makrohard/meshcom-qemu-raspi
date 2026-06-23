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
#define TX_POWER_MAX 22
#define TX_POWER_MIN -9
#define TX_OUTPUT_POWER 22
#define CURRENT_LIMIT 140
#define WAIT_TX 5

// I2C pins (bus is initialised but no I2C peripherals are present/queried in QEMU)
#define I2C_SDA 21
#define I2C_SCL 22

#define BUTTON_PIN 12

// NOTE: intentionally NOT defined for the headless QEMU profile:
//   ENABLE_GPS, ENABLE_BMX280, ENABLE_BMP390, ENABLE_AHT20, ENABLE_SHT21,
//   ENABLE_BMX680, ENABLE_MCP23017, ENABLE_INA226, ENABLE_MC811, ENABLE_RTC,
//   USE_BATT, HAS_TFT, OLED/display defines, XPOWERS_CHIP_* (PMU).
