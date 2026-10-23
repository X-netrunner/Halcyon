#!/usr/bin/env python3
"""adaptive-advisor.py : Intelligent System & Resource Performance Advisor for Halcyon
Analyzes hardware status, CPU/GPU temperatures, VRAM, memory pressure (PSI),
background daemons, systemd services, display server logs, and user workflow patterns.

Modes:
  adaptive-advisor.py                     -> Full interactive diagnostic dashboard & efficiency score
  adaptive-advisor.py doctor              -> Deep autonomous diagnostic check with confirmed fixes
  adaptive-advisor.py fix [--yes]         -> Fix detected bottlenecks (asks before changing system unless --yes)
  adaptive-advisor.py model               -> Show current model and installed models
  adaptive-advisor.py model recommend     -> Hardware-aware recommendations for running bigger local models
  adaptive-advisor.py model switch <name> -> Switch to any model (pulls it if missing)
  adaptive-advisor.py --llm               -> Synthesizes situational advice using local Ollama LLM
  adaptive-advisor.py "your question..."  -> AI agent: investigates with tools, can fix things (asks before each change; --yes pre-approves low-risk ones)
  adaptive-advisor.py leaks               -> Read the last leak-watch log: what leaked, what jumped once, zombies, clones (LLM explains it)
  adaptive-advisor.py leaks watch [min] [every_s] -> Record a new leak-watch (default 30 min, every 60 s), then analyse it
  adaptive-advisor.py triage "text"       -> Tag a notification (urgent/chat/system/promo) + one-line summary
  adaptive-advisor.py write "request"     -> Short friendly text (birthday message, reply, description)
"""

import os
import sys
import json
import glob
import re
import subprocess
import shutil
import time
import socket
import pwd
import urllib.request
import urllib.error

HOME = os.path.expanduser("~")
RICE = os.environ.get("HALCYON_DIR", os.path.join(HOME, ".config/Halcyon"))
USAGE_LOG = os.path.join(HOME, ".local/state/island/usage.log")
ISLAND_LOG = os.path.join(HOME, ".cache/island/quickshell-island.log")

# ───────────────────────── Caching & Helpers ─────────────────────────

_CACHE = {}
def cached(ttl=2.0):
    def decorator(fn):
        def wrapper(*args, **kwargs):
            key = (fn.__name__, args)
            now = time.time()
            if key in _CACHE:
                res, ts = _CACHE[key]
                if now - ts < ttl:
                    return res
            res = fn(*args, **kwargs)
            _CACHE[key] = (res, now)
            return res
        return wrapper
    return decorator

def read_file(path):
    try:
        with open(path, "r", errors="ignore") as f:
            return f.read().strip()
    except Exception:
        return ""

# ───────────────────────── Hardware & System Sensors ─────────────────────────

@cached(3.0)
def get_battery_info():
    bats = glob.glob("/sys/class/power_supply/BAT*")
    if not bats:
        return None
    bat = bats[0]
    status = read_file(os.path.join(bat, "status")) or "Unknown"
    capacity = read_file(os.path.join(bat, "capacity")) or "100"
    power_now = read_file(os.path.join(bat, "power_now"))
    watts = None
    if power_now and power_now.isdigit():
        watts = round(int(power_now) / 1_000_000.0, 1)
    try:
        cap_val = int(capacity)
    except ValueError:
        cap_val = 100
    return {"present": True, "status": status, "capacity": cap_val, "watts": watts}

@cached(2.0)
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

@cached(3.0)
def get_gpu_info():
    if is_nvidia_dgpu_suspended():
        name = "NVIDIA dGPU (D3cold suspended)"
        vram_mb = 0
        try:
            lsp = subprocess.run(["lspci", "-d", "10de:0300"], capture_output=True, text=True, timeout=1).stdout
            if not lsp:
                lsp = subprocess.run(["lspci", "-d", "10de:"], capture_output=True, text=True, timeout=1).stdout
            m = re.search(r"\[(.*?)\]", lsp)
            if m:
                model_str = m.group(1)
                name = f"NVIDIA {model_str} (D3cold idle)"
                vmatch = re.search(r"(\d+)\s*GB", model_str, re.I)
                if vmatch:
                    vram_mb = int(vmatch.group(1)) * 1024
        except Exception:
            pass
        return {"present": True, "name": name, "temp_c": 0, "vram_used_mb": 0, "vram_total_mb": vram_mb or 6144, "util_pct": 0, "suspended": True}
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
                    "util_pct": int(parts[4]),
                    "suspended": False
                }
    except Exception:
        pass
    # Check for AMD / Intel integrated GPU
    dri_cards = glob.glob("/sys/class/drm/card*")
    return {"present": len(dri_cards) > 0, "name": "Integrated GPU", "temp_c": 0, "vram_used_mb": 0, "vram_total_mb": 0, "util_pct": 0, "suspended": False}

@cached(1.5)
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
    swap_total = round(meminfo.get("SwapTotal", 0) / 1024)
    swap_free = round(meminfo.get("SwapFree", 0) / 1024)
    swap_used = swap_total - swap_free
    used_mb = total_mb - avail_mb
    pct_used = round((used_mb / total_mb * 100), 1) if total_mb > 0 else 0
    return {
        "total_mb": total_mb, "used_mb": used_mb, "avail_mb": avail_mb,
        "pct": pct_used, "swap_total_mb": swap_total, "swap_used_mb": swap_used
    }

@cached(2.0)
def get_psi_pressure():
    """Reads Linux Pressure Stall Information (PSI) for memory, cpu, and io."""
    psi = {}
    for res in ("memory", "cpu", "io"):
        path = f"/proc/pressure/{res}"
        data = read_file(path)
        if data:
            entry = {}
            for line in data.splitlines():
                parts = line.split()
                if len(parts) >= 2:
                    k = parts[0]
                    vals = {}
                    for p in parts[1:]:
                        if "=" in p:
                            vk, vv = p.split("=", 1)
                            try: vals[vk] = float(vv)
                            except ValueError: pass
                    entry[k] = vals
            psi[res] = entry
    return psi

