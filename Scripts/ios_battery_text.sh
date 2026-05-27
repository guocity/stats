#!/bin/bash
# Advanced iOS Battery Diagnostics Probe
# Safely parses the XML Plist using a native embedded plist decoder

set -euo pipefail

echo "=== iOS Battery Diagnostics (Shell) ==="

if ! command -v idevice_id >/dev/null 2>&1 || ! command -v idevicediagnostics >/dev/null 2>&1; then
    echo "Error: libimobiledevice is missing required tools."
    exit 1
fi

# Gather devices (Wi-Fi discovery disabled to prevent usbmuxd crashes)
USB_UDIDS=$(idevice_id -l 2>/dev/null || true)
NET_UDIDS="" 

if [ -z "$USB_UDIDS" ] && [ -z "$NET_UDIDS" ]; then
    echo "FAIL: No connected iOS devices found."
    exit 1
fi

# Robust Plist Parser
# Uses a hidden Python block to recursively search the Plist tree exactly like pymobiledevice3
parse_battery_xml() {
    python3 -c "$(cat << 'EOF'
import sys, plistlib
try:
    xml_data = sys.stdin.read().encode("utf-8")
    if not xml_data.strip():
        sys.exit(0)
        
    data = plistlib.loads(xml_data)
    
    # Recursive search to find keys no matter how deeply Apple nests them
    def find_key(d, key):
        if isinstance(d, dict):
            if key in d: return d[key]
            for k, v in d.items():
                res = find_key(v, key)
                if res is not None: return res
        elif isinstance(d, list):
            for item in d:
                res = find_key(item, key)
                if res is not None: return res
        return None
        
    out = {}
    for k in ["CurrentCapacity", "IsCharging", "CycleCount", "Voltage", 
              "DesignCapacity", "AppleRawMaxCapacity", "NominalChargeCapacity", 
              "Serial", "Temperature", "VirtualTemperature"]:
        val = find_key(data, k)
        out[k] = val if val is not None else "N/A"
        
    if out["AppleRawMaxCapacity"] == "N/A": 
        out["AppleRawMaxCapacity"] = out["NominalChargeCapacity"]
        
    for k in ["Temperature", "VirtualTemperature"]:
        raw = out[k]
        out[k+"_Str"] = f"{raw/100:.2f} °C (raw: {raw})" if isinstance(raw, (int, float)) else "N/A (raw: N/A)"
        
    cur = out["AppleRawMaxCapacity"]
    des = out["DesignCapacity"]
    if isinstance(cur, (int, float)) and isinstance(des, (int, float)) and des > 0:
        out["Health"] = f"{(cur/des)*100:.2f}%"
    else:
        out["Health"] = "N/A"
        
    # Export safe bash variables
    print(f'charge="{out["CurrentCapacity"]}"')
    print(f'is_charging="{out["IsCharging"]}"')
    print(f'cycle_count="{out["CycleCount"]}"')
    print(f'temp="{out["Temperature_Str"]}"')
    print(f'vtemp="{out["VirtualTemperature_Str"]}"')
    print(f'voltage="{out["Voltage"]}"')
    print(f'design_cap="{out["DesignCapacity"]}"')
    print(f'current_max="{out["AppleRawMaxCapacity"]}"')
    print(f'nominal_cap="{out["NominalChargeCapacity"]}"')
    print(f'serial="{out["Serial"]}"')
    print(f'health="{out["Health"]}"')
    
except Exception as e:
    print(f'PARSE_ERROR="{e}"')
EOF
)"
}

# Main Query Function
query_device() {
    local udid="$1"
    local conn_type="$2"
    local net_flag=""
    local conn_label="USB"
    
    if [ "$conn_type" == "WIFI" ]; then
        net_flag="-n"
        conn_label="Wi-Fi sync"
    fi

    local name=$(ideviceinfo $net_flag -u "$udid" -k DeviceName 2>/dev/null || echo "Unknown")
    local type=$(ideviceinfo $net_flag -u "$udid" -k ProductType 2>/dev/null || echo "Unknown")
    local ios_ver=$(ideviceinfo $net_flag -u "$udid" -k ProductVersion 2>/dev/null || echo "Unknown")

    local battery_xml
    battery_xml=$(idevicediagnostics $net_flag -u "$udid" diagnostics GasGauge 2>/dev/null || echo "")

    if [ -z "$battery_xml" ]; then
        echo "Battery Summary"
        echo "  Device:         $udid"
        echo "  Error:          Failed to pull GasGauge diagnostics."
        echo "--------------------------------------------------"
        return
    fi
    
    # Initialize defaults
    local charge="N/A" is_charging="N/A" cycle_count="N/A" temp="N/A" vtemp="N/A"
    local voltage="N/A" design_cap="N/A" current_max="N/A" nominal_cap="N/A" 
    local serial="N/A" health="N/A" PARSE_ERROR=""
    
    # Execute the parser to extract and assign variables
    eval "$(echo "$battery_xml" | parse_battery_xml)"
    
    if [ -n "$PARSE_ERROR" ]; then
        echo "  Error Parsing XML: $PARSE_ERROR"
    fi

    echo "Battery Summary"
    echo "  Device:         $udid"
    echo "  Name:           $name"
    echo "  Type:           $type"
    echo "  Connection:     $conn_label"
    echo "  iOS Version:    $ios_ver"
    echo "  Charge:         ${charge}%"
    echo "  Is Charging:    $is_charging"
    echo "  Cycle Count:    $cycle_count"
    echo "  Temperature:    $temp"
    echo "  Virtual Temp:   $vtemp"
    echo "  Voltage:        $voltage mV"
    echo "  Full Capacity:  $design_cap mAh"
    echo "  Current Max:    $current_max mAh"
    echo "  Nominal Cap:    $nominal_cap mAh"
    echo "  Battery Serial: $serial"
    echo "  Health Est.:    $health"
    echo "--------------------------------------------------"
}

echo "Scanning devices..."
echo "--------------------------------------------------"
for UDID in $USB_UDIDS; do
    [ -z "$UDID" ] && continue
    query_device "$UDID" "USB"
done
