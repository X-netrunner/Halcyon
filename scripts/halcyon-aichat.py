#!/usr/bin/env python3
"""halcyon-aichat.py: lightweight, multi-backend AI chat runner for Halcyon's quick chatbox.
Supports:
  1. Local Ollama (/api/chat streaming)
  2. Custom API (OpenAI, OpenRouter, Gemini, DeepSeek, Groq, local vLLM, etc.)
  3. Built-in Luna (--stdio mode without opening Luna UI)

Usage:
  halcyon-aichat.py stream                (reads payload JSON from stdin, streams JSON lines on stdout)
  halcyon-aichat.py list-models           (lists available local Ollama models and common API presets)
  halcyon-aichat.py get-config            (returns current saved chatbox configuration)
  halcyon-aichat.py set-config <json>     (updates chatbox configuration)
"""

import sys
import os
import json
import time
import subprocess
import urllib.request
import urllib.error

STATE_DIR = os.path.expanduser("~/.local/state/island")
CONFIG_FILE = os.path.join(STATE_DIR, "aichat.json")
os.makedirs(STATE_DIR, exist_ok=True)

DEFAULT_CONFIG = {
    "backend": "ollama",            # "ollama" | "api" | "luna"
    "ollamaModel": "qwen2.5:3b-instruct",
    "ollamaHost": "http://127.0.0.1:11434",
    "apiProvider": "openrouter",    # "openai" | "openrouter" | "gemini" | "deepseek" | "groq" | "custom"
    "apiModel": "openai/gpt-4o-mini",
    "apiEndpoint": "https://openrouter.ai/api/v1/chat/completions",
    "apiKey": "",
    "systemPrompt": "You are a concise, helpful assistant embedded in the Halcyon desktop environment on Arch Linux. Answer directly and informatively without unnecessary filler."
}

PROVIDER_ENDPOINTS = {
    "openrouter": "https://openrouter.ai/api/v1/chat/completions",
    "openai": "https://api.openai.com/v1/chat/completions",
    "deepseek": "https://api.deepseek.com/chat/completions",
    "groq": "https://api.groq.com/openai/v1/chat/completions",
    "gemini": "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
}

def load_config():
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                saved = json.load(f)
                if isinstance(saved, dict):
                    cfg.update(saved)
        except Exception:
            pass
    return cfg

def save_config(new_cfg):
    cfg = load_config()
    cfg.update(new_cfg)
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    return cfg

def list_ollama_models(host="http://127.0.0.1:11434"):
    try:
        url = host.rstrip("/") + "/api/tags"
        req = urllib.request.Request(url, headers={"User-Agent": "Halcyon-QuickChat"})
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return [m["name"] for m in data.get("models", [])]
    except Exception:
        return []

def stream_ollama(model, host, messages, system_prompt):
    url = host.rstrip("/") + "/api/chat"
    full_msgs = []
    if system_prompt:
        full_msgs.append({"role": "system", "content": system_prompt})
    full_msgs.extend(messages)

    payload = json.dumps({
        "model": model,
        "messages": full_msgs,
        "stream": True
    }).encode("utf-8")

    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            total_text = []
            for line in resp:
                if not line:
                    continue
                try:
                    chunk = json.loads(line.decode("utf-8").strip())
                except ValueError:
                    continue
                content = chunk.get("message", {}).get("content", "")
                if content:
                    total_text.append(content)
                    print(json.dumps({"type": "delta", "text": content}), flush=True)
                if chunk.get("done"):
                    break
            full_str = "".join(total_text)
            print(json.dumps({"type": "done", "text": full_str, "model": model}), flush=True)
    except urllib.error.URLError as e:
        err_msg = f"Cannot connect to Ollama at {host}. Is Ollama running? ({e.reason})"
        print(json.dumps({"type": "error", "error": err_msg}), flush=True)
    except Exception as e:
        print(json.dumps({"type": "error", "error": str(e)}), flush=True)

