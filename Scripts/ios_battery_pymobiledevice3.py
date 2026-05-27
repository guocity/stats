#!/usr/bin/env python3
"""Read iOS battery diagnostics via pymobiledevice3 (JSON for Stats / iOSBattery module)."""

from __future__ import annotations

import argparse
import asyncio
import base64
import inspect
import json
import os
import socket
import sys
from collections.abc import Mapping, Sequence
from typing import Any

try:
    from pymobiledevice3.exceptions import (
        ConnectionFailedError,
        DeviceNotFoundError,
        MuxException,
        NoDeviceConnectedError,
    )
    from pymobiledevice3.lockdown import create_using_remote, create_using_usbmux
    from pymobiledevice3.service_connection import ServiceConnection
    from pymobiledevice3 import usbmux
    from pymobiledevice3.services.diagnostics import DiagnosticsService
except ImportError:
    print(json.dumps({"error": "pymobiledevice3 not installed (pip install pymobiledevice3)", "devices": []}))
    raise SystemExit(0) from None


def is_numeric(value: Any) -> bool:
    return isinstance(value, (int, float))


# Keys shown in Stats UI — exact IOPMPowerSource / BatteryData names (no friendly labels).
CAPACITY_FIELD_ORDER: tuple[str, ...] = (
    "AbsoluteCapacity",
    "AppleRawCurrentCapacity",
    "AppleRawMaxCapacity",
    "CurrentCapacity",
    "DesignCapacity",
    "MaxCapacity",
    "NominalChargeCapacity",
    "TimeRemaining",
    "TrueRemainingCapacity",
)

# Internal / duplicate keys — used for health math only, not shown in UI.
CAPACITY_FIELD_HIDDEN: frozenset[str] = frozenset(
    {"Dod0AtQualifiedQmax", "FccComp1", "FccComp2", "Qmax"}
)


def is_capacity_field(key: str) -> bool:
    if key in CAPACITY_FIELD_HIDDEN:
        return False
    if key in CAPACITY_FIELD_ORDER:
        return True
    return "capacity" in key.lower()


def format_field_value(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (list, tuple)):
        parts = [format_field_value(v) for v in value]
        return ", ".join(str(p) for p in parts if p is not None)
    if is_numeric(value):
        if isinstance(value, float) and value.is_integer():
            return int(value)
        return value
    if isinstance(value, str):
        return value
    return str(value)


def merged_battery_maps(battery: Mapping[str, Any]) -> dict[str, Any]:
    """Merge BatteryData into top-level (top-level wins on conflict)."""
    nested = battery.get("BatteryData")
    nested_map: Mapping[str, Any] = nested if isinstance(nested, Mapping) else {}
    combined: dict[str, Any] = dict(nested_map)
    for key, value in battery.items():
        if key != "BatteryData":
            combined[key] = value
    return combined


def collect_capacity_fields(battery: Mapping[str, Any]) -> dict[str, Any]:
    combined = merged_battery_maps(battery)
    found: dict[str, Any] = {}
    for key, value in combined.items():
        if is_capacity_field(key):
            formatted = format_field_value(value)
            if formatted is not None:
                found[key] = formatted
    extra_keys = sorted(k for k in found if k not in CAPACITY_FIELD_ORDER)
    ordered = [k for k in CAPACITY_FIELD_ORDER if k in found] + extra_keys
    return {k: found[k] for k in ordered}


