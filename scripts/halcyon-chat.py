#!/usr/bin/env python3
"""halcyon-chat.py : talk to your local Ollama model from the terminal, about anything.

  ai                     -> interactive chat (keeps the conversation, streams the answer)
  ai "question"          -> one answer, then exit
  cat err.log | ai "why does this fail?"   -> pipe text in as context

Inside the chat:
  /sys            attach a live snapshot of your system to every message (toggle)
  /do <phrase>    run a Halcyon action ("/do dark mode"-style phrases: presenting, night light, dnd, gaming ...)
  /model [name]   show / switch the model for this session (aliases: 1b 3b qwen3b qwen4b)
  /clear          forget the conversation        /help  this list        /exit  or Ctrl-D

The model can only talk. Actions run only when YOU type /do, and only from the advisor's fixed list.
"""
import importlib.util, json, os, re, sys, urllib.request, urllib.error

HOME = os.path.expanduser("~")
RICE = os.environ.get("HALCYON_DIR", os.path.join(HOME, ".config/Halcyon"))
URL = "http://127.0.0.1:11434/api/chat"
HIST = os.path.join(HOME, ".local/state/halcyon/chat_history")
MAX_MSGS = 24   # keep the context small: a 1-3B model gets slow and confused with long histories

SYSTEM = ("You are Halcyon's assistant, running locally in the user's terminal on Arch Linux with Hyprland. "
          "The user is a computer science student interested in cybersecurity, Rust and Linux. "
          "Answer any topic (code, security concepts, writing, maths, study help), not only the system. "
          "Be concise, teach with a small worked example when explaining something, and say so when you are unsure "
          "instead of guessing. Never claim to have run a command: you cannot run anything.")

def load_advisor():
    try:
        spec = importlib.util.spec_from_file_location("advisor", os.path.join(RICE, "scripts/adaptive-advisor.py"))
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
        return m
    except Exception:
        return None
ADV = load_advisor()
MODEL_ALIASES = getattr(ADV, "MODEL_ALIASES", {}) if ADV else {}

def model():
    if ADV:
        return ADV.get_advisor_model()
    return os.environ.get("HALCYON_AI_MODEL", "llama3.2:3b")

def snapshot():
    if not ADV:
        return ""
    try:
        a = ADV.analyze_system()
        keep = {k: a.get(k) for k in ("memory", "temps", "gpu", "battery", "quickshell_mb", "hyprland_mb", "score") if k in a}
        return "Live system snapshot: " + json.dumps(keep, default=str)
    except Exception:
        return ""

class ThinkFilter:
    """Drops <think>...</think> while streaming (qwen3 style models)."""
    def __init__(self): self.buf = ""; self.inside = False
    def feed(self, s):
        self.buf += s; out = ""
        while True:
            if self.inside:
                i = self.buf.find("</think>")
                if i < 0: self.buf = self.buf[-8:]; return out
                self.buf = self.buf[i + 8:].lstrip("\n"); self.inside = False
            else:
                i = self.buf.find("<think>")
                if i >= 0:
                    out += self.buf[:i]; self.buf = self.buf[i + 7:]; self.inside = True; continue
                keep = 6   # a tag might be split across chunks
                out += self.buf[:-keep] if len(self.buf) > keep else ""
                self.buf = self.buf[-keep:] if len(self.buf) > keep else self.buf
                return out
    def flush(self): return "" if self.inside else self.buf

def ask(messages):
    payload = {"model": model(), "messages": messages, "stream": True, "keep_alive": "30m",
               "options": {"temperature": 0.4, "num_ctx": 4096}}
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    f, text = ThinkFilter(), []
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            for raw in r:
                try: chunk = json.loads(raw.decode())
                except Exception: continue
                piece = f.feed(chunk.get("message", {}).get("content", ""))
                if piece: text.append(piece); print(piece, end="", flush=True)
                if chunk.get("done"): break
        tail = f.flush()
        if tail: text.append(tail); print(tail, end="")
        print()
        return "".join(text).strip()
    except urllib.error.HTTPError as e:
        print(f"\n[!] Ollama HTTP {e.code}" + (f": model '{model()}' not installed. Try /model 3b" if e.code == 404 else ""))
    except urllib.error.URLError:
        print("\n[!] Can't reach Ollama on 127.0.0.1:11434. Start it: systemctl --user start ollama  (or: ollama serve)")
    except KeyboardInterrupt:
        print("\n[stopped]")
        return "".join(text).strip() or None
    except Exception as e:
        print(f"\n[!] {e}")
    return None

def build(history, user, with_sys):
    sysmsg = SYSTEM + (("\n" + snapshot()) if with_sys else "")
    return [{"role": "system", "content": sysmsg}] + history[-MAX_MSGS:] + [{"role": "user", "content": user}]

def turn(history, user, with_sys):
    reply = ask(build(history, user, with_sys))
    if reply:
        history += [{"role": "user", "content": user}, {"role": "assistant", "content": reply}]
    return reply

def run_do(phrase):
    if not ADV:
        print("[!] adaptive-advisor.py not found; /do needs it."); return
    if not ADV.try_dispatch_keywords(phrase):
        print("No matching action. Known: " + ", ".join(ADV.ACTIONS))

def repl():
    try:
        import readline
        os.makedirs(os.path.dirname(HIST), exist_ok=True)
        try: readline.read_history_file(HIST)
        except Exception: pass
        import atexit; atexit.register(lambda: readline.write_history_file(HIST))
    except Exception:
        pass
    history, with_sys = [], False
    print(f"Halcyon chat  ·  model {model()}  ·  /help for commands, Ctrl-D to leave")
    while True:
        try: line = input("\n\033[1;36mYou ›\033[0m ").strip()
        except EOFError: print(); return
        except KeyboardInterrupt: print(); continue
        if not line: continue
        if line in ("/exit", "/quit", "/q"): return
        if line == "/help": print(__doc__); continue
        if line == "/clear": history = []; print("(conversation cleared)"); continue
        if line == "/sys":
            with_sys = not with_sys; print(f"(live system snapshot {'ON' if with_sys else 'OFF'})"); continue
        if line.startswith("/do"): run_do(line[3:].strip()); continue
        if line.startswith("/model"):
            arg = line[6:].strip()
            if arg: os.environ["HALCYON_AI_MODEL"] = MODEL_ALIASES.get(arg.lower(), arg)
            print(f"model: {model()}"); continue
        print("\033[1;35mAI  ›\033[0m ", end="", flush=True)
        turn(history, line, with_sys)

def main():
    args = sys.argv[1:]
    piped = "" if sys.stdin.isatty() else sys.stdin.read()
    if args or piped:
        q = " ".join(args) or "Explain this."
        if piped: q += "\n\n---\n" + piped[-6000:]
        turn([], q, False); return
    repl()

if __name__ == "__main__":
    main()
