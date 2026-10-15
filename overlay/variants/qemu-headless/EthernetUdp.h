/*
 * EthernetUdp.h — QEMU stand-in: upstream's Ethernet code keeps its own EthernetUDP socket
 * (src/esp32/esp32_eth.h). Under QEMU that socket is an ordinary lwIP socket on the OpenETH netif.
 */
#pragma once

#include <WiFiUdp.h>

class EthernetUDP : public WiFiUDP {};
