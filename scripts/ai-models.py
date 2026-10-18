#!/usr/bin/env python3
"""Model picker backend for the Halcyon AI advisor (Settings > Performance > "AI advisor model").

  ai-models.py list [--refresh]   JSON: the model in use, what is installed, the online catalog (fits-this-PC flagged), the
                                  download in progress, this PC's memory
  ai-models.py status             JSON: just the download in progress (cheap)
  ai-models.py use <name>         make <name> the advisor / `ai` model (ai-advisor.conf, the same file `advisor model switch` writes)
  ai-models.py pull <name> [--use]  download it with Ollama, progress in ~/.cache/island/ai-pull.json ; --use = switch to it when done
  ai-models.py cancel             stop the download in progress
  ai-models.py rm <name>          delete an installed model

The online catalog is scraped from ollama.com/library (cached 12 h in ~/.cache/island/ai-catalog.json). Offline, or if the page
changes shape and nothing can be read, a short built-in list of good models is shown instead.
"""
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
RICE = os.environ.get("HALCYON_DIR", os.path.join(HOME, ".config", "Halcyon"))
CACHE = os.path.join(HOME, ".cache", "island")
CATALOG = os.path.join(CACHE, "ai-catalog.json")
PULLSTAT = os.path.join(CACHE, "ai-pull.json")
CONF = os.path.join(RICE, "ai-advisor.conf")
HOST = os.environ.get("OLLAMA_HOST", "127.0.0.1:11434")
if not HOST.startswith("http"):
    HOST = "http://" + HOST
CATALOG_TTL = 12 * 3600
LIB_URL = "https://ollama.com/library?sort=popular"

# a short list that always works, used when the page can't be read
BUILTIN = [
    ("llama3.2", "Meta's small, fast all-rounder", ["1b", "3b"], ["tools"], ""),
    ("llama3.1", "Meta's best general model that still runs on a laptop", ["8b"], ["tools"], ""),
    ("qwen3", "Qwen 3: strong reasoning and tool use for its size", ["4b", "8b", "14b"], ["tools", "thinking"], ""),
    ("qwen2.5", "Qwen 2.5: fast, accurate, multilingual", ["3b", "7b", "14b"], ["tools"], ""),
    ("gemma3", "Google's Gemma 3: compact and capable, reads images too", ["4b", "12b"], ["vision"], ""),
    ("phi4-mini", "Microsoft's small model that punches above its size", ["3.8b"], ["tools"], ""),
    ("deepseek-r1", "DeepSeek R1 distills: step-by-step reasoning", ["8b", "14b"], ["thinking"], ""),
    ("mistral", "Mistral 7B: the dependable classic", ["7b"], ["tools"], ""),
    ("qwen2.5-coder", "Qwen 2.5 Coder: for code questions", ["3b", "7b", "14b"], ["tools"], ""),
]


# ------------------------------------------------------------------------------------------------ helpers
def out(obj):
    sys.stdout.write(json.dumps(obj))
    sys.stdout.write("\n")


def http(path, data=None, timeout=4, method=None):
    req = urllib.request.Request(HOST + path, data=json.dumps(data).encode() if data is not None else None,
                                 headers={"Content-Type": "application/json"}, method=method)
    return urllib.request.urlopen(req, timeout=timeout)


def ollama_up():
    try:
        http("/api/version", timeout=1.5).read()
        return True
    except Exception:
        return False


def have_ollama():
    return any(os.access(os.path.join(p, "ollama"), os.X_OK) for p in os.environ.get("PATH", "").split(os.pathsep))


def installed():
    """[{name, gb}] from the running server, or `ollama list` when the server is down."""
    try:
        d = json.loads(http("/api/tags", timeout=3).read())
        return sorted([{"name": m["name"], "gb": round(m.get("size", 0) / 1e9, 1)} for m in d.get("models", [])],
                      key=lambda x: x["name"])
    except Exception:
        pass
    try:
        txt = subprocess.run(["ollama", "list"], capture_output=True, text=True, timeout=5).stdout
        res = []
        for ln in txt.splitlines()[1:]:
            p = ln.split()
            if p:
                gb = 0.0
                m = re.search(r"([\d.]+)\s*(GB|MB)", ln)
                if m:
                    gb = float(m.group(1)) / (1 if m.group(2) == "GB" else 1000)
                res.append({"name": p[0], "gb": round(gb, 1)})
        return res
    except Exception:
        return []


def current_model(have):
    if os.environ.get("HALCYON_AI_MODEL"):
        return os.environ["HALCYON_AI_MODEL"].strip()
    try:
        for ln in open(CONF).read().splitlines():
            if ln.startswith("MODEL="):
                m = ln.split("=", 1)[1].strip().strip('"').strip("'")
                if m:
                    return m
    except OSError:
        pass
    names = [h["name"] for h in have]
    for pref in ("llama3.1:8b", "llama3.2:3b", "qwen2.5:3b", "llama3.2:1b"):      # "qwen2.5:3b" also matches qwen2.5:3b-instruct
        for n in names:
            if n.startswith(pref):
                return n
    return names[0] if names else "qwen2.5:3b-instruct"


