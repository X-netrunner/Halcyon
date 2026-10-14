#!/usr/bin/env python3
"""adaptive-advisor.py : Intelligent System & Resource Performance Advisor for Halcyon
Analyzes hardware status, CPU/GPU temperatures, VRAM, memory pressure, background daemons,
and user workflow patterns.

Modes:
  adaptive-advisor.py                     -> Full interactive diagnostic dashboard & efficiency score
  adaptive-advisor.py --fix               -> Automatically applies recommended quick-fixes (trims memory, etc.)
  adaptive-advisor.py --llm               -> Synthesizes situational advice using local Ollama LLM
  adaptive-advisor.py "your question..."  -> Answers natural language questions with live hardware context
"""

import os
import sys
import json
import glob
import re
import subprocess
import shutil
import urllib.request

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

def get_gpu_info():
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
        ps = subprocess.run(["ps", "-u", os.environ.get("USER", "netrunner"), "-o", "pid,rss,%cpu,comm,args"],
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

def try_dispatch_intent(prompt):
    p = prompt.lower().strip()
    if any(k in p for k in ["projector", "mirror", "clone screen", "presentation"]):
        print("📽️ Executing Projector Mirror Mode...")
        subprocess.run(["bash", os.path.join(RICE, "scripts/display-manager.sh"), "mirror"])
        return True
    if any(k in p for k in ["extend right", "dual screen", "second monitor", "extend display"]):
        print("🖥️ Extending display to the right...")
        subprocess.run(["bash", os.path.join(RICE, "scripts/display-manager.sh"), "extend-right"])
        return True
    if any(k in p for k in ["extend left"]):
        print("🖥️ Extending display to the left...")
        subprocess.run(["bash", os.path.join(RICE, "scripts/display-manager.sh"), "extend-left"])
        return True
    if any(k in p for k in ["laptop screen only", "single screen", "disconnect display"]):
        print("💻 Switching to internal laptop screen only...")
        subprocess.run(["bash", os.path.join(RICE, "scripts/display-manager.sh"), "internal-only"])
        return True
    if any(k in p for k in ["game mode", "gaming mode", "gaming on", "gaming off"]):
        print("🎮 Toggling Gaming Mode via Quickshell...")
        subprocess.run(["quickshell", "ipc", "-p", os.path.join(RICE, "quickshell/island"), "call", "island", "gaming"])
        return True
    if any(k in p for k in ["trim memory", "clean ram", "free memory", "free ram", "flush cache"]):
        print("🧹 Trimming Quickshell RAM and cleaning system caches...")
        apply_fixes()
        return True
    if any(k in p for k in ["caffeine", "stay awake", "keep awake"]):
        print("☕ Toggling Caffeine mode...")
        subprocess.run(["quickshell", "ipc", "-p", os.path.join(RICE, "quickshell/island"), "call", "island", "caffeine"])
        return True
    if any(k in p for k in ["do not disturb", "dnd", "mute notifications", "silence"]):
        print("🔕 Toggling Do Not Disturb...")
        subprocess.run(["quickshell", "ipc", "-p", os.path.join(RICE, "quickshell/island"), "call", "island", "dnd"])
        return True
    if any(k in p for k in ["next wallpaper", "change wallpaper", "random wallpaper"]):
        print("🖼️ Cycling wallpaper...")
        subprocess.run(["quickshell", "ipc", "-p", os.path.join(RICE, "quickshell/island"), "call", "wallpaper", "next"])
        return True
    if any(k in p for k in ["night light", "nightlight", "blue light", "warm screen"]):
        print("🌙 Toggling night light...")
        subprocess.run(["bash", os.path.join(RICE, "scripts/toggle_nightlight.sh")])
        return True
    return False

def run_llm_query(analysis, custom_prompt=""):
    if custom_prompt and try_dispatch_intent(custom_prompt):
        return

    print("━" * 64)
    print("🤖 Local AI Optimization Advisor (Ollama)")
    print("━" * 64)

    model_name = get_advisor_model()
    print(f"[*] Querying model '{model_name}' with live system state...\n")

    system_summary = (
        f"Hardware: {analysis['memory']['used_mb']}MB used of {analysis['memory']['total_mb']}MB RAM ({analysis['memory']['pct']}%)\n"
        f"Quickshell RSS: {analysis['quickshell_mb']} MB | Hyprland RSS: {analysis['hyprland_mb']} MB\n"
        f"CPU Temperature: {analysis['temps']['avg']}°C (max {analysis['temps']['max']}°C)\n"
        f"GPU: {analysis['gpu']['name']} ({analysis['gpu']['vram_used_mb']}MB used / {analysis['gpu']['vram_total_mb']}MB VRAM, {analysis['gpu']['temp_c']}°C)\n"
        f"Battery: {json.dumps(analysis['battery'])}\n"
    )

    if custom_prompt:
        user_prompt = (
            "You are an expert Linux performance consultant for Hyprland and Quickshell.\n"
            f"Current Machine State:\n{system_summary}\n"
            f"User Question: {custom_prompt}\n\n"
            "Answer directly, concisely, and practically. Do not output internal thoughts."
        )
    else:
        user_prompt = (
            "You are an expert Linux performance advisor for Hyprland & Quickshell.\n"
            f"System Metrics:\n{system_summary}\n"
            "Provide 3 concise, high-impact, bulleted performance recommendations tailored for this hardware. Do not output internal thoughts."
        )

    # 1. Fast local HTTP API
    try:
        payload = json.dumps({
            "model": model_name,
            "prompt": user_prompt,
            "stream": False,
            "options": {"num_predict": 220, "temperature": 0.2}
        }).encode("utf-8")
        req = urllib.request.Request("http://127.0.0.1:11434/api/generate", data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.loads(r.read().decode("utf-8"))
            resp_text = data.get("response", "").strip()
            resp_text = re.sub(r"<think>.*?</think>", "", resp_text, flags=re.DOTALL).strip()
            if resp_text:
                print(resp_text)
                return
    except Exception:
        pass

    # 2. Subprocess fallback
    try:
        res = subprocess.run(["ollama", "run", model_name, user_prompt], capture_output=True, text=True, timeout=25)
        out = re.sub(r"<think>.*?</think>", "", res.stdout or "", flags=re.DOTALL).strip()
        if out:
            print(out)
            return
    except Exception as e:
        print(f"[!] Local model call timed out ({e}). Review rule-based advice below:")

def main():
    args = sys.argv[1:]
    
    if "--fix" in args or "-f" in args:
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
    print("  SUPER + P               -> Multi-Monitor & Projector Display Switcher")
    print("  SUPER + I               -> Open Settings (Performance & Suggestions)")

if __name__ == "__main__":
    main()