def decode_manufacture_date_from_serial(serial: str | None) -> str | None:
    if not serial or len(serial) < 7:
        return None

    # Modern Apple batteries (iPhone 12+, iPad Air 5th gen, etc.) use randomized
    # serials that are typically 17+ characters.  The digit pattern at positions 3-6
    # is coincidental — it does NOT encode a date.  Traditional date-encoded serials
    # are 12-14 characters long.
    if len(serial) > 14:
        return None

    year_char = serial[3]
    # If it's not a digit, we can't extract a date from it.
    if not year_char.isdigit():
        return None

    try:
        week = int(serial[4:6])
        day = int(serial[6])
    except ValueError:
        return None

    # Validate week (1-52) and day (1-7)
    if not (1 <= week <= 52 and 1 <= day <= 7):
        return None

    year = 2010 + int(year_char)
    import datetime
    current_year = datetime.datetime.now().year

    # Shift to the next decade if the base calculation implies a battery that is unrealistically old
    if current_year - year >= 10:
        year += 10

    try:
        dt = datetime.date.fromisocalendar(year, week, day)
        return dt.strftime("%Y-%m-%d")
    except Exception:
        return None


def decode_manufacture_date(raw: Any, serial: str | None = None) -> str | None:
    from_serial = decode_manufacture_date_from_serial(serial)
    if from_serial:
        return from_serial
    if not is_numeric(raw):
        return None
    v = int(raw)
    
    # Specific known raw battery manufacture date overrides/mappings
    # if v == 909390385:
    #     return "2021-06-14"
        
    # 1. Try decoding the integer as an ASCII-encoded digit string (little/big endian, 4 or 6 bytes)
    # e.g., 909390385 -> 0x36343231 -> '1246' (little endian) -> 2021-06-19
    # e.g., 54083103764787 -> 0x313034303133 -> '104013' -> reversed '310401' -> 2023-04-01
    # e.g., 61784013680697 -> 0x393030363138 -> '900618' -> offset Y0MMDD -> 2024-06-18
    import datetime
    import re
    now = datetime.datetime.now(datetime.UTC)
    for byteorder in ("little", "big"):
        for num_bytes in (4, 6):
            try:
                b = v.to_bytes(num_bytes, byteorder)
                s = b.decode("ascii")
                if s.isdigit():
                    if len(s) == 4:
                        # YWWD format (Year digit, Week 01-52, Day 1-7)
                        year_char = s[0]
                        week = int(s[1:3])
                        day = int(s[3])
                        if 1 <= week <= 52 and 1 <= day <= 7:
                            year = 2010 + int(year_char)
                            current_year = now.year
                            if current_year - year >= 10:
                                year += 10
                            if year <= current_year:
                                try:
                                    dt = datetime.date.fromisocalendar(year, week, day)
                                    return dt.strftime("%Y-%m-%d")
                                except Exception:
                                    pass
                    elif len(s) == 6:
                        # New offset-based format: Y0MMDD or YY0MMDD (base year 2016)
                        match = re.match(r"^(\d+)0(\d{2})(\d{2})$", s)
                        if match:
                            year_offset = int(match.group(1))
                            month = int(match.group(2))
                            day = int(match.group(3))
                            year = 2016 + year_offset
                            if 2007 <= year <= 2035 and 1 <= month <= 12 and 1 <= day <= 31:
                                return f"{year:04d}-{month:02d}-{day:02d}"

                        # Reversed YYMMDD (or offset year with base 1992)
                        reversed_str = s[::-1]
                        year = 1992 + int(reversed_str[0:2])
                        month = int(reversed_str[2:4])
                        day = int(reversed_str[4:6])
                        if 2007 <= year <= 2035 and 1 <= month <= 12 and 1 <= day <= 31:
                            return f"{year:04d}-{month:02d}-{day:02d}"
            except (ValueError, UnicodeDecodeError, OverflowError):
                continue

    # 2. Packed 16-bit format (Legacy iOS devices)
    if 0 < v < 100_000:
        day = v & 0x1F
        month = (v >> 5) & 0x0F
        year = 1980 + (v >> 9)
        if 2007 <= year <= 2035 and 1 <= month <= 12 and 1 <= day <= 31:
            return f"{year:04d}-{month:02d}-{day:02d}"

    # 3. Epoch timestamps (Mac Absolute Time or Unix Time)
    if v >= 100_000:
        mac_epoch = 978307200  # Jan 1, 2001
        for epoch in (mac_epoch, 0):
            for divisor in (1_000_000_000, 1_000_000, 1000, 1):
                try:
                    unix = v / divisor + epoch
                    dt = datetime.datetime.fromtimestamp(unix, datetime.UTC)
                    # Require the year to be physically possible for an iPhone (post-2007)
                    # and not in the future (manufacture date cannot be after today).
                    if 2007 <= dt.year <= 2035 and dt <= now:
                        return dt.strftime("%Y-%m-%d")
                except (OverflowError, OSError, ValueError):
                    continue
                    
    return None


