import pwd
#!/usr/bin/env python3
"""adaptive-advisor.py : Intelligent System & Resource Performance Advisor for Halcyon
Analyzes hardware status, CPU/GPU temperatures, VRAM, memory pressure, background daemons,
and user workflow patterns.

Modes:
  adaptive-advisor.py                     -> Full interactive diagnostic dashboard & efficiency score
  adaptive-advisor.py --fix               -> Automatically applies recommended quick-fixes (trims memory, etc.)
  adaptive-advisor.py --llm               -> Synthesizes situational advice using local Ollama LLM
  adaptive-advisor.py "your question..."  -> Answers natural language questions with live hardware context
  adaptive-advisor.py model               -> Show current model and installed models
  adaptive-advisor.py model 3b            -> Switch to llama3.2:3b (pulls it if missing)
  adaptive-advisor.py model <name>        -> Switch to any Ollama model (e.g. qwen2.5:3b)
  adaptive-advisor.py triage "text"       -> Tag a notification (urgent/chat/system/promo) + one-line summary
  adaptive-advisor.py write "request"     -> Short friendly text (birthday message, reply, description)

Natural language like "I'm presenting" or "make my screen warmer" runs the matching action:
keywords first, then the model picks from a fixed list (it can never run anything outside ACTIONS).
"""

import os
import sys
import json
import glob
import re
import subprocess
import shutil
import urllib.request
import urllib.error

HOME = os.path.expanduser("~")
RICE = os.environ.get("HALCYON_DIR", os.path.join(HOME, ".config/Halcyon"))
USAGE_LOG = os.path.join(HOME, ".local/state/island/usage.log")

def read_file(path):
    try:
        with open(path, "r", errors="ignore") as f:
            return f.read().strip()
    except Exception:
        return ""

def get_battery_info():
    bats = glob.glob("/sys/class/power_supply/BAT*")
    if not bats:
        return None
    bat = bats[0]
    status = read_file(os.path.join(bat, "status")) or "Unknown"
    capacity = read_file(os.path.join(bat, "capacity")) or "100"
    try:
        cap_val = int(capacity)
    except ValueError:
        cap_val = 100
    return {"present": True, "status": status, "capacity": cap_val}

def get_temperatures():
    temps = []
    for p in glob.glob('/sys/class/hwmon/hwmon*/temp*_input'):
        try:
            with open(p) as f:
                val = int(f.read().strip()) / 1000.0
                if 10 < val < 115:
                    temps.append(val)
        except Exception:
            pass
    if not temps:
        return {"avg": 45.0, "max": 45.0}
    return {"avg": round(sum(temps) / len(temps), 1), "max": round(max(temps), 1)}

def is_nvidia_dgpu_suspended():
    for dev in glob.glob("/sys/bus/pci/devices/*"):
        try:
            with open(os.path.join(dev, "vendor")) as vf:
                if vf.read().strip() != "0x10de":
                    continue
            with open(os.path.join(dev, "class")) as cf:
                if not cf.read().strip().startswith("0x03"):
                    continue
            with open(os.path.join(dev, "power/runtime_status")) as rf:
                if rf.read().strip() == "suspended":
                    return True
        except Exception:
            continue
    return False

def get_gpu_info():
    if is_nvidia_dgpu_suspended():
        return {"present": True, "name": "NVIDIA dGPU (D3cold suspended)", "temp_c": 0, "vram_used_mb": 0, "vram_total_mb": 0, "util_pct": 0}
    try:
        res = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,temperature.gpu,memory.used,memory.total,utilization.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=2
        )
        if res.returncode == 0 and res.stdout.strip():
            parts = [p.strip() for p in res.stdout.strip().split(",")]
            if len(parts) >= 5:
                return {
                    "present": True,
                    "name": parts[0],
                    "temp_c": int(parts[1]),
                    "vram_used_mb": int(parts[2]),
                    "vram_total_mb": int(parts[3]),
                    "util_pct": int(parts[4])
                }
    except Exception:
        pass
    return {"present": False, "name": "Integrated", "temp_c": 0, "vram_used_mb": 0, "vram_total_mb": 0, "util_pct": 0}

