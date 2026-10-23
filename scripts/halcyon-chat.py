#!/usr/bin/env python3
"""halcyon-chat.py : talk to your local Ollama model from the terminal, about anything.
The model is an AGENT: it can inspect this machine (services, logs, processes, disks, network, Hyprland, updates)
and manage it (restart/reset services, kill a process, volume, brightness, trim RAM, desktop modes, run a command).
Anything that changes the system shows the exact command and waits for your y / N / a.

Usage:
  ai                                       -> interactive terminal chat
  ai "question"                            -> single answer, then exit
  ai /diag                                 -> run deep system diagnostic and explain
  cat err.log | ai "why does this fail?"   -> pipe text in as context

Commands inside the chat:
  /diag           run full autonomous system diagnostics & explain findings
  /fix            inspect system bottlenecks and offer confirmed remediation
  /models         hardware-aware suggestions for running bigger models
  /sys            toggle live system status injection for every message
  /hypr           inspect active Hyprland monitors, workspaces & windows
  /logs           inspect recent Quickshell desktop errors
  /do <phrase>    execute a desktop action (e.g. /do gaming, /do night light, /do mirror)
  /tools          list what the assistant can look at and do
  /yes            toggle: pre-approve low-risk actions for this session (risky ones always ask)
  /agent          toggle tool use on/off (off = plain chat)
  /model [name]   view or switch current Ollama model
  /clear          clear conversation history       /help  show this menu       /exit
"""
import importlib.util
import json
import os
import sys
import subprocess
import select
import urllib.request
import urllib.error

HOME = os.path.expanduser("~")
RICE = os.environ.get("HALCYON_DIR", os.path.join(HOME, ".config/Halcyon"))
URL = "http://127.0.0.1:11434/api/chat"
# The context window every Halcyon AI script asks for: Ollama loads the model again whenever it changes between two requests,
# so chat, agent, advisor, notes and the brief all use the same one (keep it equal in each of them).
NUM_CTX = 8192
KEEP_ALIVE = "30m"
# Gaming mode is on (scripts/gamemode.sh writes this file, and unloads the models): the GPU memory is the game's, so no model is
# loaded now. Only a regular file of ours counts: /dev/shm is writable by every local user.
GAMING_FLAG = "/dev/shm/halcyon-gamemode"

def gaming():
    try:
        st = os.lstat(GAMING_FLAG)
    except OSError:
        return False
    return (st.st_mode & 0o170000) == 0o100000 and st.st_uid == os.getuid()
HIST = os.path.join(HOME, ".local/state/halcyon/chat_history")
ISLAND_LOG = os.path.join(HOME, ".cache/island/quickshell-island.log")
MAX_MSGS = 28

SYSTEM = (
    "You are Halcyon's AI system assistant, running locally in the user's terminal on Arch Linux with Hyprland. "
    "The user is a computer science student interested in cybersecurity, Rust and Linux systems programming. "
    "You have direct access to system diagnostics, memory PSI, GPU VRAM, hardware thermals, and compositor status. "
    "You answer technical topics (cybersecurity concepts, C/Rust code, algorithms, Linux kernel, study help) "
    "as well as desktop management questions. "
    "When explaining system issues, be concise and specific. When suggesting system fixes, state the exact command "
    "and explain what it does. Note that Halcyon will ask the user for confirmation before executing changes."
)

def load_advisor():
    for p in (os.path.join(RICE, "scripts/adaptive-advisor.py"),
              os.path.join(os.path.dirname(__file__), "adaptive-advisor.py")):
        if os.path.isfile(p):
            try:
                spec = importlib.util.spec_from_file_location("advisor", p)
                m = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(m)
                return m
            except Exception:
                pass
    return None

ADV = load_advisor()

def load_agent():
    for p in (os.path.join(RICE, "scripts/halcyon-agent.py"),
              os.path.join(os.path.dirname(os.path.abspath(__file__)), "halcyon-agent.py")):
        if os.path.isfile(p):
            try:
                spec = importlib.util.spec_from_file_location("halcyon_agent", p)
                m = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(m)
                return m
            except Exception as e:
                print(f"[!] agent failed to load: {e}")
    return None