def hardware():
    ram = vram = 0.0
    try:
        for ln in open("/proc/meminfo"):
            if ln.startswith("MemTotal:"):
                ram = int(ln.split()[1]) / 1048576
                break
    except OSError:
        pass
    try:
        t = subprocess.run(["nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=3).stdout.split()
        if t:
            vram = max(float(x) for x in t) / 1024
    except Exception:
        pass
    if not vram:
        try:
            base = "/sys/class/drm"
            for d in os.listdir(base):
                f = os.path.join(base, d, "device", "mem_info_vram_total")
                if os.path.isfile(f):
                    vram = max(vram, int(open(f).read().strip()) / 1073741824)
        except Exception:
            pass
    return {"ram": round(ram, 1), "vram": round(vram, 1)}


def params_b(tag):
    """'8b' -> 8.0, '1.5b' -> 1.5, '270m' -> 0.27, 'e4b' -> 4.0, '30b-a3b' -> 30.0"""
    m = re.match(r"^[a-z]?(\d+(?:\.\d+)?)([bm])", tag.lower())
    if not m:
        return None
    v = float(m.group(1))
    return v if m.group(2) == "b" else v / 1000


def est_gb(tag):
    p = params_b(tag)
    return None if p is None else round(p * 0.62 + 0.4, 1)     # ~Q4 weights + a little room


def fits(gb, hw):
    if gb is None:
        return True
    budget = max(hw["vram"] * 0.92, hw["ram"] * 0.55)
    return gb <= budget


# ------------------------------------------------------------------------------------------------ the online catalog
def clean(s):
    s = re.sub(r"<[^>]+>", "", s)
    return re.sub(r"\s+", " ", s.replace("&amp;", "&").replace("&#39;", "'").replace("&quot;", '"')).strip()


def parse_library(html):
    """Read ollama.com/library. Tolerant: it looks for each /library/<name> link and the x-test-* markers near it, and
    falls back to plain patterns when a marker is missing."""
    parts = re.split(r'href="/library/([A-Za-z0-9._-]+)"', html)
    seen, res = set(), []
    # parts = [before, name1, chunk1, name2, chunk2, ...]
    for i in range(1, len(parts) - 1, 2):
        name, chunk = parts[i], parts[i + 1][:4000]
        if name in seen:
            continue
        seen.add(name)
        m = re.search(r'<p[^>]*class="[^"]*max-w-lg[^"]*"[^>]*>(.*?)</p>', chunk, re.S) or re.search(r"<p[^>]*>(.*?)</p>", chunk, re.S)
        desc = clean(m.group(1)) if m else ""
        sizes = [clean(x) for x in re.findall(r"x-test-size[^>]*>([^<]+)<", chunk)]
        caps = [clean(x).lower() for x in re.findall(r"x-test-capability[^>]*>([^<]+)<", chunk)]
        pm = re.search(r"x-test-pull-count[^>]*>([^<]+)<", chunk)
        pulls = clean(pm.group(1)) if pm else ""
        if not sizes:
            sizes = re.findall(r">\s*(\d+(?:\.\d+)?[bm])\s*<", chunk)
        res.append((name, desc, sizes, caps, pulls))
    return res


def fetch_catalog(force=False):
    """-> (entries, source) ; entries = [(name, desc, sizes, caps, pulls)]"""
    try:
        if not force and time.time() - os.path.getmtime(CATALOG) < CATALOG_TTL:
            d = json.load(open(CATALOG))
            if d.get("entries"):
                return [tuple(e) for e in d["entries"]], "cache"
    except (OSError, ValueError):
        pass
    try:
        req = urllib.request.Request(LIB_URL, headers={"User-Agent": "Mozilla/5.0 (Halcyon model picker)"})
        html = urllib.request.urlopen(req, timeout=8).read().decode("utf-8", "replace")
        entries = parse_library(html)
        if len(entries) >= 5:
            os.makedirs(CACHE, exist_ok=True)
            json.dump({"at": time.time(), "entries": entries}, open(CATALOG, "w"))
            return entries, "online"
    except Exception:
        pass
    try:                                                    # stale cache beats nothing
        d = json.load(open(CATALOG))
        if d.get("entries"):
            return [tuple(e) for e in d["entries"]], "cache"
    except (OSError, ValueError):
        pass
    return list(BUILTIN), "builtin"


def build_catalog(entries, have, hw):
    names = {h["name"] for h in have}
    base_names = {n.split(":")[0] for n in names}
    rows = []
    for rank, (name, desc, sizes, caps, pulls) in enumerate(entries):
        if "embedding" in caps or "cloud" in caps or "cloud" in sizes:
            continue
        variants = [s for s in sizes if params_b(s) is not None]
        variants.sort(key=lambda s: params_b(s))
        if not variants:                                    # no size tags: a plain `ollama pull name`
            variants = [""]
        for v in variants[:6]:
            tag = f"{name}:{v}" if v else name
            gb = est_gb(v) if v else None
            ok = fits(gb, hw)
            inst = tag in names or (not v and (name in names or name + ":latest" in names))
            rows.append({"name": tag, "desc": desc, "gb": gb, "caps": caps, "pulls": pulls, "fits": ok,
                         "installed": inst, "rank": rank})
    # a PC-sized pick first: what fits, in popularity order; the biggest model that fits each family is the "best" one
    best = {}
    for r in rows:
        fam = r["name"].split(":")[0]
        if r["fits"] and r["gb"] is not None and r["gb"] > best.get(fam, (0, None))[0]:
            best[fam] = (r["gb"], r["name"])
    for r in rows:
        r["best"] = best.get(r["name"].split(":")[0], (0, None))[1] == r["name"]
    rows.sort(key=lambda r: (not r["fits"], r["rank"], r["gb"] or 0))
    return rows[:60]


# ------------------------------------------------------------------------------------------------ pull status
def read_pull():
    try:
        d = json.load(open(PULLSTAT))
    except (OSError, ValueError):
        return None
    if not d.get("done") and d.get("pid"):                  # a dead process leaves "downloading" behind
        try:
            os.kill(d["pid"], 0)
        except OSError:
            d["done"], d["error"] = True, d.get("error") or "stopped"
    return d


def write_pull(d):
    os.makedirs(CACHE, exist_ok=True)
    tmp = PULLSTAT + ".tmp"
    json.dump(d, open(tmp, "w"))
    os.replace(tmp, PULLSTAT)


def set_model(name):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    with open(CONF, "w") as f:
        f.write(f'MODEL="{name}"\n')


# ------------------------------------------------------------------------------------------------ commands
def cmd_list(refresh):
    have = installed()
    hw = hardware()
    entries, src = fetch_catalog(force=refresh)
    out({
        "ollama": have_ollama(), "running": ollama_up(), "current": current_model(have),
        "envOverride": bool(os.environ.get("HALCYON_AI_MODEL")),
        "installed": have, "catalog": build_catalog(entries, have, hw), "source": src, "hw": hw,
        "pull": read_pull(),
    })


def cmd_pull(name, use):
    if not have_ollama():
        write_pull({"name": name, "done": True, "error": "Ollama is not installed (pacman -S ollama)", "pct": 0})
        return 1
    if not ollama_up():                                     # start the service if it is only stopped
        subprocess.run(["systemctl", "start", "ollama"], capture_output=True)
        for _ in range(20):
            if ollama_up():
                break
            time.sleep(0.5)
        else:
            try:
                subprocess.Popen(["ollama", "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            except OSError:
                pass
            for _ in range(20):
                if ollama_up():
                    break
                time.sleep(0.5)
    st = {"name": name, "pct": 0, "status": "starting", "done": False, "error": "", "pid": os.getpid(), "use": use}
    write_pull(st)
    sig = {"stop": False}
    signal.signal(signal.SIGTERM, lambda *_: sig.__setitem__("stop", True))
    layers = {}
    try:
        r = http("/api/pull", {"name": name, "stream": True}, timeout=60)
        last = 0.0
        for raw in r:
            if sig["stop"]:
                raise KeyboardInterrupt
            try:
                j = json.loads(raw)
            except ValueError:
                continue
            if j.get("error"):
                raise RuntimeError(j["error"])
            if j.get("digest") and j.get("total"):
                layers[j["digest"]] = (j.get("completed", 0), j["total"])
            tot = sum(t for _, t in layers.values())
            cur = sum(c for c, _ in layers.values())
            st["pct"] = round(100 * cur / tot) if tot else 0
            st["status"] = j.get("status", "")[:40]
            if j.get("status") == "success":
                st["pct"] = 100
            if time.time() - last > 0.4:
                write_pull(st)
                last = time.time()
        st["pct"], st["done"], st["status"] = 100, True, "ready"
        if use:
            set_model(name)
            st["used"] = True
    except KeyboardInterrupt:
        st["done"], st["error"] = True, "cancelled"
    except urllib.error.HTTPError as e:
        st["done"], st["error"] = True, f"Ollama said {e.code}: is the model name right?"
    except Exception as e:
        st["done"], st["error"] = True, str(e)[:120]
    write_pull(st)
    return 0 if not st["error"] else 1


def cmd_cancel():
    d = read_pull()
    if d and not d.get("done") and d.get("pid"):
        try:
            os.kill(d["pid"], signal.SIGTERM)
        except OSError:
            pass
        d["done"], d["error"] = True, "cancelled"
        write_pull(d)
    return 0


def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    c, rest = a[0], a[1:]
    if c == "list":
        cmd_list("--refresh" in rest)
    elif c == "status":                                     # cheap: only the download state (the UI polls this once a second)
        out(read_pull() or {})
    elif c == "use" and rest:
        set_model(rest[0])
    elif c == "pull" and rest:
        return cmd_pull(rest[0], "--use" in rest)
    elif c == "cancel":
        return cmd_cancel()
    elif c in ("rm", "delete") and rest:
        try:
            http("/api/delete", {"name": rest[0]}, timeout=10, method="DELETE")
        except Exception:
            return subprocess.call(["ollama", "rm", rest[0]])
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
