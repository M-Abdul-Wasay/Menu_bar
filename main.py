import sys
import time
import threading
import subprocess
import os
from datetime import datetime
from typing import Optional, List

import psutil
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# Import your local PC search engine
from search_launcher import SearchLauncher

# Dedicated hardware panels - each owns its own real working logic now
from wifi_panel import router as wifi_router, is_wifi_enabled, get_current_ssid
from bluetooth_panel import router as bluetooth_router, is_bluetooth_enabled
from audio_panel import router as audio_router
from media_panel import router as media_router
from battery_panel import router as battery_router

app = FastAPI(title="Dynamic Island Backend")

# CORS so the Flutter app can call us from any origin
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Wire up the panel routers -> /api/wifi/*, /api/bluetooth/*
app.include_router(wifi_router)
app.include_router(bluetooth_router)
app.include_router(audio_router)
app.include_router(media_router)
app.include_router(battery_router)

# Initialize your local PC app indexer
search_engine = SearchLauncher()

# ── Optional hardware libs (graceful fallback) ────────────────────
try:
    from pycaw.pycaw import AudioUtilities
    PYCAW_OK = True
except Exception:
    PYCAW_OK = False

try:
    import screen_brightness_control as sbc
    SBC_OK = True
except Exception:
    SBC_OK = False

try:
    from PIL import ImageGrab
    PIL_OK = True
except Exception:
    PIL_OK = False

# ── Quick Actions persistence ──────────────────────────────────────
QUICK_ACTIONS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "quick_actions.json")
_DEFAULT_QUICK_ACTIONS = [
    {"name": "Explorer", "action": "explorer.exe", "type": "exe"},
    {"name": "Terminal", "action": "cmd.exe", "type": "exe"},
    {"name": "Task Manager", "action": "taskmgr.exe", "type": "exe"},
    {"name": "Notepad", "action": "notepad.exe", "type": "exe"},
]

def _load_quick_actions():
    import json
    if not os.path.exists(QUICK_ACTIONS_FILE):
        _save_quick_actions(_DEFAULT_QUICK_ACTIONS)
        return list(_DEFAULT_QUICK_ACTIONS)
    try:
        with open(QUICK_ACTIONS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return list(_DEFAULT_QUICK_ACTIONS)

def _save_quick_actions(items):
    import json
    try:
        with open(QUICK_ACTIONS_FILE, "w", encoding="utf-8") as f:
            json.dump(items, f, indent=2)
    except Exception:
        pass

# ── Cached state ────────────────────────────────────────────────
_cached_volume: Optional[int] = None
_cached_muted: Optional[bool] = None
_cached_brightness: Optional[int] = None

# ── Hardware Helpers ─────────────────────────────────────────────
def _run_powershell(ps_cmd: str) -> str:
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-Command", ps_cmd],
            capture_output=True, text=True, timeout=5,
        )
        return (out.stdout or "").strip()
    except Exception:
        return ""

def _get_battery() -> tuple[Optional[int], Optional[bool]]:
    bat = psutil.sensors_battery()
    if bat is None:
        return None, None
    return int(bat.percent), bool(bat.power_plugged)

def _volume_get() -> tuple[int, bool]:
    if not PYCAW_OK:
        return _cached_volume or 60, _cached_muted or False
    try:
        from ctypes import cast, POINTER
        from comtypes import CLSCTX_ALL
        from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume
        devices = AudioUtilities.GetSpeakers()
        interface = devices.Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None)
        volume = cast(interface, POINTER(IAudioEndpointVolume))
        v = int(volume.GetMasterVolumeLevelScalar() * 100)
        m = bool(volume.GetMute())
        return v, m
    except Exception:
        return _cached_volume or 60, _cached_muted or False

def _volume_set(value: int) -> bool:
    value = max(0, min(100, int(value)))
    if not PYCAW_OK: return False
    try:
        from ctypes import cast, POINTER
        from comtypes import CLSCTX_ALL
        from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume
        devices = AudioUtilities.GetSpeakers()
        interface = devices.Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None)
        volume = cast(interface, POINTER(IAudioEndpointVolume))
        volume.SetMasterVolumeLevelScalar(value / 100.0, None)
        return True
    except Exception:
        return False

def _volume_mute(muted: bool) -> bool:
    if not PYCAW_OK: return False
    try:
        from ctypes import cast, POINTER
        from comtypes import CLSCTX_ALL
        from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume
        devices = AudioUtilities.GetSpeakers()
        interface = devices.Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None)
        volume = cast(interface, POINTER(IAudioEndpointVolume))
        volume.SetMute(bool(muted), None)
        return True
    except Exception:
        return False

def _brightness_get() -> int:
    if not SBC_OK:
        return _cached_brightness or 80
    try:
        b = sbc.get_brightness()
        return int(b[0] if isinstance(b, list) and b else b or 80)
    except Exception:
        return 80

def _brightness_set(value: int) -> bool:
    value = max(0, min(100, int(value)))
    if not SBC_OK: return False
    try:
        sbc.set_brightness(value)
        return True
    except Exception:
        return False

def _darkmode_get() -> bool:
    # AppsUseLightTheme == 1 means light theme -> dark mode is the inverse
    out = _run_powershell(
        "(Get-ItemProperty -Path "
        "'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize' "
        "-Name AppsUseLightTheme).AppsUseLightTheme"
    )
    try:
        return int(out) == 0
    except Exception:
        return True

def _darkmode_set(dark: bool) -> bool:
    val = 0 if dark else 1
    _run_powershell(
        "Set-ItemProperty -Path "
        "'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize' "
        f"-Name AppsUseLightTheme -Value {val}"
    )
    _run_powershell(
        "Set-ItemProperty -Path "
        "'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize' "
        f"-Name SystemUsesLightTheme -Value {val}"
    )
    return dark

# ── Request Models ────────────────────────────────────────────────
class AppLaunchReq(BaseModel):
    exe: str

# ── Spotlight Search & Launcher API ─────────────────────────────
@app.get("/api/search")
def spotlight_search(q: str = ""):
    if not q:
        return {"results": []}

    results = []
    q_low = q.lower()

    # 1. System Utility Hooks
    actions = [
        {"name": "Turn Off Wi-Fi", "type": "Action", "action": "wifi_toggle"},
        {"name": "Mute System Volume", "type": "Action", "action": "volume_mute"},
    ]
    for act in actions:
        if q_low in act["name"].lower():
            results.append(act)

    # 2. Local App Engine Lookups
    app_names = search_engine.search(q, limit=8)
    print(f"[Search Engine] Query: '{q}' matched apps -> {app_names}")

    for name in app_names:
        results.append({
            "name": name,
            "type": "Application",
            "action": name
        })

    return {"results": results}

@app.post("/api/apps/launch")
def apps_launch(req: AppLaunchReq):
    launched = search_engine.launch(req.exe)
    if launched:
        return {"ok": True, "exe": req.exe}
    try:
        os.startfile(req.exe)
        return {"ok": True, "exe": req.exe}
    except Exception as e:
        return {"ok": False, "error": str(e)}

# ── Core Control API Implementation Routes ─────────────────────
@app.get("/api/system/status")
def system_status():
    bat_pct, bat_plugged = _get_battery()
    vol, muted = _volume_get()
    brt = _brightness_get()
    cpu = psutil.cpu_percent(interval=None)
    ram = psutil.virtual_memory().percent

    wifi_on = is_wifi_enabled()
    ssid = get_current_ssid() if wifi_on else ""

    return {
        "clock": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "wifi_enabled": wifi_on,
        "current_wifi": ssid,
        "battery_percent": bat_pct,
        "battery_plugged": bat_plugged,
        "cpu_percent": cpu,
        "ram_percent": ram,
        "bluetooth_enabled": is_bluetooth_enabled(),
        "volume": vol,
        "muted": muted,
        "brightness": brt,
    }

# NOTE: /api/wifi/toggle and /api/bluetooth/toggle now live in
# wifi_panel.py and bluetooth_panel.py respectively (via include_router
# above). They used to be duplicated here, which meant this app had two
# competing implementations fighting over the same route.

class VolumeSetReq(BaseModel):
    value: int

@app.post("/api/volume/set")
def volume_set(req: VolumeSetReq):
    return {"ok": _volume_set(req.value), "value": req.value}

class VolumeMuteReq(BaseModel):
    muted: bool

@app.post("/api/volume/mute")
def volume_mute(req: VolumeMuteReq):
    return {"ok": _volume_mute(req.muted), "muted": req.muted}

class BrightnessSetReq(BaseModel):
    value: int

@app.post("/api/brightness/set")
def brightness_set(req: BrightnessSetReq):
    return {"ok": _brightness_set(req.value), "value": req.value}

# ── Extra System Modules ───────────────────────────────────────
# NOTE: /api/power/set (power plan switching) and /api/power/status
# now live in battery_panel.py, which actually calls powercfg instead
# of just echoing the guid back like this used to.

@app.post("/api/power/lock")
def power_lock():
    try:
        subprocess.Popen(["rundll32.exe", "user32.dll,LockWorkStation"])
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}

@app.post("/api/power/sleep")
def power_sleep():
    try:
        subprocess.Popen(["rundll32.exe", "powrprof.dll,SetSuspendState", "0,1,0"])
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}

@app.post("/api/power/restart")
def power_restart():
    try:
        subprocess.Popen(["shutdown", "/r", "/t", "0"])
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}

@app.post("/api/power/shutdown")
def power_shutdown():
    try:
        subprocess.Popen(["shutdown", "/s", "/t", "0"])
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}

@app.post("/api/actions/screenshot")
def actions_screenshot():
    if not PIL_OK:
        return {"ok": False, "error": "Pillow not installed"}
    try:
        img = ImageGrab.grab()
        out_dir = os.path.join(os.path.expanduser("~"), "Pictures", "Screenshots")
        os.makedirs(out_dir, exist_ok=True)
        fname = f"Screenshot_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
        fpath = os.path.join(out_dir, fname)
        img.save(fpath)
        return {"ok": True, "path": fpath}
    except Exception as e:
        return {"ok": False, "error": str(e)}

@app.get("/api/actions/darkmode")
def darkmode_get():
    return {"dark_mode": _darkmode_get()}

@app.post("/api/actions/darkmode/toggle")
def darkmode_toggle():
    new_val = not _darkmode_get()
    _darkmode_set(new_val)
    return {"dark_mode": new_val}

# ── Quick Actions (pinned apps) ────────────────────────────────
class QuickActionAddReq(BaseModel):
    name: str
    action: str
    type: str = "app"

class QuickActionRemoveReq(BaseModel):
    name: str

@app.get("/api/quickactions")
def quickactions_list():
    return {"items": _load_quick_actions()}

@app.post("/api/quickactions/add")
def quickactions_add(req: QuickActionAddReq):
    items = _load_quick_actions()
    if not any(i["name"] == req.name for i in items):
        items.append({"name": req.name, "action": req.action, "type": req.type})
        _save_quick_actions(items)
    return {"items": items}

@app.post("/api/quickactions/remove")
def quickactions_remove(req: QuickActionRemoveReq):
    items = [i for i in _load_quick_actions() if i["name"] != req.name]
    _save_quick_actions(items)
    return {"items": items}

class ClipCopyReq(BaseModel):
    text: str

@app.post("/api/clipboard/copy")
def clipboard_copy(req: ClipCopyReq):
    return {"ok": True}

@app.post("/api/clipboard/clear")
def clipboard_clear():
    return {"ok": True}

@app.get("/api/clipboard/recent")
def clipboard_recent():
    return {"items": []}

@app.get("/api/calendar/upcoming")
def calendar_upcoming():
    return {"events": []}

@app.get("/")
def root():
    return {
        "service": "Dynamic Island Backend",
        "status": "ok",
        "capabilities": {"pycaw": PYCAW_OK, "sbc": SBC_OK}
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="info")