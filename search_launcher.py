import os
import glob
import subprocess

# Fully expanded system fallback paths to bypass empty env variables
_START_MENU_DIRS = [
    os.path.expandvars(r"%ProgramData%\Microsoft\Windows\Start Menu\Programs"),
    os.path.expandvars(r"%APPDATA%\Microsoft\Windows\Start Menu\Programs"),
    r"C:\ProgramData\Microsoft\Windows\Start Menu\Programs",
]

def _index_apps():
    apps = {}
    
    # 1. Look through standard Start Menu locations
    for base in _START_MENU_DIRS:
        if not base or not os.path.isdir(base):
            continue
        for path in glob.glob(os.path.join(base, "**", "*.lnk"), recursive=True):
            name = os.path.splitext(os.path.basename(path))[0]
            if name and name not in apps:
                apps[name] = path

    # 2. Hardcoded absolute fallbacks for standard apps (In case Windows blocks shortcut indexing)
    fallbacks = {
        "Google Chrome": r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        "Visual Studio Code": os.path.expandvars(r"%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe"),
        "Notepad": r"C:\Windows\System32\notepad.exe",
        "Command Prompt": r"C:\Windows\System32\cmd.exe",
        "Task Manager": r"C:\Windows\System32\taskmgr.exe",
        "File Explorer": r"C:\Windows\explorer.exe",
        "Edge": r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "Discord": os.path.expandvars(r"%LOCALAPPDATA%\Discord\Update.exe"),
        "Spotify": os.path.expandvars(r"%APPDATA%\Spotify\Spotify.exe")
    }

    for name, target_path in fallbacks.items():
        if os.path.exists(target_path) and name not in apps:
            apps[name] = target_path

    print(f"[Indexer Alpha] Successfully loaded {len(apps)} local apps into memory.")
    return apps

def _score(name, query):
    name_l = name.lower()
    q_l    = query.lower()
    n, q   = len(name_l), len(q_l)

    if q == 0:
        return None
    if name_l == q_l:
        return 10000
    if name_l.startswith(q_l):
        return 5000 - n
    if q_l in name_l:
        return 2000 - name_l.find(q_l)

    # Subsequence walk
    qi, score, prev = 0, 0, 0
    for ni in range(n):
        if qi < q and name_l[ni] == q_l[qi]:
            s = 10
            if ni == 0:
                s += 30
            elif name[ni - 1] in " _-./\\":
                s += 15
            elif name[ni - 1].islower() and name[ni].isupper():
                s += 15
            score += s
            qi += 1
            
    if qi < q:
        return None
    score -= n // 2
    return max(score, 1)

class SearchLauncher:
    def __init__(self):
        self._apps = {}
        self.refresh()

    def refresh(self):
        self._apps = _index_apps()

    def search(self, query, limit=8):
        if not query:
            return []
        scored = []
        for name in self._apps:
            s = _score(name, query)
            if s is not None:
                scored.append((s, name))
        scored.sort(key=lambda x: (-x[0], len(x[1]), x[1].lower()))
        return [name for _, name in scored[:limit]]

    def launch(self, name):
        path = self._apps.get(name)
        if not path:
            return False
        try:
            # Native Windows Execution Engine
            os.startfile(path)
            return True
        except Exception as e:
            try:
                subprocess.Popen(path, shell=True)
                return True
            except Exception:
                return False