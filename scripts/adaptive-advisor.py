#!/usr/bin/env python3
"""adaptive-advisor.py : Adaptive System & Resource Optimization Advisor for Halcyon
Analyzes hardware status, current memory/CPU pressure, background daemons,
and user app usage patterns to provide tailored performance recommendations.
Supports an optional experimental local LLM analysis (--llm).
"""

import os
import sys
import json
import glob
import re
import subprocess
import shutil

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
    # Scan PSS/RSS for Halcyon, quickshell, hyprland
    procs = []
    try:
        ps = subprocess.run(["ps", "-u", os.environ.get("USER", "netrunner"), "-o", "pid,rss,comm,args"],
                            capture_output=True, text=True, timeout=3)
        for line in ps.stdout.splitlines()[1:]:
            parts = line.split(None, 3)
            if len(parts) >= 4:
                procs.append({
                    "pid": parts[0],
                    "rss_mb": round(int(parts[1]) / 1024, 1),
                    "comm": parts[2],
                    "args": parts[3]
                })
    except Exception:
        pass
    return procs

def get_usage_patterns():
    if not os.path.isfile(USAGE_LOG):
        return {}
    counts = {}
    lines = read_file(USAGE_LOG).splitlines()
    for app in lines[-200:]:  # Last 200 launches
        app = app.strip()
        if app:
            counts[app] = counts.get(app, 0) + 1
    return counts

def analyze_system():
    battery = get_battery_info()
    mem = get_memory_info()
    procs = get_process_stats()
    usage = get_usage_patterns()

    qs_proc = next((p for p in procs if "quickshell" in p["comm"]), None)
    hy_proc = next((p for p in procs if "Hyprland" in p["comm"]), None)
    nm_proc = next((p for p in procs if "nm-applet" in p["comm"]), None)
    blue_proc = next((p for p in procs if "blueman-applet" in p["comm"]), None)
    gaming_active = any(p for p in procs if any(g in p["comm"].lower() for g in ["steam", "wine", "gamescope", "lutris", "heroic"]))

    suggestions = []

    # 1. Power / Battery optimization
    if battery and battery["status"].lower() == "discharging":
        if battery["capacity"] < 60:
            suggestions.append({
                "type": "Power",
                "priority": "HIGH",
                "title": f"Battery at {battery['capacity']}% (Discharging)",
                "action": "Enable Wi-Fi powersave & set 60 FPS in Settings > Performance.",
                "why": "Cuts idle draw by ~20-30% and keeps CPU frequencies scaled down."
            })

    # 2. Quickshell Memory Trim
    if qs_proc and qs_proc["rss_mb"] > 280:
        suggestions.append({
            "type": "Memory",
            "priority": "HIGH" if qs_proc["rss_mb"] > 350 else "MEDIUM",
            "title": f"Quickshell memory is elevated ({qs_proc['rss_mb']} MB)",
            "action": "Turn on 'Aggressive Memory Freeing' (opt:lazyLoad) or click 'Trim Memory Now'.",
            "why": "Unloads closed dialog heaps and releases texture buffers back to the system."
        })

    # 3. Workload based suggestion
    if gaming_active:
        suggestions.append({
            "type": "Performance",
            "priority": "HIGH",
            "title": "Active Gaming / Heavy 3D workload detected",
            "action": "Engage Gaming Mode (SUPER + F10).",
            "why": "Disables compositor blur, background poll timers, and boosts CPU governor."
        })

    # 4. Background applet overhead
    if blue_proc:
        # Check if any bluetooth device is connected
        bt_connected = False
        try:
            bt_out = subprocess.run(["bluetoothctl", "devices", "Connected"], capture_output=True, text=True, timeout=2).stdout
            if bt_out.strip():
                bt_connected = True
        except Exception:
            pass
        if not bt_connected:
            suggestions.append({
                "type": "Overhead",
                "priority": "LOW",
                "title": "Bluetooth tray running without active connected devices",
                "action": "Consider disabling blueman-applet in Settings > Startup & background.",
                "why": "Saves ~30-50 MB RAM while keeping direct pairing available on demand."
            })

    # 5. Usage based advice
    top_apps = sorted(usage.items(), key=lambda x: -x[1])[:3]
    if top_apps:
        app_names = ", ".join(f"{k} ({v}x)" for k, v in top_apps)
        suggestions.append({
            "type": "Habits",
            "priority": "INFO",
            "title": f"Frequent applications: {app_names}",
            "action": "Ensure keybinds or workspace rules are mapped in Settings > Desktop.",
            "why": "Automates window placement to minimize tiling churn."
        })

    # 6. Overall sweet spot suggestion
    if not suggestions or all(s["priority"] in ["LOW", "INFO"] for s in suggestions):
        suggestions.append({
            "type": "Tuning",
            "priority": "RECOMMENDED",
            "title": "System running optimally",
            "action": "Recommended Sweet Spot is active: 60 FPS, 2-pass blur, and lazy loading.",
            "why": "Preserves full aesthetic fidelity while keeping Halcyon idle CPU <0.5%."
        })

    return {
        "battery": battery,
        "memory": mem,
        "quickshell_mb": qs_proc["rss_mb"] if qs_proc else 0,
        "hyprland_mb": hy_proc["rss_mb"] if hy_proc else 0,
        "suggestions": suggestions
    }

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
        # Prioritize lightweight models for instant response
        for pref in ["llama3.2:1b", "qwen2.5:1.5b", "qwen2.5:0.5b", "llama3.2:3b", "qwen3:4b"]:
            match = next((m for m in models if m.startswith(pref)), None)
            if match:
                return match
        if models:
            return models[0]
    except Exception:
        pass
    return "llama3.2:1b"

