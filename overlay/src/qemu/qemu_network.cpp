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
    esp_netif_str_to_ip4("10.0.2.15", &ip.ip);
    esp_netif_str_to_ip4("255.255.255.0", &ip.netmask);
    esp_netif_str_to_ip4("10.0.2.2", &ip.gw);
    if (esp_netif_set_ip_info(s_eth_netif, &ip) == ESP_OK) {
        s_ip_info = ip;
        s_got_ip = true;
        Serial.println("[QEMU]...DHCP did NOT complete within 8s; applied SLIRP static 10.0.2.15/24 gw 10.0.2.2 (fallback)");
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
