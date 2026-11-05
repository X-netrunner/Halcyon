#!/usr/bin/env python3
"""Click on a notification: take the person to what it is about.

  notif-open.py APP_NAME DESKTOP_ENTRY ICON_OR_IMAGE SUMMARY BODY [file|focus|auto]

auto (default)
  1. the notification names a file or folder (a screenshot's picture, a recording's path in the text, "Saved to ~/...")
     -> the file manager opens with that file selected (or the folder, if it is a folder)
  2. otherwise the app's window comes to the front (Hyprland: the newest window whose class matches the app)
file   only step 1.        focus   only step 2 (used after an app's own "default" action, as a safety net).
Exit code 0 when something was opened / focused, 1 when there was nothing to do. Never prints.
"""
import json
import os
import re
import shutil
import subprocess
import sys
from urllib.parse import unquote, urlparse

HOME = os.path.expanduser("~")


def have(cmd):
    return shutil.which(cmd) is not None


def run(cmd, timeout=6):
    try:
        r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)
        return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def as_path(text):
    """a file:// url, ~/..., or an absolute path that exists -> the real path, else None"""
    t = (text or "").strip().strip("'\"")
    if not t:
        return None
    if t.startswith("file://"):
        t = unquote(urlparse(t).path)
    elif t.startswith("~/"):
        t = os.path.join(HOME, t[2:])
    if t.startswith("/") and os.path.exists(t):
        return t
    return None


def find_file(icon, summary, body):
    p = as_path(icon)
    if p:
        return p
    # a path inside the text: "Saved to ~/Pictures/Screenshots/1.png", or just the path
    for chunk in (body or "", summary or ""):
        for m in re.finditer(r"(file://\S+|~/[^\n\"']+|/(?:home|tmp|mnt|run|media)/[^\n\"']+)", chunk):
            cand = m.group(1).rstrip(".,;:)")
            p = as_path(cand)
            while not p and " " in cand:      # a path followed by words ("... .png and copied")
                cand = cand.rsplit(" ", 1)[0]
                p = as_path(cand)
            if p:
                return p
    return None


def show_in_file_manager(path):
    uri = "file://" + path
    if have("gdbus"):      # org.freedesktop.FileManager1: Thunar, Nautilus, Dolphin, Nemo ... select the file inside its folder
        if run(["gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1",
                "--object-path", "/org/freedesktop/FileManager1", "--method", "org.freedesktop.FileManager1.ShowItems",
                "['%s']" % uri, ""], timeout=4):
            return True
    folder = path if os.path.isdir(path) else os.path.dirname(path)
    for fm in ("thunar", "nautilus", "dolphin", "nemo", "pcmanfm"):
        if have(fm):
            subprocess.Popen([fm, folder], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            return True
    if have("xdg-open"):
        subprocess.Popen(["xdg-open", folder], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return True
    return False


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def focus_app(app, entry):
    if not have("hyprctl"):
        return False
    try:
        r = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, timeout=5)
        clients = json.loads(r.stdout.decode("utf-8", "replace"))
    except (OSError, ValueError, subprocess.SubprocessError):
        return False
    wants = [w for w in (norm(entry.replace(".desktop", "").split(".")[-1]), norm(entry), norm(app)) if len(w) >= 3]
    if not wants:
        return False
    best, rank = None, None
    for c in clients if isinstance(clients, list) else []:
        if c.get("mapped") is False:
            continue
        names = [norm(c.get("class")), norm(c.get("initialClass"))]
        hit = 0
        for w in wants:
            if any(n and n == w for n in names):
                hit = 2
                break
            if any(n and (w in n or n in w) for n in names):
                hit = max(hit, 1)
        if not hit:
            continue
        key = (-hit, c.get("focusHistoryID", 999))          # exact class first, then the most recently used
        if rank is None or key < rank:
            best, rank = c, key
    if not best or not best.get("address"):
        return False
    ws = (best.get("workspace") or {}).get("name") or ""
    if ws.startswith("special:"):
        run(["hyprctl", "dispatch", "togglespecialworkspace", ws.split(":", 1)[1]])
    return run(["hyprctl", "dispatch", "focuswindow", "address:" + best["address"]])


def main():
    a = sys.argv[1:] + [""] * 6
    app, entry, icon, summary, body = a[0], a[1], a[2], a[3], a[4]
    mode = a[5] or "auto"
    if mode in ("auto", "file"):
        p = find_file(icon, summary, body)
        if p and show_in_file_manager(p):
            return 0
        if mode == "file":
            return 1
    if mode in ("auto", "focus") and app != "Halcyon":
        return 0 if focus_app(app, entry) else 1
    return 1


if __name__ == "__main__":
    sys.exit(main())