def stream_api(endpoint, api_key, model, messages, system_prompt):
    if not api_key:
        print(json.dumps({"type": "error", "error": "No API Key provided. Click the ⚙ Settings button to enter your API key."}), flush=True)
        return

    full_msgs = []
    if system_prompt:
        full_msgs.append({"role": "system", "content": system_prompt})
    full_msgs.extend(messages)

    payload = json.dumps({
        "model": model,
        "messages": full_msgs,
        "stream": True
    }).encode("utf-8")

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
        "User-Agent": "Halcyon-QuickChat/1.0",
        "HTTP-Referer": "https://github.com/X-netrunner/Halcyon",
        "X-Title": "Halcyon AI Chat"
    }

    req = urllib.request.Request(endpoint, data=payload, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            total_text = []
            for raw_line in resp:
                line = raw_line.decode("utf-8").strip()
                if not line:
                    continue
                if line.startswith("data:"):
                    line = line[5:].strip()
                if line == "[DONE]":
                    break
                try:
                    chunk = json.loads(line)
                except ValueError:
                    continue
                choices = chunk.get("choices", [])
                if not choices:
                    continue
                delta = choices[0].get("delta", {}).get("content", "")
                if delta:
                    total_text.append(delta)
                    print(json.dumps({"type": "delta", "text": delta}), flush=True)
            full_str = "".join(total_text)
            print(json.dumps({"type": "done", "text": full_str, "model": model}), flush=True)
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8")
            err_json = json.loads(body)
            body = err_json.get("error", {}).get("message", body)
        except Exception:
            pass
        msg = f"API Error (HTTP {e.code}): {body or e.reason}"
        print(json.dumps({"type": "error", "error": msg}), flush=True)
    except urllib.error.URLError as e:
        print(json.dumps({"type": "error", "error": f"Connection failed to {endpoint}: {e.reason}"}), flush=True)
    except Exception as e:
        print(json.dumps({"type": "error", "error": str(e)}), flush=True)

def stream_luna(prompt, history_messages):
    luna_bin = None
    for candidate in [os.path.expanduser("~/.local/bin/luna"), "/usr/local/bin/luna", "/usr/bin/luna"]:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            luna_bin = candidate
            break

    if not luna_bin:
        print(json.dumps({"type": "error", "error": "Luna binary not found at ~/.local/bin/luna"}), flush=True)
        return

    hist_file = os.path.join(STATE_DIR, "aichat_luna_hist.json")
    try:
        proc = subprocess.Popen(
            [luna_bin, "--stdio", "--history", hist_file],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            start_new_session=True
        )
        proc.stdin.write(json.dumps({"type": "turn", "text": prompt}) + "\n")
        proc.stdin.flush()

        reply_text = ""
        model_name = "luna"
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue

            ev_type = ev.get("type")
            if ev_type == "delta":
                d = ev.get("delta", "")
                reply_text += d
                print(json.dumps({"type": "delta", "text": d}), flush=True)
            elif ev_type == "reply":
                text = ev.get("text", "")
                model_name = ev.get("model", "luna")
                if not reply_text and text:
                    reply_text = text
                    print(json.dumps({"type": "delta", "text": text}), flush=True)
                break
            elif ev_type == "error":
                print(json.dumps({"type": "error", "error": ev.get("error", "Unknown Luna error")}), flush=True)
                try:
                    proc.kill()
                except Exception:
                    pass
                return

        try:
            proc.stdin.write(json.dumps({"type": "quit"}) + "\n")
            proc.stdin.close()
            proc.wait(timeout=3)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass

        print(json.dumps({"type": "done", "text": reply_text, "model": model_name}), flush=True)
    except Exception as e:
        print(json.dumps({"type": "error", "error": f"Luna execution error: {e}"}), flush=True)

def main():
    if len(sys.argv) < 2:
        print("Usage: halcyon-aichat.py stream | list-models | get-config | set-config <json>")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "get-config":
        cfg = load_config()
        # mask api key for display
        display_cfg = dict(cfg)
        if display_cfg.get("apiKey"):
            k = display_cfg["apiKey"]
            display_cfg["maskedKey"] = k[:4] + "..." + k[-4:] if len(k) > 10 else "******"
        else:
            display_cfg["maskedKey"] = ""
        print(json.dumps(display_cfg, indent=2))
        return

    elif cmd == "set-config":
        payload_str = sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read()
        try:
            updates = json.loads(payload_str)
            cfg = save_config(updates)
            print(json.dumps({"ok": True, "config": cfg}))
        except Exception as e:
            print(json.dumps({"ok": False, "error": str(e)}), file=sys.stderr)
            sys.exit(1)
        return

    elif cmd == "list-models":
        cfg = load_config()
        host = cfg.get("ollamaHost", "http://127.0.0.1:11434")
        ollama_models = list_ollama_models(host)

        luna_installed = any(os.path.isfile(p) and os.access(p, os.X_OK) for p in [
            os.path.expanduser("~/.local/bin/luna"), "/usr/local/bin/luna", "/usr/bin/luna"
        ])

        data = {
            "ollama": ollama_models,
            "api_presets": [
                {"provider": "openrouter", "model": "openai/gpt-4o-mini", "name": "OpenRouter: GPT-4o-mini"},
                {"provider": "openrouter", "model": "anthropic/claude-3.5-sonnet", "name": "OpenRouter: Claude 3.5 Sonnet"},
                {"provider": "openrouter", "model": "deepseek/deepseek-chat", "name": "OpenRouter: DeepSeek Chat"},
                {"provider": "openrouter", "model": "meta-llama/llama-3.2-3b-instruct:free", "name": "OpenRouter: LLaMA 3.2 3B (Free)"},
                {"provider": "openai", "model": "gpt-4o-mini", "name": "OpenAI: GPT-4o-mini"},
                {"provider": "openai", "model": "gpt-4o", "name": "OpenAI: GPT-4o"},
                {"provider": "deepseek", "model": "deepseek-chat", "name": "DeepSeek: deepseek-chat"},
                {"provider": "groq", "model": "llama-3.3-70b-versatile", "name": "Groq: LLaMA 3.3 70B"},
                {"provider": "gemini", "model": "gemini-1.5-flash", "name": "Gemini: 1.5 Flash"},
            ],
            "luna": luna_installed
        }
        print(json.dumps(data, indent=2))
        return

    elif cmd == "stream":
        # Reads JSON configuration from stdin
        raw_in = sys.stdin.read()
        if not raw_in.strip():
            print(json.dumps({"type": "error", "error": "No input payload received"}), flush=True)
            sys.exit(1)

        try:
            req = json.loads(raw_in)
        except Exception as e:
            print(json.dumps({"type": "error", "error": f"Invalid JSON payload: {e}"}), flush=True)
            sys.exit(1)

        cfg = load_config()
        backend = req.get("backend", cfg.get("backend", "ollama"))
        prompt = req.get("prompt", "").strip()
        history = req.get("history", [])

        if not prompt:
            print(json.dumps({"type": "error", "error": "Empty prompt"}), flush=True)
            sys.exit(1)

        messages = []
        for h in history:
            role = "user" if h.get("role") in ["user", "you"] else "assistant"
            content = h.get("content") or h.get("text", "")
            if content:
                messages.append({"role": role, "content": content})
        messages.append({"role": "user", "content": prompt})

        system_prompt = req.get("systemPrompt", cfg.get("systemPrompt", ""))

        if backend == "ollama":
            model = req.get("ollamaModel") or cfg.get("ollamaModel", "qwen2.5:3b-instruct")
            host = req.get("ollamaHost") or cfg.get("ollamaHost", "http://127.0.0.1:11434")
            stream_ollama(model, host, messages, system_prompt)

        elif backend == "api":
            api_key = req.get("apiKey") or cfg.get("apiKey", "")
            provider = req.get("apiProvider") or cfg.get("apiProvider", "openrouter")
            model = req.get("apiModel") or cfg.get("apiModel", "openai/gpt-4o-mini")
            endpoint = req.get("apiEndpoint") or cfg.get("apiEndpoint") or PROVIDER_ENDPOINTS.get(provider, "https://openrouter.ai/api/v1/chat/completions")
            stream_api(endpoint, api_key, model, messages, system_prompt)

        elif backend == "luna":
            stream_luna(prompt, history)

        else:
            print(json.dumps({"type": "error", "error": f"Unknown backend: {backend}"}), flush=True)

if __name__ == "__main__":
    main()
