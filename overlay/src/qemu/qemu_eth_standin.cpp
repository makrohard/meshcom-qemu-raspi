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
