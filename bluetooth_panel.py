import subprocess
import json
from typing import List, Dict

from fastapi import APIRouter
from pydantic import BaseModel

# Dedicated router for Bluetooth endpoints
router = APIRouter()

# ==========================================
# LOW-LEVEL HELPERS
# ==========================================
def run_ps(command: str, timeout: int = 10) -> str:
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command", command],
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return (result.stdout or "").strip()
    except Exception as e:
        print(f"[Bluetooth Panel Error] {e}")
        return ""

def _pnp_bluetooth_entries() -> List[dict]:
    """
    Returns every PnP node under the Bluetooth / BluetoothLE classes as
    structured JSON: FriendlyName, Status, InstanceId.

    InstanceId is the key: the physical radio sits on the USB/PCI bus,
    while every *paired accessory* (headphones, mouse, phone...) plus a
    handful of generic Microsoft protocol stubs (PAN, RFCOMM, LE
    enumerator) live on the "BTHENUM\\..." bus. That split is far more
    reliable than trying to guess from the device name.
    """
    out = run_ps(
        "Get-PnpDevice -Class Bluetooth,BluetoothLE -PresentOnly | "
        "Select-Object FriendlyName, Status, InstanceId | ConvertTo-Json -Compress"
    )
    if not out:
        return []
    try:
        data = json.loads(out)
    except Exception:
        return []
    if isinstance(data, dict):
        data = [data]
    return data

# Generic Microsoft-provided protocol stubs that also live on the BTHENUM
# bus but aren't real paired accessories, so we filter them out of the
# device list.
_GENERIC_NAME_BLOCKLIST = {
    "bluetooth device (personal area network)",
    "bluetooth device (rfcomm protocol tdi)",
    "bluetooth device (bluetooth pan network adapter)",
    "microsoft bluetooth enumerator",
    "bluetooth low energy (le) enumerator",
    "generic bluetooth adapter",
    "bluetooth device (bluetooth audio sink)",
    "bluetooth device (bluetooth audio bidirectional service)",
}

def _radio_entries(entries: List[dict]) -> List[dict]:
    return [
        e for e in entries
        if not str(e.get("InstanceId", "")).upper().startswith("BTHENUM")
    ]

def is_bluetooth_enabled() -> bool:
    radios = _radio_entries(_pnp_bluetooth_entries())
    if not radios:
        return False
    return any(str(r.get("Status", "")).strip().lower() == "ok" for r in radios)

def toggle_windows_bluetooth() -> bool:
    radios = _radio_entries(_pnp_bluetooth_entries())
    enabled = any(str(r.get("Status", "")).strip().lower() == "ok" for r in radios)

    if enabled:
        run_ps(
            "Get-PnpDevice -Class Bluetooth,BluetoothLE -PresentOnly | "
            "Where-Object {$_.InstanceId -notmatch '^BTHENUM'} | "
            "Disable-PnpDevice -Confirm:$false"
        )
        return False
    else:
        run_ps(
            "Get-PnpDevice -Class Bluetooth,BluetoothLE -PresentOnly | "
            "Where-Object {$_.InstanceId -notmatch '^BTHENUM'} | "
            "Enable-PnpDevice -Confirm:$false"
        )
        return True

def list_bluetooth_devices() -> List[dict]:
    """
    Paired Bluetooth accessories with their live connected/disconnected
    state. A single physical device can register more than one PnP node
    (e.g. one for HID input, one for the audio profile) under the same
    FriendlyName, so we collapse by name and call it "connected" if any
    of its nodes report OK.
    """
    entries = _pnp_bluetooth_entries()
    devices: Dict[str, bool] = {}
    for e in entries:
        name = str(e.get("FriendlyName") or "").strip()
        instance_id = str(e.get("InstanceId") or "")
        status = str(e.get("Status") or "").strip().lower()

        if not name or not instance_id.upper().startswith("BTHENUM"):
            continue
        if name.lower() in _GENERIC_NAME_BLOCKLIST:
            continue

        connected = status == "ok"
        devices[name] = devices.get(name, False) or connected

    return [{"name": n, "connected": c} for n, c in sorted(devices.items())]

# ==========================================
# API ENDPOINTS
# ==========================================
@router.get("/api/bluetooth/status")
def get_bluetooth_status():
    enabled = is_bluetooth_enabled()
    return {
        "enabled": enabled,
        "status_text": "On" if enabled else "Off"
    }

class BluetoothToggleResponse(BaseModel):
    enabled: bool

@router.post("/api/bluetooth/toggle", response_model=BluetoothToggleResponse)
def toggle_bluetooth_endpoint():
    return {"enabled": toggle_windows_bluetooth()}

@router.get("/api/bluetooth/devices")
def bluetooth_devices():
    if not is_bluetooth_enabled():
        return {"devices": [], "bluetooth_enabled": False}
    return {"devices": list_bluetooth_devices(), "bluetooth_enabled": True}

