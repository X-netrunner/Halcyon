#!/usr/bin/env python3
"""halcyon-pass.py: native, lightweight, AES-256 encrypted password manager for Halcyon.

Vault: ~/.local/state/island/vault.enc  (AES-256-CBC, PBKDF2 via openssl; same file format as before, old vaults still open)
Key:   ~/.local/state/island/.vault.key (0600, made once; the vault is NEVER re-keyed or overwritten if it cannot be opened)

Usage:
  passman list [keyword]                   list saved services (optionally filtered)
  passman search <keyword>                 same as list <keyword>
  passman get <service> [--show|-s]        copy the password to the clipboard (cleared after 30 s)
  passman show <service>                   print username and password
  passman add <service> [user] [pass]      add or update an entry
  passman add <service> [user] -g [len]    add with a generated password
  passman add <service> [user] --stdin     read the password from stdin (keeps it out of shell history)
  passman edit <service> [user]            change the username and / or password of an entry
  passman del <service>                    delete an entry
  passman gen [length]                     generate a password (copied, cleared after 30 s)
  passman backup [file]                    copy the encrypted vault (default: ~/vault-backup-<date>.enc)
  passman import <file.csv>                import a Brave / Chrome / Edge password export (name,url,username,password)
  passman browser                          set up "save this login?" prompts in Brave / Chromium browsers
  passman status                           check the vault, the key and the tools
"""

import fcntl
import getpass
import hashlib
import json
import os
import secrets
import shutil
import string
import subprocess
import sys
import time

STATE_DIR = os.path.expanduser("~/.local/state/island")
VAULT_FILE = os.path.join(STATE_DIR, "vault.enc")
BACKUP_FILE = VAULT_FILE + ".bak"
KEY_FILE = os.path.join(STATE_DIR, ".vault.key")
LOCK_FILE = os.path.join(STATE_DIR, ".vault.lock")
SYMBOLS = "!@#$%^&*()-_=+"
CLIP_SECONDS = 30
USE_COLOUR = sys.stdout.isatty()


class VaultError(Exception):
    """Anything that must stop a command before it can damage the vault."""


def c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if USE_COLOUR else text


def err(msg: str):
    print(c("1;31", "[!]") + " " + msg, file=sys.stderr)


# ------------------------------------------------------------------------------------------------ key handling
def read_key():
    """The device key, or None if there is no usable key file."""
    try:
        with open(KEY_FILE, "rb") as f:
            key = f.read().strip()
        return key if len(key) >= 32 else None
    except FileNotFoundError:
        return None
    except OSError as e:
        raise VaultError(f"Cannot read the key file {KEY_FILE}: {e}")


def get_key(create_ok: bool) -> bytes:
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    key = read_key()
    if key:
        return key
    if os.path.isfile(VAULT_FILE) and os.path.getsize(VAULT_FILE) > 0:
        # A vault with no key cannot be opened. Making a new key here is exactly what used to wipe the vault.
        raise VaultError(
            f"The vault exists ({VAULT_FILE}) but its key file is missing or damaged ({KEY_FILE}).\n"
            "    Nothing was changed. Put the original .vault.key back (check a backup of ~/.local/state/island).")
    if not create_ok:
        return b""
    new_key = secrets.token_hex(32).encode()
    fd = os.open(KEY_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(new_key)
        f.flush()
        os.fsync(f.fileno())
    return new_key


# ------------------------------------------------------------------------------------------------ crypto
def _openssl(decrypt: bool, data: bytes, key: bytes) -> bytes:
    """The passphrase goes through its own pipe (fd), the data through stdin: they can no longer eat each other's bytes."""
    if shutil.which("openssl") is None:
        raise VaultError("openssl is not installed (sudo pacman -S openssl).")
    r, w = os.pipe()
    try:
        cmd = ["openssl", "enc"] + (["-d"] if decrypt else []) + ["-aes-256-cbc", "-pbkdf2", "-iter", "100000", "-salt", "-pass", f"fd:{r}"]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(r,))
        os.close(r)
        r = -1
        os.write(w, key + b"\n")
        os.close(w)
        w = -1
        out, errb = proc.communicate(input=data)
    finally:
        for fd in (r, w):
            if fd >= 0:
                os.close(fd)
    if proc.returncode != 0:
        text = errb.decode("utf-8", "replace")
        if decrypt and ("bad decrypt" in text or "bad magic" in text):
            raise VaultError("Decryption failed: wrong key, or the vault file is damaged")
        msg = text.strip().splitlines()
        raise VaultError(("Decryption" if decrypt else "Encryption") + " failed: " + (msg[-1] if msg else f"openssl exit {proc.returncode}"))
    return out


