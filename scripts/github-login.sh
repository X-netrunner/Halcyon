#!/usr/bin/env bash
# github-login.sh: sign in to GitHub once so that git (and Zed's git panel) never asks again, and make sure Zed's own GitHub sign-in is kept.
#   1. the keyring (gnome-keyring's secret service) is running: Zed keeps its sign-in token there, so without it Zed asks every start
#   2. `gh auth login` (browser, one time) and `gh auth setup-git`: git push / pull over https use that login from then on
# GitHub itself needs ONE approval in the browser; nothing can skip that. After it, nothing asks again.
# Run it from a terminal:  github-login
have() { command -v "$1" >/dev/null 2>&1; }
say() { printf '%s\n' "$*"; }

# 1. the keyring
if have gnome-keyring-daemon; then
  if ! pgrep -u "$USER" -x gnome-keyring-d >/dev/null 2>&1; then
    eval "$(gnome-keyring-daemon --start --components=secrets 2>/dev/null)" >/dev/null 2>&1
    say "keyring: started"
  else
    say "keyring: running"
  fi
else
  say "keyring: gnome-keyring is not installed, so Zed cannot remember its sign-in. Install it:  sudo pacman -S gnome-keyring libsecret"
fi

# 2. GitHub for git
if ! have gh; then
  say "gh: the GitHub CLI is not installed. Install it:  sudo pacman -S github-cli   then run github-login again"
  exit 1
fi
if gh auth status -h github.com >/dev/null 2>&1; then
  say "github: already signed in ($(gh api user --jq .login 2>/dev/null))"
else
  say "github: opening the sign-in (a code and your browser; once)"
  gh auth login -h github.com -p https -w || exit 1
fi
gh auth setup-git -h github.com >/dev/null 2>&1 && say "git: https pushes and pulls now use this login"
say
say "Zed: open it and click Sign in (top right) once. It keeps that sign-in in the keyring, so the next starts are automatic."