AG = load_agent() if ADV else None
AGENT = None

def agent(assume_yes=False):
    global AGENT
    if AGENT is None and AG and ADV:
        AGENT = AG.Agent(ADV, model, assume_yes=assume_yes)
    return AGENT
MODEL_ALIASES = getattr(ADV, "MODEL_ALIASES", {}) if ADV else {}

def model():
    if ADV:
        return ADV.get_advisor_model()
    return os.environ.get("HALCYON_AI_MODEL", "qwen2.5:3b-instruct")

def snapshot():
    if not ADV:
        return ""
    try:
        a = ADV.analyze_system()
        keep = {
            "score": a.get("score"),
            "rating": a.get("rating"),
            "memory": a.get("memory"),
            "temps": a.get("temps"),
            "gpu": a.get("gpu"),
            "battery": a.get("battery"),
            "quickshell_mb": a.get("quickshell_mb"),
            "hyprland_mb": a.get("hyprland_mb"),
            "failed_svcs": a.get("failed_svcs"),
            "zombies": len(a.get("zombies") or []),
            "suggestions": [s["title"] for s in a.get("suggestions", [])]
        }
        return "Live machine telemetry: " + json.dumps(keep, default=str)
    except Exception:
        return ""

def get_hypr_info():
    info = []
    try:
        mon = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True, timeout=2)
        if mon.returncode == 0:
            md = json.loads(mon.stdout)
            for m in md:
                info.append(f"Monitor {m.get('name')}: {m.get('width')}x{m.get('height')}@{m.get('refreshRate'):.1f}Hz (scale {m.get('scale')})")
        act = subprocess.run(["hyprctl", "activewindow", "-j"], capture_output=True, text=True, timeout=2)
        if act.returncode == 0 and act.stdout.strip():
            ad = json.loads(act.stdout)
            info.append(f"Active window: '{ad.get('title')}' class='{ad.get('class')}' on workspace {ad.get('workspace', {}).get('name')}")
    except Exception as e:
        info.append(f"Hyprland query error: {e}")
    return "\n".join(info)

def get_recent_logs(lines=25):
    if not os.path.isfile(ISLAND_LOG):
        return "(no log file found)"
    try:
        with open(ISLAND_LOG, "r", errors="ignore") as f:
            all_lines = f.readlines()
            return "".join(all_lines[-lines:])
    except Exception as e:
        return f"(error reading log: {e})"

class ThinkFilter:
    """Drops <think>...</think> while streaming (qwen3/reasoning models)."""
    def __init__(self):
        self.buf = ""
        self.inside = False

    def feed(self, s):
        self.buf += s
        out = ""
        while True:
            if self.inside:
                i = self.buf.find("</think>")
                if i < 0:
                    self.buf = self.buf[-8:]
                    return out
                self.buf = self.buf[i + 8:].lstrip("\n")
                self.inside = False
            else:
                i = self.buf.find("<think>")
                if i >= 0:
                    out += self.buf[:i]
                    self.buf = self.buf[i + 7:]
                    self.inside = True
                    continue
                keep = 6
                out += self.buf[:-keep] if len(self.buf) > keep else ""
                self.buf = self.buf[-keep:] if len(self.buf) > keep else self.buf
                return out

    def flush(self):
        return "" if self.inside else self.buf

def ctx_warn(chunk):
    """Ollama silently drops the oldest part of a prompt that does not fit (the system prompt first): say so when it is close."""
    used = chunk.get("prompt_eval_count") or 0
    if used >= 0.9 * NUM_CTX and not CTX_WARNED[0]:
        CTX_WARNED[0] = True
        print(f"\033[2m(the conversation is {used} of {NUM_CTX} tokens: older parts, the instructions first, will be dropped; /clear starts afresh)\033[0m")
CTX_WARNED = [False]