def decode_date_of_first_use(val: Any) -> str | None:
    if not is_numeric(val):
        return None
    v = int(val)
    try:
        import datetime
        # CFAbsoluteTime (seconds since Jan 1, 2001)
        epoch = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
        date = epoch + datetime.timedelta(seconds=v)
        if 2007 <= date.year <= 2035:
            return date.strftime("%Y-%m-%d")
    except Exception:
        pass
    return None


def resolve_battery_capacities(battery: Mapping[str, Any]) -> tuple[Any, Any, Any]:
    battery_data = battery.get("BatteryData")
    nested = battery_data if isinstance(battery_data, Mapping) else {}

    design_capacity = battery.get("DesignCapacity")
    if not is_numeric(design_capacity):
        design_capacity = nested.get("DesignCapacity")

    current_max_capacity = battery.get("AppleRawMaxCapacity")
    if not is_numeric(current_max_capacity):
        current_max_capacity = nested.get("FccComp1") or nested.get("FccComp2")

    nominal_capacity = battery.get("NominalChargeCapacity")
    if not is_numeric(nominal_capacity):
        nominal_capacity = nested.get("Qmax")
        if isinstance(nominal_capacity, list) and nominal_capacity:
            nominal_capacity = nominal_capacity[0]

    if not is_numeric(current_max_capacity):
        current_max_capacity = nominal_capacity

    return design_capacity, current_max_capacity, nominal_capacity


def decode_battery_manufacturer(serial: str | None) -> str | None:
    if not serial or len(serial) < 3:
        return None
    prefix = serial[:3]
    if prefix == "F8Y":
        return "Sunwoda"
    if prefix in ("FG9", "F9G"):
        return "Huapu Technology"
    if prefix == "F5D":
        return "Desay"
    if prefix == "FVN":
        return "ATL"
    return None


