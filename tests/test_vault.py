"""Password vault: python3 tests/test_vault.py   (scripts/halcyon-pass.py in a throwaway HOME; needs openssl, not the keyring)
An old unsealed vault still opens and is sealed on its next save, a changed byte or a wrong key is refused, the file is untouched."""
import importlib.util, io, os, sys, tempfile, contextlib, hashlib

here = os.path.dirname(os.path.abspath(__file__))
home = tempfile.mkdtemp(prefix="halcyon-vault-test-")
os.environ.update({"HOME": home, "PATH": "/usr/bin:/bin", "HALCYON_VAULT_KEYRING_ITEM": "test-never-stored"})
spec = importlib.util.spec_from_file_location("passman", os.path.join(here, "..", "scripts", "halcyon-pass.py"))
pm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pm)
pm.keyring_key = lambda: None                 # never ask the real desktop keyring from a test

bad = 0


def check(label, got, want):
    global bad
    if got != want:
        bad += 1
        print(f"FAIL {label}: {got!r} (want {want!r})")


def raises(label, fn):
    global bad
    try:
        fn()
    except pm.VaultError:
        return
    bad += 1
    print(f"FAIL {label}: no VaultError")


def digest(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


key = pm.get_key(create_ok=True)
# an old vault: plain openssl output, no seal
old = pm._openssl(False, b'{"version": 1, "entries": {"a.com": {"user": "x", "pass": "1"}}}', key)
os.makedirs(pm.STATE_DIR, exist_ok=True)
with open(pm.VAULT_FILE, "wb") as f:
    f.write(old)
check("old vault opens", list(pm.load_vault()["entries"]), ["a.com"])

v = pm.load_vault()
v["entries"]["b.org"] = {"user": "y", "pass": "2"}
pm.save_vault(v)
check("saved vault is sealed", open(pm.VAULT_FILE, "rb").read().startswith(pm.SEAL), True)
check("sealed vault opens", sorted(pm.load_vault()["entries"]), ["a.com", "b.org"])

good = open(pm.VAULT_FILE, "rb").read()
for pos in (len(pm.SEAL) + 3, len(good) - 5):                    # a byte of the seal, a byte of the data
    b = bytearray(good)
    b[pos] ^= 1
    with open(pm.VAULT_FILE, "wb") as f:
        f.write(b)
    before = digest(pm.VAULT_FILE)
    raises(f"changed byte at {pos} is refused", pm.load_vault)
    check(f"changed vault left as it was ({pos})", digest(pm.VAULT_FILE), before)

with open(pm.VAULT_FILE, "wb") as f:
    f.write(good)
check("wrong key is refused", (lambda: (raises("wrong key", lambda: pm.decrypt_data(good, b"a" * 64)), True)[1])(), True)

with contextlib.redirect_stdout(io.StringIO()):
    rc = pm.main.__globals__["status"]()
check("status passes", rc, 0)

print("ok" if not bad else f"{bad} failed")
sys.exit(1 if bad else 0)
