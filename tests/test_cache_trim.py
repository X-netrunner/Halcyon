"""scripts/cache-trim.py: python3 tests/test_cache_trim.py   (a temporary HOME; nothing real is touched)"""
import importlib.util
import json
import os
import sys
import tempfile
import time

here = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="halcyon-trim-test-")
os.environ.update({"HOME": tmp, "HALCYON_STATE": os.path.join(tmp, "s")})
spec = importlib.util.spec_from_file_location("ct", os.path.join(here, "..", "scripts", "cache-trim.py"))
ct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ct)
bad = n = 0


def check(label, got, want):
    global bad, n
    n += 1
    if got != want:
        bad += 1
        print(f"FAIL {label}: {got!r} (want {want!r})")


def put(path, mb, age=0):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(b"x" * (mb * 1048576))
    t = time.time() - age
    os.utime(path, (t, t))


ct.ISLAND_MAX = 3 * 1048576
ct.BUILD_MAX = 5 * 1048576
ct.building = lambda: False
put(f"{tmp}/.cache/island/live-proxy/old.mp4", 2, age=900)
put(f"{tmp}/.cache/island/live-proxy/new.mp4", 2, age=10)
put(f"{tmp}/.cache/island/wpcolors/c.json", 1, age=500)
put(f"{tmp}/.cache/island/ai-catalog.json", 4)          # not in a trimmed folder
put(f"{tmp}/.cache/spotify/blob", 9)                      # another program's cache
put(f"{tmp}/.cache/halcyon-build/shared/CACHEDIR.TAG", 0)
put(f"{tmp}/.cache/halcyon-build/shared/big", 4)
put(f"{tmp}/.cache/halcyon-build/ai-firewall/CACHEDIR.TAG", 0)
put(f"{tmp}/.cache/halcyon-build/ai-firewall/big", 4)
put(f"{tmp}/.cache/halcyon-build/src-checkout/main.rs", 1)    # no CACHEDIR.TAG: not build output

ct.main([])
check("oldest island file goes first", os.path.exists(f"{tmp}/.cache/island/live-proxy/old.mp4"), False)
check("newer island files stay", os.path.exists(f"{tmp}/.cache/island/live-proxy/new.mp4"), True)
check("files outside the trimmed folders stay", os.path.exists(f"{tmp}/.cache/island/ai-catalog.json"), True)
check("another program's cache is never touched", os.path.exists(f"{tmp}/.cache/spotify/blob"), True)
check("cargo output over the limit goes", [os.path.exists(f"{tmp}/.cache/halcyon-build/{d}") for d in ("shared", "ai-firewall")], [False, False])
check("a folder that is not build output stays", os.path.exists(f"{tmp}/.cache/halcyon-build/src-checkout/main.rs"), True)

put(f"{tmp}/.cache/halcyon-build/shared/CACHEDIR.TAG", 0)
put(f"{tmp}/.cache/halcyon-build/shared/big", 6)
ct.building = lambda: True
ct.main([])
check("nothing is deleted while a build runs", os.path.exists(f"{tmp}/.cache/halcyon-build/shared/big"), True)
ct.building = lambda: False
os.makedirs(ct.STATE, exist_ok=True)
json.dump({"opt": {"lazyLoad": False}}, open(os.path.join(ct.STATE, "settings.json"), "w"))
ct.main([])
check("setting off -> nothing is deleted", os.path.exists(f"{tmp}/.cache/halcyon-build/shared/big"), True)
ct.main(["--force"])
check("--force ignores the setting", os.path.exists(f"{tmp}/.cache/halcyon-build/shared/big"), False)
print(f"{n - bad}/{n} checks passed")
sys.exit(1 if bad else 0)