@cached(2.0)
def get_process_stats():
    procs = []
    try:
        user = os.environ.get("USER") or pwd.getpwuid(os.getuid()).pw_name
        ps = subprocess.run(["ps", "-u", user, "-o", "pid,rss,%cpu,stat,comm,args"],
                            capture_output=True, text=True, timeout=3)
        for line in ps.stdout.splitlines()[1:]:
            parts = line.split(None, 5)
            if len(parts) >= 6:
                procs.append({
                    "pid": parts[0],
                    "rss_mb": round(int(parts[1]) / 1024, 1),
                    "cpu_pct": float(parts[2]),
                    "stat": parts[3],
                    "comm": parts[4],
                    "args": parts[5]
                })
    except Exception:
        pass
    return procs

def get_failed_services():
    failed = []
    for scope, flag in [("system", []), ("user", ["--user"])]:
        try:
            res = subprocess.run(["systemctl", *flag, "--failed", "--no-legend"], capture_output=True, text=True, timeout=2)
            for line in res.stdout.splitlines():
                parts = line.strip().split()
                # Skip leading bullet (●) if present
                if parts and parts[0] in ("●", "*", "-"):
                    parts = parts[1:]
                if parts and parts[0].endswith(".service"):
                    failed.append((scope, parts[0]))
        except Exception:
            pass
    return failed

# systemd-pcr* / tpm2-setup units extend TPM2 PCR registers (measured boot). They fail when the machine has no usable TPM2
# (fTPM / PTT off in the BIOS, no TPM, or no measured-boot log). Restarting them cannot work, and nothing is broken.
_TPM_UNIT = re.compile(r"^systemd-(pcr[a-z0-9\-]*|tpm2-setup(-early)?)(@[^.]*)?\.service$")

def tpm_device_present():
    return os.path.exists("/dev/tpmrm0") or os.path.exists("/sys/class/tpm/tpm0")

@cached(8.0)
def classify_failed_unit(scope, unit):
    """Why did this unit fail, and is a restart even the right fix?
    Returns {"benign": bool, "cause": str, "fix": str, "journal": [lines]}"""
    flag = ["--user"] if scope == "user" else []
    try:
        st = subprocess.run(["systemctl", *flag, "status", "--no-pager", "-n", "8", unit],
                            capture_output=True, text=True, timeout=5).stdout.strip().splitlines()
    except Exception:
        st = []
    code = next((m.group(0) for l in st for m in [re.search(r"code=\w+, status=\S+", l)] if m), "")
    pre = "" if scope == "user" else "sudo "
    if _TPM_UNIT.match(unit):
        if tpm_device_present():
            cause = ("A TPM2 is present, but this measured-boot / TPM setup step fails" + (f" ({code})" if code else "") +
                     ". It only matters if you use measured boot (UKI + systemd-stub, TPM-bound disk keys); otherwise harmless.")
        else:
            cause = ("No usable TPM2 device is exposed to Linux (fTPM / Intel PTT / AMD PSP TPM is probably disabled in the BIOS, or the "
                     "machine has none), so the unit that measures into the TPM cannot work. Restarting it cannot help; nothing is broken.")
        fix = (f"Clear the flag: {pre}systemctl reset-failed {unit}  (it returns at next boot). To stop it for good: "
               f"{pre}systemctl mask {unit}  (undo with unmask). Or enable fTPM/PTT in the BIOS if you want a TPM.")
        return {"benign": True, "cause": cause, "fix": fix, "journal": st}
    cause = f"The unit failed{(' (' + code + ')') if code else ''}; see the log lines for the reason."
    fix = (f"Read why first: journalctl {'--user ' if scope == 'user' else ''}-u {unit} -b -n 40   then restart only once the cause is fixed.")
    return {"benign": False, "cause": cause, "fix": fix, "journal": st}

def get_zombie_processes():
    zombies = []
    try:
        ps = subprocess.run(["ps", "-eo", "pid,stat,comm,ppid"], capture_output=True, text=True, timeout=2)
        for line in ps.stdout.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 4 and "Z" in parts[1]:
                zombies.append((parts[0], parts[2], parts[3]))   # (pid, name, parent pid)
    except Exception:
        pass
    return zombies

def get_disk_health():
    disks = []
    for mount in ("/", HOME):
        try:
            usage = shutil.disk_usage(mount)
            total_gb = round(usage.total / (1024**3), 1)
            used_gb = round(usage.used / (1024**3), 1)
            free_gb = round(usage.free / (1024**3), 1)
            pct = round(usage.used / usage.total * 100, 1)
            disks.append({"mount": mount, "total_gb": total_gb, "free_gb": free_gb, "pct": pct})
        except Exception:
            pass
    return disks

def get_network_health():
    """Quick non-blocking network & DNS check."""
    has_default_route = False
    try:
        routes = read_file("/proc/net/route")
        for line in routes.splitlines()[1:]:
            fields = line.split()
            if len(fields) >= 2 and fields[1] == "00000000":
                has_default_route = True
                break
    except Exception:
        pass

    dns_ok = False
    if has_default_route:
        try:
            socket.setdefaulttimeout(1.5)
            socket.getaddrinfo("archlinux.org", 80, socket.AF_UNSPEC, socket.SOCK_STREAM)
            dns_ok = True
        except Exception:
            try:
                socket.getaddrinfo("1.1.1.1", 53, socket.AF_INET, socket.SOCK_DGRAM)
                dns_ok = True
            except Exception:
                pass
    return {"online": has_default_route, "dns_ok": dns_ok}

def get_quickshell_log_health():
    if not os.path.isfile(ISLAND_LOG):
        return {"exists": False, "errors": 0, "recent_error": None}
    recent_errors = []
    try:
        with open(ISLAND_LOG, "r", errors="ignore") as f:
            lines = f.readlines()[-150:]
            for l in lines:
                if any(k in l for k in ("CRITICAL", "Error", "TypeError", "ReferenceError")):
                    recent_errors.append(l.strip())
    except Exception:
        pass
    return {
        "exists": True,
        "errors": len(recent_errors),
        "recent_error": recent_errors[-1] if recent_errors else None
    }

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

# ───────────────────────── Score & Comprehensive Analysis ─────────────────────────

