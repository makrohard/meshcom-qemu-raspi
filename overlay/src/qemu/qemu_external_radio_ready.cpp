/*
 * qemu_external_radio_ready.cpp — QEMU-only STRONG override of the firmware's
 * weak externalRadioNetworkReady() seam.
 *
 * Compiled ONLY in the opt-in QEMU external-radio build (both QEMU_HEADLESS and
 * EXTERNAL_RADIO defined). It reports readiness true ONLY when the OpenETH
 * interface has actually obtained an IPv4 address via a genuine IP_EVENT_ETH_GOT_IP
 * (qemuNetworkReadyEvent()) — i.e. real guest IP connectivity, NEVER unconditionally
 * and NEVER from the transparent SLIRP static fallback. Readiness is cleared again on
 * genuine Ethernet loss (DISCONNECTED/STOP/LOST_IP), so the transport stops safely and
 * reconnects only when a real IP returns. This keeps the firmware's connection gate
 * honest under emulation: the external radio transport connects to the bridge only once
 * the guest can route to the host (10.0.2.2), exactly as the weak Wi-Fi default intends
 * on real hardware.
 *
 * This file is part of the meshcom-qemu-raspi overlay (copied into the workspace
 * by apply-overlay.sh). It lives only in the QEMU harness, never in the firmware
 * repository. On any non-QEMU or non-external-radio build it is empty, so the
 * firmware's weak default (Wi-Fi/STA readiness) is used unchanged.
 */
#if defined(QEMU_HEADLESS) && defined(EXTERNAL_RADIO)

#include "qemu/qemu_network.h"

// Strong (non-weak) definition: at link time this overrides the weak default
// defined in src/esp32/external_radio_glue.cpp. Signature must match exactly.
bool externalRadioNetworkReady(void* /*ctx*/)
{
    // STRICT, event-backed: real OpenETH IP only (never the static SLIRP fallback),
    // cleared on Ethernet loss. The XR transport's own poll() reconnects when it returns.
    return qemuNetworkReadyEvent();
}

#endif // QEMU_HEADLESS && EXTERNAL_RADIO
