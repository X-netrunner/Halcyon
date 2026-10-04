#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import time

LOG_FILE = "/home/netrunner/logs/recon-attempts.log"
ALERT_LOG = "/home/netrunner/logs/ids-alerts.log"

# Strict, pre-compiled regex signatures matching standard tooling footprints
SIGNATURES = {
    "Metasploit / Automated Login Scan": re.compile(r"CREDENTIALS HARVESTED.*(Username|USER)=(admin|root|1234)", re.IGNORECASE),
    "Directory Brute Force Attempt": re.compile(r"Directory brute-force detected|GET /(wp-admin|admin|config|backup|shell|phpmyadmin|\.env)", re.IGNORECASE),
    "Automated SSH Scanner Footprint": re.compile(r"\[PAYLOAD\] SSH packet.*(libssh|Paramiko|Go-SSH)", re.IGNORECASE),
    "SQL Injection Probing Pattern": re.compile(r"(' OR '1'='1|UNION SELECT|SELECT.*FROM|waitfor delay)", re.IGNORECASE),
    "Cross-Site Scripting Probe": re.compile(r"(<script>|alert\(|javascript:)", re.IGNORECASE),
}


def get_user_desktop_env():
    env = {"DISPLAY": ":0", "XDG_RUNTIME_DIR": "/run/user/1000"}
    try:
        pids = [pid for pid in os.listdir("/proc") if pid.isdigit()]
        for pid in pids:
            try:
                stat_info = os.stat(f"/proc/{pid}")
                if stat_info.st_uid == 1000:
                    with open(f"/proc/{pid}/environ", "rb") as f:
                        environ_data = f.read()
                    environ = {}
                    for item in environ_data.split(b"\x00"):
                        if b"=" in item:
                            parts = item.split(b"=", 1)
                            environ[parts[0].decode("utf-8", errors="ignore")] = parts[
                                1
                            ].decode("utf-8", errors="ignore")

                    if "WAYLAND_DISPLAY" in environ or "DISPLAY" in environ:
                        for k in [
                            "DISPLAY",
                            "WAYLAND_DISPLAY",
                            "XDG_RUNTIME_DIR",
                            "DBUS_SESSION_BUS_ADDRESS",
                        ]:
                            if k in environ:
                                env[k] = environ[k]
                        return env
            except Exception:
                continue
    except Exception:
        pass
    return env


def run_notify_send(title, message, urgency="normal", icon="dialog-information"):
    desktop_env = get_user_desktop_env()
    dbus = desktop_env.get("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/user/1000/bus")
    display = desktop_env.get("DISPLAY", ":0")
    wayland = desktop_env.get("WAYLAND_DISPLAY", "")
    xdg = desktop_env.get("XDG_RUNTIME_DIR", "/run/user/1000")

    cmd = [
        "sudo",
        "-u",
        "netrunner",
        "env",
        f"DBUS_SESSION_BUS_ADDRESS={dbus}",
        f"DISPLAY={display}",
        f"XDG_RUNTIME_DIR={xdg}",
    ]
    if wayland:
        cmd.append(f"WAYLAND_DISPLAY={wayland}")

    cmd.extend([
        "notify-send",
        "-u",
        urgency,
        "-i",
        icon,
        title,
        message,
    ])
    try:
        subprocess.Popen(
            cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    except Exception:
        pass


def log_alert(signature_name, raw_log):
    try:
        os.makedirs(os.path.dirname(ALERT_LOG), exist_ok=True)
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(ALERT_LOG, "a") as f:
            f.write(f"[{timestamp}] [CRITICAL ALERT] Match Found: {signature_name}\n")
            f.write(f"    Raw Log Entry: {raw_log}\n\n")

        # Trigger desktop notification
        run_notify_send(
            "IDS Attack Detected",
            f"Signature: {signature_name}\nLog: {raw_log[:100]}...",
            "critical",
            "security-high"
        )
    except Exception:
        pass


def scan_line(line):
    for sig_name, regex in SIGNATURES.items():
        if regex.search(line):
            log_alert(sig_name, line.strip())


def main():
    if not os.path.exists(LOG_FILE):
        print(f"[!] Target log file {LOG_FILE} does not exist yet. Waiting for initialization...")
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        open(LOG_FILE, "a").close()

    print("[*] Lightweight Signature-Matching IDS Daemon Active (RAM safe)...")
    
    while True:
        try:
            with open(LOG_FILE, "r") as f:
                current_ino = os.fstat(f.fileno()).st_ino
                f.seek(0, os.SEEK_END)
                
                while True:
                    line = f.readline()
                    if not line:
                        time.sleep(1)
                        # Check if file was rotated or truncated
                        if os.path.exists(LOG_FILE):
                            try:
                                new_st = os.stat(LOG_FILE)
                                if new_st.st_ino != current_ino or new_st.st_size < f.tell():
                                    break  # Re-open file
                            except OSError:
                                pass
                        continue
                    
                    scan_line(line)
        except Exception as e:
            time.sleep(2)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
