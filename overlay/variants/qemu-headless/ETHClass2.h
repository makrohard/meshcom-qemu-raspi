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
