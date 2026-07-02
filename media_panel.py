import subprocess
import json
from typing import Optional

from fastapi import APIRouter

# Dedicated router for Now Playing / media transport controls.
#
# Uses Windows' Windows.Media.Control WinRT API
# (GlobalSystemMediaTransportControlsSessionManager) - the same source
# that powers the volume flyout's "Now Playing" widget in Windows 10/11.
# It works with whatever app currently holds the active media session
# (Spotify, browser tab playing audio, VLC, etc.) without needing any
# per-app integration.
router = APIRouter()

def run_ps(command: str, timeout: int = 10) -> str:
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command", command],
            capture_output=True,
            text=True,
            timeout=timeout
        )
        if result.returncode != 0 or result.stderr.strip():
            print(f"[Media Panel PowerShell stderr] {result.stderr.strip()}")
        return (result.stdout or "").strip()
    except Exception as e:
        print(f"[Media Panel Error] {e}")
        return ""

def run_ps_debug(command: str, timeout: int = 10) -> dict:
    """Same as run_ps but returns stdout+stderr+returncode instead of
    swallowing them - used only by the /api/media/debug endpoint."""
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command", command],
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return {
            "returncode": result.returncode,
            "stdout": (result.stdout or "").strip(),
            "stderr": (result.stderr or "").strip(),
        }
    except Exception as e:
        return {"returncode": -1, "stdout": "", "stderr": str(e)}

# Small helper that lets PowerShell "await" WinRT async operations -
# a well-known pattern since WinRT's IAsyncOperation isn't directly
# awaitable from PowerShell.
_AWAIT_HELPER = r'''
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Function Await($WinRtTask, $ResultType) {
    $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
    $asTaskGeneric = $asTask.MakeGenericMethod($ResultType)
    $netTask = $asTaskGeneric.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    return $netTask.Result
}
'''

_SESSION_SETUP = r'''
[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime] | Out-Null
[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties,Windows.Media.Control,ContentType=WindowsRuntime] | Out-Null
$sessionManager = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
$currentSession = $sessionManager.GetCurrentSession()
'''

def get_now_playing() -> Optional[dict]:
    script = _AWAIT_HELPER + _SESSION_SETUP + r'''
if ($currentSession) {
    $props = Await ($currentSession.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    $playback = $currentSession.GetPlaybackInfo()
    [PSCustomObject]@{
        title = $props.Title
        artist = $props.Artist
        album = $props.AlbumTitle
        status = $playback.PlaybackStatus.ToString()
        app = $currentSession.SourceAppUserModelId
    } | ConvertTo-Json -Compress
}
'''
    out = run_ps(script)
    if not out:
        return None
    try:
        data = json.loads(out)
    except Exception as e:
        print(f"[Media Panel Parse Error] {e}")
        return None
    return {
        "title": data.get("title") or "",
        "artist": data.get("artist") or "",
        "album": data.get("album") or "",
        "status": (data.get("status") or "").strip().lower(),  # playing / paused / stopped / changing
        "app": data.get("app") or "",
    }

def _send_media_command(method: str) -> bool:
    script = _AWAIT_HELPER + _SESSION_SETUP + f'''
if ($currentSession) {{
    $ok = Await ($currentSession.{method}()) ([bool])
    Write-Output $ok
}} else {{
    Write-Output "false"
}}
'''
    out = run_ps(script)
    return out.strip().lower() == "true"

def media_toggle_play_pause() -> bool:
    return _send_media_command("TryTogglePlayPauseAsync")

def media_next() -> bool:
    return _send_media_command("TrySkipNextAsync")

def media_previous() -> bool:
    return _send_media_command("TrySkipPreviousAsync")

# ==========================================
# API ENDPOINTS
# ==========================================
@router.get("/api/media/now-playing")
def now_playing():
    info = get_now_playing()
    if info is None:
        return {"active": False}
    return {"active": True, **info}

@router.get("/api/media/debug")
def media_debug():
    """
    Diagnostic endpoint: runs the exact same script now-playing uses,
    but returns raw stdout/stderr instead of swallowing errors. Hit
    this in a browser (http://127.0.0.1:8000/api/media/debug) while
    music is playing to see what's actually happening.
    """
    script = _AWAIT_HELPER + _SESSION_SETUP + r'''
if ($currentSession) {
    $props = Await ($currentSession.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    $playback = $currentSession.GetPlaybackInfo()
    [PSCustomObject]@{
        sessionFound = $true
        title = $props.Title
        artist = $props.Artist
        status = $playback.PlaybackStatus.ToString()
        app = $currentSession.SourceAppUserModelId
    } | ConvertTo-Json -Compress
} else {
    [PSCustomObject]@{ sessionFound = $false } | ConvertTo-Json -Compress
}
'''
    return run_ps_debug(script)

@router.post("/api/media/play-pause")
def play_pause():
    return {"ok": media_toggle_play_pause()}

@router.post("/api/media/next")
def next_track():
    return {"ok": media_next()}

@router.post("/api/media/previous")
def previous_track():
    return {"ok": media_previous()}