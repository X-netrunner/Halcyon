#!/bin/sh
# features.sh (what the login screen may offer: fingerprint, keyboard layouts) reads only root-owned files; check what it says for a
# few PAM / greetd files, and that halcyon-greeter.sh builds the cage keyboard variables the way the login screen expects.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
bad() { echo "FAIL: $*"; fail=1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
feat() { HALCYON_PAM_GREETD="$tmp/pam" HALCYON_GREETD_CONF="$tmp/conf" sh "$here/greeter/features.sh"; }

# 1. nothing set up: no facts at all
printf 'auth include system-login\n' > "$tmp/pam"; printf '[default_session]\ncommand = "cage -s -- quickshell"\n' > "$tmp/conf"
[ -z "$(feat)" ] || bad "plain setup should report nothing, got: $(feat)"

# 2. a commented pam_fprintd line does not count; a real one does
printf '#auth sufficient pam_fprintd.so\nauth include system-login\n' > "$tmp/pam"
feat | grep -q '^fingerprint' && bad "a commented pam_fprintd line was counted"
printf 'auth sufficient pam_fprintd.so max-tries=2 # halcyon-fingerprint\nauth include system-login\n' > "$tmp/pam"
feat | grep -q "^fingerprint	1$" || bad "pam_fprintd line not noticed"

# 3. layouts and the switch key
printf 'command = "env XDG_CACHE_HOME=/x XKB_DEFAULT_LAYOUT=us,de XKB_DEFAULT_VARIANT=,nodeadkeys XKB_DEFAULT_OPTIONS=caps:escape,grp:alt_shift_toggle cage -s -- quickshell"\n' > "$tmp/conf"
feat | grep -q "^layouts	us,de$" || bad "layouts not reported"
feat | grep -q "^kbtoggle	Alt+Shift$" || bad "switch key not reported"
printf 'command = "env XKB_DEFAULT_LAYOUT=fr cage -s -- quickshell"\n' > "$tmp/conf"
feat | grep -q "^layouts	fr$" || bad "single layout not reported"
feat | grep -q '^kbtoggle' && bad "no switch key expected for one layout"

# 4. keyboard_env of the install script: a file decides, several layouts get a switch key, odd characters are dropped
kbf="$tmp/kb"
out="$(HALCYON_TEST_KB="$kbf" bash -c '
  set -u
  src="$1"; kbf="$2"
  have() { command -v "$1" >/dev/null 2>&1; }
  eval "$(sed -n "/^kb_env() {/,/^}/p" "$src" | sed "s|\$KBFILE|$kbf|g")"
  printf "de|nodeadkeys|\n" > "$kbf"; kb_env; echo
  printf "us,ru||\n" > "$kbf"; kb_env; echo
  printf "us;rm -rf|||\n" > "$kbf"; kb_env; echo
' _ "$here/scripts/halcyon-greeter.sh" "$kbf")"
printf '%s\n' "$out" | sed -n 1p | grep -q '^ XKB_DEFAULT_LAYOUT=de XKB_DEFAULT_VARIANT=nodeadkeys$' || bad "single layout + variant: $(printf '%s\n' "$out" | sed -n 1p)"
printf '%s\n' "$out" | sed -n 2p | grep -q 'XKB_DEFAULT_LAYOUT=us,ru XKB_DEFAULT_OPTIONS=grp:alt_shift_toggle' || bad "two layouts should get Alt+Shift: $(printf '%s\n' "$out" | sed -n 2p)"
printf '%s\n' "$out" | sed -n 3p | grep -q '[;/ ]rm' && bad "unsafe characters survived: $(printf '%s\n' "$out" | sed -n 3p)"

bash -n "$here/scripts/halcyon-greeter.sh" || bad "halcyon-greeter.sh has a syntax error"
[ "$fail" = 0 ] && echo "greeter-features: ok"
exit "$fail"