def calculate_score(mem, temps, qs_mb, battery, psi, failed_svcs, zombies):
    score = 100
    if mem["pct"] > 88: score -= 22
    elif mem["pct"] > 75: score -= 12

    if temps["max"] > 92: score -= 25
    elif temps["max"] > 82: score -= 12

    if qs_mb > 450: score -= 15
    elif qs_mb > 320: score -= 8

    if battery and battery["status"] == "Discharging" and battery["capacity"] < 25:
        score -= 10

    # PSI memory stall penalty
    mem_some = psi.get("memory", {}).get("some", {}).get("avg10", 0.0)
    if mem_some > 15.0: score -= 15
    elif mem_some > 5.0: score -= 8

    # Failed services
    if failed_svcs:
        score -= min(20, len(failed_svcs) * 10)

    # Zombie processes
    if zombies:
        score -= min(10, len(zombies) * 5)

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
    psi = get_psi_pressure()
    failed_svcs = get_failed_services()
    zombies = get_zombie_processes()
    disks = get_disk_health()
    net = get_network_health()
    qs_log = get_quickshell_log_health()

    qs_proc = next((p for p in procs if "quickshell" in p["comm"]), None)
    hy_proc = next((p for p in procs if "Hyprland" in p["comm"]), None)
    gaming_active = any(p for p in procs if any(g in p["comm"].lower() for g in ["steam", "wine", "gamescope", "lutris", "heroic"]))

    qs_mb = qs_proc["rss_mb"] if qs_proc else 0
    hy_mb = hy_proc["rss_mb"] if hy_proc else 0

    suggestions = []
    remediations = []  # actionable fixes that require confirmation

    # Failed services: diagnose first. A blind "restart" is wrong for units that fail for a hardware reason.
    real_failed, failed_info = [], {}
    for scope, svc in failed_svcs:
        d = classify_failed_unit(scope, svc)
        failed_info[svc] = d
        sudo = "" if scope == "user" else "sudo "
        flag = "--user " if scope == "user" else ""
        if d["benign"]:
            reset_cmd = f"{sudo}systemctl {flag}reset-failed {svc}"
            suggestions.append({
                "id": f"harmless_svc_{svc}", "priority": "LOW",
                "title": f"Harmless failed unit: {svc} ({scope})",
                "action": d["fix"], "why": d["cause"], "cmd": reset_cmd})
            remediations.append((f"Clear the failed flag of '{svc}'", reset_cmd, "Harmless failure; a restart cannot fix it."))
        else:
            real_failed.append((scope, svc))
            restart_cmd = f"{sudo}systemctl {flag}restart {svc}"
            suggestions.append({
                "id": f"restart_svc_{svc}", "priority": "HIGH",
                "title": f"Service failure: {svc} ({scope})",
                "action": d["fix"], "why": d["cause"], "cmd": restart_cmd})
            remediations.append((f"Restart failed service '{svc}'", restart_cmd, "Only after reading its log; the log is shown if it fails again."))

    # Memory pressure & Quickshell trim
    if qs_mb > 350:
        trim_cmd = f"quickshell ipc -p {os.path.join(RICE, 'quickshell/island')} call island trim"
        suggestions.append({
            "id": "trim_quickshell",
            "priority": "HIGH",
            "title": f"Quickshell memory elevated ({qs_mb:.1f} MB)",
            "action": "Trim Quickshell memory heap caches.",
            "why": "Frees closed dialog heaps and unused textures back to OS.",
            "cmd": trim_cmd
        })
        remediations.append(("Trim Quickshell RAM", trim_cmd, "Frees cached QML dialog textures back to OS."))

    if mem["pct"] > 82 or psi.get("memory", {}).get("some", {}).get("avg10", 0.0) > 8.0:
        clean_cmd = "sync"
        suggestions.append({
            "id": "memory_pressure",
            "priority": "HIGH",
            "title": f"High memory pressure ({mem['pct']}% used, {mem['avail_mb']} MB available)",
            "action": "Run 'sync' and trim inactive caches.",
            "why": "System tasks are experiencing memory pressure delays.",
            "cmd": clean_cmd
        })
        remediations.append(("Synchronize page caches", clean_cmd, "Flushes dirty pagecache buffers to disk safely."))

    # Zombies
    if zombies:
        z_pids = " ".join(z[0] for z in zombies)
        parents = sorted({z[2] for z in zombies})
        suggestions.append({
            "id": "zombies",
            "priority": "MEDIUM",
            "title": f"Found {len(zombies)} zombie/defunct process(es)",
            "action": f"Zombies are already dead (kill -9 does nothing); ask their parent(s) {' '.join(parents)} to reap them.",
            "why": f"Defunct PIDs {z_pids} stay in the process table until the parent calls wait().",
            "cmd": "kill -s CHLD " + " ".join(parents)
        })
        remediations.append(("Ask the parent process(es) to reap zombies", "kill -s CHLD " + " ".join(parents),
                             "Sends SIGCHLD (harmless); if they remain, restart the parent."))

    # Thermals
    if temps["max"] > 84:
        suggestions.append({
            "id": "thermal_warm",
            "priority": "MEDIUM",
            "title": f"High CPU Temperature ({temps['max']}°C)",
            "action": "Switch to Balanced thermal profile or clear heavy background loops.",
            "why": "Prevents thermal throttling and fan fatigue."
        })

    # Disk Space
    for d in disks:
        if d["pct"] > 90:
            suggestions.append({
                "id": f"disk_full_{d['mount']}",
                "priority": "HIGH",
                "title": f"Storage volume {d['mount']} is nearly full ({d['pct']}%)",
                "action": "Clean package cache: 'paccache -r' or remove old cache files.",
                "why": f"Only {d['free_gb']} GB remaining on {d['mount']}."
            })

    # Gaming
    if gaming_active:
        suggestions.append({
            "id": "gaming_mode",
            "priority": "INFO",
            "title": "Active Game Process Detected",
            "action": "Engage Gaming Mode (SUPER + F10 or Settings > Gaming).",
            "why": "Uncaps refresh rate and suspends background animations."
        })

    # Battery
    if battery and battery["status"] == "Discharging" and battery["capacity"] < 25:
        suggestions.append({
            "id": "battery_saver",
            "priority": "HIGH",
            "title": f"Battery Critically Low ({battery['capacity']}%)",
            "action": "Connect power adapter or activate power saver mode.",
            "why": f"Battery is discharging at {battery.get('watts', 15)}W."
        })

    score, rating = calculate_score(mem, temps, qs_mb, battery, psi, real_failed, zombies)   # harmless failures do not cost points

    return {
        "battery": battery,
        "memory": mem,
        "temps": temps,
        "gpu": gpu,
        "psi": psi,
        "failed_svcs": failed_svcs,
        "failed_info": failed_info,
        "zombies": zombies,
        "disks": disks,
        "net": net,
        "qs_log": qs_log,
        "quickshell_mb": qs_mb,
        "hyprland_mb": hy_mb,
        "score": score,
        "rating": rating,
        "suggestions": suggestions,
        "remediations": remediations,
        "procs": procs,
        "usage": usage
    }