# ==========================================
# NEARBY DEVICE DISCOVERY (classic Bluetooth inquiry)
# ==========================================
# Note: this uses the classic BR/EDR BluetoothFindFirstDevice/NextDevice
# Win32 API via a small inline C# shim. It reliably finds classic
# Bluetooth devices (most headphones, speakers, keyboards/mice). It will
# NOT find BLE-only devices in advertising/pairing mode - that needs the
# WinRT BluetoothLEAdvertisementWatcher APIs, which are a separate,
# heavier feature.
_SCAN_SCRIPT = r'''
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class BtScan {
    [StructLayout(LayoutKind.Sequential)]
    public struct SEARCH_PARAMS {
        public int dwSize;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnAuthenticated;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnUnknown;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool fIssueInquiry;
        public byte cTimeoutMultiplier;
        public IntPtr hRadio;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEMTIME {
        public short wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVICE_INFO {
        public int dwSize;
        public long Address;
        public uint ulClassofDevice;
        [MarshalAs(UnmanagedType.Bool)] public bool fConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool fRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool fAuthenticated;
        public SYSTEMTIME stLastSeen;
        public SYSTEMTIME stLastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)]
        public string szName;
    }

    [DllImport("Irprops.cpl", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr BluetoothFindFirstDevice(ref SEARCH_PARAMS p, ref DEVICE_INFO info);

    [DllImport("Irprops.cpl", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool BluetoothFindNextDevice(IntPtr hFind, ref DEVICE_INFO info);

    [DllImport("Irprops.cpl")]
    public static extern bool BluetoothFindDeviceClose(IntPtr hFind);
}
"@

$p = New-Object BtScan+SEARCH_PARAMS
$p.dwSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]"BtScan+SEARCH_PARAMS")
$p.fReturnAuthenticated = $true
$p.fReturnRemembered = $true
$p.fReturnUnknown = $true
$p.fReturnConnected = $true
$p.fIssueInquiry = $true
$p.cTimeoutMultiplier = 8
$p.hRadio = [IntPtr]::Zero

$info = New-Object BtScan+DEVICE_INFO
$info.dwSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]"BtScan+DEVICE_INFO")

$results = @()
$h = [BtScan]::BluetoothFindFirstDevice([ref]$p, [ref]$info)
if ($h -ne [IntPtr]::Zero) {
    do {
        $addrBytes = [BitConverter]::GetBytes($info.Address)
        $mac = "{0:X2}:{1:X2}:{2:X2}:{3:X2}:{4:X2}:{5:X2}" -f $addrBytes[5],$addrBytes[4],$addrBytes[3],$addrBytes[2],$addrBytes[1],$addrBytes[0]
        $results += [PSCustomObject]@{
            name = $info.szName
            address = $mac
            paired = [bool]$info.fRemembered
            connected = [bool]$info.fConnected
        }
        $info.dwSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]"BtScan+DEVICE_INFO")
    } while ([BtScan]::BluetoothFindNextDevice($h, [ref]$info))
    [BtScan]::BluetoothFindDeviceClose($h) | Out-Null
}

$results | ConvertTo-Json -Compress
'''

def scan_nearby_devices() -> List[dict]:
    """
    Runs a ~10 second classic Bluetooth inquiry and returns every device
    seen, paired or not. Takes real time because that's how Bluetooth
    inquiry works - there's no faster path.
    """
    out = run_ps(_SCAN_SCRIPT, timeout=20)
    if not out:
        return []
    try:
        data = json.loads(out)
    except Exception as e:
        print(f"[Bluetooth Scan Parse Error] {e}")
        return []
    if isinstance(data, dict):
        data = [data]

    devices = []
    seen_addresses = set()
    for d in data:
        addr = d.get("address")
        if not addr or addr in seen_addresses:
            continue
        seen_addresses.add(addr)
        name = (d.get("name") or "").strip() or "Unknown Device"
        devices.append({
            "name": name,
            "address": addr,
            "paired": bool(d.get("paired")),
            "connected": bool(d.get("connected")),
        })
    return devices

@router.get("/api/bluetooth/scan")
def bluetooth_scan():
    if not is_bluetooth_enabled():
        return {"devices": [], "bluetooth_enabled": False}
    return {"devices": scan_nearby_devices(), "bluetooth_enabled": True}

@router.post("/api/bluetooth/pair")
def bluetooth_pair():
    """
    Opens Windows' native Bluetooth settings so the person can complete
    pairing (PIN entry / numeric confirmation) through the real OS flow
    instead of a hand-rolled one.
    """
    try:
        subprocess.Popen(["cmd", "/c", "start", "", "ms-settings:bluetooth"])
        return {"ok": True, "opened_settings": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}