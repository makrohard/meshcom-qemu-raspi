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