def decrypt_data(cipher: bytes, key: bytes) -> bytes:
    return _openssl(True, cipher, key)


def encrypt_data(plain: bytes, key: bytes) -> bytes:
    return _openssl(False, plain, key)


# ------------------------------------------------------------------------------------------------ vault file
class locked:
    """One writer at a time (the island, QuickTerm and a terminal can all call passman)."""
    def __enter__(self):
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        self.f = open(LOCK_FILE, "a")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def load_vault(create_ok: bool = False) -> dict:
    """The vault, or a fresh empty one if there is none yet. Raises VaultError if it exists but cannot be opened."""
    if not os.path.isfile(VAULT_FILE) or os.path.getsize(VAULT_FILE) == 0:
        return {"version": 1, "entries": {}}
    key = get_key(create_ok=False)
    with open(VAULT_FILE, "rb") as f:
        cipher = f.read()
    try:
        data = json.loads(decrypt_data(cipher, key).decode("utf-8"))
    except VaultError as e:
        raise VaultError(f"{e}\n    The vault was NOT changed. The key file may not match this vault (restore {BACKUP_FILE} or the original .vault.key).")
    except ValueError:
        raise VaultError("The vault decrypted but is not valid JSON. It was NOT changed; restore " + BACKUP_FILE)
    if not isinstance(data, dict):
        raise VaultError("The vault has an unexpected format. It was NOT changed.")
    data.setdefault("version", 1)
    if not isinstance(data.get("entries"), dict):
        data["entries"] = {}
    return data


def save_vault(vault: dict):
    key = get_key(create_ok=True)
    plain = json.dumps(vault, indent=2).encode("utf-8")
    cipher = encrypt_data(plain, key)
    if decrypt_data(cipher, key) != plain:         # never replace the vault with something that does not open again
        raise VaultError("Self-check failed; nothing was written.")
    tmp = VAULT_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(cipher)
        f.flush()
        os.fsync(f.fileno())
    if os.path.isfile(VAULT_FILE) and os.path.getsize(VAULT_FILE) > 0:
        shutil.copy2(VAULT_FILE, BACKUP_FILE)       # the last good copy
        os.chmod(BACKUP_FILE, 0o600)
    os.replace(tmp, VAULT_FILE)


# ------------------------------------------------------------------------------------------------ helpers
def generate_password(length: int = 20) -> str:
    length = max(8, min(128, length))
    alphabet = string.ascii_letters + string.digits + SYMBOLS
    while True:
        pwd = "".join(secrets.choice(alphabet) for _ in range(length))
        if (any(ch.islower() for ch in pwd) and any(ch.isupper() for ch in pwd)
                and any(ch.isdigit() for ch in pwd) and any(ch in SYMBOLS for ch in pwd)):
            return pwd