def get_memory_info():
    meminfo = {}
    for line in read_file("/proc/meminfo").splitlines():
        parts = line.split(":")
        if len(parts) == 2:
            key = parts[0].strip()
            val = parts[1].strip().split()[0]
            try:
                meminfo[key] = int(val)
            except ValueError:
                pass
    total_mb = round(meminfo.get("MemTotal", 0) / 1024)
    avail_mb = round(meminfo.get("MemAvailable", 0) / 1024)
    used_mb = total_mb - avail_mb
    pct_used = round((used_mb / total_mb * 100), 1) if total_mb > 0 else 0
    return {"total_mb": total_mb, "used_mb": used_mb, "avail_mb": avail_mb, "pct": pct_used}

def get_process_stats():
    procs = []
    try:
        ps = subprocess.run(["ps", "-u", os.environ.get("USER") or pwd.getpwuid(os.getuid()).pw_name, "-o", "pid,rss,%cpu,comm,args"],
                            capture_output=True, text=True, timeout=3)
        for line in ps.stdout.splitlines()[1:]:
            parts = line.split(None, 4)
            if len(parts) >= 5:
                procs.append({
                    "pid": parts[0],
                    "rss_mb": round(int(parts[1]) / 1024, 1),
                    "cpu_pct": float(parts[2]),
                    "comm": parts[3],
                    "args": parts[4]
                })
    except Exception:
        pass
    return procs

def get_usage_patterns():
    if not os.path.isfile(USAGE_LOG):
        return {}
    counts = {}
    lines = read_file(USAGE_LOG).splitlines()
    for app in lines[-200:]:
        app = app.strip()
        if app:
            counts[app] = counts.get(app, 0) + 1
    return counts

def calculate_score(mem, temps, qs_mb, battery):
    score = 100
    if mem["pct"] > 85:
        score -= 20
    elif mem["pct"] > 70:
        score -= 10

    if temps["max"] > 90:
        score -= 25
    elif temps["max"] > 80:
        score -= 12

    if qs_mb > 450:
        score -= 15
    elif qs_mb > 300:
        score -= 8

    if battery and battery["status"] == "Discharging" and battery["capacity"] < 25:
        score -= 10

    score = max(10, min(100, score))
    rating = "EXCELLENT" if score >= 90 else "GOOD" if score >= 75 else "FAIR" if score >= 55 else "ATTENTION NEEDED"
    return score, rating

def analyze_system():
    battery = get_battery_info()
    mem = get_memory_info()
    procs = get_process_stats()
    usage = get_usage_patterns()
    temps = get_temperatures()
    gpu = get_gpu_info()

    qs_proc = next((p for p in procs if "quickshell" in p["comm"]), None)
    hy_proc = next((p for p in procs if "Hyprland" in p["comm"]), None)
    gaming_active = any(p for p in procs if any(g in p["comm"].lower() for g in ["steam", "wine", "gamescope", "lutris", "heroic"]))

    suggestions = []
    qs_mb = qs_proc["rss_mb"] if qs_proc else 0
    hy_mb = hy_proc["rss_mb"] if hy_proc else 0

    if qs_mb > 350:
        suggestions.append({
            "id": "trim_quickshell",
            "priority": "HIGH",
            "title": f"Quickshell memory is elevated ({qs_mb:.1f} MB)",
            "action": "Run 'advisor fix' or toggle 'Aggressive Memory Freeing' (opt:lazyLoad) in Settings.",
            "why": "Frees closed dialog heaps and texture caches back to the operating system."
        })

    if gaming_active:
        suggestions.append({
            "id": "gaming_mode",
            "priority": "HIGH",
            "title": "Active Gaming Process Detected",
            "action": "Engage Gaming Mode (SUPER + F10 or Settings > Gaming).",
            "why": "Uncaps refresh rate, enables tearing mode, and suspends background animations."
        })

    if battery and battery["status"] == "Discharging":
        if battery["capacity"] < 30:
            suggestions.append({
                "id": "battery_saver",
                "priority": "HIGH",
                "title": f"Battery Low ({battery['capacity']}%)",
                "action": "Turn on Power Saving profile and reduce screen brightness.",
                "why": "Extends remaining battery runtime significantly."
            })

    if temps["max"] > 82:
        suggestions.append({
            "id": "thermal_warm",
            "priority": "MEDIUM",
            "title": f"Elevated CPU Temperature ({temps['max']}°C)",
            "action": "Switch to Balanced thermal profile or clear heavy background workers.",
            "why": "Maintains sustained clock boost without thermal throttling."
        })

    # Top apps suggestion
    if usage:
        top_apps = sorted(usage.items(), key=lambda x: x[1], reverse=True)[:3]
        app_summary = ", ".join([f"{k} ({v}x)" for k, v in top_apps])
        suggestions.append({
            "id": "app_habits",
            "priority": "INFO",
            "title": f"Frequently used applications: {app_summary}",
            "action": "Map dedicated keybinds (Settings > Shortcuts) or autostart rules.",
            "why": "Optimizes workspace flow and reduces launcher churn."
        })

    score, rating = calculate_score(mem, temps, qs_mb, battery)

    return {
        "battery": battery,
        "memory": mem,
        "temps": temps,
        "gpu": gpu,
        "quickshell_mb": qs_mb,
        "hyprland_mb": hy_mb,
        "score": score,
        "rating": rating,
        "suggestions": suggestions,
        "procs": procs
    }

