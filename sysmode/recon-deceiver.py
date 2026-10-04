#!/usr/bin/env python3
import gzip
import io
import os
import random
import tarfile
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.parse

PERSONA_FILE = "/etc/sysmode.persona"

def get_active_persona():
    if os.path.isfile(PERSONA_FILE):
        try:
            with open(PERSONA_FILE, "r") as f:
                p = f.read().strip().lower()
                if p in ("cisco", "synology", "ubuntu"):
                    return p
        except Exception:
            pass
    return "ubuntu"

def get_port_banner(port):
    persona = get_active_persona()
    host = socket.gethostname()
    if persona == "cisco":
        banners = {
            21: b"220 Cisco FTP Server (Version 1.1) ready.\r\n",
            22: b"SSH-2.0-Cisco-1.25\r\n",
            23: f"\r\nUser Access Verification\r\n\r\n{host}> ".encode(),
            80: b"HTTP/1.1 200 OK\r\nServer: cisco-IOS\r\n\r\n",
            25: f"220 {host} ESMTP Postfix (Cisco)\r\n".encode(),
            8080: b"HTTP/1.1 200 OK\r\nServer: cisco-IOS\r\nConnection: close\r\n\r\n<html><head><title>Cisco Systems Access</title></head><body><h1>Cisco IOS Web Console</h1></body></html>\r\n",
        }
    elif persona == "synology":
        banners = {
            21: b"220 Synology FTP Server ready.\r\n",
            22: b"SSH-2.0-OpenSSH_8.2p1 Synology-DSM\r\n",
            23: f"\r\nSynology DiskStation\r\n{host} login: ".encode(),
            80: b"HTTP/1.1 200 OK\r\nServer: Synology-DSM/7.1\r\n\r\n",
            25: f"220 {host} ESMTP Synology MailPlus\r\n".encode(),
            8080: b"HTTP/1.1 200 OK\r\nServer: Synology-DSM/7.1\r\nConnection: close\r\n\r\n<html><head><title>Synology DSM</title></head><body><h1>DiskStation Manager</h1></body></html>\r\n",
        }
    else:
        banners = {
            21: b"220 ProFTPD 1.3.5 Server (Ubuntu)\r\n",
            22: b"SSH-2.0-OpenSSH_6.6.1p1 Ubuntu-2ubuntu2\r\n",
            23: f"\r\nUbuntu 14.04.5 LTS\r\n\r\n{host} login: ".encode(),
            80: b"HTTP/1.1 200 OK\r\nServer: Apache/2.4.7 (Ubuntu)\r\n\r\n",
            25: f"220 {host} ESMTP Postfix (Ubuntu)\r\n".encode(),
            8080: b"HTTP/1.1 200 OK\r\nServer: nginx/1.18.0 (Ubuntu)\r\nConnection: close\r\n\r\n<html><body><h1>It works!</h1></body></html>\r\n",
        }
    if port in banners:
        return banners[port]
    return PORTS.get(port, b"")

# Ports to spoof with fake vulnerable service banners (aligned to dynamic hostname)
PORTS = {
    21: b"220 ProFTPD 1.3.5 Server (Ubuntu)\r\n",
    22: b"SSH-2.0-OpenSSH_6.6.1p1 Ubuntu-2ubuntu2\r\n",
    23: f"\r\nUbuntu 14.04.5 LTS\r\n\r\n{socket.gethostname()} login: ".encode(),
    80: b"HTTP/1.1 200 OK\r\nServer: Apache/2.4.7 (Ubuntu)\r\n",
    445: b"\x00\x00\x00\x55\xff\x53\x4d\x42\x72\x00\x00\x00\x00\x18\x01\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xe0\x1f\x00\x00\x00\x00\x01\x00\x03\x00\x01\x00\x10\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\xfd\xe3\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x4c\x4d\x31\x2e\x32\x00",
    25: f"220 {socket.gethostname()} ESMTP Postfix (Ubuntu)\r\n".encode(),
    3306: (b"\x0a"
           b"5.5.54-log\x00"
           b"\x09\x9a\x00\x00"
           b"\x2a\x4a\x36\x75\x4a\x3f\x5a\x34\x00"
           b"\xff\xff\x21\x02\x00\xff\x7f\x15"
           b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
           b"\x32\x4e\x33\x79\x2b\x49\x35\x6f\x54\x77\x4e\x72\x00"
           b"mysql_native_password\x00"),
    3389: b"\x03\x00\x00\x13\x0e\xe0\x00\x00\x00\x00\x00\x01\x00\x08\x00\x03\x00\x00\x00",
    8080: b"HTTP/1.1 200 OK\r\nServer: nginx/1.18.0 (Ubuntu)\r\nConnection: close\r\n\r\n<html><body><h1>It works!</h1></body></html>\r\n",
}

LOG_FILE = "/home/netrunner/logs/recon-attempts.log"

# When this marker file exists, port 22 is served by the Cowrie SSH honeypot
# container instead of the banner tarpit. sysmode creates/removes it, and the
# decoy skips binding 22 so Cowrie can own the port.
COWRIE_ACTIVE_FILE = "/run/cowrie.active"

# Webshell uploads mapping (filename -> source file path)
UPLOADED_WEBSHELLS = {}
WEBSHELL_LOCK = threading.Lock()
NOTIFICATION_LOCK = threading.Lock()
LAST_NOTIFICATION_TIME = {}
BANNED_IPS = set()
BAN_LOCK = threading.Lock()
TRACKER_LOCK = threading.Lock()
FIRST_SEEN_TRACKER = {}

TIME_LIMIT_BEFORE_BAN = 120

# --- Randomized telnet credential (generated once at daemon start) ---
# A real telnetd has a fixed account, so we bake one random-looking pair
# for the whole daemon run rather than accepting Enter/Enter like before.
TELNET_CRED_FILE = "/home/netrunner/logs/honeypot-credentials.txt"
TELNET_USERNAMES = [
    "ubuntu", "admin", "root", "backup", "deploy", "webadmin", "sysadmin",
    "support", "operator", "user", "test", "postgres", "mysql", "git",
    "ftp", "nobody", "guest", "default", "server", "office",
]
TELNET_PASSWORD_WORDS = [
    "Summer", "Winter", "Spring", "Autumn", "Shadow", "Dragon", "Monkey",
    "Tiger", "Eagle", "Wolf", "Delta", "Matrix", "Quantum", "Solar", "Nova",
    "Phantom", "Falcon", "Coffee", "Mango", "Bluebird", "Chocolate",
    "Welcome", "Letmein", "Admin", "Server", "Linux", "Backup", "Secure",
    "Temp", "Guest", "Test", "Sunshine", "Thunder", "Fire", "Ice", "Star",
]


def generate_telnet_credential():
    username = random.choice(TELNET_USERNAMES)
    if random.random() < 0.45:
        username += str(random.randint(1, 99))
    word = random.choice(TELNET_PASSWORD_WORDS)
    year = random.choice(["2024", "2025", "2026"])
    suffix = random.choice(["", "", "1", "2", "123", "!", "@", "#", "!", "123", "456"])
    password = word + year + suffix
    return username, password


TELNET_USERNAME, TELNET_PASSWORD = generate_telnet_credential()


def write_telnet_credential_file():
    try:
        os.makedirs(os.path.dirname(TELNET_CRED_FILE), exist_ok=True)
        with open(TELNET_CRED_FILE, "w") as f:
            f.write(
                "Decoy telnet credential (generated at daemon start)\n"
                f"Username: {TELNET_USERNAME}\n"
                f"Password: {TELNET_PASSWORD}\n"
            )
        os.chmod(TELNET_CRED_FILE, 0o600)
    except Exception:
        pass


def log_event(message):
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}\n")
    except Exception:
        pass


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
    title = title.replace("\x00", "")
    message = message.replace("\x00", "")
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
    except Exception as e:
        log_event(f"[ERROR] Failed to run notify-send: {e}")


def send_notification(ip, port_info):
    current_time = time.time()
    with NOTIFICATION_LOCK:
        last_time = LAST_NOTIFICATION_TIME.get(ip, 0)
        if current_time - last_time < 10:
            return
        LAST_NOTIFICATION_TIME[ip] = current_time

    run_notify_send(
        "Recon Alert",
        f"Host {ip} is probing decoy ports (Port {port_info})",
        "critical",
        "security-medium"
    )


def send_credential_notification(ip, service, username, password):
    run_notify_send(
        "Credential Harvested",
        f"Host {ip} entered credentials on {service}!\nUser: {username}\nPass: {password}",
        "critical",
        "security-high"
    )


def send_ban_notification(ip):
    run_notify_send(
        "Active Defense Lockout",
        f"Banned host {ip} for 10 minutes in UFW firewall",
        "normal",
        "security-low"
    )


