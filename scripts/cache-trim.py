#!/usr/bin/env python3
"""cache-trim.py: keep Halcyon's own caches from growing without limit.

  cache-trim.py            trim when Settings > Performance > Aggressive Memory Freeing is on (the default in Low / Medium use)
  cache-trim.py --force    trim whatever the setting says
  cache-trim.py --status   sizes and limits, deletes nothing

Only Halcyon's folders are touched, never another program's cache (browser, Spotify, thumbnails, package builds):
  ~/.cache/island/{live-proxy,live-thumbs,clip-thumbs,wpcolors}   over 200 MB: the oldest files go first (all of it is made again on demand)
  ~/.cache/halcyon-build                                          over 600 MB: the Rust build folders go (only build output; the
                                                                  programs are installed in ~/.config/Halcyon/bin; the next update
                                                                  builds them again, which takes a few minutes). Skipped while an install or a build is running.
"""
import json
import os
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")
CACHE = os.path.join(HOME, ".cache")
ISLAND = os.path.join(CACHE, "island")
BUILD = os.path.join(CACHE, "halcyon-build")
STATE = os.environ.get("HALCYON_STATE") or os.path.join(HOME, ".local", "state", "island")
ISLAND_DIRS = ("live-proxy", "live-thumbs", "clip-thumbs", "wpcolors")
ISLAND_MAX = 200 * 1024 * 1024
BUILD_MAX = 600 * 1024 * 1024


def aggressive():
    try:
        o = json.load(open(os.path.join(STATE, "settings.json"), encoding="utf-8")).get("opt", {})
        return o.get("lazyLoad", True) is not False
    except (OSError, ValueError, AttributeError):
        return True


def files_under(path):
    out = []
    for d, _, names in os.walk(path):
        for n in names:
            p = os.path.join(d, n)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if os.path.isfile(p) and not os.path.islink(p):
                out.append((st.st_mtime, st.st_size, p))
    return out


def size(path):
    return sum(s for _, s, _ in files_under(path)) if os.path.isdir(path) else 0


def building():
    """An install or a cargo / rustc run of this user is going on: leave the build folders alone."""
    r = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "cargo|rustc|install.sh|update.sh"], capture_output=True)
    if r.returncode == 0:
        return True
    r = subprocess.run(["pgrep", "-u", str(os.getuid()), "-f", r"(^|/)(install|update)\.sh( |$)"], capture_output=True)
    return r.returncode == 0


def trim_island():
    files = []
    for d in ISLAND_DIRS:
        files += files_under(os.path.join(ISLAND, d))
    total = sum(s for _, s, _ in files)
    freed = 0
    for _, s, p in sorted(files):                     # oldest first
        if total - freed <= ISLAND_MAX:
            break
        try:
            os.remove(p)
            freed += s
        except OSError:
            pass
    return freed


def trim_build():
    if size(BUILD) <= BUILD_MAX or building():
        return 0
    freed = 0
    for name in sorted(os.listdir(BUILD)) if os.path.isdir(BUILD) else []:
        sub = os.path.join(BUILD, name)
        # only cargo output: a folder with CACHEDIR.TAG (cargo writes one) or the shared target dir; never a source checkout
        if os.path.isdir(sub) and os.path.isfile(os.path.join(sub, "CACHEDIR.TAG")):
            freed += size(sub)
            shutil.rmtree(sub, ignore_errors=True)
    return freed


def mb(n):
    return f"{n / 1048576:.0f} MB"


def main(argv):
    if "--status" in argv:
        isl = sum(size(os.path.join(ISLAND, d)) for d in ISLAND_DIRS)
        print(f"island caches {mb(isl)} (limit {mb(ISLAND_MAX)}), build cache {mb(size(BUILD))} (limit {mb(BUILD_MAX)}), "
              f"Aggressive Memory Freeing {'on' if aggressive() else 'off'}")
        return 0
    if "--force" not in argv and not aggressive():
        return 0
    freed = trim_island() + trim_build()
    if freed:
        print(f"cache-trim: freed {mb(freed)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
