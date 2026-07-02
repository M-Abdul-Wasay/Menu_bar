import subprocess
import json
from typing import List, Optional

from fastapi import APIRouter
from pydantic import BaseModel

# Dedicated router for audio output-device switching.
#
# Windows has no built-in cmdlet to list/switch the default playback
# device. The reliable, widely-used way to do this from PowerShell is
# the free "AudioDeviceCmdlets" module. If it isn't installed, this
# panel reports that clearly instead of failing silently.
router = APIRouter()

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
        print(f"[Audio Panel Error] {e}")
        return ""

def _module_available() -> bool:
    out = run_ps(
        "Get-Module -ListAvailable -Name AudioDeviceCmdlets | "
        "Select-Object -First 1 -ExpandProperty Name"
    )
    return bool(out.strip())

def list_output_devices() -> List[dict]:
    if not _module_available():
        return []
    out = run_ps(
        "Import-Module AudioDeviceCmdlets; "
        "Get-AudioDevice -List | Where-Object {$_.Type -eq 'Playback'} | "
        "Select-Object Index, Name, Default | ConvertTo-Json -Compress"
    )
    if not out:
        return []
    try:
        data = json.loads(out)
    except Exception as e:
        print(f"[Audio Panel Parse Error] {e}")
        return []
    if isinstance(data, dict):
        data = [data]

    devices = []
    for d in data:
        name = d.get("Name")
        if not name:
            continue
        devices.append({
            "index": d.get("Index"),
            "name": name,
            "default": bool(d.get("Default")),
        })
    return devices

def set_output_device(index: int) -> bool:
    run_ps(f"Import-Module AudioDeviceCmdlets; Set-AudioDevice -Index {index}")
    # Set-AudioDevice doesn't return a clean success/fail signal on stdout,
    # so we confirm by re-reading which device is now marked Default.
    devices = list_output_devices()
    return any(d["index"] == index and d["default"] for d in devices)

# ==========================================
# API ENDPOINTS
# ==========================================
@router.get("/api/audio/devices")
def audio_devices():
    return {
        "devices": list_output_devices(),
        "module_installed": _module_available(),
    }

class AudioDeviceSetReq(BaseModel):
    index: int

@router.post("/api/audio/set-device")
def audio_set_device(req: AudioDeviceSetReq):
    ok = set_output_device(req.index)
    return {"ok": ok, "devices": list_output_devices()}