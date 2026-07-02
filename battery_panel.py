import subprocess
import re
from typing import List, Optional

import psutil
from fastapi import APIRouter
from pydantic import BaseModel

# Dedicated router for battery status + Windows power plan switching.
router = APIRouter()

def run_cmd(args: list, timeout: int = 8) -> str:
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return result.stdout or ""
    except Exception as e:
        print(f"[Battery Panel Error] {e}")
        return ""

def _format_seconds(secs: int) -> str:
    h = secs // 3600
    m = (secs % 3600) // 60
    if h > 0:
        return f"{h}h {m}m remaining"
    return f"{m}m remaining"

def get_battery_status() -> dict:
    bat = psutil.sensors_battery()
    if bat is None:
        # Desktop PC with no battery at all.
        return {"available": False}

    secsleft = bat.secsleft
    if bat.power_plugged:
        time_text = "Fully Charged" if int(bat.percent) >= 100 else "Charging"
    else:
        if secsleft == psutil.POWER_TIME_UNLIMITED:
            time_text = None
        elif secsleft == psutil.POWER_TIME_UNKNOWN or secsleft is None:
            time_text = "Calculating..."
        else:
            time_text = _format_seconds(int(secsleft))

    return {
        "available": True,
        "percent": int(bat.percent),
        "plugged": bool(bat.power_plugged),
        "time_text": time_text,
    }

def list_power_plans() -> List[dict]:
    out = run_cmd(["powercfg", "/list"])
    plans = []
    for line in out.splitlines():
        m = re.search(r"Power Scheme GUID:\s*([0-9a-fA-F-]+)\s*\((.*?)\)\s*(\*)?", line)
        if m:
            plans.append({
                "guid": m.group(1).strip(),
                "name": m.group(2).strip(),
                "active": bool(m.group(3)),
            })
    return plans

def set_power_plan(guid: str) -> bool:
    result = subprocess.run(
        ["powercfg", "/setactive", guid],
        capture_output=True, text=True, timeout=8
    )
    return result.returncode == 0

# ==========================================
# API ENDPOINTS
# ==========================================
@router.get("/api/power/status")
def power_status():
    return get_battery_status()

@router.get("/api/power/plans")
def power_plans():
    return {"plans": list_power_plans()}

class PowerPlanSetReq(BaseModel):
    guid: str

@router.post("/api/power/set")
def power_set(req: PowerPlanSetReq):
    ok = set_power_plan(req.guid)
    return {"ok": ok, "plans": list_power_plans()}