def apply_fixes():
    print("━" * 60)
    print("🔧 Applying Automatic System Optimizations...")
    print("━" * 60)
    
    # 1. Trim quickshell
    print("[*] Releasing Quickshell caches & texture heaps...")
    try:
        subprocess.run(
            ["quickshell", "ipc", "-p", os.path.join(RICE, "quickshell", "island"), "call", "island", "trim"],
            capture_output=True, timeout=4
        )
        print("  ✔ Quickshell memory trimmed.")
    except Exception as e:
        print(f"  ⚠ Quickshell trim call: {e}")

    # 2. Sync and drop caches if memory is tight
    mem = get_memory_info()
    if mem["pct"] > 75:
        print("[*] Releasing file system pagecache buffers...")
        try:
            subprocess.run(["sync"], timeout=3)
            print("  ✔ Pagecache synchronized.")
        except Exception:
            pass

    print("\n✔ Optimization complete! Run 'advisor' to view updated score.")

MODEL_ALIASES = {
    "1b": "llama3.2:1b",
    "3b": "llama3.2:3b",
    "llama1b": "llama3.2:1b",
    "llama3b": "llama3.2:3b",
    "qwen1.5b": "qwen2.5:1.5b",
    "qwen3b": "qwen2.5:3b",
    "qwen4b": "qwen3:4b",
}

def installed_models():
    try:
        out = subprocess.run(["ollama", "list"], capture_output=True, text=True, timeout=5).stdout
        return [l.split()[0] for l in out.splitlines()[1:] if l.strip()]
    except Exception:
        return []

def free_ram_mb():
    try:
        for line in read_file("/proc/meminfo").splitlines():
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) // 1024
    except Exception:
        pass
    return 0

def model_command(args):
    """advisor model [name|alias]"""
    current = get_advisor_model()
    have = installed_models()
    if not args:
        print(f"Current model : {current}")
        print("Installed     : " + (", ".join(have) if have else "(none found - is ollama running?)"))
        print("Aliases       : " + ", ".join(f"{k}={v}" for k, v in MODEL_ALIASES.items()))
        print("\nSwitch with: advisor model 3b")
        return
    name = MODEL_ALIASES.get(args[0].lower(), args[0])
    if not any(m == name or m.startswith(name + ":") or m.split(":")[0] == name for m in have):
        free = free_ram_mb()
        print(f"[*] '{name}' is not installed. Pulling it now (this can take a few minutes)...")
        if free and free < 3000 and "3b" in name:
            print(f"[!] Only ~{free} MB RAM free. A 3B model wants roughly 3 GB headroom; it may be slow.")
        r = subprocess.run(["ollama", "pull", name])
        if r.returncode != 0:
            print(f"[!] Pull failed. Keeping '{current}'.")
            return
    os.makedirs(RICE, exist_ok=True)
    conf = os.path.join(RICE, "ai-advisor.conf")
    with open(conf, "w") as f:
        f.write(f'MODEL="{name}"\n')
    print(f"✔ Advisor model set to {name}  (saved in {conf})")
    if os.environ.get("HALCYON_AI_MODEL"):
        print("[!] HALCYON_AI_MODEL is set in your shell and overrides this. Unset it to use the saved choice.")