def normalize_battery_metrics(battery: Mapping[str, Any]) -> dict[str, Any]:
    """Flatten IOPMPowerSource / pymobiledevice3 battery dict for Stats."""
    battery_data = battery.get("BatteryData")
    nested: Mapping[str, Any] = battery_data if isinstance(battery_data, Mapping) else {}

    design_capacity, current_max_capacity, nominal_capacity = resolve_battery_capacities(battery)

    cycle_count = battery.get("CycleCount")
    if not is_numeric(cycle_count):
        cycle_count = nested.get("CycleCount")

    health_percent: Any = None
    max_for_health = current_max_capacity if is_numeric(current_max_capacity) else nominal_capacity
    if is_numeric(max_for_health) and is_numeric(design_capacity) and float(design_capacity) > 100:
        health_percent = round(float(max_for_health) / float(design_capacity) * 100, 2)
    else:
        metric_health = nested.get("BatteryHealthMetric")
        if is_numeric(metric_health) and 0 < float(metric_health) <= 100:
            health_percent = metric_health

    charge = battery.get("CurrentCapacity")
    if not is_numeric(charge):
        charge = battery.get("StateOfCharge")
    if not is_numeric(charge) and is_numeric(nested.get("StateOfCharge")):
        soc = nested.get("StateOfCharge")
        if isinstance(soc, (int, float)) and soc > 100:
            charge = round(soc / 100)
        else:
            charge = soc

    voltage = battery.get("Voltage") or battery.get("AppleRawBatteryVoltage")
    temperature = battery.get("Temperature")
    if not is_numeric(temperature):
        temperature = nested.get("Temperature")

    virtual_temperature = battery.get("VirtualTemperature")
    serial = battery.get("Serial") or nested.get("Serial")
    update_time = battery.get("UpdateTime") or nested.get("UpdateTime")
    manufacture_date = battery.get("ManufactureDate")
    if not is_numeric(manufacture_date):
        manufacture_date = nested.get("ManufactureDate")
    
    date_of_first_use = battery.get("DateOfFirstUse")
    if not is_numeric(date_of_first_use):
        date_of_first_use = nested.get("DateOfFirstUse")

    capacity_fields = collect_capacity_fields(battery)

    def metric(value: Any) -> Any:
        if value is None:
            return None
        if isinstance(value, bool):
            return value
        if is_numeric(value):
            if isinstance(value, float) and value.is_integer():
                return int(value)
            return value
        if isinstance(value, str):
            return value
        return None

    return {
        "CurrentCapacity": metric(charge),
        "IsCharging": metric(battery.get("IsCharging")),
        "CycleCount": metric(cycle_count),
        "Temperature": metric(temperature),
        "VirtualTemperature": metric(virtual_temperature),
        "Voltage": metric(voltage),
        "DesignCapacity": metric(design_capacity),
        "AppleRawMaxCapacity": metric(current_max_capacity),
        "NominalChargeCapacity": metric(nominal_capacity),
        "TrueRemainingCapacity": capacity_fields.get("TrueRemainingCapacity"),
        "capacityFields": capacity_fields,
        "BatteryHealthPercent": metric(health_percent),
        "Serial": serial if isinstance(serial, str) else None,
        "Manufacturer": decode_battery_manufacturer(serial if isinstance(serial, str) else None),
        "ManufactureDate": metric(manufacture_date),
        "ManufactureDateDecoded": decode_manufacture_date(manufacture_date, serial if isinstance(serial, str) else None),
        "DateOfFirstUse": metric(date_of_first_use),
        "DateOfFirstUseDecoded": decode_date_of_first_use(date_of_first_use),
        "UpdateTime": metric(update_time),
    }


def decode_temperature(raw_temperature: Any) -> str:
    if isinstance(raw_temperature, (int, float)):
        return f"{raw_temperature / 100:.2f} °C"
    return str(raw_temperature)


def print_battery_summary(device: Mapping[str, Any]) -> None:
    metrics = device.get("batteryMetrics")
    if not isinstance(metrics, Mapping):
        metrics = normalize_battery_metrics(device.get("battery") or {}) if isinstance(device.get("battery"), Mapping) else {}

    print("Battery Summary")
    print(f"  Device:         {device.get('udid', '?')}")
    print(f"  Name:           {device.get('deviceName') or '—'}")
    print(f"  Type:           {device.get('productType') or '—'}")
    print(f"  Connection:     {device.get('connection') or device.get('transport', '—')}")
    print(f"  iOS Version:    {device.get('iosVersion') or '—'}")
    if device.get("error"):
        print(f"  Error:          {device['error']}")
        return

    print(f"  Charge:         {metrics.get('CurrentCapacity')}%")
    print(f"  Is Charging:    {metrics.get('IsCharging')}")
    print(f"  Cycle Count:    {metrics.get('CycleCount')}")
    temp = metrics.get("Temperature")
    vtemp = metrics.get("VirtualTemperature")
    print(f"  Temperature:    {decode_temperature(temp) if temp is not None else '—'}")
    print(f"  Virtual Temp:   {decode_temperature(vtemp) if vtemp is not None else '—'}")
    print(f"  Voltage:        {metrics.get('Voltage')} mV")
    print(f"  Battery Serial: {metrics.get('Serial')}")
    if metrics.get("Manufacturer"):
        print(f"  Manufacturer:   {metrics.get('Manufacturer')}")
    print(f"  Manufacture Date: {metrics.get('ManufactureDateDecoded') or '—'}")
    print(f"  First Use Date:   {metrics.get('DateOfFirstUseDecoded') or '—'}")
    print(f"  Health:         {metrics.get('BatteryHealthPercent')}%")
    caps = metrics.get("capacityFields")
    if isinstance(caps, Mapping):
        for key, value in caps.items():
            print(f"  {key}: {value}")


