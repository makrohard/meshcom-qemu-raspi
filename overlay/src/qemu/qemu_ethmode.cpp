/*
 * qemu_ethmode.cpp — QEMU-only: start OpenETH before setup() and hand its IPv4 address to upstream's
 * Ethernet mode (node_netmode == 1, HAS_ETHERNET).
 *
 * Arduino-ESP32 calls the weak initVariant() before setup(); upstream does not define it, so this strong
 * definition starts the OpenETH driver (qemu_network.cpp) without any change to a MeshCom file. A small
 * task then mirrors what upstream's W5500 path (EspETH::initethDHCP) does once it has an address: the
 * IP strings, node_hasIPaddress, and the shared UDP socket. Because node_hasIPaddress is already true
 * when setup() calls startNetwork(), upstream never calls the W5500 init, and its web, net-console and
 * watchdog gates follow Ethernet mode.
 *
 * The task re-asserts the state when a MeshCom path clears it (the settings load at boot, a UDP error
 * reset), because node_hasIPaddress false in Ethernet mode would send the main loop to the W5500 init.
 */
#ifdef QEMU_HEADLESS

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <configuration.h>
#include <esp32/esp32_flash.h>   // meshcom_settings

#include "qemu/qemu_network.h"

#include "esp32/esp32_eth.h"

EspETH neth;                 // declared in the variant's configuration.h; never initialised here
extern WiFiUDP Udp;          // udp_functions.cpp
extern bool hasIPaddress;    // udp_functions.cpp

static void qemuEthModeTask(void *)
{
    unsigned handovers = 0;
    for (;;) {
        IPAddress ip, gw, mask;
        if (qemuNetworkReady() && qemuNetworkGetIp(ip, gw, mask)) {
            char ip_s[16];
            snprintf(ip_s, sizeof(ip_s), "%u.%u.%u.%u", ip[0], ip[1], ip[2], ip[3]);

            if (!hasIPaddress) {
                // As upstream's Ethernet path: the socket is opened once the address is known.
                if (Udp.begin(EXTERN_PORT))
                    hasIPaddress = true;
            }
            if (!meshcom_settings.node_hasIPaddress || strcmp(meshcom_settings.node_ip, ip_s) != 0) {
                snprintf(meshcom_settings.node_ip, sizeof(meshcom_settings.node_ip), "%s", ip_s);
                snprintf(meshcom_settings.node_gw, sizeof(meshcom_settings.node_gw), "%u.%u.%u.%u", gw[0], gw[1], gw[2], gw[3]);
                snprintf(meshcom_settings.node_subnet, sizeof(meshcom_settings.node_subnet), "%u.%u.%u.%u", mask[0], mask[1], mask[2], mask[3]);
                meshcom_settings.node_hasIPaddress = true;
                if (++handovers <= 5)
                    Serial.printf("[QEMU]...ethmode: IP %s handed over (#%u, %lu ms, udp=%d)\n",
                                  ip_s, handovers, (unsigned long)millis(), (int)hasIPaddress);
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