def ask(messages):
    payload = {
        "model": model(),
        "messages": messages,
        "stream": True,
        "keep_alive": KEEP_ALIVE,
        "options": {"temperature": 0.35, "num_ctx": NUM_CTX}
    }
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    f, text = ThinkFilter(), []
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            for raw in r:
                try:
                    chunk = json.loads(raw.decode())
                except Exception:
                    continue
                piece = f.feed(chunk.get("message", {}).get("content", ""))
                if piece:
                    text.append(piece)
                    print(piece, end="", flush=True)
                if chunk.get("done"):
                    ctx_warn(chunk)
                    break
        tail = f.flush()
        if tail:
            text.append(tail)
            print(tail, end="")
        print()
        return "".join(text).strip()
    except urllib.error.HTTPError as e:
        print(f"\n[!] Ollama HTTP {e.code}" + (f": model '{model()}' not installed. Try: advisor model switch {model()}" if e.code == 404 else ""))
    except urllib.error.URLError:
        print("\n[!] Can't reach Ollama on 127.0.0.1:11434. Start it with: systemctl --user start ollama")
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
        print("[!] adaptive-advisor.py not found; /do needs it.")
        return
    if not ADV.try_dispatch_keywords(phrase):
        print("No matching action. Known: " + ", ".join(ADV.ACTIONS))

def run_chat_diagnostics(history):
    print("\nRunning Halcyon Autonomous Diagnostic Check...")
    if ADV:
        a = ADV.analyze_system()
        findings = ADV.build_findings(a)
        print(findings)
        print("\n\033[1;35mAI Analysis ›\033[0m ", end="", flush=True)
        prompt = (
            f"Here is the latest live machine telemetry:\n{findings}\n\n"
            "Diagnose the system state: identify if any components need attention, explain root causes, "
            "and propose exact steps to optimize performance."
        )
        turn(history, prompt, False)
    else:
        print("[!] Advisor engine not loaded.")

def repl():
    try:
        import readline
        os.makedirs(os.path.dirname(HIST), exist_ok=True)
        try: readline.read_history_file(HIST)
        except Exception: pass
        import atexit
        atexit.register(lambda: readline.write_history_file(HIST))
    except Exception:
        pass

    history, with_sys, use_agent = [], True, True
    print("━" * 68)
    print(f" Halcyon AI Assistant  ·  Model: \033[1;36m{model()}\033[0m")
    print(" Ask anything, or tell it what to do: \"why is bluetooth failing, fix it\", \"free some RAM\", \"volume 30\"")
    print(" It asks before every change.  /tools  /diag  /fix  /models  /help  (Ctrl-D to exit)")
    print("━" * 68)
    if AG:
        note = AG.small_model_note(model())
        if note:
            print(note)

    while True:
        try:
            line = input("\n\033[1;36mYou ›\033[0m ").strip()
        except EOFError:
            print()
            return
        except KeyboardInterrupt:
            print()
            continue

        if not line:
            continue
        if line in ("/exit", "/quit", "/q"):
            return
        if line == "/help":
            print(__doc__)
            continue
        if line == "/clear":
            history = []
            print("(conversation cleared)")
            continue
        if line == "/tools":
            a = agent()
            if not a:
                print("(agent not loaded)")
            else:
                for n, t in a.tools.items():
                    kind = ("\033[1;31mrisky \033[0m" if t["risk"] == "high" else "\033[1;33maction\033[0m") if t["mutating"] else "\033[32mread  \033[0m"
                    print(f"  {kind}  {n:<20} {t['schema']['function']['description'][:78]}")
            continue
        if line == "/yes":
            a = agent()
            if a:
                a.assume_yes = not a.assume_yes
                print(f"(low-risk actions are {'PRE-APPROVED' if a.assume_yes else 'confirmed one by one'}; risky ones always ask)")
            continue
        if line == "/agent":
            use_agent = not use_agent
            print(f"(tool use {'ON' if use_agent else 'OFF: plain chat'})")
            continue
        if line == "/sys":
            with_sys = not with_sys
            print(f"(live system snapshot telemetry {'ON' if with_sys else 'OFF'})")
            continue
        if line in ("/diag", "/doctor", "/health"):
            run_chat_diagnostics(history)
            continue
        if line in ("/models", "/bigger"):
            if ADV: ADV.recommend_models()
            else: print("[!] Advisor not found.")
            continue
        if line == "/fix":
            if ADV: ADV.run_doctor()
            else: print("[!] Advisor not found.")
            continue
        if line == "/hypr":
            print("\nHyprland State:")
            print(get_hypr_info())
            continue
        if line == "/logs":
            print("\nQuickshell Recent Logs:")
            print(get_recent_logs(20))
            continue
        if line.startswith("/do"):
            run_do(line[3:].strip())
            continue
        if line.startswith("/model"):
            arg = line[6:].strip()
            if arg:
                if ADV: ADV.model_command([arg])
                else: os.environ["HALCYON_AI_MODEL"] = arg
            else:
                if ADV: ADV.model_command([])
                else: print(f"Current model: {model()}")
            continue

        # Check for natural language diagnostics intent
        low = line.lower()
        if any(p in low for p in ("diagnose my system", "why is my laptop slow", "is my system okay", "system health")):
            run_chat_diagnostics(history)
            continue

        if use_agent and agent():
            agent().turn(history, line)          # prints its own "AI ›" prefix, tool calls, confirmations
        else:
            print("\033[1;35mAI  ›\033[0m ", end="", flush=True)
            turn(history, line, with_sys)