# ───────────────────────── Interactive Safe Remediation ─────────────────────────

def ask_and_execute(title, command, reason, assume_yes=False):
    """Asks user for confirmation before executing any system modification command."""
    print(f"\n\033[1;33m[?] Action proposed:\033[0m \033[1m{title}\033[0m")
    print(f"    \033[36mCommand:\033[0m {command}")
    print(f"    \033[37mReason:\033[0m  {reason}")
    if assume_yes:
        print("    \033[32m[Auto-approved via --yes]\033[0m")
    else:
        try:
            choice = input("    Proceed with this system change? [y/N]: ").strip().lower()
            if choice not in ("y", "yes"):
                print("    \033[33mSkipped by user.\033[0m")
                return False
        except (EOFError, KeyboardInterrupt):
            print("\n    \033[33mSkipped.\033[0m")
            return False
    print("    \033[32mExecuting...\033[0m")
    try:
        # sudo asks for the password on the terminal itself (not through the captured pipes); allow time to type it
        res = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=90 if "sudo" in command else 20)
        if res.returncode == 0:
            print("    \033[32m✔ Applied successfully.\033[0m")
            return True
        print(f"    \033[31m✗ Command exited with code {res.returncode}: {(res.stderr or res.stdout).strip()}\033[0m")
        m = re.search(r"systemctl\s+(--user\s+)?(?:restart|start)\s+(\S+)", command)
        if m:   # do not leave the user with only "exited with error code": show what the unit says
            flag = ["--user"] if m.group(1) else []
            st = subprocess.run(["systemctl", *flag, "status", "--no-pager", "-n", "8", m.group(2)],
                                capture_output=True, text=True, timeout=8).stdout.strip()
            print("    \033[37mWhy (unit status / journal):\033[0m\n      " + st.replace("\n", "\n      "))
            d = classify_failed_unit("user" if m.group(1) else "system", m.group(2))
            print(f"    \033[33mDiagnosis:\033[0m {d['cause']}\n    \033[33mFix:\033[0m {d['fix']}")
        return False
    except Exception as e:
        print(f"    \033[31m✗ Execution failed: {e}\033[0m")
        return False

def run_doctor(assume_yes=False):
    """Full autonomous diagnostic battery with confirmed fixes."""
    print("━" * 68)
    print("Halcyon Autonomous System Doctor & Diagnostician")
    print("━" * 68)
    a = analyze_system()

    # 1. System summary
    sc = "\033[1;32m" if a["score"] >= 90 else "\033[1;33m" if a["score"] >= 70 else "\033[1;31m"
    print(f"Overall Health: {sc}{a['score']}/100 [{a['rating']}]\033[0m")
    print(f"• RAM: {a['memory']['used_mb']}/{a['memory']['total_mb']} MB ({a['memory']['pct']}%)  |  Swap: {a['memory']['swap_used_mb']}/{a['memory']['swap_total_mb']} MB")
    print(f"• Temperatures: CPU avg {a['temps']['avg']}°C, peak {a['temps']['max']}°C")
    if a["gpu"]["present"]:
        print(f"• GPU: {a['gpu']['name']}  |  VRAM: {a['gpu']['vram_used_mb']}/{a['gpu']['vram_total_mb']} MB")
    if a["battery"]:
        print(f"• Battery: {a['battery']['capacity']}% ({a['battery']['status']})")
    print(f"• Network: {'✔ Online' if a['net']['online'] else '✗ Disconnected'} (DNS: {'✔ OK' if a['net']['dns_ok'] else '✗ Failing'})")
    print(f"• Shell Heaps: Quickshell {a['quickshell_mb']} MB  |  Hyprland {a['hyprland_mb']} MB")

    # 2. Issues report
    print("\nDiagnostic Findings:")
    if not a["suggestions"]:
        print("  \033[32m✔ No system anomalies, failed services, or severe bottlenecks found.\033[0m")
        return

    for idx, s in enumerate(a["suggestions"], 1):
        prio_color = {
            "HIGH": "\033[1;31m[HIGH]\033[0m",
            "MEDIUM": "\033[1;33m[MED]\033[0m",
            "LOW": "\033[1;34m[LOW]\033[0m",
            "INFO": "\033[1;36m[INFO]\033[0m"
        }.get(s["priority"], f"[{s['priority']}]")
        print(f"  {idx}. {prio_color} \033[1m{s['title']}\033[0m")
        print(f"     Why: {s['why']}")
        print(f"     Action: {s['action']}")

    # 3. Remediation execution
    if a["remediations"]:
        print("\nAvailable Remediations (each change requires your explicit confirmation):")
        applied = 0
        for title, cmd, why in a["remediations"]:
            if ask_and_execute(title, cmd, why, assume_yes=assume_yes):
                applied += 1
        print(f"\nDoctor finished. {applied} remediation(s) applied.")
    else:
        print("\n✔ No automated changes needed.")

def apply_fixes(assume_yes=False):
    """Trims quickshell and flushes buffers with confirmation."""
    print("━" * 60)
    print("Halcyon System Optimizations")
    print("━" * 60)
    trim_cmd = f"quickshell ipc -p {os.path.join(RICE, 'quickshell/island')} call island trim"
    ask_and_execute("Trim Quickshell Heap Caches", trim_cmd, "Releases unused dialog textures and caches back to the operating system.", assume_yes=assume_yes)
    mem = get_memory_info()
    if mem["pct"] > 70:
        ask_and_execute("Synchronize File Buffers", "sync", "Flushes pending write buffers before freeing pagecache.", assume_yes=assume_yes)
    print("\n✔ Optimization step complete. Run 'advisor' to check new score.")

# ───────────────────────── Hardware-Aware Model Advisor ─────────────────────────

MODEL_ALIASES = {
    "1b": "llama3.2:1b",
    "3b": "llama3.2:3b",
    "llama1b": "llama3.2:1b",
    "llama3b": "llama3.2:3b",
    "llama8b": "llama3.1:8b",
    "8b": "llama3.1:8b",
    "14b": "qwen2.5:14b",
    "qwen1.5b": "qwen2.5:1.5b",
    "qwen3b": "qwen2.5:3b-instruct",
    "3b-instruct": "qwen2.5:3b-instruct",
    "qwen14b": "qwen2.5:14b",
    "deepseek8b": "deepseek-r1:8b",
    "deepseek14b": "deepseek-r1:14b",
}