def get_advisor_model():
    if os.environ.get("HALCYON_AI_MODEL"):
        return os.environ.get("HALCYON_AI_MODEL").strip()
    conf_path = os.path.join(RICE, "ai-advisor.conf")
    if os.path.isfile(conf_path):
        for line in read_file(conf_path).splitlines():
            if line.startswith("MODEL="):
                m = line.split("=", 1)[1].strip().strip('"').strip("'")
                if m:
                    return m
    try:
        models_out = subprocess.run(["ollama", "list"], capture_output=True, text=True, timeout=3).stdout
        models = [line.split()[0] for line in models_out.splitlines()[1:] if line.strip()]
        for pref in ["llama3.2:1b", "qwen2.5:1.5b", "qwen2.5:0.5b", "llama3.2:3b", "qwen3:4b"]:
            match = next((m for m in models if m.startswith(pref)), None)
            if match:
                return match
        if models:
            return models[0]
    except Exception:
        pass
    return "llama3.2:1b"

# ───────────────────────── Actions the advisor can run ─────────────────────────

def _qs(*call):
    subprocess.run(["quickshell", "ipc", "-p", os.path.join(RICE, "quickshell/island"), "call", *call])

def _script(name, *a):
    subprocess.run(["bash", os.path.join(RICE, "scripts", name), *a])

# name -> (message, runner, description shown to the model, keywords, needs_confirm_when_inferred)
ACTIONS = {
    "mirror":        ("📽️ Executing Projector Mirror Mode...", lambda: _script("display-manager.sh", "mirror"),
                      "mirror the laptop screen to a projector / TV / external display (presenting)",
                      ["projector", "mirror", "clone screen", "presentation"], False),
    "extend-right":  ("🖥️ Extending display to the right...", lambda: _script("display-manager.sh", "extend-right"),
                      "use an external monitor as a second screen to the right",
                      ["extend right", "dual screen", "second monitor", "extend display"], False),
    "extend-left":   ("🖥️ Extending display to the left...", lambda: _script("display-manager.sh", "extend-left"),
                      "use an external monitor as a second screen to the left",
                      ["extend left"], False),
    "internal-only": ("💻 Switching to internal laptop screen only...", lambda: _script("display-manager.sh", "internal-only"),
                      "turn off external displays and use only the laptop screen",
                      ["laptop screen only", "single screen", "disconnect display"], True),
    "gaming":        ("🎮 Toggling Gaming Mode via Quickshell...", lambda: _qs("island", "gaming"),
                      "toggle gaming mode (max performance, no background animations)",
                      ["game mode", "gaming mode", "gaming on", "gaming off"], False),
    "trim-memory":   ("🧹 Trimming Quickshell RAM and cleaning system caches...", lambda: apply_fixes(),
                      "free up RAM: trim Quickshell memory and flush caches",
                      ["trim memory", "clean ram", "free memory", "free ram", "flush cache"], True),
    "caffeine":      ("☕ Toggling Caffeine mode...", lambda: _qs("island", "caffeine"),
                      "keep the screen awake and stop it from sleeping or locking",
                      ["caffeine", "stay awake", "keep awake"], False),
    "dnd":           ("🔕 Toggling Do Not Disturb...", lambda: _qs("island", "dnd"),
                      "silence notifications / do not disturb / focus time",
                      ["do not disturb", "dnd", "mute notifications", "silence"], False),
    "wallpaper":     ("🖼️ Cycling wallpaper...", lambda: _qs("wallpaper", "next"),
                      "switch to the next wallpaper",
                      ["next wallpaper", "change wallpaper", "random wallpaper"], False),
    "nightlight":    ("🌙 Toggling night light...", lambda: _script("toggle_nightlight.sh"),
                      "warmer screen colour / reduce blue light for the evening",
                      ["night light", "nightlight", "blue light", "warm screen"], False),
}

_QUESTION_START = ("why", "what", "how", "which", "who", "when", "where", "is ", "are ", "does ", "do ", "should ", "explain", "tell me")

def looks_like_question(p):
    p = p.lower().strip()
    return p.endswith("?") or p.startswith(_QUESTION_START)

def run_action(name):
    msg, runner = ACTIONS[name][0], ACTIONS[name][1]
    print(msg)
    runner()

def try_dispatch_keywords(prompt):
    p = prompt.lower().strip()
    for name, spec in ACTIONS.items():
        if any(k in p for k in spec[3]):
            run_action(name)
            return True
    return False

# ───────────────────────── Ollama helpers ─────────────────────────

OLLAMA_URL = "http://127.0.0.1:11434/api/generate"
LAST_LLM_ERROR = ""