def copy_to_clipboard_timed(text: str, timeout_sec: int = CLIP_SECONDS) -> bool:
    """Copy (the text goes through stdin, never through the process list) and clear it again if it is still there."""
    # --sensitive marks the copy as a secret: clipboard history tools (cliphist behind SUPER+V) skip it instead of writing
    # the password to disk in plain text. An older wl-copy does not know the flag, so the plain call follows as a fallback.
    for cmd, clear in ((["wl-copy", "--sensitive"], ["wl-copy", "--clear"]),
                       (["wl-copy"], ["wl-copy", "--clear"]),
                       (["xclip", "-selection", "clipboard"], None)):
        if shutil.which(cmd[0]) is None:
            continue
        try:
            subprocess.run(cmd, input=text.encode("utf-8"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True)
        except (subprocess.SubprocessError, OSError):
            continue
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if clear:
            script = ('sleep "$1"; cur=$(wl-paste -n 2>/dev/null | sha256sum | cut -d" " -f1); '
                      '[ "$cur" = "$2" ] && wl-copy --clear 2>/dev/null; exit 0')
        else:
            script = ('sleep "$1"; cur=$(xclip -o -selection clipboard 2>/dev/null | sha256sum | cut -d" " -f1); '
                      '[ "$cur" = "$2" ] && printf "" | xclip -selection clipboard 2>/dev/null; exit 0')
        subprocess.Popen(["bash", "-c", script, "_", str(timeout_sec), digest], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return True
    err("No clipboard tool found (install wl-clipboard).")
    return False


def find_service(entries: dict, name: str):
    """Exact, then case-insensitive, then a single partial match. Returns the key, or None after saying why."""
    if name in entries:
        return name
    low = name.lower()
    for s in entries:
        if s.lower() == low:
            return s
    part = [s for s in entries if low in s.lower()]
    if len(part) == 1:
        return part[0]
    if len(part) > 1:
        err(f"Ambiguous match for '{name}': " + ", ".join(sorted(part)))
    else:
        err(f"No entry found for: {name}")
    return None


# ------------------------------------------------------------------------------------------------ commands
def list_entries(filter_kw: str = ""):
    entries = load_vault().get("entries", {})
    if not entries:
        print(c("1;33", "Vault is empty.") + " Use " + c("1", "passman add <service> [username]") + " to add passwords.")
        return
    kw = filter_kw.lower().strip()
    items = []
    for srv, info in sorted(entries.items(), key=lambda x: x[0].lower()):
        user = info.get("user", "")
        if kw and kw not in srv.lower() and kw not in user.lower():
            continue
        items.append((srv, user, info.get("updated", "")))
    if not items:
        print(c("1;33", "No entries found matching:") + f" {filter_kw}")
        return
    print(c("1;36", "Halcyon Password Vault"))
    print(c("90", f"{'SERVICE':<24} {'USERNAME/EMAIL':<28} {'LAST UPDATED':<16}"))
    print(c("90", "-" * 70))
    for srv, user, updated in items:
        dt = time.strftime("%Y-%m-%d %H:%M", time.localtime(updated)) if isinstance(updated, (int, float)) else str(updated)[:16]
        print(f"{c('1', f'{srv:<24}')} {(user or '-'):<28} {c('90', f'{dt:<16}')}")
    print(c("90", f"\nTotal: {len(items)} entr{'y' if len(items) == 1 else 'ies'}. Run 'passman get <service>' to copy."))


def get_entry(service: str, show: bool = False) -> int:
    entries = load_vault().get("entries", {})
    key = find_service(entries, service)
    if key is None:
        return 1
    entry = entries[key]
    pwd, usr = entry.get("pass", ""), entry.get("user", "")
    if show:
        print(c("1;36", "Service:  ") + key)
        if usr:
            print(c("1;36", "User:     ") + usr)
        print(c("1;32", "Password: ") + pwd)
        return 0
    if usr:
        print(c("1;36", "User:     ") + usr)
    if copy_to_clipboard_timed(pwd):
        print(c("1;32", "OK") + f" Password for {c('1', key)} copied to the clipboard " + c("90", f"(clears in {CLIP_SECONDS} s)"))
        return 0
    print(c("1;32", f"Password for {key}: ") + pwd)
    return 0


def find_exact(entries: dict, name: str):
    if name in entries:
        return name
    for s in entries:
        if s.lower() == name.lower():
            return s
    return None


def _keep_history(old: dict, pwd: str) -> list:
    hist = list(old.get("history", []))
    if old.get("pass") and old.get("pass") != pwd:
        hist = ([{"pass": old["pass"], "changed": old.get("updated", 0)}] + hist)[:3]
    return hist


def _merge(entries: dict, service: str, user: str, pwd: str) -> str:
    """Put one login into `entries` (the caller holds the lock and saves). Returns saved | updated | unchanged."""
    existing = find_exact(entries, service)
    old = entries.get(existing) if existing else None
    user = user.strip()
    if old and old.get("pass") == pwd and (old.get("user", "") == user or not user):
        return "unchanged"
    rec = {"user": user or (old or {}).get("user", ""), "pass": pwd, "updated": time.time()}
    if old:
        hist = _keep_history(old, pwd)
        if hist:
            rec["history"] = hist
    entries[existing or service] = rec
    return "updated" if old else "saved"


def add_entry(service: str, user: str = "", pwd: str = "", generate: bool = False, length: int = 20, from_stdin: bool = False) -> int:
    service = service.strip()
    if not service:
        print("Usage: passman add <service> [username] [password] [-g [length]] [--stdin]")
        return 1
    note = ""
    if from_stdin:
        pwd = sys.stdin.readline().rstrip("\r\n")
        if not pwd:
            err("--stdin was given but nothing was read.")
            return 1
    elif generate:
        pwd = generate_password(length)
        note = "Generated password: " + c("1;32", pwd)
    elif not pwd:
        if sys.stdin.isatty():
            pwd = getpass.getpass(f"Password for {service} (blank = generate one): ")
        if not pwd:
            pwd = generate_password(length)
            note = "No password was given, so one was generated: " + c("1;32", pwd)
    # Questions are asked BEFORE the vault lock is taken. The lock used to be held while waiting for an answer, so a prompt
    # left open froze every other writer (the browser's "save this login?" included) until someone typed something.
    if sys.stdin.isatty() and not from_stdin:
        existing = find_exact(load_vault().get("entries", {}), service)
        if existing and input(f"'{existing}' already exists. Replace it? [y/N] ").strip().lower() not in ("y", "yes"):
            print("Nothing changed.")
            return 1
    with locked():
        vault = load_vault(create_ok=True)
        entries = vault["entries"]
        existing = find_exact(entries, service)
        result = _merge(entries, service, user, pwd)
        if result != "unchanged":
            save_vault(vault)
        service = existing or service
    print(c("1;32", "OK") + f" {'Updated' if result == 'updated' else 'Saved'} {c('1', service)}")
    if note:
        print(note)
    if copy_to_clipboard_timed(pwd):
        print(c("90", f"(copied to the clipboard; clears in {CLIP_SECONDS} s)"))
    return 0


def store_entry(service: str, user: str, pwd: str) -> str:
    """Quiet add for the browser helper and the importer: no prompts, no clipboard.  Returns saved | updated | unchanged."""
    service = service.strip()
    if not service or not pwd:
        raise VaultError("service and password are required")
    with locked():
        vault = load_vault(create_ok=True)
        result = _merge(vault["entries"], service, user, pwd)
        if result != "unchanged":
            save_vault(vault)
    return result


def import_csv(path: str) -> int:
    """Chrome / Brave / Edge export: name,url,username,password[,note].  One entry per site; an existing one is only changed if the password differs.
    The whole file is merged in memory and the vault is written ONCE. It used to decrypt and re-encrypt the vault several
    times per row (a few hundred logins took minutes) and it overwrote vault.enc.bak at every row, so the backup never held
    the vault as it was before the import."""
    import csv
    from urllib.parse import urlparse
    path = os.path.expanduser(path)
    if not os.path.isfile(path):
        err(f"No such file: {path}")
        return 1
    counts = {"saved": 0, "updated": 0, "unchanged": 0, "skipped": 0}
    try:
        with locked():
            vault = load_vault(create_ok=True)
            entries = vault["entries"]
            with open(path, newline="", encoding="utf-8-sig") as f:
                for row in csv.DictReader(f):
                    row = {(k or "").strip().lower(): (v or "") for k, v in row.items() if isinstance(v, (str, type(None)))}
                    pwd, user = row.get("password", ""), row.get("username", "") or row.get("user", "")
                    host = (urlparse(row.get("url", "")).hostname or "").removeprefix("www.")
                    name = host or row.get("name", "").strip()
                    if not name or not pwd:
                        counts["skipped"] += 1
                        continue
                    k = find_exact(entries, name)
                    if user and k and entries[k].get("user", "") and entries[k].get("user", "") != user:
                        name = f"{name} ({user})"      # a second account on the same site
                    counts[_merge(entries, name, user, pwd)] += 1
            if counts["saved"] or counts["updated"]:
                save_vault(vault)
    except (csv.Error, UnicodeDecodeError) as e:
        err(f"Could not read {path} as a password export ({type(e).__name__}); the vault was not changed.")
        return 1
    print(c("1;32", "OK") + f" Imported: {counts['saved']} new, {counts['updated']} updated, {counts['unchanged']} unchanged, {counts['skipped']} skipped")
    print(c("90", "Now delete the CSV (it holds every password in plain text):  shred -u " + path))
    return 0


def edit_entry(service: str, new_user: str = "") -> int:
    entries = load_vault().get("entries", {})
    key = find_service(entries, service)
    if key is None:
        return 1
    new_pass = ""
    if sys.stdin.isatty():            # asked before the lock is taken (see add_entry)
        new_pass = getpass.getpass(f"New password for {key} (blank = keep, 'g' = generate): ")
        if new_pass == "g":
            new_pass = generate_password()
            print("Generated password: " + c("1;32", new_pass))
    with locked():
        vault = load_vault()
        e = vault["entries"].get(key)
        if e is None:
            err(f"Entry not found: {key}")
            return 1
        if new_user:
            e["user"] = new_user.strip()
        if new_pass:
            e["pass"], e["history"] = new_pass, _keep_history(e, new_pass)
        e["updated"] = time.time()
        save_vault(vault)
    print(c("1;32", "OK") + f" Updated {c('1', key)}")
    return 0


def del_entry(service: str) -> int:
    key = find_exact(load_vault().get("entries", {}), service)
    if key is None:
        err(f"Entry not found: {service}")
        return 1
    if sys.stdin.isatty() and input(f"Delete '{key}'? [y/N] ").strip().lower() not in ("y", "yes"):
        print("Nothing changed.")
        return 1
    with locked():
        vault = load_vault()
        if key not in vault["entries"]:
            err(f"Entry not found: {service}")
            return 1
        del vault["entries"][key]
        save_vault(vault)
    print(c("1;32", "OK") + f" Deleted {c('1', key)} (the previous vault is kept as vault.enc.bak)")
    return 0


def backup(dest: str = "") -> int:
    if not os.path.isfile(VAULT_FILE):
        err("There is no vault to back up yet.")
        return 1
    dest = os.path.expanduser(dest) if dest else os.path.expanduser(f"~/vault-backup-{time.strftime('%Y-%m-%d')}.enc")
    shutil.copy2(VAULT_FILE, dest)
    os.chmod(dest, 0o600)
    print(c("1;32", "OK") + f" Encrypted vault copied to {dest}")
    print(c("90", "It only opens with ~/.local/state/island/.vault.key: back that file up too, but keep it somewhere else."))
    return 0


def status() -> int:
    ok = shutil.which("openssl") is not None
    print(c("1;36", "Halcyon password vault: status"))
    print(f"  {'openssl':<14}" + ("found" if ok else c("1;31", "MISSING")))
    print(f"  {'clipboard':<14}" + ("found" if (shutil.which("wl-copy") or shutil.which("xclip")) else c("1;33", "no wl-copy / xclip (passwords are printed instead)")))
    print(f"  {'key file':<14}" + ("present" if read_key() else c("1;31", "missing")))
    print(f"  {'vault file':<14}" + ((f"{os.path.getsize(VAULT_FILE)} bytes") if os.path.isfile(VAULT_FILE) else "none yet"))
    print(f"  {'last backup':<14}" + (time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(BACKUP_FILE))) if os.path.isfile(BACKUP_FILE) else "none yet"))
    if shutil.which("wl-copy") and shutil.which("cliphist"):
        try:
            h = subprocess.run(["wl-copy", "--help"], capture_output=True, text=True, timeout=3)
            sensitive = "--sensitive" in (h.stdout + h.stderr)
        except (subprocess.SubprocessError, OSError):
            sensitive = False
        if not sensitive:
            print(f"  {'clip history':<14}" + c("1;33", "wl-copy has no --sensitive: copied passwords are kept by cliphist (SUPER+V). Update wl-clipboard or switch the clipboard history off."))
    try:
        n = len(load_vault().get("entries", {}))
        print(f"  {'opens':<14}" + c("1;32", f"yes, {n} entries"))
    except VaultError as e:
        print(f"  {'opens':<14}" + c("1;31", "NO"))
        print("    " + str(e))
        ok = False
    return 0 if ok else 1