def installed_models():
    try:
        out = subprocess.run(["ollama", "list"], capture_output=True, text=True, timeout=5).stdout
        return [l.split()[0] for l in out.splitlines()[1:] if l.strip()]
    except Exception:
        return []

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
    have = installed_models()
    for pref in ["llama3.1:8b", "llama3.2:3b", "qwen2.5:3b", "llama3.2:1b"]:      # "qwen2.5:3b" also matches qwen2.5:3b-instruct
        match = next((m for m in have if m.startswith(pref)), None)
        if match:
            return match
    if have:
        return have[0]
    return "qwen2.5:3b-instruct"

def recommend_models():
    """Hardware-aware sizing and suggestions for users wanting a bigger local model."""
    mem = get_memory_info()
    gpu = get_gpu_info()
    disks = get_disk_health()
    free_disk_gb = disks[0]["free_gb"] if disks else 20.0
    vram_mb = gpu["vram_total_mb"]
    ram_gb = round(mem["total_mb"] / 1024, 1)

    print("━" * 68)
    print("Halcyon AI Hardware-Aware Model Advisor")
    print("━" * 68)
    print(f"Detected Hardware:")
    print(f"  • System RAM : {ram_gb} GB ({round(mem['avail_mb']/1024, 1)} GB available)")
    if gpu["present"]:
        print(f"  • GPU / VRAM : {gpu['name']} ({vram_mb} MB VRAM)")
    else:
        print(f"  • GPU        : Integrated Graphics (relies on shared system RAM)")
    print(f"  • Disk Space : {free_disk_gb} GB free for model weights")
    print("─" * 68)

    print("Recommended Model Tiers for Your Machine:\n")

    # Tier 1: Sweet spot
    if vram_mb >= 5500:
        print("★ TIER 1: SWEET SPOT (100% GPU VRAM Offload, Blazing 40-60+ tps)")
        print("  Your 6 GB VRAM comfortably fits full 8B quantized models on the GPU:")
        print("  • \033[1;36mllama3.1:8b\033[0m    (~4.9 GB) -> \033[1mRECOMMENDED\033[0m: premier conversational model, tool-capable")
        print("  • \033[1;36mdeepseek-r1:8b\033[0m (~4.9 GB) -> Advanced step-by-step reasoning and math")
    else:
        print("★ TIER 1: ULTRA-RESPONSIVE (Low RAM & Fast on CPU/Integrated GPU)")
        print("  • \033[1;36mllama3.2:3b\033[0m    (~2.0 GB) -> Fast, accurate, very gentle on battery")
        print("  • \033[1;36mqwen2.5:3b-instruct\033[0m (~1.9 GB) -> Great instruction following and compact; best for the Notes AI overview")

    # Tier 2: Heavyweights
    print("\n★ TIER 2: ADVANCED REASONING (High Intelligence, Partial CPU Offload)")
    if ram_gb >= 12:
        print("  • \033[1;36mqwen2.5:14b\033[0m    (~9.0 GB) -> Near GPT-4 class reasoning for complex coding")
        print("  • \033[1;36mdeepseek-r1:14b\033[0m(~9.0 GB) -> Deep analytical chain-of-thought")
        print("    (Runs ~12-18 tps using hybrid GPU + CPU RAM offloading)")
    else:
        print("  • \033[1;36mllama3.1:8b\033[0m    (~4.9 GB) -> Maximum recommended model for this RAM budget")

    # Tier 3: Ultra-light
    print("\n★ TIER 3: ULTRA-LIGHT / TRAVEL (Zero System Burden)")
    print("  • \033[1;36mllama3.2:1b\033[0m    (~1.3 GB) -> Instant reply, runs on bare minimum resources")

    print("\n" + "─" * 68)
    print("Performance & Optimization Tips for Bigger Models:")
    print("  1. Keep context window optimal: 4096 to 8192 tokens preserves VRAM.")
    print("  2. In Ollama, keep OLLAMA_NUM_PARALLEL=1 so VRAM is not duplicated.")
    print("  3. To switch to the best model now, run:")
    print("     \033[1;32madvisor model switch llama3.1:8b\033[0m   (or: advisor model switch 8b)")
    print("  4. The Notes AI overview does better on a small, fast model than on 8B: keep chat on the big one and give Notes its own:")
    print("     \033[1;32mnotes set NOTES_MODEL qwen2.5:3b-instruct\033[0m   (ollama pull qwen2.5:3b-instruct first; 'default' undoes it)")
    print("━" * 68)

def model_command(args):
    """advisor model [recommend|switch <name>|<name>]"""
    if args and args[0] in ("recommend", "suggest", "bigger", "tiers"):
        recommend_models()
        return

    current = get_advisor_model()
    have = installed_models()

    if not args:
        print(f"Current model : {current}")
        print("Installed     : " + (", ".join(have) if have else "(none found - is ollama running?)"))
        print("Aliases       : " + ", ".join(f"{k}={v}" for k, v in MODEL_ALIASES.items()))
        print("\nCommands:")
        print("  advisor model recommend         -> View hardware-tailored recommendations for bigger models")
        print("  advisor model switch llama3.1:8b -> Pull and activate a new model")
        print("  advisor model 3b                -> Quick switch to 3B model")
        return

    target = args[1] if args[0] in ("switch", "set") and len(args) > 1 else args[0]
    name = MODEL_ALIASES.get(target.lower(), target)

    if not any(m == name or m.startswith(name + ":") or m.split(":")[0] == name for m in have):
        mem = get_memory_info()
        free_mb = mem["avail_mb"]
        print(f"[*] '{name}' is not currently downloaded.")
        print(f"[*] Available RAM: ~{free_mb} MB.")
        try:
            confirm = input(f"    Download and install '{name}' from Ollama registry? [Y/n]: ").strip().lower()
            if confirm in ("n", "no"):
                print("    Aborted.")
                return
        except (EOFError, KeyboardInterrupt):
            print("\n    Aborted.")
            return

        print(f"[*] Pulling '{name}'... (this may take a couple minutes depending on connection)")
        r = subprocess.run(["ollama", "pull", name])
        if r.returncode != 0:
            print(f"[!] Pull failed. Retaining current model '{current}'.")
            return

    os.makedirs(RICE, exist_ok=True)
    conf = os.path.join(RICE, "ai-advisor.conf")
    with open(conf, "w") as f:
        f.write(f'MODEL="{name}"\n')
    print(f"✔ Advisor model successfully set to {name}  (saved in {conf})")
    if os.environ.get("HALCYON_AI_MODEL"):
        print("[!] Note: HALCYON_AI_MODEL is set in current environment and overrides this file.")

