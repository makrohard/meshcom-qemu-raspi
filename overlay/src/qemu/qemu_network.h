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

// True only after an IPv4 address was obtained via IP_EVENT_ETH_GOT_IP.
bool qemuNetworkReady();

// Copies the current IPv4 address/gateway/mask. Returns false if not ready.
bool qemuNetworkGetIp(IPAddress &ip, IPAddress &gateway, IPAddress &mask);

// Stop the OpenETH driver (not used in normal startup; provided for completeness).
void qemuNetworkStop();

#endif // QEMU_HEADLESS
