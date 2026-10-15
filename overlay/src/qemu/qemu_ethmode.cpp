/*
 * qemu_ethmode.cpp — QEMU-only: start OpenETH before setup() and report its address to MeshCom.
 *
 * Arduino-ESP32 calls the weak initVariant() before setup(); upstream does not define it, so this strong
 * definition starts the OpenETH driver (qemu_network.cpp) without any change to a MeshCom file.
 *
 * The task below publishes the address the way upstream's own paths do. node_hasIPaddress must be true
 * before setup() reaches startNetwork(): with it false, stock code in Wi-Fi mode (a fresh node, before
 * provisioning) starts the Wi-Fi PHY, which QEMU does not emulate (a panic in register_chipv7_phy).
 * The address is published only once the shared UDP socket is open.
 *
 * Readiness never outlives the netif: whenever node_hasIPaddress is true while qemuNetworkReady() is
 * false (a link loss, an expired lease, a flag carried over in the saved settings, or upstream's
 * DHCP-failure fallback in neth.initethDHCP(), which sets it after ETH.config() whatever that returns),
 * the task withdraws it. In Ethernet mode the main loop then calls neth.initethDHCP() again, which runs
 * against the ETHClass2 stand-in in the variant and retries the driver start.
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
        } else if (meshcom_settings.node_hasIPaddress || hasIPaddress) {
            // ntpHarvestUDP() copies hasIPaddress into node_hasIPaddress, so both go.
            meshcom_settings.node_hasIPaddress = false;
            hasIPaddress = false;
            reported = false;
            Serial.printf("[QEMU]...ethmode: no address; readiness withdrawn (%lu ms)\n", (unsigned long)millis());
        }
#ifdef QEMU_TEST_CLEAR_FLAG_MS
        // Test build only (tests/test-boot-gates.sh, gate b'): clear the flag once and leave the
        // hand-over to upstream's initethDHCP() path.
        static bool cleared = false;
        if (!cleared && millis() > QEMU_TEST_CLEAR_FLAG_MS) {
            cleared = true;
            meshcom_settings.node_hasIPaddress = false;
            Serial.printf("[QEMU]...TEST: node_hasIPaddress cleared (%lu ms)\n", (unsigned long)millis());
            vTaskSuspend(nullptr);
        }
#endif
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

void initVariant(void)
{
    qemuNetworkStart();
    xTaskCreatePinnedToCore(qemuEthModeTask, "qemu_ethmode", 3072, nullptr, 1, nullptr, 1);
}

#endif // QEMU_HEADLESS