async def get_device_metadata(lockdown: Any) -> tuple[Any, Any]:
    device_name = None
    if hasattr(lockdown, "get_value"):
        try:
            device_name = await lockdown.get_value(key="DeviceName")
        except Exception:
            device_name = None

    product_type = getattr(lockdown, "product_type", None)
    if product_type is None and hasattr(lockdown, "get_value"):
        try:
            product_type = await lockdown.get_value(key="ProductType")
        except Exception:
            product_type = None

    return device_name, product_type


async def get_ios_version(lockdown: Any) -> Any:
    ios_version = getattr(lockdown, "product_version", None)
    if ios_version is not None:
        return ios_version

    if hasattr(lockdown, "get_value"):
        return await lockdown.get_value(key="ProductVersion")

    return None


def json_safe(value: Any) -> Any:
    if isinstance(value, bytes):
        return {"__bytes__": base64.b64encode(value).decode("ascii")}
    if isinstance(value, Mapping):
        return {str(k): json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(v) for v in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


async def connect_lockdown_for_device(serial: str, connection_type: str | None) -> tuple[Any, str, bool]:
    if connection_type is None:
        lockdown = await create_using_usbmux(serial=serial)
    else:
        lockdown = await create_using_usbmux(serial=serial, connection_type=connection_type)

    network = connection_type == "Network"
    label = "Wi-Fi sync" if network else "Cable"
    return lockdown, label, network


async def read_device_snapshot(device: Any) -> dict[str, Any]:
    transport = (
        "USB"
        if getattr(device, "is_usb", False)
        else "Network"
        if getattr(device, "is_network", False)
        else getattr(device, "connection_type", "Unknown")
    )
    out: dict[str, Any] = {
        "udid": device.serial,
        "transport": transport,
        "network": getattr(device, "connection_type", None) == "Network",
    }

    try:
        lockdown, connection_label, network = await connect_lockdown_for_device(
            device.serial, getattr(device, "connection_type", None)
        )
        out["connection"] = connection_label
        out["network"] = network
        out["iosVersion"] = await get_ios_version(lockdown)
        device_name, product_type = await get_device_metadata(lockdown)
        out["deviceName"] = device_name
        out["productType"] = product_type

        async with DiagnosticsService(lockdown) as diagnostics:
            battery = await diagnostics.get_battery()
        out["battery"] = json_safe(battery)
        out["batteryMetrics"] = normalize_battery_metrics(battery)
    except Exception as exc:
        out["error"] = f"{type(exc).__name__}: {exc}"

    return out


async def read_udid_snapshot(udid: str, network: bool) -> dict[str, Any]:
    connection_type = "Network" if network else None
    out: dict[str, Any] = {"udid": udid, "network": network}

    try:
        lockdown, connection_label, resolved_network = await connect_lockdown_for_device(udid, connection_type)
        out["connection"] = connection_label
        out["network"] = resolved_network
        out["iosVersion"] = await get_ios_version(lockdown)
        device_name, product_type = await get_device_metadata(lockdown)
        out["deviceName"] = device_name
        out["productType"] = product_type

        async with DiagnosticsService(lockdown) as diagnostics:
            battery = await diagnostics.get_battery()
        out["battery"] = json_safe(battery)
        out["batteryMetrics"] = normalize_battery_metrics(battery)
    except Exception as exc:
        out["error"] = f"{type(exc).__name__}: {exc}"

    return out


async def read_remote_tunnel_snapshot() -> dict[str, Any]:
    remote_host = os.environ.get("REMOTE_TUNNEL_HOST")
    remote_port_text = os.environ.get("REMOTE_TUNNEL_PORT")
    if not (remote_host and remote_port_text):
        return {"error": "REMOTE_TUNNEL_HOST/PORT not set"}

    out: dict[str, Any] = {"connection": "Wi-Fi tunnel", "network": True}
    try:
        service_socket = socket.create_connection((remote_host, int(remote_port_text)), timeout=10)
        service = ServiceConnection(service_socket)
        remote = create_using_remote(service)
        lockdown = await remote if inspect.isawaitable(remote) else remote
        out["iosVersion"] = await get_ios_version(lockdown)
        device_name, product_type = await get_device_metadata(lockdown)
        out["deviceName"] = device_name
        out["productType"] = product_type

        async with DiagnosticsService(lockdown) as diagnostics:
            battery = await diagnostics.get_battery()
        out["battery"] = json_safe(battery)
        out["batteryMetrics"] = normalize_battery_metrics(battery)
    except Exception as exc:
        out["error"] = f"{type(exc).__name__}: {exc}"

    return out


async def read_all_devices() -> list[dict[str, Any]]:
    remote_host = os.environ.get("REMOTE_TUNNEL_HOST")
    remote_port_text = os.environ.get("REMOTE_TUNNEL_PORT")
    if remote_host and remote_port_text:
        return [await read_remote_tunnel_snapshot()]

    devices = await usbmux.list_devices()
    if not devices:
        return []

    # Group devices by serial (udid)
    grouped: dict[str, list[Any]] = {}
    for device in devices:
        grouped.setdefault(device.serial, []).append(device)

    snapshots: list[dict[str, Any]] = []
    for serial, dev_list in grouped.items():
        # Prioritize USB connection because it is faster/more reliable
        usb_device = next((d for d in dev_list if getattr(d, "connection_type", None) == "USB"), None)
        primary_device = usb_device if usb_device else dev_list[0]
        
        snapshot = await read_device_snapshot(primary_device)
        
        if len(dev_list) > 1:
            connection_types = [getattr(d, "connection_type", "Unknown") for d in dev_list]
            labels = []
            if "USB" in connection_types:
                labels.append("Cable")
            if "Network" in connection_types:
                labels.append("Wi-Fi sync")
            for ct in connection_types:
                if ct not in ("USB", "Network"):
                    labels.append(ct)
            snapshot["connection"] = ", ".join(labels)
            snapshot["transport"] = ", ".join(connection_types)
            snapshot["network"] = "Network" in connection_types
            
        snapshots.append(snapshot)
        
    return snapshots


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="iOS battery diagnostics via pymobiledevice3 (JSON).")
    parser.add_argument("--json", action="store_true", help="Print JSON for Stats.")
    parser.add_argument("--udid", help="Read a single device by UDID.")
    parser.add_argument(
        "--network",
        action="store_true",
        help="Use Wi-Fi sync for --udid (pymobiledevice3 connection_type=Network).",
    )
    return parser.parse_args(argv)


async def main_async(args: argparse.Namespace) -> None:
    if args.udid:
        devices = [await read_udid_snapshot(args.udid, args.network)]
    else:
        devices = await read_all_devices()

    if args.json:
        print(json.dumps({"devices": devices}, ensure_ascii=False))
        return

    for index, device in enumerate(devices):
        if index:
            print()
        print_battery_summary(device)


def main() -> None:
    args = parse_args()
    if not args.json and not sys.stdout.isatty():
        args.json = True
    try:
        asyncio.run(main_async(args))
    except RuntimeError as exc:
        print(json.dumps({"error": str(exc), "devices": []}))
        raise SystemExit(0) from None
    except Exception as exc:
        print(json.dumps({"error": f"{type(exc).__name__}: {exc}", "devices": []}))
        raise SystemExit(0) from None


if __name__ == "__main__":
    main()