# ───────────────────────── Actions the Advisor Can Dispatch ─────────────────────────

def _qs(*call):
    subprocess.run(["quickshell", "ipc", "-p", os.path.join(RICE, "quickshell/island"), "call", *call])

def _script(name, *a):
    subprocess.run(["bash", os.path.join(RICE, "scripts", name), *a])

ACTIONS = {
    "mirror":        ("Executing Projector Mirror Mode...", lambda: _script("display-manager.sh", "mirror"),
                      "mirror laptop screen to a projector / TV / external display",
                      ["projector", "mirror", "clone screen", "presentation"], False),
    "extend-right":  ("Extending display to the right...", lambda: _script("display-manager.sh", "extend-right"),
                      "use external monitor as second screen to the right",
                      ["extend right", "dual screen", "second monitor", "extend display"], False),
    "extend-left":   ("Extending display to the left...", lambda: _script("display-manager.sh", "extend-left"),
                      "use external monitor as second screen to the left",
                      ["extend left"], False),
    "internal-only": ("Switching to internal laptop screen only...", lambda: _script("display-manager.sh", "internal-only"),
                      "turn off external displays and use only laptop screen",
                      ["laptop screen only", "single screen", "disconnect display"], True),
    "gaming":        ("Toggling Gaming Mode via Quickshell...", lambda: _qs("island", "gaming"),
                      "toggle gaming mode (max performance, uncap refresh, suspend animations)",
                      ["game mode", "gaming mode", "gaming on", "gaming off"], False),
    "trim-memory":   ("Trimming Quickshell RAM and cleaning system caches...", lambda: apply_fixes(),
                      "free up RAM: trim Quickshell memory and sync caches",
                      ["trim memory", "clean ram", "free memory", "free ram", "flush cache"], True),
    "caffeine":      ("Toggling Caffeine mode...", lambda: _qs("island", "caffeine"),
                      "keep the screen awake and prevent sleep/lock",
                      ["caffeine", "stay awake", "keep awake"], False),
    "dnd":           ("Toggling Do Not Disturb...", lambda: _qs("island", "dnd"),
                      "silence desktop notifications",
                      ["do not disturb", "dnd", "mute notifications", "silence"], False),
    "wallpaper":     ("Cycling wallpaper...", lambda: _qs("wallpaper", "next"),
                      "switch to the next wallpaper",
                      ["next wallpaper", "change wallpaper", "random wallpaper"], False),
    "nightlight":    ("Toggling night light...", lambda: _script("toggle_nightlight.sh"),
                      "warmer screen colour / reduce blue light",
                      ["night light", "nightlight", "blue light", "warm screen"], False),
    "doctor":        ("Running system diagnostics doctor...", lambda: run_doctor(),
                      "run deep system diagnostics check and diagnose bottlenecks",
                      ["diagnose", "system check", "doctor", "health check", "scan system"], False),
    "recommend-model":("Opening Model Recommendations...", lambda: recommend_models(),
                      "recommend best local AI models for this hardware",
                      ["recommend model", "bigger model", "models", "what model"], False),
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

# ───────────────────────── Ollama LLM Interface ─────────────────────────

OLLAMA_URL = "http://127.0.0.1:11434/api/generate"
LAST_LLM_ERROR = ""
# The context window every Halcyon AI script asks for: Ollama loads the model again whenever it changes between two requests,
# so chat, agent, advisor, notes and the brief all use the same one (keep it equal in each of them).
NUM_CTX = 8192
KEEP_ALIVE = "30m"            # halcyon-chat.py sets 0 for a question asked while Gaming mode is on
# Gaming mode is on (scripts/gamemode.sh writes this file, and unloads the models): the GPU memory is the game's, so no model is
# loaded now. Only a regular file of ours counts: /dev/shm is writable by every local user.
GAMING_FLAG = "/dev/shm/halcyon-gamemode"

def gaming():
    try:
        st = os.lstat(GAMING_FLAG)
    except OSError:
        return False
    return (st.st_mode & 0o170000) == 0o100000 and st.st_uid == os.getuid()


def ollama_generate(prompt, schema=None, num_predict=320, temperature=0.2, stream=False, timeout=90):
    global LAST_LLM_ERROR
    LAST_LLM_ERROR = ""
    if gaming() and KEEP_ALIVE != 0:
        LAST_LLM_ERROR = "Gaming mode is on: the model is not loaded while a game needs the GPU memory."
        return None
    model = get_advisor_model()
    if "qwen3" in model:
        stream = False
    payload = {
        "model": model, "prompt": prompt, "stream": bool(stream),
        "keep_alive": KEEP_ALIVE,
        "options": {"num_predict": num_predict, "temperature": temperature, "num_ctx": NUM_CTX},
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
                    try: chunk = json.loads(raw.decode("utf-8"))
                    except Exception: continue
                    piece = chunk.get("response", "")
                    if piece:
                        out.append(piece)
                        print(piece, end="", flush=True)
                    if chunk.get("done"): break
                print()
                return "".join(out).strip() or None
            data = json.loads(r.read().decode("utf-8"))
            text = re.sub(r"<think>.*?</think>", "", data.get("response", ""), flags=re.DOTALL).strip()
            return text or None
    except urllib.error.HTTPError as e:
        if e.code == 404:
            LAST_LLM_ERROR = f"Model '{model}' is not installed. Run: advisor model switch {model}"
        else:
            LAST_LLM_ERROR = f"Ollama returned HTTP {e.code}."
    except urllib.error.URLError:
        LAST_LLM_ERROR = "Can't reach Ollama on 127.0.0.1:11434. Start it: systemctl --user start ollama"
    except Exception as e:
        LAST_LLM_ERROR = f"Model call failed: {e}"

    if not schema:
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

def llm_json(prompt, schema, num_predict=90):
    text = ollama_generate(prompt, schema=schema, num_predict=num_predict, temperature=0.0)
    if not text:
        return None
    try:
        return json.loads(text)
    except Exception:
        m = re.search(r"\{.*\}", text, flags=re.DOTALL)
        try: return json.loads(m.group(0)) if m else None
        except Exception: return None

def build_findings(analysis):
    m, g = analysis["memory"], analysis["gpu"]
    lines = [
        f"RAM: {m['used_mb']} of {m['total_mb']} MB used ({m['pct']}%), Swap {m['swap_used_mb']} MB",
        f"Quickshell {analysis['quickshell_mb']} MB, Hyprland {analysis['hyprland_mb']} MB",
        f"CPU temperature: avg {analysis['temps']['avg']}C, peak {analysis['temps']['max']}C",
    ]
    if g.get("present"):
        lines.append(f"GPU: {g['name']}, VRAM {g['vram_used_mb']}/{g['vram_total_mb']} MB, temp {g['temp_c']}C")
    if analysis["battery"]:
        lines.append(f"Battery: {analysis['battery']['capacity']}% ({analysis['battery']['status']})")
    lines.append(f"Health score: {analysis['score']}/100 ({analysis['rating']})")
    if analysis["failed_svcs"]:
        lines.append("Failed systemd units: " + ", ".join(
            f"{s[1]} ({s[0]}, {'harmless: ' + analysis['failed_info'][s[1]]['cause'][:90] if analysis.get('failed_info', {}).get(s[1], {}).get('benign') else 'needs attention'})"
            for s in analysis["failed_svcs"]))
    if analysis["zombies"]:
        lines.append(f"Zombie processes: {len(analysis['zombies'])}")
    top = sorted(analysis.get("procs") or [], key=lambda p: p["rss_mb"], reverse=True)[:5]
    if top:
        lines.append("Top memory consumers: " + "; ".join(f"{p['comm']} {p['rss_mb']}MB" for p in top))
    flagged = [s for s in analysis["suggestions"] if s["priority"] != "INFO"]
    if flagged:
        lines.append("Detected issues: " + "; ".join(f"[{s['priority']}] {s['title']} -> {s['action']}" for s in flagged))
    else:
        lines.append("Detected issues: none")
    return "\n".join(lines)

ADVISOR_RULES = (
    "You are the system assistant built into Halcyon, running on Arch Linux with Hyprland and Quickshell.\n"
    "Rules: Use the provided system snapshot. Be specific, accurate, and concise (under 5 sentences).\n"
    "Explain what is happening and specify the exact next command the user should run.\n"
    "If system changes are required, mention that Halcyon Advisor will ask for confirmation before modifying files or services."
)

def _self_module():
    m = sys.modules.get(__name__)
    if m is None:       # loaded by path (halcyon-chat.py does this) and not registered: hand the agent a module-like view
        import types
        m = types.ModuleType(__name__)
        m.__dict__.update(globals())
    return m

def load_agent():
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    for p in (os.path.join(RICE, "scripts/halcyon-agent.py"), os.path.join(here, "halcyon-agent.py")):
        if os.path.isfile(p):
            try:
                spec = importlib.util.spec_from_file_location("halcyon_agent", p)
                m = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(m)
                return m
            except Exception as e:
                print(f"[!] could not load the agent ({e})")
    return None

def run_agent_query(question, assume_yes=False):
    """Let the model investigate and act with tools.
    Returns None if the agent module is missing (caller falls back to plain Q&A), else True when an answer was given, False on an error."""
    ag = load_agent()
    if not ag:
        return None
    note = ag.small_model_note(get_advisor_model())
    if note:
        print(note + "\n")
    return ag.Agent(_self_module(), get_advisor_model, assume_yes=assume_yes).turn([], question) is not None

def run_llm_query(analysis, custom_prompt="", assume_yes=False):
    # a direct command ("gaming mode", "next wallpaper") runs at once; a question ("what is dnd?") goes to the model
    if custom_prompt and not looks_like_question(custom_prompt) and try_dispatch_keywords(custom_prompt):
        return True

    if custom_prompt:
        print("━" * 68)
        print("Halcyon AI Agent (Ollama)  ·  inspects and manages this machine; every change asks you first")
        print("━" * 68)
        print(f"[*] Model: {get_advisor_model()}\n")
        r = run_agent_query(custom_prompt, assume_yes)
        if r is not None:
            return r

    if not custom_prompt:
        print("━" * 68)
        print("Local AI Advisor (Ollama)")
        print("━" * 68)
        print(f"[*] Model: {get_advisor_model()}\n")

    findings = build_findings(analysis)
    if custom_prompt:
        prompt = f"{ADVISOR_RULES}\nLive Machine Snapshot:\n{findings}\n\nUser Question: {custom_prompt}\nAnswer:"
    else:
        prompt = (f"{ADVISOR_RULES}\nLive Machine Snapshot:\n{findings}\n\n"
                  "Task: in 2-3 concise sentences summarize machine health, pinpoint any bottlenecks, and recommend the best next action.\nAnswer:")
    if ollama_generate(prompt, stream=True) is None and LAST_LLM_ERROR:
        print(f"[!] {LAST_LLM_ERROR}\n    Standard rule-based metrics below still apply.")
    return False

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
        f'Notification: "{text}" ->'
    )
    res = llm_json(prompt, schema, num_predict=70)
    if not res:
        print(f"[!] {LAST_LLM_ERROR or 'No usable answer from the model.'}")
        return
    icon = {"urgent": "", "chat": "", "system": "", "promo": ""}.get(res.get("category"), "•")
    print(f"{icon} [{res.get('category')}] {res.get('one_line')}")

def write_short(request):
    if not request.strip():
        print('Usage: advisor write "short request"')
        return
    prompt = ("Write exactly what is asked, under 60 words, natural and friendly. "
              "Output only the text itself, no preamble.\n\n"
              f"Request: {request}\nText:")
    if ollama_generate(prompt, num_predict=140, temperature=0.7, stream=True) is None:
        print(f"[!] {LAST_LLM_ERROR}")

# ───────────────────────── CLI Entrypoint ─────────────────────────


# ───────────────────────── Leak watch: record -> analyse (script) -> explain (LLM) ─────────────────────────

def _leaks_module():
    """scripts/halcyon-leaks.py (the arithmetic lives there, so the model never has to do it)."""
    import importlib.util
    for base in (os.path.join(RICE, "scripts"), os.path.dirname(os.path.abspath(__file__))):
        p = os.path.join(base, "halcyon-leaks.py")
        if os.path.isfile(p):
            spec = importlib.util.spec_from_file_location("halcyon_leaks", p)
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            return m
    return None

def island_log_near(t_from, t_to, limit=12):
    """Lines of the island log that mention a clock time (HH:MM) inside [t_from, t_to] (best effort: depends on the log's own timestamps)."""
    if not os.path.isfile(ISLAND_LOG):
        return []
    mins = set()
    t = int(t_from) - 60
    while t <= int(t_to) + 60:
        mins.add(time.strftime("%H:%M", time.localtime(t)))
        t += 30
    hits = []
    try:
        with open(ISLAND_LOG, errors="ignore") as f:
            for line in f:
                if any((m + ":") in line for m in mins):
                    hits.append(line.rstrip()[:220])
    except Exception:
        pass
    return hits[-limit:]

def leak_context(res):
    """Island-log lines around every memory jump in an analysis result."""
    out = []
    for f in res.get("findings", []):
        if f.get("kind") == "step" and f.get("t_from"):
            out += island_log_near(f["t_from"], f["t_to"])
    return out

def leaks_command(args, assume_yes=False):
    mod = _leaks_module()
    if mod is None:
        print("halcyon-leaks.py is missing from the Halcyon scripts folder.")
        return
    use_llm = "--no-llm" not in args
    want_json = "--json" in args
    args = [a for a in args if not a.startswith("--")]
    log = mod.DEFAULT_LOG
    if args and args[0] in ("watch", "record", "run"):
        mins = args[1] if len(args) > 1 and args[1].isdigit() else "30"
        every = args[2] if len(args) > 2 and args[2].isdigit() else "60"
        script = os.path.join(RICE, "scripts", "halcyon-leak-watch.sh")
        if not os.path.isfile(script):
            script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "halcyon-leak-watch.sh")
        print(f"Recording {mins} min, one sample every {every} s. Leave the desktop alone until it finishes (Ctrl+C stops it and keeps the samples).")
        try:
            subprocess.run(["bash", script, mins, every])
        except KeyboardInterrupt:
            print("\nstopped early: analysing what was recorded.")
    elif args:
        log = os.path.expanduser(args[0])

    res = mod.analyze(log)
    if want_json:
        print(json.dumps(res, indent=1))
        return
    report = mod.render(res)
    print(report)
    if "error" in res:
        return
    ctx = leak_context(res)
    if ctx:
        print("\nisland log around the jump:")
        for l in ctx:
            print("  " + l)
    if not use_llm:
        return
    if res["verdict"] == "clean":
        return          # nothing to explain: the script's verdict is the answer
    print("\n── what it means ──")
    prompt = (
        "You review a memory-leak watch of a Linux desktop (Hyprland + the Quickshell 'island' shell + Rust helpers named hx, cava, hal). "
        "The numbers below were computed by a script and are CORRECT: never recompute them and never invent others.\n"
        "Say in plain words, per LEAK / JUMP line: what the pattern means (a steady leak, a one-off jump that was never given back, a "
        "repeating step, a clone, a zombie) and the most likely cause for THAT program (quickshell = QML/JS heap, images and windows loaded on demand; "
        "cava = audio visualiser). Then give at most 3 concrete next steps as shell commands. Be short: no preamble, no headings.\n\n"
        f"REPORT:\n{report}\n"
        + (f"\nISLAND LOG AROUND THE JUMP:\n" + "\n".join(ctx) + "\n" if ctx else "")
    )
    if ollama_generate(prompt, num_predict=380, temperature=0.2, stream=True, timeout=120) is None and LAST_LLM_ERROR:
        print(LAST_LLM_ERROR + " (the report above stands on its own)")

