#!/usr/bin/env bash
# install-ai.sh : installs Halcyon AI and Advisor onto your system PATH and shell configuration.
# Sets up `ai` and `advisor` commands, checks Ollama service, and configures hardware-tailored models.
set -euo pipefail

RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
BIN_DIR="$HOME/.local/bin"

if [ -t 1 ]; then
  C_H=$'\033[1;36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'; C_B=$'\033[1;32m'; C_0=$'\033[0m'
else
  C_H=; C_OK=; C_W=; C_E=; C_B=; C_0=;
fi

say()  { printf '%s== %s%s\n' "$C_H" "$*" "$C_0"; }
ok()   { printf '   %s✓%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '   %s!%s %s\n' "$C_W" "$C_0" "$*"; }
info() { printf '   %s\n' "$*"; }

say "Installing Halcyon AI & System Advisor"

# 1. Ensure scripts and bin files exist and are executable
mkdir -p "$RICE/scripts" "$RICE/bin" "$BIN_DIR"

for s in halcyon-chat.py adaptive-advisor.py; do
  if [ -f "scripts/$s" ]; then
    cp -p "scripts/$s" "$RICE/scripts/$s"
    chmod +x "$RICE/scripts/$s"
  fi
done

for b in ai advisor; do
  if [ -f "bin/$b" ]; then
    cp -p "bin/$b" "$RICE/bin/$b"
    chmod +x "$RICE/bin/$b"
  fi
done
ok "AI engine and advisor scripts synced to $RICE"

# 2. Put `ai` and `advisor` on PATH in ~/.local/bin
ln -sf "$RICE/bin/ai" "$BIN_DIR/ai"
ln -sf "$RICE/bin/advisor" "$BIN_DIR/advisor"
ok "Commands linked: $BIN_DIR/ai and $BIN_DIR/advisor"

# Try /usr/local/bin if writable
if [ -w "/usr/local/bin" ]; then
  ln -sf "$RICE/bin/ai" "/usr/local/bin/ai" 2>/dev/null || true
  ln -sf "$RICE/bin/advisor" "/usr/local/bin/advisor" 2>/dev/null || true
  ok "System-wide links created in /usr/local/bin"
fi

# 3. Fish shell integration
if command -v fish >/dev/null 2>&1; then
  mkdir -p "$HOME/.config/fish/functions" "$HOME/.config/fish/conf.d"
  for f in ai advisor; do
    if [ -f "$RICE/config/fish/functions/$f.fish" ]; then
      cp -p "$RICE/config/fish/functions/$f.fish" "$HOME/.config/fish/functions/$f.fish"
    elif [ -f "config/fish/functions/$f.fish" ]; then
      cp -p "config/fish/functions/$f.fish" "$HOME/.config/fish/functions/$f.fish"
      cp -p "config/fish/functions/$f.fish" "$RICE/config/fish/functions/$f.fish" 2>/dev/null || true
    fi
  done
  # Ensure ~/.local/bin is in fish path
  cat > "$HOME/.config/fish/conf.d/halcyon-path.fish" <<'FISH'
# Halcyon PATH additions
fish_add_path -g -p "$HOME/.local/bin" "$HOME/.config/Halcyon/bin"
FISH
  ok "Fish functions and path configured (ai, advisor)"
fi

# 4. Bash and Zsh PATH verification
for p in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [ -f "$p" ]; then
    if ! grep -q 'HOME/.local/bin' "$p" 2>/dev/null; then
      printf '\n# Halcyon bin path\nexport PATH="$HOME/.local/bin:$HOME/.config/Halcyon/bin:$PATH"\n' >> "$p"
      ok "Added PATH exports to $(basename "$p")"
    fi
  fi
done

# 5. Ollama Status & Hardware Model Check
say "Checking Local AI Runtime (Ollama)"
if command -v ollama >/dev/null 2>&1; then
  ok "Ollama CLI is installed"
  if curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    ok "Ollama service is active and responding on 127.0.0.1:11434"
  else
    warn "Ollama service is not running. Starting it via systemctl user service..."
    systemctl --user start ollama 2>/dev/null || ollama serve >/dev/null 2>&1 &
    sleep 2
    if curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      ok "Ollama service started successfully"
    else
      warn "Could not reach Ollama. Start it with: sudo systemctl start ollama, or systemctl --user start ollama (or run 'ollama serve')"
    fi
  fi
else
  warn "Ollama is not installed. To use local AI, install it with your package manager (Arch: sudo pacman -S ollama, Fedora: sudo dnf install ollama), or run ./install.sh --llm"
fi

# 6. Run Hardware Model Recommendation
if [ -f "$RICE/scripts/adaptive-advisor.py" ]; then
  python3 "$RICE/scripts/adaptive-advisor.py" model recommend 2>/dev/null || true
fi

say "Halcyon AI Installation Complete!"
info "You can now run:"
info "  ai                   -> Interactive AI chat with system diagnostics"
info "  ai \"question\"        -> Ask anything directly"
info "  advisor              -> Full system efficiency score & bottleneck detector"
info "  advisor doctor       -> Autonomous diagnostic check with confirmed fixes"
info "  advisor model 3b     -> Switch local model"