def ban_ip(ip):
    if ip in ("127.0.0.1", "localhost", "::1"):
        return

    with TRACKER_LOCK:
        first_seen = FIRST_SEEN_TRACKER.get(ip)
        if not first_seen:
            return

        elapsed = time.time() - first_seen
        # If they are still within the illusion window, let them keep playing
        if elapsed < TIME_LIMIT_BEFORE_BAN:
            return

    with BAN_LOCK:
        if ip in BANNED_IPS:
            return
        BANNED_IPS.add(ip)

    log_event(f"[ALERT] Tarpit time limit reached. Banning IP {ip} for 10 minutes...")
    send_ban_notification(ip)
    try:
        subprocess.run(
            [
                "ufw",
                "insert",
                "1",
                "deny",
                "from",
                ip,
                "to",
                "any",
                "comment",
                "recon-deceiver-ban",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        threading.Thread(target=unban_ip_later, args=(ip,), daemon=True).start()
    except Exception as e:
        log_event(f"[ERROR] Failed to ban IP {ip}: {e}")


def unban_ip_later(ip):
    time.sleep(600)
    log_event(f"[INFO] Unbanning IP {ip}...")
    try:
        subprocess.run(
            [
                "ufw",
                "delete",
                "deny",
                "from",
                ip,
                "to",
                "any",
                "comment",
                "recon-deceiver-ban",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        log_event(f"[ERROR] Failed to unban IP {ip}: {e}")
    finally:
        with BAN_LOCK:
            BANNED_IPS.discard(ip)


# --- Automated counter-scan of attackers (active defense) ---
# When an attacker connects to (or DNS-probes) the decoy, automatically
# profile them back with nmap and log the results for later review.
SCAN_LOG_FILE = "/home/netrunner/logs/attacker-scans.log"
LAST_SCAN_TIME = {}
SCAN_COOLDOWN = 300  # seconds; never scan the same IP more often than this


def get_local_ips():
    ips = {"127.0.0.1", "::1"}
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            ips.add(s.getsockname()[0])
        except Exception:
            pass
        finally:
            s.close()
    except Exception:
        pass
    return ips


def _skip_scan_target(ip):
    if ip in get_local_ips():
        return True
    try:
        parts = ip.split(".")
        if len(parts) != 4:
            return True
        a = int(parts[0])
        if a == 0 or a >= 224:  # 0/8, multicast, reserved broadcast
            return True
        if a == 169 and int(parts[1]) == 254:  # link-local
            return True
    except Exception:
        return True
    return False


def scan_attacker(ip):
    now = time.time()
    with TRACKER_LOCK:
        last = LAST_SCAN_TIME.get(ip, 0)
        if now - last < SCAN_COOLDOWN:
            return
        LAST_SCAN_TIME[ip] = now

    if _skip_scan_target(ip):
        return
    if not shutil.which("nmap"):
        return

    def _run():
        cmd = [
            "nmap", "-Pn", "-sS", "-sV", "--version-light", "-O",
            "--top-ports", "100", "--max-retries", "1",
            "--host-timeout", "120s", "-oN", "-", ip,
        ]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=150)
            out = proc.stdout
        except Exception as e:
            log_event(f"[COUNTER-SCAN] nmap failed against {ip}: {e}")
            return
        try:
            os.makedirs(os.path.dirname(SCAN_LOG_FILE), exist_ok=True)
            with open(SCAN_LOG_FILE, "a") as f:
                f.write(
                    f"\n===== COUNTER-SCAN {ip} at {time.strftime('%Y-%m-%d %H:%M:%S')} =====\n"
                )
                f.write(out)
        except Exception:
            pass
        open_ports = []
        os_match = "n/a"
        for ln in out.splitlines():
            if "/tcp" in ln and "open" in ln:
                open_ports.append(ln.split()[0])
            if ln.startswith("OS details") or ln.startswith("OS guesses"):
                os_match = ln
        log_event(
            f"[COUNTER-SCAN] {ip}: open ports={','.join(open_ports) or 'none'} os={os_match}"
        )

    threading.Thread(target=_run, daemon=True).start()


# High-Interaction service emulators with Tarpit mechanics


TELNET_IAC = b"\xff"
TELNET_WILL = b"\xfb"
TELNET_DO = b"\xfd"
TELNET_OPT_ECHO = b"\x01"
TELNET_OPT_SUPPRESS_GA = b"\x03"
TELNET_OPT_TERMTYPE = b"\x18"


PROBE_HEADER_PATTERN = re.compile(
    r"(SIP/2\.0|HTTP/1\.[01]|^(GET|POST|OPTIONS|HEAD|PROPFIND)\s|"
    r"^(Via|Call-ID|CSeq|Max-Forwards|Contact|User-Agent|From|To):)",
    re.IGNORECASE,
)

# Paths that indicate an actual scan/probe (sensitive files, CMS/admin
# panels, secrets, common vuln-scanner targets) — distinct from ordinary
# HTTP verbs, which every ordinary request also carries and shouldn't be
# treated as evidence of brute-forcing on their own.
SUSPICIOUS_PATH_PATTERN = re.compile(
    r"(wp-admin|wp-login|wp-content|phpmyadmin|\.env|\.git/|\.aws/|\.ssh/|"
    r"config\.php|config\.json|backup|shell|etc/passwd|\.sql$|\.bak$|"
    r"xmlrpc\.php|server-status|actuator|\.well-known/security|"
    r"credentials|secrets|id_rsa|\.htpasswd)",
    re.IGNORECASE,
)


def looks_like_protocol_probe(text):
    """Distinguish a human typing at a login prompt from a scanner
    probe (SIP/HTTP/TLS/etc.) landing on the wrong port. Real telnetd
    never executes or echoes back this kind of payload pre-auth, so
    treating it as valid input is a strong honeypot fingerprint."""
    if not text:
        return False
    if PROBE_HEADER_PATTERN.search(text):
        return True
    # Scanner payloads often carry a lot of non-printable/binary bytes;
    # a human at a keyboard basically never does.
    printable = sum(1 for c in text if c.isprintable())
    if len(text) > 4 and (printable / len(text)) < 0.85:
        return True
    return False


def telnet_negotiate(client_socket):
    """Send the option-negotiation handshake a real telnetd issues before
    its banner, then drain the client's IAC replies. Without this, nmap
    receives raw text with no IAC bytes at all and can't confirm the
    service as telnet (shows up as 'telnet?')."""
    try:
        client_socket.sendall(
            TELNET_IAC + TELNET_WILL + TELNET_OPT_ECHO
            + TELNET_IAC + TELNET_WILL + TELNET_OPT_SUPPRESS_GA
            + TELNET_IAC + TELNET_DO + TELNET_OPT_TERMTYPE
        )
        client_socket.settimeout(0.5)
        try:
            while True:
                chunk = client_socket.recv(64)
                if not chunk or TELNET_IAC not in chunk:
                    break
        except socket.timeout:
            pass
    except Exception:
        pass


def telnet_readline(client_socket):
    buf = b""
    while True:
        try:
            char = client_socket.recv(1)
            if not char:
                break
            if char == b"\xff":
                # Telnet negotiation command: skip next 2 bytes
                client_socket.recv(2)
                continue
            if char in (b"\r", b"\n"):
                # Real NVT telnet sends CR LF or CR NUL for Enter, but
                # many clients in character-at-a-time mode send a bare
                # CR or bare LF instead. Whichever arrives first ends
                # the line; best-effort drain a single pairing byte
                # (NUL/LF/CR) so it doesn't leak into the next line.
                try:
                    client_socket.settimeout(0.05)
                    pair = client_socket.recv(1)
                    if pair and pair not in (b"\n", b"\r", b"\x00"):
                        # Not a pairing byte — extremely unlikely, but
                        # we can't push it back onto the socket. Accept
                        # the edge case rather than block indefinitely.
                        pass
                except socket.timeout:
                    pass
                finally:
                    client_socket.settimeout(60.0)
                break
            # Handle backspace
            if char in (b"\x08", b"\x7f"):
                if len(buf) > 0:
                    buf = buf[:-1]
                continue
            buf += char
            if len(buf) > 500:
                break
        except socket.timeout:
            break
        except Exception:
            break
    return buf.decode("utf-8", errors="ignore").strip()


def execute_mock_command(cmd):
    cmd = cmd.strip()
    if not cmd:
        return ""

    # Strip quotes or basic shell syntax if attackers wrap them
    cmd_clean = cmd.replace("'", "").replace('"', "")
    parts = cmd_clean.split()
    base_cmd = parts[0] if parts else ""

    if base_cmd == "whoami":
        return "www-data\n"
    elif base_cmd == "id":
        return "uid=33(www-data) gid=33(www-data) groups=33(www-data)\n"
    elif base_cmd == "uname" or (base_cmd == "uname" and len(parts) > 1 and parts[1] == "-a"):
        return f"Linux {socket.gethostname()} 4.15.0-142-generic #146-Ubuntu SMP Tue Apr 13 01:11:19 UTC 2021 x86_64 GNU/Linux\n"
    elif base_cmd == "pwd":
        return "/var/www/html\n"
    elif base_cmd == "ls":
        return (
            "total 16\n"
            "drwxr-xr-x 2 www-data www-data 4096 Jul  9 12:00 .\n"
            "drwxr-xr-x 3 root     root     4096 Jul  9 11:30 ..\n"
            "-rw-r--r-- 1 www-data www-data  230 Jul  9 12:00 backdoor.php\n"
            "-rw-r--r-- 1 root     root     1024 Jul  9 11:30 index.php\n"
        )
    elif "passwd" in cmd_clean:
        return (
            "root:x:0:0:root:/root:/bin/bash\n"
            "daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n"
            "bin:x:2:2:bin:/bin:/usr/sbin/nologin\n"
            "sys:x:3:3:sys:/dev:/usr/sbin/nologin\n"
            "sync:x:4:65534:sync:/bin:/bin/sync\n"
            "www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin\n"
            "sys_admin:x:1001:1001:System Administrator:/home/sys_admin:/bin/bash\n"
        )
    elif "shadow" in cmd_clean:
        return "cat: /etc/shadow: Permission denied\n"
    elif "config.php" in cmd_clean or "config" in cmd_clean:
        return (
            "<?php\n"
            "// Ubuntu System database configuration\n"
            "define('DB_HOST', 'localhost');\n"
            "define('DB_USER', 'sys_admin');\n"
            "define('DB_PASS', 'UB_Admin_P@ss_2026_Secure');\n"
            "define('DB_NAME', 'system_config');\n"
            "?>\n"
        )
    elif base_cmd in ("env", "printenv"):
        return (
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n"
            "PWD=/var/www/html\n"
            "USER=www-data\n"
            "HOME=/var/www\n"
            "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n"
            "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n"
        )
    else:
        return f"sh: 1: {base_cmd}: Permission denied or command not found\n"


# --- Interactive telnet "sandbox": a small stateful fake filesystem so a
# telnet session behaves like a real shell (cd/pwd/ls persist correctly)
# instead of every command being answered from a flat, stateless keyword
# table. Nothing here touches the real filesystem or runs real commands.

SANDBOX_HOME = "/home/ubuntu"

SANDBOX_FS = {
    "/": ["bin", "boot", "dev", "etc", "home", "lib", "media", "mnt", "opt",
          "proc", "root", "run", "sbin", "srv", "sys", "tmp", "usr", "var"],
    "/root": [],
    "/tmp": [],
    "/home": ["ubuntu", "sys_admin"],
    "/home/ubuntu": [".bash_history", ".ssh", ".bashrc", ".profile"],
    "/home/ubuntu/.ssh": ["authorized_keys"],
    "/home/sys_admin": [".bash_history", ".ssh", "backup.tar.gz", "notes.txt"],
    "/home/sys_admin/.ssh": ["id_rsa", "id_rsa.pub", "authorized_keys"],
    "/etc": ["passwd", "shadow", "hostname", "hosts", "crontab", "resolv.conf"],
    "/var": ["www", "log", "backups"],
    "/var/www": ["html"],
    "/var/www/html": ["index.php", "config.php", "backdoor.php", "uploads"],
    "/var/www/html/uploads": [],
    "/var/backups": ["db_dump_2026-06-30.sql.gz"],
    "/var/log": ["auth.log", "syslog"],
}

# Bait content returned by `cat`. Planted here specifically to see what an
# attacker does with harvested-looking secrets (e.g. do they try to reuse
# this key elsewhere) — none of it is a real, working credential.
SANDBOX_FILES = {
    "/etc/passwd": (
        "root:x:0:0:root:/root:/bin/bash\n"
        "daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n"
        "bin:x:2:2:bin:/bin:/usr/sbin/nologin\n"
        "sys:x:3:3:sys:/dev:/usr/sbin/nologin\n"
        "sync:x:4:65534:sync:/bin:/bin/sync\n"
        "www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin\n"
        "ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash\n"
        "sys_admin:x:1001:1001:System Administrator:/home/sys_admin:/bin/bash\n"
    ),
    "/etc/hostname": f"{socket.gethostname()}\n",
    "/etc/hosts": f"127.0.0.1\tlocalhost\n127.0.1.1\t{socket.gethostname()}\n",
    "/etc/resolv.conf": "nameserver 8.8.8.8\nnameserver 1.1.1.1\n",
    "/etc/crontab": "0 3 * * * root /usr/local/bin/backup.sh\n",
    "/var/www/html/config.php": (
        "<?php\n"
        "// Ubuntu System database configuration\n"
        "define('DB_HOST', 'localhost');\n"
        "define('DB_USER', 'sys_admin');\n"
        "define('DB_PASS', 'UB_Admin_P@ss_2026_Secure');\n"
        "define('DB_NAME', 'system_config');\n"
        "?>\n"
    ),
    "/home/ubuntu/.bash_history": (
        "sudo apt update\nls -la\ncd /var/www/html\nnano config.php\n"
        "sudo systemctl restart apache2\nexit\n"
    ),
    "/home/sys_admin/.bash_history": (
        "ls -la\ncat /etc/passwd\nmysql -u root -p'UB_Admin_P@ss_2026_Secure' system_config\n"
        "scp backup.tar.gz admin@10.0.0.5:/backups/\nsudo systemctl restart apache2\nhistory -c\n"
    ),
    "/home/sys_admin/notes.txt": (
        "TODO: rotate the db password again, last one leaked in a config commit\n"
        "TODO: patch ProFTPD, saw a CVE mentioned on a forum\n"
        "reminder: backup cron runs 0300 daily to /var/backups\n"
    ),
    "/home/sys_admin/.ssh/id_rsa.pub": (
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7k2Jd8pQmXz1RfN0v3aLd9wYp2Tn4"
        "Qm8Vb6Hs5Ej0Rk3Wc7Lp1Nx9Ad4Vt2Bq8Ym6Zf3Cw0Xr7Ku5Hb1Sd6Jn9Pe4Tv2Ol"
        "8Gm3Qz sys_admin@ubuntu-server\n"
    ),
    "/home/sys_admin/.ssh/id_rsa": (
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABlwAAAAdzc2gtcn\n"
        "NhAAAAAwEAAQAAAYEA1qk4Pfy8Bx0uW3Zj9Nr2Ld6QpAmYt7Vb2Sc5Hn8Fk3Wr0Cx4Bt\n"
        "9Ym2Ql6Zj3Rf7Vn1Dw8Ep5Ct0Gr4Ky9Lu2Bx6Sm3Fq1Nd8Th5Wj0Az7Cv4Ro2Ye9Ku6\n"
        "Ip1Bn3Sd8Fw2Cl5Xt0Rm7Vh4Yq9Gj6Nk1Bp3Ea8Wo5Uc2Fz7Lr0Tv4Xd9Ym1Sn6Qi3Kh\n"
        "8Bt5Ce0Ao2Uj7Fw4Ry9Nv1Xd6Ql3Sm8Bh0Kt5Ei2Wc7Fo4Ur9Lp1Yn6Gj3Zx0Vb8Dm5\n"
        "-----END OPENSSH PRIVATE KEY-----\n"
    ),
    "/home/sys_admin/.ssh/authorized_keys": (
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDp4Sq1Yj9Fw6Nr3Cv0Bt8Ke5Ho2Lx7Wm"
        "1Ad4Uq9Ez6Rf3Tn0Cy8Jv5Pg2Bs7Xk4Om1Wt6Dh3Qz0Lu9Rc5Vi2Ea8Nf7Kj4Bp1Xo6"
        "Sm3Yg deploy@ci-runner\n"
    ),
}

# Paths that exist but should always answer "Permission denied" rather than
# leak content, matching how a real 'ubuntu' shell user (not root) behaves.
SANDBOX_DENIED = {"/etc/shadow"}

# --- FTP decoy bait -------------------------------------------------------
# The fake FTP server shares the sandbox filesystem so the whole deception is
# consistent (telnet and FTP show the same "box"). On top of that it serves a
# few binary-looking archives generated on demand so downloads pass cursory
# inspection (real gzip/tar magic bytes), and it captures anything an attacker
# uploads (STOR) for analysis — the "they plant a backdoor and log out" win.

FTP_UPLOAD_DIR = "/home/netrunner/logs/attacker-uploads"
FTP_DENIED = {"/etc/shadow", "/etc/gshadow", "/etc/shadow-", "/etc/sudoers"}


def _fake_sql_dump():
    sql = (
        "-- MySQL dump 10.13  Distrib 5.5.54, for debian-linux-gnu (x86_64)\n"
        "-- Host: localhost    Database: system_config\n"
        "-- Server version\t5.5.54-0ubuntu0.14.04.1\n\n"
        "/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;\n"
        "CREATE TABLE `users` (\n"
        "  `id` int(11) NOT NULL AUTO_INCREMENT,\n"
        "  `username` varchar(64) NOT NULL,\n"
        "  `password_hash` varchar(255) NOT NULL,\n"
        "  `role` enum('admin','operator','viewer') NOT NULL DEFAULT 'viewer',\n"
        "  PRIMARY KEY (`id`)\n"
        ") ENGINE=InnoDB DEFAULT CHARSET=utf8;\n"
        "INSERT INTO `users` VALUES "
        "(1,'root','$6$rounds=656000$Kj9sXp2VbN0qZtWc$XWZ/QLjP/Q8bDy7uKc2sV9fEa1GhN4Rt3Wm5Vx8Yz0Cd6Lp2Tq7Jf1Sb4No8Ma3Ub9Ke5Oi7Qd9Yt3Wf1',"
        "'admin'),"
        "(2,'sys_admin','$6$rounds=656000$Q2mzC8oR1pW4tXn9$Ae3Gh7Lj2Mk5Pq9Rs0Tu6Vx4Wz8Yb1Cd3Ef5Gj7Hl2Km4Np6Qr9St1Uv3Wx8Yz0Ab5',"
        "'admin'),"
        "(3,'backup','$6$rounds=656000$L8r4Cv7yN2hB5kFq$Uv1Wd3Xf5Gh6Jk8Lm9Np1Qr3St4Uv6Wx8Yz0Ab2Cd4Ef7Gh9Jk1Lm3Np5Qr7St9Uv2Wx4Yz6Ab8',"
        "'operator');\n\n"
        "CREATE TABLE `credentials` (\n"
        "  `id` int(11) NOT NULL AUTO_INCREMENT,\n"
        "  `service` varchar(32) NOT NULL,\n"
        "  `username` varchar(64) NOT NULL,\n"
        "  `password` varchar(128) NOT NULL,\n"
        "  PRIMARY KEY (`id`)\n"
        ") ENGINE=InnoDB DEFAULT CHARSET=utf8;\n"
        "INSERT INTO `credentials` VALUES "
        "(1,'vpn_primary','netadmin','7nQz!Pw2$KvR9xLm'),"
        "(2,'vpn_secondary','netadmin','xM4#LbT8@FcN6sVw'),"
        "(3,'nas_admin','admin','S3rvice!T3am2026'),"
        "(4,'router_cfg','cisco','C1sc0.R0ut3r!2026'),"
        "(5,'api_dashboard','apiuser','9gH#2pLk$7nVm4Bq');\n\n"
        "CREATE TABLE `backup_servers` (\n"
        "  `id` int(11) NOT NULL AUTO_INCREMENT,\n"
        "  `host` varchar(255) NOT NULL,\n"
        "  `username` varchar(64) NOT NULL,\n"
        "  `password` varchar(128) NOT NULL,\n"
        "  PRIMARY KEY (`id`)\n"
        ") ENGINE=InnoDB DEFAULT CHARSET=utf8;\n"
        "INSERT INTO `backup_servers` VALUES "
        "(1,'10.0.0.5','admin','B@ckup_Cr3d_2026!'),"
        "(2,'backup.dc.example.com','archive','4rch!ve_K3y_2026');\n\n"
        "CREATE TABLE `api_keys` (\n"
        "  `id` int(11) NOT NULL AUTO_INCREMENT,\n"
        "  `service` varchar(32) NOT NULL,\n"
        "  `api_key` varchar(128) NOT NULL,\n"
        "  PRIMARY KEY (`id`)\n"
        ") ENGINE=InnoDB DEFAULT CHARSET=utf8;\n"
        "INSERT INTO `api_keys` VALUES "
        "(1,'payment','test_key'),"
        "(2,'cloud_sync','test_key'),"
        "(3,'monitoring','test_key');\n"
    )
    return gzip.compress(sql.encode("utf-8"))


def _fake_backup_tar():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        def add(name, content):
            data = content.encode("utf-8")
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mtime = int(time.time()) - 3 * 86400
            tf.addfile(info, io.BytesIO(data))

        add("backup/config.php", (
            "<?php\n"
            "// Application database configuration (production)\n"
            "define('DB_HOST', 'localhost');\n"
            "define('DB_USER', 'sys_admin');\n"
            "define('DB_PASS', 'UB_Admin_P@ss_2026_Secure');\n"
            "define('DB_NAME', 'system_config');\n"
            "define('VPN_ENDPOINT', '10.8.0.1');\n"
            "define('VPN_PSK', '4f8e2b1a-9c3d-4e7f-b6a2-1d5c8e9f0a3b');\n"
            "?>\n"
        ))
        add("backup/credentials.txt", (
            "# Stored credentials - rotate on 30 day cycle\n"
            "vpn_primary    netadmin    7nQz!Pw2$KvR9xLm\n"
            "vpn_secondary  netadmin    xM4#LbT8@FcN6sVw\n"
            "nas            admin       S3rvice!T3am2026\n"
            "router         cisco       C1sc0.R0ut3r!2026\n"
            "root_db        sys_admin   UB_Admin_P@ss_2026_Secure\n"
        ))
        add("backup/.bash_history", (
            "mysql -u root -p'UB_Admin_P@ss_2026_Secure' system_config\n"
            "mysqldump system_config | gzip > /var/backups/db_dump_2026-06-30.sql.gz\n"
            "scp backup.tar.gz admin@10.0.0.5:/backups/\n"
        ))
        add("backup/README.txt", (
            "Automated 0300 daily backup set (cron).\n"
            "Ships to 10.0.0.5:/backups/ - contact sys_admin for access.\n"
        ))
    return buf.getvalue()


def _ftp_content(path):
    if path in SANDBOX_FILES:
        return SANDBOX_FILES[path].encode("utf-8")
    if path == "/var/backups/db_dump_2026-06-30.sql.gz":
        return _fake_sql_dump()
    if path == "/home/sys_admin/backup.tar.gz":
        return _fake_backup_tar()
    if path == "/var/www/html/config.php":
        return SANDBOX_FILES["/var/www/html/config.php"].encode("utf-8")
    if path == "/var/www/html/backdoor.php":
        return (
            "<?php\n"
            "// injected payload (sample) - see /var/log/auth.log for upload evidence\n"
            "if(isset($_REQUEST['c'])){system($_REQUEST['c']);}\n"
            "?>\n"
        ).encode("utf-8")
    if path == "/var/www/html/index.php":
        return (
            "<?php\n"
            "echo \"srv-db-cluster internal status page\\n\";\n"
            "?>\n"
        ).encode("utf-8")
    if path == "/etc/hostname":
        return f"{socket.gethostname()}\n".encode("utf-8")
    return None


def _ftp_save_upload(ip, fname, payload):
    try:
        os.makedirs(FTP_UPLOAD_DIR, exist_ok=True)
        base = os.path.basename(fname) or "unknown"
        path = os.path.join(
            FTP_UPLOAD_DIR, f"{time.strftime('%Y%m%d_%H%M%S')}_{ip}_{base}"
        )
        with open(path, "wb") as f:
            f.write(payload)
        os.chmod(path, 0o644)
        os.chmod(FTP_UPLOAD_DIR, 0o700)
        try:
            os.chown(path, 1000, 1000)
            os.chown(FTP_UPLOAD_DIR, 1000, 1000)
        except OSError:
            pass
        return path
    except OSError:
        return None


def _sandbox_normalize(cwd, target):
    if not target:
        return cwd
    base = target if target.startswith("/") else cwd.rstrip("/") + "/" + target
    if target == "~" or target.startswith("~/"):
        base = SANDBOX_HOME + target[1:]
    parts = []
    for segment in base.split("/"):
        if segment in ("", "."):
            continue
        if segment == "..":
            if parts:
                parts.pop()
            continue
        parts.append(segment)
    return "/" + "/".join(parts)


def _sandbox_display_cwd(cwd):
    if cwd == SANDBOX_HOME:
        return "~"
    if cwd.startswith(SANDBOX_HOME + "/"):
        return "~" + cwd[len(SANDBOX_HOME):]
    return cwd


def _sandbox_owner(path):
    if path.startswith("/home/ubuntu"):
        return "ubuntu   ubuntu  "
    if path.startswith("/home/sys_admin"):
        return "sys_admin sys_admin"
    if path.startswith("/var/www"):
        return "www-data www-data"
    return "root     root    "


def _sandbox_ls(cwd, detailed):
    entries = SANDBOX_FS.get(cwd, [])
    if not detailed:
        return ("  ".join(sorted(entries)) + "\n") if entries else ""
    owner = _sandbox_owner(cwd)
    lines = [f"total {max(len(entries) * 4, 8)}"]
    lines.append(f"drwxr-xr-x  2 {owner} 4096 Jul  9 12:00 .")
    lines.append(f"drwxr-xr-x  3 root     root     4096 Jul  9 11:30 ..")
    for name in sorted(entries):
        child = _sandbox_normalize(cwd, name)
        if child in SANDBOX_FS:
            lines.append(f"drwxr-xr-x  2 {owner} 4096 Jul  9 12:00 {name}")
        else:
            content = SANDBOX_FILES.get(child, "")
            size = len(content.encode("utf-8")) if content else 220
            perm = "-rw-------" if name.startswith(".") or "id_rsa" == name else "-rw-r--r--"
            lines.append(f"{perm}  1 {owner} {size:>5} Jul  9 12:00 {name}")
    return "\n".join(lines) + "\n"


def execute_sandbox_command(cmd, session):
    """Session-aware mock shell used by the telnet decoy. `session` is a
    per-connection dict holding at least {'cwd': <path>} so cd/pwd/ls stay
    consistent for the life of the connection, the way a real shell does."""
    cmd = cmd.strip()
    if not cmd:
        return ""

    cmd_clean = cmd.replace("'", "").replace('"', "")
    parts = cmd_clean.split()
    base_cmd = parts[0] if parts else ""
    args = parts[1:]
    cwd = session.get("cwd", SANDBOX_HOME)

    if base_cmd == "cd":
        target = args[-1] if args else SANDBOX_HOME
        new_path = _sandbox_normalize(cwd, target)
        if new_path in SANDBOX_FS:
            session["cwd"] = new_path
            return ""
        elif new_path in SANDBOX_FILES:
            return f"bash: cd: {target}: Not a directory\n"
        else:
            return f"bash: cd: {target}: No such file or directory\n"

    elif base_cmd == "pwd":
        return cwd + "\n"

    elif base_cmd == "ls":
        detailed = any(a in ("-l", "-la", "-al", "-lah", "-a") for a in args)
        target = next((a for a in args if not a.startswith("-")), None)
        target_path = _sandbox_normalize(cwd, target) if target else cwd
        if target_path not in SANDBOX_FS:
            if target_path in SANDBOX_FILES or target_path.rsplit("/", 1)[-1]:
                return target if target else ""
            return f"ls: cannot access '{target}': No such file or directory\n"
        return _sandbox_ls(target_path, detailed)

    elif base_cmd in ("cat", "more", "less", "head", "tail"):
        non_flag_args = [a for a in args if not a.startswith("-")]
        if not non_flag_args:
            return f"{base_cmd}: missing operand\n"
        target = non_flag_args[-1]
        full_path = _sandbox_normalize(cwd, target)
        if full_path in SANDBOX_DENIED:
            return f"{base_cmd}: {target}: Permission denied\n"
        if full_path in SANDBOX_FILES:
            content = SANDBOX_FILES[full_path]
            if base_cmd in ("head", "tail"):
                lines = content.splitlines(keepends=True)
                n = 10
                if "-n" in args:
                    try:
                        n = int(args[args.index("-n") + 1])
                    except (ValueError, IndexError):
                        pass
                content = "".join(lines[:n] if base_cmd == "head" else lines[-n:])
                if base_cmd == "tail" and "-f" in args:
                    # A real `tail -f` on a quiet log just blocks waiting
                    # for new lines. We can't stream live fake entries
                    # here without restructuring the read loop, so at
                    # least don't dump-and-return like a static cat —
                    # print what exists and let the caller's next
                    # keystroke act as the "nothing new yet" moment.
                    pass
            return content
        if full_path in SANDBOX_FS:
            return f"{base_cmd}: {target}: Is a directory\n"
        return f"{base_cmd}: {target}: No such file or directory\n"

    elif base_cmd in ("rm", "chmod", "chown", "mv", "touch", "mkdir", "nano", "vi", "vim"):
        # Attackers modifying the "filesystem" get a plausible success/
        # denial instead of "command not found" — a real Ubuntu box has
        # all of these, so a blank miss here is itself a honeypot tell.
        if not args:
            return f"{base_cmd}: missing operand\n"
        target = args[-1]
        full_path = _sandbox_normalize(cwd, target)
        if base_cmd in ("nano", "vi", "vim"):
            return ""  # editors just "open" silently in this transcript view
        if base_cmd == "mkdir":
            return "" if full_path not in SANDBOX_FS else f"mkdir: cannot create directory '{target}': File exists\n"
        if full_path in SANDBOX_DENIED or (
            full_path.startswith("/etc") and base_cmd in ("rm", "chmod", "chown")
        ):
            return f"{base_cmd}: cannot access '{target}': Operation not permitted\n"
        return ""

    elif base_cmd == "grep":
        non_flag_args = [a for a in args if not a.startswith("-")]
        if len(non_flag_args) < 2:
            return "Usage: grep [OPTION]... PATTERN [FILE]...\n"
        pattern, target = non_flag_args[0], non_flag_args[-1]
        full_path = _sandbox_normalize(cwd, target)
        content = SANDBOX_FILES.get(full_path)
        if content is None:
            return f"grep: {target}: No such file or directory\n"
        matches = [line for line in content.splitlines() if pattern in line]
        return ("\n".join(matches) + "\n") if matches else ""

    elif base_cmd == "find":
        # Cheap emulation: walk SANDBOX_FS keys under the given root.
        root = args[0] if args and not args[0].startswith("-") else cwd
        root_path = _sandbox_normalize(cwd, root)
        results = [p for p in SANDBOX_FS if p == root_path or p.startswith(root_path.rstrip("/") + "/")]
        for parent, children in SANDBOX_FS.items():
            if parent == root_path or parent.startswith(root_path.rstrip("/") + "/"):
                for child in children:
                    child_path = _sandbox_normalize(parent, child)
                    if child_path not in SANDBOX_FS:
                        results.append(child_path)
        return "\n".join(sorted(set(results))) + "\n" if results else ""

    elif base_cmd == "wc":
        non_flag_args = [a for a in args if not a.startswith("-")]
        target = non_flag_args[-1] if non_flag_args else None
        full_path = _sandbox_normalize(cwd, target) if target else None
        content = SANDBOX_FILES.get(full_path, "") if full_path else ""
        lines = content.count("\n")
        words = len(content.split())
        chars = len(content)
        return f"{lines:>4} {words:>4} {chars:>5} {target or ''}\n"

    elif base_cmd in ("wget", "curl"):
        url = args[-1] if args else ""
        log_event(f"[ALERT] Sandbox observed outbound fetch attempt: {base_cmd} {url}")
        return f"{base_cmd}: unable to resolve host address\n"

    elif base_cmd == "history":
        hist_path = _sandbox_normalize(cwd, "~/.bash_history")
        return SANDBOX_FILES.get(hist_path, "")

    elif base_cmd == "ps":
        return (
            "  PID TTY          TIME CMD\n"
            " 1022 pts/0    00:00:00 bash\n"
            " 1841 pts/0    00:00:00 ps\n"
        )

    elif base_cmd in ("netstat", "ss"):
        return (
            "Active Internet connections (only servers)\n"
            "Proto Recv-Q Send-Q Local Address           Foreign Address         State\n"
            "tcp        0      0 0.0.0.0:21              0.0.0.0:*               LISTEN\n"
            "tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN\n"
            "tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN\n"
        )

    elif base_cmd in ("ifconfig", "ip"):
        return (
            "eth0      Link encap:Ethernet  HWaddr 00:16:3e:2f:88:11\n"
            "          inet addr:192.168.1.13  Bcast:192.168.1.255  Mask:255.255.255.0\n"
            "          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1\n"
        )

    elif base_cmd == "sudo":
        return "ubuntu is not in the sudoers file.  This incident will be reported.\n"

    elif base_cmd == "crontab" and "-l" in args:
        return SANDBOX_FILES.get("/etc/crontab", "no crontab for ubuntu\n")

    elif base_cmd in ("clear",):
        return ""

    elif base_cmd in ("whoami",):
        return "ubuntu\n"

    elif base_cmd == "id":
        return "uid=1000(ubuntu) gid=1000(ubuntu) groups=1000(ubuntu),27(sudo)\n"

    elif base_cmd == "uname":
        return f"Linux {socket.gethostname()} 3.13.0-160-generic #210-Ubuntu SMP x86_64 GNU/Linux\n"

    else:
        return f"{base_cmd}: command not found\n"


def handle_ftp(client_socket, client_address):
    ip, client_port = client_address
    log_event(
        f"[INFO] FTP DECOY CONNECTED: Source IP {ip}:{client_port}. Tarpit Engaged."
    )
    send_notification(ip, "21 (FTP Tarpit)")

    current_cpfr = None
    user = "unknown"
    passw = "unknown"
    cwd = "/"
    data_mode = None       # None | 'pasv' | 'port'
    data_listener = None   # socket for PASV/EPSV
    port_endpoint = None   # (host, port) for PORT mode
    ftp_timestamp = "20260709120000"

    def open_pasv():
        nonlocal data_mode, data_listener
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("0.0.0.0", 0))
            s.listen(1)
            s.settimeout(10.0)
            data_listener = s
            data_mode = "pasv"
            port = s.getsockname()[1]
            a, b, c, d = client_socket.getsockname()[0].split(".")
            return f"227 Entering Passive Mode ({a},{b},{c},{d},{port >> 8},{port & 0xff})\r\n".encode()
        except OSError:
            return b"425 Can't open data connection.\r\n"

    def acquire_data_conn():
        nonlocal data_mode, data_listener, port_endpoint
        if data_mode == "pasv" and data_listener is not None:
            s = data_listener
            data_listener = None
            data_mode = None
            try:
                conn, _ = s.accept()
                conn.settimeout(20.0)
                return conn
            except (socket.timeout, OSError):
                return None
            finally:
                s.close()
        if data_mode == "port" and port_endpoint is not None:
            host, port = port_endpoint
            data_mode = None
            port_endpoint = None
            try:
                conn = socket.create_connection((host, port), timeout=6.0)
                conn.settimeout(20.0)
                return conn
            except OSError:
                return None
        data_mode = None
        port_endpoint = None
        return None

    def ftp_listing(path, style):
        entries = SANDBOX_FS.get(path, [])
        if style == "nlst":
            return ("\r\n".join(entries) + "\r\n").encode() if entries else b"\r\n"
        lines = []
        for name in sorted(entries):
            child = _sandbox_normalize(path, name)
            if child in SANDBOX_FS:
                size, kind = 4096, "dir"
            else:
                content = _ftp_content(child)
                size, kind = len(content) if content else 0, "file"
            if style == "mlsd":
                lines.append(f"type={kind};size={size};modify={ftp_timestamp}; {name}")
            else:
                perm = "drwxr-xr-x" if kind == "dir" else "-rw-r--r--"
                lines.append(f"{perm} 2 ftp ftp {size:>5} Jul 09 12:00 {name}")
        return ("\r\n".join(lines) + "\r\n").encode() if lines else b"\r\n"

    def reply(msg):
        client_socket.sendall(msg if isinstance(msg, bytes) else msg.encode())

    try:
        client_socket.sendall(get_port_banner(21))
        client_socket.settimeout(15.0)

        while True:
            data = client_socket.recv(1024)
            if not data:
                break

            line = data.decode("utf-8", errors="ignore").strip()
            if not line:
                continue

            log_event(f"[FTP] Command from {ip}: {line}")

            parts = line.split(" ", 1)
            cmd = parts[0].upper()
            args = parts[1].strip() if len(parts) > 1 else ""

            if cmd == "USER":
                user = args
                reply(f"331 Password required for {user}\r\n")
            elif cmd == "PASS":
                passw = args
                log_event(
                    f"[ALERT] CREDENTIALS HARVESTED (FTP) from {ip}: USER={user}, PASS={passw}"
                )
                send_credential_notification(ip, "FTP", user, passw)
                reply("230 User logged in, proceed\r\n")
            elif cmd == "SYST":
                reply("215 UNIX Type: L8\r\n")
            elif cmd == "FEAT":
                reply("211-Features:\r\n EPRT\r\n EPSV\r\n MDTM\r\n MLST type*;size*;modify*;\r\n MLSD\r\n PASV\r\n REST STREAM\r\n SIZE\r\n SITE\r\n211 End\r\n")
            elif cmd == "PWD":
                reply(f'257 "{cwd}" is current directory\r\n')
            elif cmd in ("TYPE", "STRU", "MODE", "ALLO"):
                reply(f"200 Command okay.\r\n")
            elif cmd == "CWD":
                target = _sandbox_normalize(cwd, args) if args else "/"
                if target in SANDBOX_FS:
                    cwd = target
                    reply(f'250 Directory successfully changed.\r\n')
                else:
                    reply(f'550 Failed to change directory.\r\n')
            elif cmd == "CDUP":
                target = _sandbox_normalize(cwd, "..")
                if target in SANDBOX_FS:
                    cwd = target
                    reply(b"250 Directory successfully changed.\r\n")
                else:
                    reply(b"550 Failed to change directory.\r\n")
            elif cmd == "PORT":
                nums = re.findall(r"\d+", args)
                if len(nums) >= 6:
                    host = ".".join(nums[:4])
                    port = int(nums[4]) * 256 + int(nums[5])
                    if host == ip:
                        data_mode = "port"
                        port_endpoint = (host, port)
                        reply(b"200 PORT command successful\r\n")
                    else:
                        log_event(f"[ALERT] FTP PORT bounce attempt from {ip} targeting {host}:{port} (blocked)")
                        data_mode = "port"
                        port_endpoint = None
                        reply(b"200 PORT command successful\r\n")
                else:
                    reply(b"501 Syntax error in parameters\r\n")
            elif cmd == "PASV":
                reply(open_pasv())
            elif cmd == "EPSV":
                data_mode = "pasv"
                try:
                    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    s.bind(("0.0.0.0", 0))
                    s.listen(1)
                    s.settimeout(10.0)
                    data_listener = s
                    reply(f"229 Entering Extended Passive Mode (|||{s.getsockname()[1]}|)\r\n")
                except OSError:
                    data_mode = None
                    reply(b"425 Can't open data connection.\r\n")
            elif cmd in ("LIST", "NLST", "MLSD"):
                target = args if args else cwd
                if target.startswith("-"):
                    target = cwd
                full = _sandbox_normalize(cwd, target)
                if full not in SANDBOX_FS:
                    reply(b"550 No such directory.\r\n")
                    continue
                reply(b"150 Here comes the directory listing.\r\n")
                conn = acquire_data_conn()
                if conn is None:
                    reply(b"425 Can't open data connection.\r\n")
                    continue
                try:
                    conn.sendall(ftp_listing(full, cmd.lower()))
                finally:
                    conn.close()
                reply(b"226 Directory send OK.\r\n")
            elif cmd == "RETR":
                if not args:
                    reply(b"550 No file specified.\r\n")
                    continue
                full = _sandbox_normalize(cwd, args)
                if full in FTP_DENIED:
                    reply(b"550 Permission denied.\r\n")
                    continue
                content = _ftp_content(full)
                if content is None:
                    reply(b"550 File not found.\r\n")
                    continue
                reply(b"150 Opening BINARY mode data connection.\r\n")
                conn = acquire_data_conn()
                if conn is None:
                    reply(b"425 Can't open data connection.\r\n")
                    continue
                try:
                    conn.sendall(content)
                finally:
                    conn.close()
                log_event(f"[ALERT] FTP BAIT EXFILTRATED by {ip}: {full} ({len(content)} bytes) served as decoy data")
                reply(b"226 Transfer complete.\r\n")
            elif cmd == "STOR":
                if not args:
                    reply(b"550 No file specified.\r\n")
                    continue
                reply(b"150 Ok to send data.\r\n")
                conn = acquire_data_conn()
                if conn is None:
                    reply(b"425 Can't open data connection.\r\n")
                    continue
                chunks = []
                try:
                    while True:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        chunks.append(chunk)
                except (socket.timeout, OSError):
                    pass
                finally:
                    conn.close()
                payload = b"".join(chunks)
                if payload:
                    path = _ftp_save_upload(ip, args, payload)
                    log_event(
                        f"[ALERT] ATTACKER PAYLOAD CAPTURED: {ip} uploaded {args} "
                        f"({len(payload)} bytes) -> {path}"
                    )
                    send_notification(ip, f"FTP STOR: attacker payload {args} captured")
                    if args.lower().endswith((".php", ".php5", ".phtml", ".phar")):
                        with WEBSHELL_LOCK:
                            UPLOADED_WEBSHELLS[os.path.basename(args)] = (
                                f"(ftp-uploaded {path})"
                            )
                        log_event(f"[INFO] FTP-uploaded PHP registered as live webshell: {os.path.basename(args)}")
                else:
                    log_event(f"[ALERT] FTP STOR (empty upload) from {ip}: {args}")
                reply(b"226 Transfer complete.\r\n")
            elif cmd == "SIZE":
                if not args:
                    reply(b"501 Syntax error in parameters\r\n")
                    continue
                full = _sandbox_normalize(cwd, args)
                if full in FTP_DENIED:
                    reply(b"550 Permission denied.\r\n")
                    continue
                content = _ftp_content(full)
                if content is None:
                    reply(b"550 File not found.\r\n")
                else:
                    reply(f"213 {len(content)}\r\n")
            elif cmd == "MDTM":
                full = _sandbox_normalize(cwd, args) if args else ""
                if full not in SANDBOX_FS and full not in SANDBOX_FILES and _ftp_content(full) is None:
                    reply(b"550 File not found.\r\n")
                else:
                    reply(f"213 {ftp_timestamp}\r\n")
            elif cmd in ("DELE", "MKD", "RMD", "RNFR", "RNTO", "APPE"):
                reply(b"550 Permission denied.\r\n")
            elif cmd == "NOOP":
                reply(b"200 NOOP ok.\r\n")
            elif cmd in ("CPFR", "CPTO") and not args:
                reply(b"501 Syntax error in parameters.\r\n")
            elif cmd == "CPFR":
                current_cpfr = args
                log_event(f"[ALERT] EXPLOIT ATTEMPT: FTP mod_copy CPFR from {ip} for file: {current_cpfr}")
                reply(b"350 File or directory exists, ready for destination name\r\n")
            elif cmd == "CPTO":
                if current_cpfr:
                    dest_path = args
                    filename = dest_path.split("/")[-1]
                    with WEBSHELL_LOCK:
                        UPLOADED_WEBSHELLS[filename] = current_cpfr
                    log_event(f"[ALERT] EXPLOIT SUCCESSFUL: FTP mod_copy CPTO from {ip} to path: {dest_path} (registered webshell: {filename})")
                    reply(b"250 Copy successful\r\n")
                else:
                    reply(b"503 Bad sequence of commands.\r\n")
            elif cmd == "SITE":
                site_parts = args.split(" ", 1)
                site_cmd = site_parts[0].upper()
                site_args = site_parts[1].strip() if len(site_parts) > 1 else ""

                if site_cmd == "CPFR":
                    current_cpfr = site_args
                    log_event(f"[ALERT] EXPLOIT ATTEMPT: FTP mod_copy CPFR from {ip} for file: {current_cpfr}")
                    reply(b"350 File or directory exists, ready for destination name\r\n")
                elif site_cmd == "CPTO":
                    if current_cpfr:
                        dest_path = site_args
                        filename = dest_path.split("/")[-1]
                        with WEBSHELL_LOCK:
                            UPLOADED_WEBSHELLS[filename] = current_cpfr
                        log_event(f"[ALERT] EXPLOIT SUCCESSFUL: FTP mod_copy CPTO from {ip} to path: {dest_path} (registered webshell: {filename})")
                        reply(b"250 Copy successful\r\n")
                    else:
                        reply(b"503 Bad sequence of commands.\r\n")
                else:
                    reply(b"500 Syntax error, command unrecognized.\r\n")
            elif cmd == "QUIT":
                reply(b"221 Goodbye.\r\n")
                break
            else:
                reply(b"500 Syntax error, command unrecognized.\r\n")
    except Exception:
        pass
    finally:
        if data_listener is not None:
            try:
                data_listener.close()
            except OSError:
                pass
        client_socket.close()


def handle_ssh(client_socket, client_address):
    ip, client_port = client_address
    log_event(
        f"[INFO] SSH DECOY CONNECTED: Source IP {ip}:{client_port}. Tarpit Engaged."
    )
    send_notification(ip, "22 (SSH Tarpit)")
    try:
        client_socket.sendall(PORTS[22])
        while True:
            if (
                time.time() - FIRST_SEEN_TRACKER.get(ip, time.time())
                > TIME_LIMIT_BEFORE_BAN
            ):
                log_event(f"[INFO] Tarpit expired for {ip} on SSH.")
                break

            client_socket.settimeout(5.0)
            try:
                data = client_socket.recv(4096)
                if data:
                    log_event(
                        f"[PAYLOAD] SSH packet from {ip}: {data.decode('utf-8', errors='ignore').strip()}"
                    )
                    time.sleep(5)
                    client_socket.sendall(b"Protocol mismatch.\r\n")
                else:
                    break
            except socket.timeout:
                client_socket.sendall(b"\x00")
    except Exception:
        pass
    finally:
        client_socket.close()


def handle_telnet(client_socket, client_address):
    ip, client_port = client_address
    log_event(
        f"[INFO] TELNET DECOY CONNECTED: Source IP {ip}:{client_port}. Tarpit Engaged."
    )
    send_notification(ip, "23 (Telnet Tarpit)")
    try:
        client_socket.settimeout(60.0)
        telnet_negotiate(client_socket)
        client_socket.settimeout(60.0)
        client_socket.sendall(get_port_banner(23))

        # Require the randomized credential so Enter/Enter no longer grants
        # access — mimics a real telnetd with 3 attempts then disconnect.
        attempts = 0
        while True:
            username = telnet_readline(client_socket)
            if looks_like_protocol_probe(username):
                # Not a real telnet client typing credentials — a probe from
                # another protocol landed on this port. A real telnetd would
                # never get this far into a coherent exchange with it, so
                # just drop the connection instead of "authenticating" it.
                return
            client_socket.sendall(b"Password: ")
            password = telnet_readline(client_socket)
            if looks_like_protocol_probe(password):
                return

            if username == TELNET_USERNAME and password == TELNET_PASSWORD:
                log_event(
                    f"[ALERT] CREDENTIALS HARVESTED (Telnet) from {ip}: "
                    f"Username={username}, Password={password} [VALID DECOY LOGIN]"
                )
                send_credential_notification(ip, "Telnet", username, password)
                break

            attempts += 1
            log_event(
                f"[INFO] Telnet login FAILURE from {ip}: "
                f"Username={username!r}, Password={password!r}"
            )
            client_socket.sendall(b"Login incorrect\r\n\r\n")
            if attempts >= 3:
                log_event(
                    f"[INFO] Telnet login failures exceeded (3) from {ip}, dropping connection."
                )
                return
            client_socket.sendall(f"{socket.gethostname()} login: ".encode())

        # Access Granted! Serve Ubuntu Server Shell Greeting
        current_hostname = socket.gethostname()
        session = {"cwd": SANDBOX_HOME}
        greeting = (
            "\r\n"
            "Welcome to Ubuntu 14.04.5 LTS (GNU/Linux 3.13.0-160-generic x86_64)\r\n"
            "\r\n"
            " * Documentation:  https://help.ubuntu.com/\r\n"
            "\r\n"
            "Last login: Thu Jul  9 11:12:04 2026 from 192.168.1.15\r\n"
            f"{TELNET_USERNAME}@{current_hostname}:{_sandbox_display_cwd(session['cwd'])}$ "
        )
        client_socket.sendall(greeting.encode())

        while True:
            cmd_line = telnet_readline(client_socket)
            if not cmd_line:
                break

            if looks_like_protocol_probe(cmd_line):
                # A scanner probe slipping in mid-session — drop rather
                # than run it through the mock shell and leak a real
                # "sh: command not found" error for header text.
                break

            log_event(f"[TELNET CLI] IP {ip} typed: {cmd_line}")

            if cmd_line.lower() in ("exit", "quit", "logout"):
                client_socket.sendall(b"\r\nlogout\r\nConnection closed by foreign host.\r\n")
                break

            # Run command in the stateful sandbox shell
            output = execute_sandbox_command(cmd_line, session)
            # Replace single newlines with telnet-friendly \r\n
            output_telnet = output.replace("\n", "\r\n").encode("utf-8")

            client_socket.sendall(output_telnet)
            client_socket.sendall(
                f"{TELNET_USERNAME}@{current_hostname}:{_sandbox_display_cwd(session['cwd'])}$ ".encode()
            )
    except Exception:
        pass
    finally:
        client_socket.close()


def handle_http(client_socket, client_address):
    ip, client_port = client_address
    log_event(f"[INFO] HTTP DECOY CONNECTED: Source IP {ip}:{client_port}")
    send_notification(ip, "80 (HTTP)")
    try:
        client_socket.settimeout(5.0)
        request = client_socket.recv(2048)
        if not request:
            client_socket.close()
            return

        request_str = request.decode("utf-8", errors="ignore")
        lines = request_str.split("\r\n")
        first_line = lines[0] if lines else ""

        parts = first_line.split()
        path = parts[1] if len(parts) >= 2 else ""
        method = parts[0] if len(parts) >= 1 else "GET"

        # Split path and query parameters
        route = path.split("?")[0]
        query_string = path.split("?", 1)[1] if "?" in path else ""
        filename = route.lstrip("/")

        # Check if the requested route is a registered web shell (match by
        # basename so shells planted into subdirectories, e.g. /uploads/cc.php,
        # still fire like they would on a real Apache + mod_copy victim)
        is_webshell = False
        basename = filename.rsplit("/", 1)[-1]
        with WEBSHELL_LOCK:
            if basename in UPLOADED_WEBSHELLS:
                is_webshell = True

        if is_webshell:
            # Parse GET or POST command params
            params = {}
            if query_string:
                for pair in query_string.split("&"):
                    if "=" in pair:
                        k, v = pair.split("=", 1)
                        params[k] = urllib.parse.unquote(v)
            if method == "POST":
                body = ""
                if "\r\n\r\n" in request_str:
                    body = request_str.split("\r\n\r\n", 1)[1]
                if body:
                    for pair in body.split("&"):
                        if "=" in pair:
                            k, v = pair.split("=", 1)
                            params[k] = urllib.parse.unquote(v)

            cmd = params.get("cmd") or params.get("c") or params.get("shell") or params.get("exec")
            if cmd:
                log_event(f"[ALERT] EXPLOIT BACKDOOR EXECUTED: Source IP {ip} executed cmd=\"{cmd}\" on webshell {filename}")
                output = execute_mock_command(cmd)
                output_bytes = output.encode("utf-8")
                response = (
                    f"HTTP/1.1 200 OK\r\n"
                    f"Content-Type: text/plain\r\n"
                    f"Content-Length: {len(output_bytes)}\r\n"
                    f"Connection: close\r\n\r\n"
                ).encode("utf-8") + output_bytes
                client_socket.sendall(response)
            else:
                # Return standard webshell frontend form if accessed in browser without params
                html = f"""<!DOCTYPE html>
<html>
<head>
    <title>Web Shell Console - {filename}</title>
    <style>
        body {{ font-family: monospace; background-color: #121212; color: #00ff00; padding: 20px; }}
        input[type="text"] {{ width: 80%; background-color: #222; color: #00ff00; border: 1px solid #00ff00; padding: 5px; }}
        input[type="submit"] {{ background-color: #00ff00; color: #121212; border: none; padding: 5px 10px; font-weight: bold; cursor: pointer; }}
    </style>
</head>
<body>
    <h2>SafeShell v1.0 - Connected to {socket.gethostname()}</h2>
    <form method="GET">
        <span>www-data@{socket.gethostname()}:/var/www/html$ </span>
        <input type="text" name="cmd" autofocus placeholder="Type command...">
        <input type="submit" value="Run">
    </form>
</body>
</html>
"""
                response = (
                    f"HTTP/1.1 200 OK\r\n"
                    f"Content-Type: text/html\r\n"
                    f"Content-Length: {len(html)}\r\n"
                    f"Connection: close\r\n\r\n"
                    f"{html}"
                ).encode("utf-8")
                client_socket.sendall(response)
            client_socket.close()
            return

        elif route == "/infrastructure_passwords.txt":
            log_event(f"[ALERT] HONEY-TOKEN TRIP: {ip} downloaded /infrastructure_passwords.txt")
            run_notify_send(
                "Honey-Token Tripped",
                f"Host {ip} downloaded /infrastructure_passwords.txt!",
                "critical",
                "security-high"
            )
            content = (
                "# Ubuntu Server Infrastructure Configuration\n"
                "# Admin credential fallback (Do not share!)\n"
                "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n"
                "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n"
                "production_db_host=db.ubuntu-internal.net\n"
                "production_db_user=sys_admin\n"
                "production_db_pass=UB_Admin_P@ss_2026_Secure\n"
            ).encode("utf-8")
            response = (
                f"HTTP/1.1 200 OK\r\n"
                f"Content-Type: text/plain\r\n"
                f"Content-Length: {len(content)}\r\n"
                f"Connection: close\r\n\r\n"
            ).encode("utf-8") + content
            client_socket.sendall(response)
            client_socket.close()
            return

        elif route == "/network_backup.sql":
            log_event(f"[ALERT] HONEY-TOKEN TRIP: {ip} downloaded /network_backup.sql")
            run_notify_send(
                "Honey-Token Tripped",
                f"Host {ip} downloaded /network_backup.sql!",
                "critical",
                "security-high"
            )
            content = (
                "-- Ubuntu Server Decoy Database Dump\n"
                "-- Table structure for table `users`\n"
                "CREATE TABLE `users` (\n"
                "  `username` varchar(50) NOT NULL,\n"
                "  `password` varchar(255) NOT NULL\n"
                ");\n"
                "INSERT INTO `users` VALUES ('admin','pbkdf2_sha256$260000$yX8wQ1sFp9Z0$L2qN3oP4q5r6s7t8u9v0w1x2y3z4A5B6C7D8E9F0g1h='),('backup_agent','AKIA5F3B4C5D6E7F8G9H');\n"
            ).encode("utf-8")
            response = (
                f"HTTP/1.1 200 OK\r\n"
                f"Content-Type: application/sql\r\n"
                f"Content-Length: {len(content)}\r\n"
                f"Connection: close\r\n\r\n"
            ).encode("utf-8") + content
            client_socket.sendall(response)
            client_socket.close()
            return

        elif method == "POST" and route in ("/login", "/login.php", "/login.html"):
            body = ""
            if "\r\n\r\n" in request_str:
                body = request_str.split("\r\n\r\n", 1)[1]

            username = "unknown"
            password = "unknown"
            for part in body.split("&"):
                if "=" in part:
                    k, v = part.split("=", 1)
                    if k == "username":
                        username = urllib.parse.unquote(v)
                    elif k == "password":
                        password = urllib.parse.unquote(v)

            log_event(
                f"[ALERT] CREDENTIALS HARVESTED (HTTP Cockpit) from {ip}: Username={username}, Password={password}"
            )
            send_credential_notification(ip, "Ubuntu Cockpit Portal", username, password)

            # Redirect to Dashboard showing successful authentication
            response = (
                b"HTTP/1.1 302 Found\r\n"
                b"Location: /admin/dashboard.html\r\n"
                b"Content-Length: 0\r\n"
                b"Connection: close\r\n\r\n"
            )
            client_socket.sendall(response)
            client_socket.close()
            return

        elif method == "GET" and route in ("/admin/dashboard.html", "/admin/dashboard", "/admin/"):
            html = """<!DOCTYPE html>
<html>
<head>
    <title>Cockpit System Console - ubuntu-server</title>
    <style>
        body { font-family: 'Outfit', Arial, sans-serif; background-color: #0b0c10; color: #c5c6c7; margin: 0; padding: 0; }
        .header { background-color: #1f2833; color: #66fcf1; padding: 15px 30px; display: flex; justify-content: space-between; align-items: center; border-bottom: 2px solid #66fcf1; }
        .header h1 { margin: 0; font-size: 22px; font-weight: bold; text-transform: uppercase; letter-spacing: 1px; }
        .container { max-width: 1200px; margin: 30px auto; padding: 0 25px; }
        .card { background-color: #151922; border: 1px solid rgba(102,252,241,0.15); border-radius: 8px; padding: 25px; margin-bottom: 25px; box-shadow: 0 4px 15px rgba(0,0,0,0.3); }
        .card h3 { margin-top: 0; color: #66fcf1; border-bottom: 1px solid rgba(102,252,241,0.3); padding-bottom: 10px; font-weight: 500; text-transform: uppercase; letter-spacing: 0.5px; }
        .grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 25px; }
        .info-row { display: flex; justify-content: space-between; padding: 10px 0; border-bottom: 1px solid rgba(255,255,255,0.05); }
        .info-row:last-child { border-bottom: none; }
        .label { font-weight: bold; color: #45f3ff; }
        .value { color: #fff; }
        .footer { text-align: center; margin-top: 40px; font-size: 12px; color: #666; padding: 20px 0; }
        .badge { background-color: #1b4d3e; color: #2ecc71; padding: 4px 10px; border-radius: 12px; font-size: 11px; font-weight: bold; border: 1px solid #2ecc71; }
        code { background-color: #0b0c10; padding: 3px 8px; border-radius: 4px; color: #ff6b6b; font-family: monospace; border: 1px solid rgba(255,107,107,0.2); }
        table { width: 100%; border-collapse: collapse; text-align: left; margin-top: 15px; }
        th { border-bottom: 2px solid rgba(102,252,241,0.3); padding: 12px 10px; color: #66fcf1; font-weight: 600; }
        td { padding: 12px 10px; border-bottom: 1px solid rgba(255,255,255,0.05); color: #fff; }
        tr:hover { background-color: rgba(102,252,241,0.02); }
    </style>
</head>
<body>
    <div class="header">
        <h1>Cockpit System Control</h1>
        <div><span>Server: ubuntu-server</span> | <a href="/logout" style="color: #66fcf1; text-decoration: none; font-weight: bold; border: 1px solid #66fcf1; padding: 5px 15px; border-radius: 4px; transition: 0.3s;">Logout</a></div>
    </div>
    <div class="container">
        <div class="grid">
            <div class="card">
                <h3>System Status</h3>
                <div class="info-row"><span class="label">System Name</span><span class="value">ubuntu-server</span></div>
                <div class="info-row"><span class="label">Operating System</span><span class="value">Ubuntu 18.04.6 LTS (Bionic Beaver)</span></div>
                <div class="info-row"><span class="label">System Uptime</span><span class="value">04:32:11</span></div>
                <div class="info-row"><span class="label">Kernel Version</span><span class="value">4.15.0-142-generic</span></div>
                <div class="info-row"><span class="label">CPU Usage</span><span class="value">8.2%</span></div>
                <div class="info-row"><span class="label">Memory Usage</span><span class="value">31.4% (3.8 GB / 12.0 GB)</span></div>
            </div>
            <div class="card">
                <h3>Network Configurations</h3>
                <div class="info-row"><span class="label">Active Interfaces</span><span class="value">eth0, eth1, wlan0 <span class="badge">Online</span></span></div>
                <div class="info-row"><span class="label">eth0 (WAN IP)</span><span class="value">192.168.100.15</span></div>
                <div class="info-row"><span class="label">eth1 (LAN Gateway)</span><span class="value">192.168.1.1</span></div>
                <div class="info-row"><span class="label">Primary DNS</span><span class="value">127.0.0.1 (dnscrypt-proxy)</span></div>
                <div class="info-row"><span class="label">Active DHCP Leases</span><span class="value">3 Clients Active</span></div>
            </div>
        </div>

        <div class="card">
            <h3>Enterprise VPN Gateway Service</h3>
            <p style="color: #c5c6c7; font-size: 13px; margin-bottom: 20px;">Secure tunnel connecting remote data center instances.</p>
            <div class="info-row"><span class="label">Connection Endpoint</span><span class="value">vpn.corp-internal-cloud.com</span></div>
            <div class="info-row"><span class="label">Tunnel Status</span><span class="value"><span class="badge">Active</span></span></div>
            <div class="info-row"><span class="label">Tunnel Encryption</span><span class="value">AES-256-GCM / SHA-256</span></div>
            <div class="info-row"><span class="label">Pre-Shared Key (PSK)</span><span class="value"><code>UB_ServerCorp2026_Secure_Key!</code></span></div>
            <div class="info-row"><span class="label">Admin Backup Username</span><span class="value"><code>sys_backup</code></span></div>
            <div class="info-row"><span class="label">Admin Backup Password</span><span class="value"><code>Backup_Agent_8829_Pass!</code></span></div>
        </div>

        <div class="card">
            <h3>Active Local LAN Client Directory</h3>
            <table>
                <thead>
                    <tr>
                        <th>IP Address</th>
                        <th>Device Name</th>
                        <th>MAC Address</th>
                        <th>Interface / Type</th>
                    </tr>
                </thead>
                <tbody>
                    <tr>
                        <td>192.168.1.10</td>
                        <td>CEO-Notebook</td>
                        <td>3C:A9:F4:11:AA:BB</td>
                        <td>Wireless (WPA2)</td>
                    </tr>
                    <tr>
                        <td>192.168.1.50</td>
                        <td>Corporate-DB-Server</td>
                        <td>00:15:5D:01:23:45</td>
                        <td>Wired (1Gbps)</td>
                    </tr>
                    <tr>
                        <td>192.168.1.100</td>
                        <td>Backup-NAS-01</td>
                        <td>90:E2:BA:44:55:66</td>
                        <td>Wired (1Gbps)</td>
                    </tr>
                </tbody>
            </table>
        </div>
    </div>
    <div class="footer">
        &copy; 2026 Ubuntu Linux Server Administration Console. Confidential Device.
    </div>
</body>
</html>
"""
            html = html.replace("ubuntu-server", socket.gethostname())
            response = (
                f"HTTP/1.1 200 OK\r\n"
                f"Content-Type: text/html\r\n"
                f"Content-Length: {len(html)}\r\n"
                f"Connection: close\r\n\r\n"
                f"{html}"
            ).encode("utf-8")
            client_socket.sendall(response)
            client_socket.close()
            return

        elif method == "GET" and route in ("", "/", "/index.html", "/index.htm", "/login", "/login.html"):
            # Return original NETGEAR Router Login HTML
            html = """<!DOCTYPE html>
<html>
<head>
    <title>Cockpit System Console Login</title>
    <style>
        body {
            font-family: 'Outfit', sans-serif;
            background-color: #0b0c10;
            color: #c5c6c7;
            margin: 0;
            padding: 0;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            background: radial-gradient(circle at center, #1f2833 0%, #0b0c10 100%);
        }
        .login-box {
            width: 400px;
            padding: 40px;
            background: rgba(31, 40, 51, 0.45);
            backdrop-filter: blur(10px);
            border: 1px solid rgba(102, 252, 241, 0.2);
            box-shadow: 0 8px 32px 0 rgba(0, 0, 0, 0.37);
            border-radius: 12px;
            text-align: center;
            transition: transform 0.3s ease;
        }
        .login-box:hover {
            transform: translateY(-5px);
        }
        h2 {
            color: #66fcf1;
            margin-bottom: 30px;
            font-weight: 600;
            letter-spacing: 1px;
            text-transform: uppercase;
        }
        .field {
            margin-bottom: 20px;
            text-align: left;
        }
        .field label {
            display: block;
            margin-bottom: 8px;
            color: #45f3ff;
            font-size: 14px;
        }
        .field input {
            width: 100%;
            padding: 12px;
            background: #0b0c10;
            border: 1px solid #45f3ff;
            border-radius: 6px;
            color: #fff;
            font-size: 15px;
            outline: none;
            transition: 0.3s;
        }
        .field input:focus {
            border-color: #66fcf1;
            box-shadow: 0 0 8px #66fcf1;
        }
        .btn {
            width: 100%;
            padding: 12px;
            background: #66fcf1;
            border: none;
            color: #0b0c10;
            font-weight: bold;
            font-size: 16px;
            cursor: pointer;
            border-radius: 6px;
            transition: 0.3s;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        .btn:hover {
            background: #45f3ff;
            box-shadow: 0 0 15px #45f3ff;
        }
        .footer {
            margin-top: 30px;
            font-size: 11px;
            color: #666;
            letter-spacing: 0.5px;
        }
    </style>
</head>
<body>
    <div class="login-box">
        <h2>System Web Console</h2>
        <form method="POST" action="/login">
            <div class="field">
                <label for="username">Username</label>
                <input type="text" id="username" name="username" required autocomplete="off">
            </div>
            <div class="field">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" required>
            </div>
            <button type="submit" class="btn">Log In</button>
        </form>
        <div class="footer">
            &copy; 2026 Ubuntu Linux Server. Authorized access only.
        </div>
    </div>
</body>
</html>
"""
            response = (
                f"HTTP/1.1 200 OK\r\n"
                f"Content-Type: text/html\r\n"
                f"Content-Length: {len(html)}\r\n"
                f"Connection: close\r\n\r\n"
                f"{html}"
            ).encode("utf-8")
            client_socket.sendall(response)
            client_socket.close()
            return

        elif method == "GET" and route == "/logout":
            response = (
                b"HTTP/1.1 302 Found\r\n"
                b"Location: /\r\n"
                b"Content-Length: 0\r\n"
                b"Connection: close\r\n\r\n"
            )
            client_socket.sendall(response)
            client_socket.close()
            return

        else:
            # Only tag this as active recon if the path itself looks like a
            # probe (sensitive files, CMS/admin panels, secrets, traversal,
            # etc). A bare "GET /" or a normal-looking asset request isn't
            # brute-forcing anything and shouldn't be logged as if it were.
            if SUSPICIOUS_PATH_PATTERN.search(route) or ".." in route or len(route) > 60:
                log_event(f"[ALERT] Directory brute-force detected from {ip} requesting: {first_line}")
                time.sleep(1)  # Brief delay to slow down scans
            else:
                log_event(f"[INFO] Generic HTTP request from {ip}: {first_line}")

            # Serve a real 404 for unknown paths — a real Apache doesn't
            # answer every missing path with 200 OK (that was a giveaway).
            body = (
                f'<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">\n'
                f'<html><head>\n'
                f'<title>404 Not Found</title>\n'
                f'</head><body>\n'
                f'<h1>Not Found</h1>\n'
                f'<p>The requested URL {route} was not found on this server.</p>\n'
                f'<hr>\n'
                f'<address>Apache/2.4.7 (Ubuntu) Server at {socket.gethostname()} Port 80</address>\n'
                f'</body></html>\n'
            ).encode("utf-8")
            response = (
                f"HTTP/1.1 404 Not Found\r\n"
                f"Content-Type: text/html\r\n"
                f"Content-Length: {len(body)}\r\n"
                f"Connection: close\r\n\r\n"
            ).encode("utf-8") + body
            client_socket.sendall(response)
            client_socket.close()
            return
    except Exception:
        pass
    finally:
        client_socket.close()


def handle_smtp(client_socket, client_address):
    ip, client_port = client_address
    log_event(
        f"[INFO] SMTP DECOY CONNECTED: Source IP {ip}:{client_port}. Tarpit Engaged."
    )
    send_notification(ip, "25 (SMTP Tarpit)")

    try:
        client_socket.sendall(PORTS[25])
        client_socket.settimeout(15.0)

        while True:
            data = client_socket.recv(1024)
            if not data:
                break

            line = data.decode("utf-8", errors="ignore").strip()
            if not line:
                continue

            log_event(f"[SMTP] Command from {ip}: {line}")

            cmd = line.split(" ", 1)[0].upper()

            if cmd == "EHLO":
                client_socket.sendall(
                    f"250-{socket.gethostname()}\r\n"
                    "250-PIPELINING\r\n"
                    "250-SIZE 10240000\r\n"
                    "250-VRFY\r\n"
                    "250-ENHANCEDSTATUSCODES\r\n"
                    "250-8BITMIME\r\n"
                    "250 DSN\r\n".encode("utf-8")
                )
            elif cmd == "HELO":
                client_socket.sendall(f"250 {socket.gethostname()}\r\n".encode("utf-8"))
            elif cmd == "MAIL":
                client_socket.sendall(b"250 2.1.0 Ok\r\n")
            elif cmd == "RCPT":
                client_socket.sendall(b"250 2.1.5 Ok\r\n")
            elif cmd == "DATA":
                client_socket.sendall(b"354 End data with <CR><LF>.<CR><LF>\r\n")
                data_buf = b""
                while True:
                    d = client_socket.recv(1024)
                    if not d:
                        break
                    data_buf += d
                    log_event(
                        f"[SMTP] DATA from {ip}: {d.decode('utf-8', errors='ignore')[:120]}"
                    )
                    if b"\r\n.\r\n" in data_buf or data_buf.strip() == b".":
                        break
                client_socket.sendall(
                    f"250 2.0.0 Ok: queued as {random.randint(100000000, 999999999)}\r\n".encode()
                )
            elif cmd == "VRFY":
                client_socket.sendall(
                    b"550 5.1.1 <user>: Recipient address rejected: User unknown in virtual mailbox table\r\n"
                )
            elif cmd == "EXPN":
                client_socket.sendall(b"502 5.5.2 Error: command not implemented\r\n")
            elif cmd == "STARTTLS":
                client_socket.sendall(b"454 4.7.0 TLS not available due to local problem\r\n")
            elif cmd == "AUTH":
                client_socket.sendall(b"503 5.5.1 Error: authentication not enabled\r\n")
            elif cmd == "NOOP":
                client_socket.sendall(b"250 2.0.0 Ok\r\n")
            elif cmd == "RSET":
                client_socket.sendall(b"250 2.0.0 Ok\r\n")
            elif cmd == "QUIT":
                client_socket.sendall(b"221 2.0.0 Bye\r\n")
                break
            else:
                client_socket.sendall(b"500 5.5.2 Error: command not recognized\r\n")
    except Exception:
        pass
    finally:
        client_socket.close()


def looks_like_smb_request(data):
    """A real SMB negotiate request starts with a 4-byte NetBIOS session
    header followed by the 0xFF 'SMB' signature. Anything else (raw HTTP
    text, Kerberos, RTSP, etc. landing on 445 during a -sV sweep) is not
    something a real SMB stack would parse or answer coherently."""
    return len(data) >= 8 and data[4:8] == b"\xffSMB"


def handle_generic(client_socket, port, client_address):
    ip, client_port = client_address
    log_event(
        f"[INFO] RECON DETECTED: Source IP {ip}:{client_port} connected to spoofed Port {port}"
    )
    send_notification(ip, str(port))

    try:
        client_socket.settimeout(5.0)

        if port == 445:
            # SMB doesn't send a greeting on connect — it waits for the
            # client's negotiate request first, then decides how to answer.
            try:
                first = client_socket.recv(1024)
            except socket.timeout:
                first = b""
            if first and looks_like_smb_request(first):
                log_event(
                    f"    - Received probe payload from {ip} on Port {port}: {first[:100]}"
                )
                client_socket.sendall(PORTS[445])
            else:
                # Non-SMB probe traffic — a real SMB service would just
                # never reply to this, so drop the connection instead of
                # echoing back a fingerprint that answers everything.
                if first:
                    log_event(
                        f"    - Dropped non-SMB probe from {ip} on Port {port}: {first[:100]}"
                    )
                return
        elif port in PORTS:
            client_socket.sendall(get_port_banner(port))

        while True:
            if (
                time.time() - FIRST_SEEN_TRACKER.get(ip, time.time())
                > TIME_LIMIT_BEFORE_BAN
            ):
                break

            try:
                data = client_socket.recv(1024)
                if data:
                    log_event(
                        f"    - Received probe payload from {ip} on Port {port}: {data[:100]}"
                    )
                else:
                    break
            except socket.timeout:
                client_socket.sendall(b"\x00")
    except Exception:
        pass
    finally:
        client_socket.close()


# DNS Poisoning / Deception parser and response generator


def parse_dns_query(data):
    try:
        domain = []
        idx = 12
        while True:
            length = data[idx]
            if length == 0:
                break
            domain.append(
                data[idx + 1 : idx + 1 + length].decode("utf-8", errors="ignore")
            )
            idx += 1 + length
        domain_name = ".".join(domain)
        qtype = (data[idx + 1] << 8) + data[idx + 2]
        return domain_name, qtype
    except Exception:
        return None, None


def build_dns_response(data, domain_name, ip_address="127.0.0.1"):
    try:
        tx_id = data[0:2]
        flags = b"\x81\x80"
        counts = b"\x00\x01\x00\x01\x00\x00\x00\x00"

        idx = 12
        while True:
            length = data[idx]
            if length == 0:
                idx += 1
                break
            idx += 1 + length
        question_section = data[12 : idx + 4]

        answer_name = b"\xc0\x0c"
        answer_type = b"\x00\x01"
        answer_class = b"\x00\x01"
        answer_ttl = b"\x00\x00\x00\x3c"
        answer_rdlength = b"\x00\x04"
        octets = [int(x) for x in ip_address.split(".")]
        answer_rdata = bytes(octets)

        response = (
            tx_id
            + flags
            + counts
            + data[12 : 12 + len(question_section)]
            + answer_name
            + answer_type
            + answer_class
            + answer_ttl
            + answer_rdlength
            + answer_rdata
        )
        return response
    except Exception:
        return None


def get_primary_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.254.254.254", 1))
        ip = s.getsockname()[0]
    except Exception:
        ip = "0.0.0.0"
    finally:
        s.close()
    return ip


def start_dns_listener():
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        bind_ip = get_primary_ip()
        if bind_ip == "127.0.0.1":
            bind_ip = "0.0.0.0"
        server.bind((bind_ip, 53))
        log_event(f"[*] Started DNS deception poisoner on UDP {bind_ip}:53")

        while True:
            data, addr = server.recvfrom(2048)
            ip, client_port = addr

            with TRACKER_LOCK:
                if ip not in FIRST_SEEN_TRACKER:
                    FIRST_SEEN_TRACKER[ip] = time.time()

            scan_attacker(ip)

            domain_name, qtype = parse_dns_query(data)
            if domain_name:
                log_event(
                    f"[ALERT] DNS QUERY DETECTED: Source IP {ip} queried '{domain_name}'"
                )

                local_ip = "127.0.0.1"
                try:
                    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    s.connect((ip, 80))
                    local_ip = s.getsockname()[0]
                    s.close()
                except Exception:
                    pass

                response = build_dns_response(data, domain_name, local_ip)
                if response:
                    server.sendto(response, addr)
                    log_event(
                        f"[INFO] DNS POISONED: Sent A record for {domain_name} -> {local_ip}"
                    )

                send_notification(ip, f"53 (DNS query for {domain_name})")
                ban_ip(ip)
    except OSError as e:
        log_event(f"[ERROR] Failed to bind DNS listener on UDP Port 53: {e}")
    except Exception as e:
        log_event(f"[ERROR] Error on DNS listener: {e}")


# Main execution loop


def start_listener(port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(("0.0.0.0", port))
        server.listen(10)
        log_event(f"[*] Started deception honeypot listener on Port {port}")

        while True:
            client_sock, client_addr = server.accept()

            if port == 21:
                handler = handle_ftp
            elif port == 22:
                handler = handle_ssh
            elif port == 23:
                handler = handle_telnet
            elif port == 25:
                handler = handle_smtp
            elif port == 80:
                handler = handle_http
            else:
                handler = lambda cs, addr: handle_generic(cs, port, addr)

            # Wrapper to initialize tracking and check ban after thread execution
            def wrapped_handler(cs, addr):
                ip = addr[0]
                with TRACKER_LOCK:
                    if ip not in FIRST_SEEN_TRACKER:
                        FIRST_SEEN_TRACKER[ip] = time.time()
                scan_attacker(ip)
                try:
                    handler(cs, addr)
                finally:
                    ban_ip(ip)

            client_thread = threading.Thread(
                target=wrapped_handler, args=(client_sock, client_addr), daemon=True
            )
            client_thread.start()
    except OSError as e:
        log_event(f"[ERROR] Failed to bind listener on Port {port}: {e}")
    except Exception as e:
        log_event(f"[ERROR] Error on Port {port} listener: {e}")


def start_snmp_listener():
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("0.0.0.0", 161))
        log_event("[*] Started SNMP deception responder on UDP Port 161")
    except OSError as e:
        log_event(f"[ERROR] Failed to bind SNMP listener on UDP Port 161: {e}")
        return
    except Exception as e:
        log_event(f"[ERROR] Error on SNMP listener: {e}")
        return

    while True:
        try:
            data, addr = sock.recvfrom(2048)
            if not data:
                continue
            ip, port = addr
            log_event(f"[INFO] SNMP PROBE DETECTED: Source IP {ip}:{port}")
            send_notification(ip, "161 (SNMP)")
            scan_attacker(ip)
            persona = get_active_persona()
            host = socket.gethostname()
            if persona == "cisco":
                desc = f"Cisco IOS Software, C3560 Software (C3560-IPSERVICESK9-M), Version 12.2(55)SE10, RELEASE SOFTWARE (fc1)"
            elif persona == "synology":
                desc = f"Synology DiskStation DSM 7.1-42661 Linux 4.4.180+ #42661 SMP {host}"
            else:
                desc = f"Linux {host} 4.15.0-142-generic #146-Ubuntu SMP Tue Apr 13 01:11:19 UTC 2021 x86_64"

            if b"public" in data or b"private" in data:
                resp_str = desc.encode("utf-8")
                resp = b"\x30" + bytes([len(resp_str) + 18]) + b"\x02\x01\x01\x04\x06public\xa2" + bytes([len(resp_str) + 9]) + b"\x02\x01\x01\x02\x01\x00\x30" + bytes([len(resp_str) + 2]) + b"\x04" + bytes([len(resp_str)]) + resp_str
                sock.sendto(resp, addr)
        except Exception:
            continue


def main():
    if os.geteuid() != 0:
        print("[ERROR] Must run as root to bind ports below 1024", file=sys.stderr)
        sys.exit(1)

    log_event("--- Recon Deception Honeypot Daemon Started ---")
    log_event(f"[*] Active Ban Time Limit set to: {TIME_LIMIT_BEFORE_BAN} seconds")
    write_telnet_credential_file()
    log_event(
        f"[*] Decoy telnet credential set: Username={TELNET_USERNAME}, "
        f"Password={TELNET_PASSWORD} (saved to {TELNET_CRED_FILE})"
    )

    threads = []
    dns_t = threading.Thread(target=start_dns_listener, daemon=True)
    dns_t.start()
    threads.append(dns_t)

    snmp_t = threading.Thread(target=start_snmp_listener, daemon=True)
    snmp_t.start()
    threads.append(snmp_t)

    for port in PORTS.keys():
        if port == 22 and os.path.exists(COWRIE_ACTIVE_FILE):
            log_event(
                "[*] Cowrie SSH honeypot marker present; skipping banner decoy "
                "on Port 22 (handed off to cowrie container)"
            )
            continue
        t = threading.Thread(target=start_listener, args=(port,), daemon=True)
        t.start()
        threads.append(t)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        log_event("--- Recon Deception Honeypot Daemon Stopped ---")
        sys.exit(0)


if __name__ == "__main__":
    main()