# Master AI switch (Settings > Performance > AI features): while ~/.local/state/island/ai-off exists no model is asked anything.
AI_OFF_FLAG = os.path.join(os.path.expanduser("~"), ".local", "state", "island", "ai-off")
AI_OFF_MSG = "The AI is switched off. Turn it back on in Settings > Performance > AI features (or: python3 ~/.config/Halcyon/scripts/ai-models.py master on)."

def ai_enabled():
    return not os.path.exists(AI_OFF_FLAG)


def main():
    args = sys.argv[1:]

    assume_yes = "--yes" in args or "-y" in args

    if args and args[0] in ("model", "models"):
        model_command(args[1:])
        return
    if args and args[0] in ("doctor", "diagnose", "--diag"):
        run_doctor(assume_yes=assume_yes)
        return
    if args and args[0] in ("fix", "--fix", "-f"):
        apply_fixes(assume_yes=assume_yes)
        return
    if args and args[0] in ("leaks", "leak"):
        leaks_command(args[1:], assume_yes=assume_yes)
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

    custom_question = ""
    use_llm = "--llm" in args

    for a in args:
        if a not in ("--llm", "--fix", "-f", "--yes", "-y") and not a.startswith("-"):
            custom_question = a
            use_llm = True
            break

    if use_llm and not ai_enabled():
        print(AI_OFF_MSG)
        if custom_question:
            return                  # a question needs the model: there is nothing else to show for it
        print()
        use_llm = False             # `advisor --llm`: the normal (rule-based) dashboard below still works

    analysis = analyze_system()

    if use_llm:
        handled = run_llm_query(analysis, custom_question, assume_yes)
        print()
        if custom_question and handled:
            return          # the agent may just have changed the machine: a dashboard from before that would be stale

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
    if analysis["failed_svcs"]:
        print(f"• \033[1;31mFailed Services:\033[0m {len(analysis['failed_svcs'])} unit(s) need attention")
    print("─" * 68)

    if analysis["suggestions"]:
        print("Tailored Recommendations:")
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
        print("✔ System is operating in peak condition. No bottlenecks detected.")

    print("─" * 68)
    print("Commands:")
    print("  advisor doctor            -> Autonomous diagnostics with confirmed fixes")
    print("  advisor fix               -> Apply recommended system optimizations")
    print("  advisor leaks             -> Analyse the last leak-watch: leaks, one-off jumps, zombies, clones (LLM explains)")
    print("  advisor leaks watch 30 60 -> Record a new 30-minute leak-watch (sample every 60 s), then analyse it")
    print("  advisor model recommend   -> Hardware-tailored advice for bigger AI models")
    print("  advisor model switch <m>  -> Download and activate a local AI model")
    print("  advisor \"<question>\"     -> Ask the local AI: it inspects the machine and can fix things (asks before every change)")
    print("  advisor \"restart bluetooth and check why it failed\"   -> example of a task it can carry out")
    print("  ai                        -> Interactive AI chat with the same tools (/tools lists them)")

if __name__ == "__main__":
    main()
