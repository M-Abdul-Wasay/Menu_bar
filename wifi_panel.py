import subprocess
import re
import os
import tempfile
from xml.sax.saxutils import escape as xml_escape
from typing import Optional, List

from fastapi import APIRouter
from pydantic import BaseModel

# Dedicated router for Wi-Fi endpoints
router = APIRouter()

# ==========================================
# LOW-LEVEL HELPERS
# ==========================================
def run_ps(command: str, timeout: int = 8) -> str:
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command", command],
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return (result.stdout or "").strip()
    except Exception as e:
        print(f"[Wi-Fi Panel Error] {e}")
        return ""

def run_netsh(args: list, timeout: int = 12) -> str:
    try:
        result = subprocess.run(
            ["netsh"] + args,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return result.stdout or ""
    except Exception as e:
        print(f"[Wi-Fi netsh Error] {e}")
        return ""

# ==========================================
# STATUS / TOGGLE (unchanged behavior)
# ==========================================
def is_wifi_enabled() -> bool:
    out = run_ps(
        "(Get-NetAdapter | Where-Object {$_.Name -like '*Wi-Fi*'} | "
        "Select-Object -First 1).Status"
    )
    return "Up" in out

def get_current_ssid() -> str:
    if not is_wifi_enabled():
        return ""

    out = subprocess.run(
        ["netsh", "wlan", "show", "interfaces"],
        capture_output=True, text=True
    ).stdout

    for line in out.split('\n'):
        if "BSSID" in line:
            continue
        if "SSID" in line:
            parts = line.split(":")
            if len(parts) > 1:
                return parts[1].strip()
    return ""

def toggle_windows_wifi() -> bool:
    enabled = is_wifi_enabled()
    if enabled:
        run_ps("Disable-NetAdapter -Name '*Wi-Fi*' -Confirm:$false")
        return False
    else:
        run_ps("Enable-NetAdapter -Name '*Wi-Fi*' -Confirm:$false")
        return True

# ==========================================
# NETWORK SCANNING
# ==========================================
def get_saved_profiles() -> set:
    out = run_netsh(["wlan", "show", "profiles"])
    profiles = re.findall(r"All User Profile\s*:\s*(.*)", out)
    return set(p.strip() for p in profiles)

def scan_networks() -> List[dict]:
    """
    Uses `netsh wlan show networks mode=bssid`, which also nudges Windows
    to refresh its scan list. Returns one entry per unique SSID (highest
    signal BSSID wins if the same network is seen on multiple channels).
    """
    out = run_netsh(["wlan", "show", "networks", "mode=bssid"])
    if not out.strip():
        return []

    current_ssid = get_current_ssid()
    saved = get_saved_profiles()

    # Split into per-SSID blocks
    blocks = re.split(r"\r?\n(?=SSID \d+ :)", out)
    found = {}
    for block in blocks:
        m = re.search(r"SSID \d+ : (.*)", block)
        if not m:
            continue
        ssid = m.group(1).strip()
        if not ssid:
            continue  # hidden network, skip

        auth_m = re.search(r"Authentication\s*:\s*(.*)", block)
        authentication = auth_m.group(1).strip() if auth_m else "Unknown"

        signal_m = re.search(r"Signal\s*:\s*(\d+)%", block)
        signal = int(signal_m.group(1)) if signal_m else 0

        entry = {
            "ssid": ssid,
            "authentication": authentication,
            "signal": signal,
            "secured": authentication.strip().lower() != "open",
            "connected": ssid == current_ssid,
            "saved": ssid in saved,
        }

        if ssid not in found or signal > found[ssid]["signal"]:
            found[ssid] = entry

    result = list(found.values())
    # Connected network first, then strongest signal first
    result.sort(key=lambda n: (not n["connected"], -n["signal"]))
    return result

# ==========================================
# CONNECT / FORGET
# ==========================================
def _build_profile_xml(ssid: str, password: Optional[str]) -> str:
    safe_ssid = xml_escape(ssid)
    if password:
        safe_pw = xml_escape(password)
        return f'''<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>{safe_ssid}</name>
    <SSIDConfig>
        <SSID>
            <name>{safe_ssid}</name>
        </SSID>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>WPA2PSK</authentication>
                <encryption>AES</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>{safe_pw}</keyMaterial>
            </sharedKey>
        </security>
    </MSM>
</WLANProfile>'''
    else:
        return f'''<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>{safe_ssid}</name>
    <SSIDConfig>
        <SSID>
            <name>{safe_ssid}</name>
        </SSID>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>open</authentication>
                <encryption>none</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
        </security>
    </MSM>
</WLANProfile>'''

def connect_to_network(ssid: str, password: Optional[str] = None):
    saved = get_saved_profiles()

    # If we don't already have a saved profile for this network, create one.
    # (If it's already saved, Windows remembers the password from before —
    # we don't need/want to overwrite it unless a new password was given.)
    if ssid not in saved or password:
        xml = _build_profile_xml(ssid, password)
        tmp_path = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", suffix=".xml", delete=False, encoding="utf-8") as f:
                f.write(xml)
                tmp_path = f.name
            add_result = subprocess.run(
                ["netsh", "wlan", "add", "profile", f"filename={tmp_path}", "user=all"],
                capture_output=True, text=True, timeout=10
            )
            if add_result.returncode != 0:
                msg = (add_result.stdout or add_result.stderr or "Failed to add profile").strip()
                return False, msg
        finally:
            if tmp_path:
                try:
                    os.remove(tmp_path)
                except Exception:
                    pass

    conn_result = subprocess.run(
        ["netsh", "wlan", "connect", f"name={ssid}", f"ssid={ssid}"],
        capture_output=True, text=True, timeout=10
    )
    output = (conn_result.stdout or conn_result.stderr or "").strip()
    ok = conn_result.returncode == 0 and "completed successfully" in output.lower()
    return ok, output

def forget_network(ssid: str) -> bool:
    result = subprocess.run(
        ["netsh", "wlan", "delete", "profile", f"name={ssid}"],
        capture_output=True, text=True, timeout=8
    )
    return result.returncode == 0

# ==========================================
# API ENDPOINTS
# ==========================================
@router.get("/api/wifi/status")
def get_wifi_status():
    enabled = is_wifi_enabled()
    ssid = get_current_ssid() if enabled else ""
    return {
        "enabled": enabled,
        "ssid": ssid,
        "status_text": "Connected" if ssid else ("Disconnected" if enabled else "Off")
    }

class WifiToggleResponse(BaseModel):
    enabled: bool

@router.post("/api/wifi/toggle", response_model=WifiToggleResponse)
def toggle_wifi_endpoint():
    is_now_enabled = toggle_windows_wifi()
    return {"enabled": is_now_enabled}

@router.get("/api/wifi/networks")
def wifi_networks():
    if not is_wifi_enabled():
        return {"networks": [], "wifi_enabled": False}
    return {"networks": scan_networks(), "wifi_enabled": True}

class WifiConnectReq(BaseModel):
    ssid: str
    password: Optional[str] = None

@router.post("/api/wifi/connect")
def wifi_connect(req: WifiConnectReq):
    ok, message = connect_to_network(req.ssid, req.password)
    return {"ok": ok, "message": message, "ssid": req.ssid}

class WifiForgetReq(BaseModel):
    ssid: str

@router.post("/api/wifi/forget")
def wifi_forget(req: WifiForgetReq):
    return {"ok": forget_network(req.ssid)}