def ollama_generate(prompt, schema=None, num_predict=260, temperature=0.2, stream=False, timeout=90):
    """Call Ollama. Returns text or None. With `schema`, output is forced to valid JSON."""
    global LAST_LLM_ERROR
    LAST_LLM_ERROR = ""
    model = get_advisor_model()
    if "qwen3" in model:
        stream = False  # <think> blocks are stripped after the fact
    payload = {
        "model": model, "prompt": prompt, "stream": bool(stream),
        "keep_alive": "30m",
        "options": {"num_predict": num_predict, "temperature": temperature, "num_ctx": 2048},
    }
    if schema:
        payload["format"] = schema
        payload["stream"] = False
    req = urllib.request.Request(OLLAMA_URL, data=json.dumps(payload).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if payload["stream"]:
                out = []
                for raw in r:
                    try:
                        chunk = json.loads(raw.decode("utf-8"))
                    except Exception:
                        continue
                    piece = chunk.get("response", "")
                    if piece:
                        out.append(piece)
                        print(piece, end="", flush=True)
                    if chunk.get("done"):
                        break
                print()
                return "".join(out).strip() or None
            data = json.loads(r.read().decode("utf-8"))
            text = re.sub(r"<think>.*?</think>", "", data.get("response", ""), flags=re.DOTALL).strip()
            return text or None
    except urllib.error.HTTPError as e:
        if e.code == 404:
            LAST_LLM_ERROR = f"Model '{model}' is not installed. Run: advisor model {model}"
        else:
            LAST_LLM_ERROR = f"Ollama returned HTTP {e.code}."
    except urllib.error.URLError:
        LAST_LLM_ERROR = "Can't reach Ollama on 127.0.0.1:11434. Start it with: systemctl --user start ollama  (or: ollama serve)"
    except Exception as e:
        LAST_LLM_ERROR = f"Model call failed or timed out ({e})."

    if not schema:  # last resort: CLI
        try:
            res = subprocess.run(["ollama", "run", model, prompt], capture_output=True, text=True, timeout=timeout)
            out = re.sub(r"<think>.*?</think>", "", res.stdout or "", flags=re.DOTALL).strip()
            if out:
                LAST_LLM_ERROR = ""
                print(out)
                return out
        except Exception:
            pass
    return None

def llm_json(prompt, schema, num_predict=80):
    text = ollama_generate(prompt, schema=schema, num_predict=num_predict, temperature=0.0)
    if not text:
        return None
    try:
        return json.loads(text)
    except Exception:
        m = re.search(r"\{.*\}", text, flags=re.DOTALL)
        try:
            return json.loads(m.group(0)) if m else None
        except Exception:
            return None

# ───────────────────────── 1. Intent routing (model picks from a fixed list) ─────────────────────────

def llm_pick_action(prompt):
    names = list(ACTIONS.keys())
    schema = {"type": "object", "properties": {"action": {"type": "string", "enum": names + ["none"]}}, "required": ["action"]}
    menu = "\n".join(f"- {n}: {ACTIONS[n][2]}" for n in names)
    instr = (
        "You route a user's request on a Linux desktop to exactly one action, or 'none'.\n"
        f"Actions:\n{menu}\n- none: anything else, including questions, advice requests, or unclear requests\n\n"
        "Examples:\n"
        'Request: "I\'m presenting to my class" -> {"action": "mirror"}\n'
        'Request: "make my screen easier on my eyes" -> {"action": "nightlight"}\n'
        'Request: "I need to focus, no pings" -> {"action": "dnd"}\n'
        'Request: "my laptop feels slow, why?" -> {"action": "none"}\n'
        'Request: "what is a good wallpaper size" -> {"action": "none"}\n\n'
        f'Request: "{prompt}" ->'
    )
    res = llm_json(instr, schema)
    act = (res or {}).get("action", "none")
    return act if act in ACTIONS else None

def try_dispatch_intent(prompt):
    if try_dispatch_keywords(prompt):
        return True
    if looks_like_question(prompt):
        return False
    act = llm_pick_action(prompt)
    if not act:
        return False
    print(f"🧭 Understood as: {ACTIONS[act][2]}")
    if ACTIONS[act][4] and sys.stdin.isatty():
        try:
            if input("   Run it? [y/N] ").strip().lower() not in ("y", "yes"):
                print("   Skipped.")
                return True
        except EOFError:
            return True
    run_action(act)
    return True

# ───────────────────────── 2. Grounded advice (Python finds, model explains) ─────────────────────────

def build_findings(analysis):
    m, g = analysis["memory"], analysis["gpu"]
    lines = [
        f"RAM: {m['used_mb']} of {m['total_mb']} MB used ({m['pct']}%)",
        f"Quickshell uses {analysis['quickshell_mb']} MB, Hyprland {analysis['hyprland_mb']} MB",
        f"CPU temp: avg {analysis['temps']['avg']}C, max {analysis['temps']['max']}C",
    ]
    if g.get("present"):
        lines.append(f"GPU: {g['name']}, VRAM {g['vram_used_mb']}/{g['vram_total_mb']} MB, {g['temp_c']}C")
    if analysis["battery"]:
        lines.append(f"Battery: {analysis['battery']['capacity']}% ({analysis['battery']['status']})")
    lines.append(f"Health score: {analysis['score']}/100 ({analysis['rating']})")
    top = sorted(analysis.get("procs") or [], key=lambda p: p["rss_mb"], reverse=True)[:5]
    if top:
        lines.append("Top processes by memory: " + "; ".join(f"{p['comm']} {p['rss_mb']} MB ({p['cpu_pct']}% CPU)" for p in top))
    flagged = [s for s in analysis["suggestions"] if s["priority"] != "INFO"]
    if flagged:
        lines.append("Problems detected by the checker: " + "; ".join(f"[{s['priority']}] {s['title']} -> {s['action']}" for s in flagged))
    else:
        lines.append("Problems detected by the checker: none")
    return "\n".join(lines)

ADVISOR_RULES = (
    "You are the assistant built into Halcyon, a Hyprland + Quickshell desktop on Linux.\n"
    "Rules: use ONLY the data given. Never invent numbers, process names or settings. "
    "If the data cannot answer the question, say what is missing in one line. "
    "Only suggest these commands: 'advisor fix' (trim memory/caches), 'advisor model <name>', "
    "SUPER+P (display switcher), SUPER+I (Settings). Be plain, specific and short: at most 5 lines. No preamble.\n"
)

def run_llm_query(analysis, custom_prompt=""):
    if custom_prompt and try_dispatch_intent(custom_prompt):
        return

    print("━" * 64)
    print("🤖 Local AI Advisor (Ollama)")
    print("━" * 64)
    print(f"[*] Model: {get_advisor_model()}\n")

    findings = build_findings(analysis)
    if custom_prompt:
        prompt = f"{ADVISOR_RULES}\nMachine data:\n{findings}\n\nUser question: {custom_prompt}\nAnswer:"
    else:
        prompt = (f"{ADVISOR_RULES}\nMachine data:\n{findings}\n\n"
                  "Task: in 2-3 plain sentences say how the machine is doing, then give the ONE most useful next step "
                  "taken from the checker's problems (or say nothing needs doing).\nAnswer:")
    if ollama_generate(prompt, stream=True) is None and LAST_LLM_ERROR:
        print(f"[!] {LAST_LLM_ERROR}\n    Rule-based advice below still applies.")

# ───────────────────────── 3. Notification triage & short writing ─────────────────────────

def triage_notification(text):
    if not text.strip():
        print('Usage: advisor triage "notification text"')
        return
    schema = {"type": "object",
              "properties": {"category": {"type": "string", "enum": ["urgent", "chat", "system", "promo", "other"]},
                             "one_line": {"type": "string"}},
              "required": ["category", "one_line"]}
    prompt = (
        "Classify this desktop notification and summarise it in at most 12 words.\n"
        "urgent = needs action soon (security alert, call, deadline, low battery, payment failed); chat = a person messaging; "
        "system = OS/app status; promo = marketing or offers; other = none of these.\n\n"
        'Examples:\n"Your verification code is 482913" -> {"category":"urgent","one_line":"Verification code arrived"}\n'
        '"50% off everything this weekend!" -> {"category":"promo","one_line":"Weekend 50% off sale"}\n\n'
        f'Notification: "{text}" ->'
    )
    res = llm_json(prompt, schema, num_predict=70)
    if not res:
        print(f"[!] {LAST_LLM_ERROR or 'No usable answer from the model.'}")
        return
    icon = {"urgent": "🚨", "chat": "💬", "system": "⚙️", "promo": "🏷️"}.get(res.get("category"), "•")
    print(f"{icon} [{res.get('category')}] {res.get('one_line')}")

def write_short(request):
    if not request.strip():
        print('Usage: advisor write "short request, e.g. birthday message for my sister, warm and funny"')
        return
    prompt = ("Write exactly what is asked, short (under 60 words), natural and friendly. "
              "Output only the text itself, no preamble, no quotes.\n\n"
              f"Request: {request}\nText:")
    if ollama_generate(prompt, num_predict=140, temperature=0.7, stream=True) is None:
        print(f"[!] {LAST_LLM_ERROR}")


def main():
    args = sys.argv[1:]

    if args and args[0] == "model":
        model_command(args[1:])
        return
    if args and args[0] == "triage":
        triage_notification(" ".join(args[1:]))
        return
    if args and args[0] == "write":
        write_short(" ".join(args[1:]))
        return

    if "--model" in args:
        i = args.index("--model")
        if i + 1 < len(args):
            val = args[i + 1]
            os.environ["HALCYON_AI_MODEL"] = MODEL_ALIASES.get(val.lower(), val)
            del args[i:i + 2]

    if "--fix" in args or "-f" in args or (args and args[0] == "fix"):
        apply_fixes()
        return

    custom_question = ""
    use_llm = "--llm" in args

    for a in args:
        if a not in ("--llm", "--fix", "-f") and not a.startswith("-"):
            custom_question = a
            use_llm = True
            break

    analysis = analyze_system()

    if use_llm:
        run_llm_query(analysis, custom_question)
        print()

    # Dashboard display
    score_color = "\033[1;32m" if analysis["score"] >= 90 else "\033[1;33m" if analysis["score"] >= 70 else "\033[1;31m"
    reset_color = "\033[0m"

    print("╔════════════════════════════════════════════════════════════════════╗")
    print(f"║     Halcyon System Health Score:  {score_color}{analysis['score']:3d} / 100 [{analysis['rating']}]{reset_color}     ║")
    print("╚════════════════════════════════════════════════════════════════════╝")
    print(f"• RAM: {analysis['memory']['used_mb']} MB / {analysis['memory']['total_mb']} MB ({analysis['memory']['pct']}%)  |  CPU Temp: {analysis['temps']['avg']}°C (peak {analysis['temps']['max']}°C)")
    print(f"• Quickshell: {analysis['quickshell_mb']} MB  |  Hyprland: {analysis['hyprland_mb']} MB")
    if analysis['gpu']['present']:
        print(f"• GPU: {analysis['gpu']['name']}  |  VRAM: {analysis['gpu']['vram_used_mb']} MB / {analysis['gpu']['vram_total_mb']} MB ({analysis['gpu']['temp_c']}°C)")
    if analysis['battery']:
        print(f"• Battery: {analysis['battery']['capacity']}% ({analysis['battery']['status']})")
    print("─" * 68)

    if analysis["suggestions"]:
        print("💡 Tailored Recommendations:")
        for idx, s in enumerate(analysis["suggestions"], 1):
            prio_color = {
                "HIGH": "\033[1;31m[HIGH]\033[0m",
                "MEDIUM": "\033[1;33m[MED]\033[0m",
                "LOW": "\033[1;36m[LOW]\033[0m",
                "INFO": "\033[1;34m[INFO]\033[0m"
            }.get(s["priority"], f"[{s['priority']}]")

            print(f"{idx}. {prio_color} {s['title']}")
            print(f"   ➜ Action: {s['action']}")
            print(f"   ℹ Detail: {s['why']}\n")
    else:
        print("✔ System is in peak operating condition. No bottlenecks detected.")

    print("─" * 68)
    print("Commands:")
    print("  advisor fix             -> Automatically trim memory & caches")
    print("  advisor \"<question>\"    -> Ask local AI advisor about your system")
    print("  advisor model 3b        -> Switch AI model (run 'advisor model' to see options)")
    print("  advisor triage \"text\"   -> Classify & summarise a notification")
    print("  advisor write \"request\"  -> Draft a short message")
    print("  advisor \"I'm presenting\" -> Natural language: the AI runs the right action")
    print("  SUPER + P               -> Multi-Monitor & Projector Display Switcher")
    print("  SUPER + I               -> Open Settings (Performance & Suggestions)")

if __name__ == "__main__":
    main()