def check_piped_input():
    if sys.stdin.isatty():
        return ""
    try:
        r, _, _ = select.select([sys.stdin], [], [], 0.0)
        if r:
            return sys.stdin.read()
    except Exception:
        pass
    return ""

# Master AI switch (Settings > Performance > AI features): while ~/.local/state/island/ai-off exists no model is asked anything.
AI_OFF_FLAG = os.path.join(os.path.expanduser("~"), ".local", "state", "island", "ai-off")
AI_OFF_MSG = "The AI is switched off. Turn it back on in Settings > Performance > AI features (or: python3 ~/.config/Halcyon/scripts/ai-models.py master on)."

def ai_enabled():
    return not os.path.exists(AI_OFF_FLAG)


def gaming_ok():
    """Gaming mode: the model would take GPU memory from the game. Asked at a terminal (and then let go right after each answer);
    refused when nobody can answer."""
    global KEEP_ALIVE
    if not gaming():
        return True
    if not sys.stdin.isatty():
        print("Gaming mode is on: the AI is paused so the game keeps the GPU memory. Ask again when Gaming mode is off.")
        return False
    try:
        ans = input("Gaming mode is on: loading the model takes GPU memory from the game. Ask anyway? [y/N] ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False
    if ans not in ("y", "yes"):
        return False
    KEEP_ALIVE = 0                  # the model is unloaded again right after each answer
    for m in (ADV, AG):
        if m is not None:
            m.KEEP_ALIVE = 0
    return True

def main():
    args = sys.argv[1:]
    if not ai_enabled():
        print(AI_OFF_MSG)
        return
    if not gaming_ok():
        return
    piped = check_piped_input()

    if args and args[0] in ("/diag", "doctor", "--diag"):
        run_chat_diagnostics([])
        return
    if args and args[0] in ("/models", "models", "recommend"):
        if ADV: ADV.recommend_models()
        return

    if args or piped:
        yes = "--yes" in args or "-y" in args
        args = [a for a in args if a not in ("--yes", "-y")]
        q = " ".join(args) or "Explain this."
        if piped:
            q += "\n\n---\n" + piped[-6000:]
            turn([], q, True)               # piped text is for reading, not for acting on
            return
        if agent(yes):
            note = AG.small_model_note(model())
            if note:
                print(note)
            agent().turn([], q)
        else:
            turn([], q, True)
        return

    # If running non-interactively without tty and without args, output a friendly greeting / status
    if not sys.stdin.isatty():
        print("Halcyon AI System Assistant. Run 'ai <question>' or 'ai /diag'.")
        return

    repl()

if __name__ == "__main__":
    main()