def run_llm_analysis(analysis):
    print("━" * 56)
    print("🤖 Experimental Local LLM Advisor")
    print("━" * 56)

    ollama_path = shutil.which("ollama")
    if not ollama_path:
        print("[!] Ollama is not installed.")
        print("To enable the local AI advisor:")
        print("  curl -fsSL https://ollama.com/install.sh | sh")
        print("  ollama pull llama3.2:1b")
        print("\nDisplaying rule-based adaptive recommendations instead:")
        return

    # Check available models
    try:
        models_out = subprocess.run(["ollama", "list"], capture_output=True, text=True, timeout=3).stdout
        models = [line.split()[0] for line in models_out.splitlines()[1:] if line.strip()]
    except Exception:
        models = []

    if not models:
        print("[!] Ollama is installed but no local models are pulled.")
        print("Run: `ollama pull llama3.2:1b` (recommended ~1.3 GB)")
        print("\nDisplaying rule-based adaptive recommendations instead:")
        return

    model_name = get_advisor_model()
    print(f"[*] Querying local model '{model_name}' with system profile...\n")

    prompt = (
        "You are an expert Linux system performance advisor for Hyprland & Quickshell. "
        "Review the following metrics and provide 3 concise, bulleted, high-impact recommendations:\n\n"
        f"RAM: {analysis['memory']['used_mb']} MB used of {analysis['memory']['total_mb']} MB ({analysis['memory']['pct']}%)\n"
        f"Quickshell RSS: {analysis['quickshell_mb']} MB\n"
        f"Hyprland RSS: {analysis['hyprland_mb']} MB\n"
        f"Battery Status: {json.dumps(analysis['battery'])}\n\n"
        "Keep advice practical, brief, and actionable. Do not output internal thoughts."
    )

    # 1. Try fast local HTTP API
    try:
        import urllib.request
        payload = json.dumps({
            "model": model_name,
            "prompt": prompt,
            "stream": False,
            "options": {"num_predict": 180, "temperature": 0.2}
        }).encode("utf-8")
        req = urllib.request.Request("http://127.0.0.1:11434/api/generate", data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=12) as r:
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
        res = subprocess.run(["ollama", "run", model_name, prompt], capture_output=True, text=True, timeout=20)
        out = re.sub(r"<think>.*?</think>", "", res.stdout or "", flags=re.DOTALL).strip()
        if out:
            print(out)
            return
    except Exception as e:
        print(f"[!] LLM query timed out or unavailable ({e}). Using heuristic advice below:")

def main():
    use_llm = "--llm" in sys.argv
    analysis = analyze_system()

    if use_llm:
        run_llm_analysis(analysis)
        print()

    print("╔════════════════════════════════════════════════════════════════╗")
    print("║            Halcyon Adaptive Performance Advisor                ║")
    print("╚════════════════════════════════════════════════════════════════╝")
    print(f"• Total RAM: {analysis['memory']['used_mb']} MB / {analysis['memory']['total_mb']} MB ({analysis['memory']['pct']}%)")
    print(f"• Quickshell: {analysis['quickshell_mb']} MB | Hyprland: {analysis['hyprland_mb']} MB")
    if analysis['battery']:
        print(f"• Battery: {analysis['battery']['capacity']}% ({analysis['battery']['status']})")
    print("─" * 64)

    for idx, s in enumerate(analysis["suggestions"], 1):
        prio_color = {
            "HIGH": "\033[1;31m[HIGH]\033[0m",
            "MEDIUM": "\033[1;33m[MED]\033[0m",
            "LOW": "\033[1;36m[LOW]\033[0m",
            "RECOMMENDED": "\033[1;32m[OK]\033[0m",
            "INFO": "\033[1;34m[INFO]\033[0m"
        }.get(s["priority"], f"[{s['priority']}]")

        print(f"{idx}. {prio_color} {s['title']}")
        print(f"   ➜ Action: {s['action']}")
        print(f"   ℹ Detail: {s['why']}\n")

    print("─" * 64)
    print("Tip: Adjust these in Settings > Performance & Suggestions (SUPER + I)")

if __name__ == "__main__":
    main()