def print_help():
    print(__doc__.split("Usage:\n")[1].rstrip())


def main() -> int:
    args = sys.argv[1:]
    if not args:
        list_entries()
        return 0
    cmd, rest = args[0].lower(), args[1:]
    if cmd in ("list", "ls", "search", "find"):
        list_entries(rest[0] if rest else "")
    elif cmd in ("get", "copy"):
        names = [a for a in rest if a not in ("--show", "-s")]
        if not names:
            print("Usage: passman get <service> [--show|-s]")
            return 1
        return get_entry(" ".join(names), show=("--show" in rest or "-s" in rest))
    elif cmd == "show":
        if not rest:
            print("Usage: passman show <service>")
            return 1
        return get_entry(rest[0], show=True)
    elif cmd in ("add", "new", "set"):
        if not rest:
            print("Usage: passman add <service> [username] [password] [-g [length]] [--stdin]")
            return 1
        flags = ("-g", "--gen", "--generate", "--stdin")
        gen = any(a in rest for a in ("-g", "--gen", "--generate"))
        length = 20
        rest = list(rest)
        for i, a in enumerate(rest):                          # the number right after -g is the length: passman add svc -g 32
            if a in ("-g", "--gen", "--generate") and i + 1 < len(rest) and rest[i + 1].isdigit():
                length = int(rest.pop(i + 1))
                break
        pos = [a for a in rest if a not in flags]
        return add_entry(pos[0], pos[1] if len(pos) > 1 else "", pos[2] if len(pos) > 2 else "",
                         generate=gen, length=length, from_stdin="--stdin" in rest)
    elif cmd == "edit":
        if not rest:
            print("Usage: passman edit <service> [new username]")
            return 1
        return edit_entry(rest[0], rest[1] if len(rest) > 1 else "")
    elif cmd in ("del", "rm", "delete"):
        if not rest:
            print("Usage: passman del <service>")
            return 1
        return del_entry(rest[0])
    elif cmd in ("gen", "generate"):
        length = int(rest[0]) if rest and rest[0].isdigit() else 20
        pwd = generate_password(length)
        print(c("1;32", pwd))
        if copy_to_clipboard_timed(pwd):
            print(c("90", f"(copied to the clipboard; clears in {CLIP_SECONDS} s)"))
    elif cmd == "import":
        if not rest:
            print("Usage: passman import <file.csv>   (Brave: brave://password-manager/settings > Export passwords)")
            return 1
        return import_csv(rest[0])
    elif cmd == "browser":
        setup = os.path.join(os.path.dirname(os.path.abspath(__file__)), "passman-browser-setup.sh")
        return subprocess.call(["bash", setup] + rest)
    elif cmd == "backup":
        return backup(rest[0] if rest else "")
    elif cmd in ("status", "doctor", "check"):
        return status()
    elif cmd in ("help", "-h", "--help"):
        print_help()
    elif cmd.startswith("-"):
        print_help()
        return 1
    else:
        return get_entry(args[0])      # "passman github" is a shorthand for "passman get github"
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except VaultError as e:
        err(str(e))
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
