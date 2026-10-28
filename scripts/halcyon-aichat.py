#!/usr/bin/env python3
"""halcyon-aichat.py: the runner behind Halcyon's AI chatbox (QuickChat.qml).

One chat, several providers. Switching is one click in the box and takes effect at once:

  luna        Luna, the local assistant (runs on this machine, has tools and saved sessions: it goes through halcyon-luna.py,
              so the chat is the same conversation you see in the >luna window)
  ollama      a model Ollama serves on this machine
  openrouter  openai  anthropic  gemini  groq  deepseek     hosted models, one API key each
  custom      any OpenAI-compatible endpoint (vLLM, LM Studio, llama.cpp server ...)

"auto" (the default until you pick one) means: Luna when she is installed, otherwise Ollama.

  halcyon-aichat.py status                 everything the box needs to draw itself, as JSON (config, which providers are ready,
                                           Ollama's models, Luna's state). API keys are never part of it.
  halcyon-aichat.py set-config <json>      save choices (provider, models, ollamaHost, customEndpoint, systemPrompt)
  halcyon-aichat.py set-key <provider>     store that provider's API key, read from STANDARD INPUT (empty input removes it)
  halcyon-aichat.py luna-new               start a fresh Luna session for the chatbox
  halcyon-aichat.py stream                 one reply: request JSON on stdin, one JSON object per line on stdout
      {"type": "delta", "text"}            a piece of the answer
      {"type": "tool", "state": "start"|"end", "name", "summary", "ok"}    what Luna is running (Luna only)
      {"type": "think"}                    Luna is reasoning (no text, just a heartbeat)
      {"type": "done", "text", "model", "provider", "secs"}
      {"type": "error", "error"}

Keys live in ~/.local/state/island/aichat-keys.json (mode 0600) and are only ever sent to the provider they belong to.
Settings live in ~/.local/state/island/aichat.json.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(HOME, ".local", "state", "island")
CONFIG_FILE = os.path.join(STATE_DIR, "aichat.json")
KEYS_FILE = os.path.join(STATE_DIR, "aichat-keys.json")
HERE = os.path.dirname(os.path.abspath(__file__))
LUNA_PY = os.path.join(HERE, "halcyon-luna.py")
LUNA_DATA = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share"), "halcyon", "luna", "sessions")
GAMING_FLAG = "/dev/shm/halcyon-gamemode"
AI_OFF_FLAG = os.path.join(STATE_DIR, "ai-off")
os.makedirs(STATE_DIR, exist_ok=True)

SYSTEM_PROMPT = ("You are a concise, helpful assistant inside the Halcyon desktop on Arch Linux. "
                 "Answer directly, in plain text, without filler.")

# kind: luna | ollama | openai (OpenAI-compatible chat completions) | anthropic (native messages API)
PROVIDERS = {
    "luna":       {"name": "Luna",       "kind": "luna"},
    "ollama":     {"name": "Ollama",     "kind": "ollama",    "model": "qwen2.5:3b-instruct"},
    "openrouter": {"name": "OpenRouter", "kind": "openai",    "model": "openai/gpt-4o-mini",
                   "endpoint": "https://openrouter.ai/api/v1/chat/completions",
                   "presets": ["openai/gpt-4o-mini", "anthropic/claude-haiku-5-5", "deepseek/deepseek-chat", "meta-llama/llama-3.3-70b-instruct:free"]},
    "openai":     {"name": "OpenAI",     "kind": "openai",    "model": "gpt-4o-mini",
                   "endpoint": "https://api.openai.com/v1/chat/completions",
                   "presets": ["gpt-4o-mini", "gpt-4o"]},
    "anthropic":  {"name": "Anthropic",  "kind": "anthropic", "model": "claude-haiku-5-5",
                   "endpoint": "https://api.anthropic.com/v1/messages",
                   "presets": ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]},
    "gemini":     {"name": "Gemini",     "kind": "openai",    "model": "gemini-2.5-flash",
                   "endpoint": "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                   "presets": ["gemini-2.5-flash", "gemini-2.5-pro"]},
    "groq":       {"name": "Groq",       "kind": "openai",    "model": "llama-3.3-70b-versatile",
                   "endpoint": "https://api.groq.com/openai/v1/chat/completions",
                   "presets": ["llama-3.3-70b-versatile", "llama-3.1-8b-instant"]},
    "deepseek":   {"name": "DeepSeek",   "kind": "openai",    "model": "deepseek-chat",
                   "endpoint": "https://api.deepseek.com/chat/completions",
                   "presets": ["deepseek-chat", "deepseek-reasoner"]},
    "custom":     {"name": "Custom",     "kind": "openai",    "model": "", "endpoint": ""},
}
ORDER = ["luna", "ollama", "openrouter", "openai", "anthropic", "gemini", "groq", "deepseek", "custom"]
KEYLESS = ("luna", "ollama")
DEFAULT_HOST = "http://127.0.0.1:11434"


def out(o):
    print(json.dumps(o), flush=True)


# ------------------------------------------------------------------------------------------------ files

def read_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            v = json.load(f)
        return v if isinstance(v, type(default)) else default
    except (OSError, ValueError):
        return default


def write_json(path, obj, private=False):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600 if private else 0o644)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
    os.replace(tmp, path)
    if private:
        os.chmod(path, 0o600)


def load_config():
    """The saved choices, with the older layout (backend / apiProvider / apiModel / apiKey) carried over once."""
    saved = read_json(CONFIG_FILE, {})
    cfg = {"provider": "auto", "models": {}, "ollamaHost": DEFAULT_HOST, "customEndpoint": "", "lunaSession": "", "systemPrompt": SYSTEM_PROMPT}
    cfg.update({k: v for k, v in saved.items() if k in cfg})
    if "provider" not in saved and "backend" in saved:               # old file
        b = saved.get("backend")
        if b == "api":
            cfg["provider"] = saved.get("apiProvider") if saved.get("apiProvider") in PROVIDERS else "custom"
            if saved.get("apiModel"):
                cfg["models"][cfg["provider"]] = saved["apiModel"]
            if cfg["provider"] == "custom" and saved.get("apiEndpoint"):
                cfg["customEndpoint"] = saved["apiEndpoint"]
        elif b in ("ollama", "luna"):
            cfg["provider"] = b
        if saved.get("ollamaModel"):
            cfg["models"].setdefault("ollama", saved["ollamaModel"])
    if not isinstance(cfg["models"], dict):
        cfg["models"] = {}
    return cfg


def load_keys():
    keys = read_json(KEYS_FILE, {})
    if not keys:                                                      # the old file kept one key in the config
        old = read_json(CONFIG_FILE, {})
        if old.get("apiKey") and old.get("apiProvider") in PROVIDERS:
            keys = {old["apiProvider"]: old["apiKey"]}
            write_json(KEYS_FILE, keys, private=True)
    return keys


def model_of(cfg, p):
    m = cfg["models"].get(p)
    return m if isinstance(m, str) and m.strip() else PROVIDERS[p].get("model", "")


# ------------------------------------------------------------------------------------------------ Luna / Ollama state

def luna_path():
    p = os.environ.get("HALCYON_LUNA_BIN")
    if p:
        return p if os.access(p, os.X_OK) else None
    for c in (os.path.join(HOME, ".local", "bin", "luna"), shutil.which("luna")):
        if c and os.access(c, os.X_OK):
            return c
    return None


def luna_state():
    b = luna_path()
    why = ""
    if os.path.lexists(GAMING_FLAG):
        why = "Gaming mode is on: the AI is paused."
    elif os.path.lexists(AI_OFF_FLAG):
        why = "AI features are switched off (Settings > Performance > AI features)."
    return {"installed": b is not None, "blocked": why, "ready": b is not None and not why}


def ollama_models(host):
    try:
        req = urllib.request.Request(host.rstrip("/") + "/api/tags", headers={"User-Agent": "Halcyon-QuickChat"})
        with urllib.request.urlopen(req, timeout=2.5) as r:
            return [m["name"] for m in json.loads(r.read().decode("utf-8")).get("models", [])]
    except Exception:
        return None                                                   # None = not reachable, [] = reachable but empty


def resolve(cfg, luna):
    p = cfg.get("provider", "auto")
    if p == "auto" or p not in PROVIDERS:
        return "luna" if luna["installed"] else "ollama"
    return p


def cmd_status():
    cfg = load_config()
    keys = load_keys()
    luna = luna_state()
    host = cfg.get("ollamaHost") or DEFAULT_HOST
    om = ollama_models(host)
    ready = {}
    for p in ORDER:
        if p == "luna":
            ready[p] = luna["installed"]
        elif p == "ollama":
            ready[p] = om is not None
        elif p == "custom":
            ready[p] = bool(cfg.get("customEndpoint")) and bool(model_of(cfg, p))
        else:
            ready[p] = bool(keys.get(p))
    out({
        "provider": resolve(cfg, luna),
        "chosen": cfg.get("provider", "auto"),
        "models": {p: model_of(cfg, p) for p in ORDER},
        "ollamaHost": host,
        "customEndpoint": cfg.get("customEndpoint", ""),
        "ollamaModels": om or [],
        "ollamaUp": om is not None,
        "luna": luna,
        "keySet": {p: bool(keys.get(p)) for p in ORDER if p not in KEYLESS},
        "ready": ready,
        "providers": [{"id": p, "name": PROVIDERS[p]["name"], "kind": PROVIDERS[p]["kind"],
                       "presets": PROVIDERS[p].get("presets", [])} for p in ORDER],
    })


def cmd_set_config(raw):
    try:
        upd = json.loads(raw)
        if not isinstance(upd, dict):
            raise ValueError("expected an object")
    except ValueError as e:
        out({"ok": False, "error": str(e)})
        return 1
    cfg = load_config()
    if upd.get("provider") in PROVIDERS or upd.get("provider") == "auto":
        cfg["provider"] = upd["provider"]
    if isinstance(upd.get("models"), dict):
        for p, m in upd["models"].items():
            if p in PROVIDERS and isinstance(m, str):
                cfg["models"][p] = m.strip()
    for k in ("ollamaHost", "customEndpoint", "systemPrompt"):
        if isinstance(upd.get(k), str):
            cfg[k] = upd[k].strip()
    write_json(CONFIG_FILE, cfg)
    out({"ok": True})
    return 0


def cmd_set_key(provider):
    if provider not in PROVIDERS or provider in KEYLESS:
        out({"ok": False, "error": "that provider has no key"})
        return 1
    key = sys.stdin.read().strip()
    keys = load_keys()
    if key:
        keys[provider] = key
    else:
        keys.pop(provider, None)
    write_json(KEYS_FILE, keys, private=True)
    out({"ok": True, "set": bool(key)})
    return 0


# ------------------------------------------------------------------------------------------------ streaming

def safe_endpoint(url):
    """A key only goes over https, or over plain http to this machine / the home network."""
    u = urllib.parse.urlparse(url)
    if u.scheme == "https" and u.hostname:
        return ""
    if u.scheme == "http" and u.hostname:
        h = u.hostname
        if h in ("localhost", "::1") or h.startswith(("127.", "10.", "192.168.")) or re.match(r"^172\.(1[6-9]|2\d|3[01])\.", h):
            return ""
        return "Refusing to send an API key over plain http to " + h + ". Use https."
    return "That endpoint is not a web address: " + (url or "(empty)")


def http_error(e):
    body = ""
    try:
        raw = e.read().decode("utf-8", "replace")
        try:
            j = json.loads(raw)
            err = j.get("error", j)
            body = err.get("message", "") if isinstance(err, dict) else str(err)
        except ValueError:
            body = raw[:300]
    except Exception:
        pass
    hint = {401: " Check the API key.", 403: " The key may not allow this model.", 404: " Check the model name.", 429: " Rate limit or no credit."}.get(e.code, "")
    return "HTTP %d: %s%s" % (e.code, body or e.reason, hint)


def stream_ollama(model, host, messages, system):
    msgs = ([{"role": "system", "content": system}] if system else []) + messages
    req = urllib.request.Request(host.rstrip("/") + "/api/chat", data=json.dumps({"model": model, "messages": msgs, "stream": True}).encode(),
                                 headers={"Content-Type": "application/json"})
    t0, parts = time.time(), []
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            for line in r:
                try:
                    ch = json.loads(line.decode("utf-8").strip())
                except ValueError:
                    continue
                if ch.get("error"):
                    out({"type": "error", "error": "Ollama: " + str(ch["error"])})
                    return
                c = (ch.get("message") or {}).get("content", "")
                if c:
                    parts.append(c)
                    out({"type": "delta", "text": c})
                if ch.get("done"):
                    break
        out({"type": "done", "text": "".join(parts), "model": model, "provider": "ollama", "secs": round(time.time() - t0, 1)})
    except urllib.error.HTTPError as e:
        out({"type": "error", "error": "Ollama: " + http_error(e)})
    except urllib.error.URLError as e:
        out({"type": "error", "error": "Cannot reach Ollama at %s (%s). Start it with: systemctl --user start ollama" % (host, e.reason)})
    except Exception as e:
        out({"type": "error", "error": str(e)})


def stream_openai(pid, endpoint, key, model, messages, system):
    if not key:
        out({"type": "error", "error": "No API key for %s. Open the provider list and paste one." % PROVIDERS[pid]["name"]})
        return
    if not model:
        out({"type": "error", "error": "No model set for %s. Pick one in the provider list." % PROVIDERS[pid]["name"]})
        return
    bad = safe_endpoint(endpoint)
    if bad:
        out({"type": "error", "error": bad})
        return
    msgs = ([{"role": "system", "content": system}] if system else []) + messages
    req = urllib.request.Request(endpoint, data=json.dumps({"model": model, "messages": msgs, "stream": True}).encode(), headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + key, "User-Agent": "Halcyon-QuickChat/2",
        "X-Title": "Halcyon"})
    t0, parts = time.time(), []
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                line = line[5:].strip()
                if line == "[DONE]":
                    break
                try:
                    ch = json.loads(line)
                except ValueError:
                    continue
                if ch.get("error"):
                    e = ch["error"]
                    out({"type": "error", "error": e.get("message", str(e)) if isinstance(e, dict) else str(e)})
                    return
                d = ((ch.get("choices") or [{}])[0].get("delta") or {}).get("content") or ""
                if d:
                    parts.append(d)
                    out({"type": "delta", "text": d})
        out({"type": "done", "text": "".join(parts), "model": model, "provider": pid, "secs": round(time.time() - t0, 1)})
    except urllib.error.HTTPError as e:
        out({"type": "error", "error": http_error(e)})
    except urllib.error.URLError as e:
        out({"type": "error", "error": "Could not connect to %s: %s" % (urllib.parse.urlparse(endpoint).hostname, e.reason)})
    except Exception as e:
        out({"type": "error", "error": str(e)})


def stream_anthropic(key, model, messages, system):
    if not key:
        out({"type": "error", "error": "No API key for Anthropic. Open the provider list and paste one."})
        return
    body = {"model": model, "max_tokens": 4096, "messages": messages, "stream": True}
    if system:
        body["system"] = system
    req = urllib.request.Request(PROVIDERS["anthropic"]["endpoint"], data=json.dumps(body).encode(), headers={
        "Content-Type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01", "User-Agent": "Halcyon-QuickChat/2"})
    t0, parts = time.time(), []
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                try:
                    ev = json.loads(line[5:].strip())
                except ValueError:
                    continue
                t = ev.get("type")
                if t == "content_block_delta" and (ev.get("delta") or {}).get("type") == "text_delta":
                    d = ev["delta"].get("text", "")
                    if d:
                        parts.append(d)
                        out({"type": "delta", "text": d})
                elif t == "error":
                    out({"type": "error", "error": (ev.get("error") or {}).get("message", "Anthropic error")})
                    return
                elif t == "message_stop":
                    break
        out({"type": "done", "text": "".join(parts), "model": model, "provider": "anthropic", "secs": round(time.time() - t0, 1)})
    except urllib.error.HTTPError as e:
        out({"type": "error", "error": http_error(e)})
    except urllib.error.URLError as e:
        out({"type": "error", "error": "Could not connect to api.anthropic.com: " + str(e.reason)})
    except Exception as e:
        out({"type": "error", "error": str(e)})


def luna_session(cfg, fresh=False):
    """The one Luna session the chatbox keeps (it shows up in the >luna window too). Returns its id or ''."""
    sid = "" if fresh else cfg.get("lunaSession", "")
    if sid and re.fullmatch(r"[0-9]{10,14}-[0-9a-f]{4}", sid) and os.path.isfile(os.path.join(LUNA_DATA, sid + ".json")):
        return sid
    try:
        r = subprocess.run([sys.executable, LUNA_PY, "new", "--json"], capture_output=True, text=True, timeout=15)
        sid = json.loads(r.stdout).get("id", "")
    except Exception:
        return ""
    if sid:
        cfg["lunaSession"] = sid
        write_json(CONFIG_FILE, cfg)
    return sid


def stream_luna(cfg, prompt):
    st = luna_state()
    if not st["installed"]:
        out({"type": "error", "error": "Luna is not installed. Run install.sh --luna, or pick another provider."})
        return
    if st["blocked"]:
        out({"type": "error", "error": st["blocked"]})
        return
    sid = luna_session(cfg)
    if not sid:
        out({"type": "error", "error": "Could not start a Luna session (is halcyon-luna.py next to this script?)."})
        return
    proc = subprocess.Popen([sys.executable, LUNA_PY, "chat", sid, "--json", "--", prompt], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, bufsize=1, start_new_session=True)

    def stop(*_):                                                     # Esc in the box sends SIGTERM here: stop Luna too
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            pass
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    reply, err = None, ""
    for line in proc.stdout:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        k = ev.get("type")
        if k == "thinking":
            out({"type": "think"})
        elif k == "activity":
            kind = ev.get("kind")
            if kind in ("tool_start", "tool_end"):
                out({"type": "tool", "state": "start" if kind == "tool_start" else "end", "name": ev.get("name", ""),
                     "summary": str(ev.get("summary", ""))[:160], "ok": ev.get("ok", True)})
        elif k == "reply":
            reply = ev
        elif k == "error":
            err = str(ev.get("error", "Luna failed."))
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        stop()
    if err:
        out({"type": "error", "error": err})
    elif reply is None:
        out({"type": "error", "error": "Stopped."})
    else:
        text = reply.get("text", "")
        out({"type": "delta", "text": text})
        out({"type": "done", "text": text, "model": reply.get("model", "luna"), "provider": "luna", "secs": reply.get("secs", 0)})


def cmd_stream():
    try:
        req = json.loads(sys.stdin.read())
    except ValueError as e:
        out({"type": "error", "error": "Bad request: %s" % e})
        return 1
    prompt = str(req.get("prompt", "")).strip()
    if not prompt:
        out({"type": "error", "error": "Empty prompt."})
        return 1
    cfg = load_config()
    luna = luna_state()
    pid = req.get("provider") if req.get("provider") in PROVIDERS else resolve(cfg, luna)
    if pid == "luna":
        stream_luna(cfg, prompt)
        return 0
    msgs = []
    for h in req.get("history", []):
        c = h.get("content") or h.get("text") or ""
        if c:
            msgs.append({"role": "user" if h.get("role") in ("user", "you") else "assistant", "content": c})
    msgs.append({"role": "user", "content": prompt})
    system = cfg.get("systemPrompt", SYSTEM_PROMPT)
    model = (req.get("model") or "").strip() or model_of(cfg, pid)
    kind = PROVIDERS[pid]["kind"]
    if kind == "ollama":
        stream_ollama(model, req.get("ollamaHost") or cfg.get("ollamaHost") or DEFAULT_HOST, msgs, system)
    elif kind == "anthropic":
        stream_anthropic(load_keys().get("anthropic", ""), model, msgs, system)
    else:
        endpoint = (req.get("endpoint") or cfg.get("customEndpoint", "")) if pid == "custom" else PROVIDERS[pid]["endpoint"]
        stream_openai(pid, endpoint, load_keys().get(pid, ""), model, msgs, system)
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip())
        return 2
    c = argv[1]
    if c == "status":
        cmd_status()
        return 0
    if c in ("get-config", "list-models"):                            # kept for older callers: same answer as status
        cmd_status()
        return 0
    if c == "set-config":
        return cmd_set_config(argv[2] if len(argv) > 2 else sys.stdin.read())
    if c == "set-key" and len(argv) > 2:
        return cmd_set_key(argv[2])
    if c == "luna-new":
        sid = luna_session(load_config(), fresh=True)
        out({"ok": bool(sid), "id": sid})
        return 0 if sid else 1
    if c == "stream":
        return cmd_stream()
    print(__doc__.strip())
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
