#!/bin/bash
# Quick sanity check that this Mac can read a connected iOS device (libimobiledevice).
# Run with iPad/iPhone connected, unlocked, and trusted.

set -euo pipefail

echo "=== iOS device probe (libimobiledevice) ==="

if ! command -v idevice_id >/dev/null 2>&1; then
    echo "SKIP: idevice_id not installed (brew install libimobiledevice)"
    exit 0
fi

# Fetch USB and Network UDIDs separately
USB_UDIDS=$(idevice_id -l 2>/dev/null || true)
NET_UDIDS=$(idevice_id -n 2>/dev/null || true)

if [ -z "$USB_UDIDS" ] && [ -z "$NET_UDIDS" ]; then
    echo "FAIL: No iOS devices found."
    echo "  USB:    plug in cable, unlock, tap Trust"
    echo "  Wi‑Fi:  enable Wi‑Fi sync in Finder, same network, then: idevice_id -n"
    exit 1
fi

# Helper function to run the diagnostics
query_device() {
    local udid="$1"
    local conn_type="$2"
    local net_flag=""
    
    if [ "$conn_type" == "WIFI" ]; then
        # The critical fix: append -n for network devices
        net_flag="-n"
        echo "--- $udid (Wi-Fi) ---"
    else
        echo "--- $udid (USB) ---"
    fi

    ideviceinfo $net_flag -u "$udid" -k DeviceName 2>/dev/null || echo "DeviceName: (failed)"
    ideviceinfo $net_flag -u "$udid" -k ProductType 2>/dev/null || true
    ideviceinfo $net_flag -u "$udid" -k ProductVersion 2>/dev/null || true
    ideviceinfo $net_flag -u "$udid" -k BatteryCurrentCapacity 2>/dev/null || true
    
    if command -v idevicediagnostics >/dev/null 2>&1; then
        echo "GasGauge (diagnostics):"
        idevicediagnostics $net_flag -u "$udid" diagnostics GasGauge 2>/dev/null | head -20 || echo "(diagnostics failed — unlock device after boot)"
    fi
}

echo "Devices found..."

# 1. Process USB devices
for UDID in $USB_UDIDS; do
    [ -z "$UDID" ] && continue
    echo ""
    query_device "$UDID" "USB"
done

# 2. Process Network devices
for UDID in $NET_UDIDS; do
    [ -z "$UDID" ] && continue
    echo ""
    # Avoid double-querying a device if it is connected via both USB and Wi-Fi
    if echo "$USB_UDIDS" | grep -q "$UDID"; then
        echo "--- $UDID (Wi-Fi) ---"
        echo "Skipping network probe (already probed via USB for speed/reliability)."
        continue
    fi
    query_device "$UDID" "WIFI"
done
echo ""
echo "OK: device communication works on this Mac."
