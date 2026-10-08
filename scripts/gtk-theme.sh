#!/usr/bin/env bash
# gtk-theme.sh [--remove | --auto]   make GTK apps (Thunar, file dialogs, ...) wear the rice's colours.
# Reads the island palette (~/.cache/island/palette.json) and the theme (dark | light, ~/.local/state/island/theme), writes
#   ~/.config/gtk-3.0/gtk.css   and   ~/.config/gtk-4.0/gtk.css
# between "halcyon" markers (anything else you keep in those files is left alone), and sets gtk-application-prefer-dark-theme.
# Run by the island on every wallpaper / theme change, and by hand:  ~/.config/Halcyon/scripts/gtk-theme.sh
# Already open GTK apps keep their old colours until you reopen them (for Thunar:  thunar -q).
#   --remove                      take the halcyon block out again
#   --auto                        what the island runs: does nothing while gtk-follow is off
#   ~/.local/state/island/gtk-follow = off     stops the automatic runs (running it by hand still works)
pal="$HOME/.cache/island/palette.json"
state="$HOME/.local/state/island"
B="/* >>> halcyon >>> */"; E="/* <<< halcyon <<< */"

strip() {   # strip FILE: the file without the halcyon block
  [ -f "$1" ] && awk -v b="$B" -v e="$E" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$1"
}
if [ "${1:-}" = "--remove" ]; then
  for v in 3.0 4.0; do f="$HOME/.config/gtk-$v/gtk.css"; [ -f "$f" ] && { strip "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }; done
  exit 0
fi
[ "${1:-}" = "--auto" ] && [ "$(head -n1 "$state/gtk-follow" 2>/dev/null)" = "off" ] && exit 0
[ -f "$pal" ] || exit 0
get() { sed -n "s/.*\"$1\": *\"\\(#[0-9a-fA-F]\\{6\\}\\)\".*/\\1/p" "$pal" | head -n1; }
pbg=$(get bg); psurf=$(get surface); phi=$(get surfaceHi); pacc=$(get accent); pacc2=$(get accent2); ptxt=$(get text); pmut=$(get muted)
[ -n "$pbg" ] && [ -n "$ptxt" ] && [ -n "$pacc" ] || exit 0
mode=$(head -n1 "$state/theme" 2>/dev/null); [ "$mode" = light ] || mode=dark

mixv() {   # mixv A B percent-of-B -> $MIX
  local a=${1#\#} b=${2#\#} p=$3
  printf -v MIX '#%02x%02x%02x' \
    $(( (16#${a:0:2} * (100 - p) + 16#${b:0:2} * p) / 100 )) \
    $(( (16#${a:2:2} * (100 - p) + 16#${b:2:2} * p) / 100 )) \
    $(( (16#${a:4:2} * (100 - p) + 16#${b:4:2} * p) / 100 ))
}
if [ "$mode" = dark ]; then
  BG=$pbg; SURF=$psurf; HI=$phi; TXT=$ptxt; MUT=$pmut; ACC=$pacc; ACC2=${pacc2:-$pacc}; FGA=$pbg
  mixv "$phi" "$pmut" 22; LINE=$MIX; PREFER=1
else   # the wallpaper palette is made for dark: light surfaces tinted with the same accent
  mixv "#ffffff" "$pacc" 6;  BG=$MIX
  mixv "#ffffff" "$pacc" 13; SURF=$MIX
  mixv "#ffffff" "$pacc" 21; HI=$MIX
  mixv "#17171c" "$pacc" 14; TXT=$MIX
  mixv "$TXT" "$BG" 42;      MUT=$MIX
  mixv "$pacc" "#000000" 38; ACC=$MIX
  mixv "${pacc2:-$pacc}" "#000000" 38; ACC2=$MIX
  FGA="#ffffff"
  mixv "$HI" "$TXT" 14; LINE=$MIX; PREFER=0
fi

mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"
colors() { cat <<C
@define-color theme_bg_color $BG;
@define-color theme_fg_color $TXT;
@define-color theme_base_color $BG;
@define-color theme_text_color $TXT;
@define-color theme_selected_bg_color $ACC;
@define-color theme_selected_fg_color $FGA;
@define-color theme_unfocused_bg_color $BG;
@define-color theme_unfocused_fg_color $MUT;
@define-color theme_unfocused_base_color $BG;
@define-color theme_unfocused_text_color $TXT;
@define-color theme_unfocused_selected_bg_color $ACC;
@define-color theme_unfocused_selected_fg_color $FGA;
@define-color insensitive_bg_color $SURF;
@define-color insensitive_fg_color $MUT;
@define-color insensitive_base_color $SURF;
@define-color borders $LINE;
@define-color unfocused_borders $LINE;
@define-color content_view_bg $BG;
@define-color text_view_bg $BG;
@define-color tooltip_bg_color $HI;
@define-color tooltip_fg_color $TXT;
@define-color link_color $ACC;
@define-color visited_link_color $ACC2;
@define-color warning_color #e5c07b;
@define-color error_color #e58a8a;
@define-color success_color #8fcfa0;
C
}
colors4() { cat <<C
@define-color accent_bg_color $ACC;
@define-color accent_fg_color $FGA;
@define-color accent_color $ACC;
@define-color window_bg_color $BG;
@define-color window_fg_color $TXT;
@define-color view_bg_color $BG;
@define-color view_fg_color $TXT;
@define-color headerbar_bg_color $SURF;
@define-color headerbar_fg_color $TXT;
@define-color headerbar_border_color $LINE;
@define-color card_bg_color $SURF;
@define-color card_fg_color $TXT;
@define-color dialog_bg_color $SURF;
@define-color dialog_fg_color $TXT;
@define-color popover_bg_color $SURF;
@define-color popover_fg_color $TXT;
@define-color sidebar_bg_color $SURF;
@define-color sidebar_fg_color $TXT;
@define-color sidebar_backdrop_color $SURF;
@define-color sidebar_border_color $LINE;
@define-color secondary_sidebar_bg_color $BG;
@define-color shade_color alpha(black, 0.25);
C
}
# widget rules (GTK 3: Thunar and friends): soft, rounded, one accent, the same surfaces as the island
rules3() { cat <<C
window, .background { background-color: $BG; color: $TXT; }
headerbar, .titlebar, toolbar, .primary-toolbar, .inline-toolbar, statusbar, actionbar {
  background-image: none; background-color: $SURF; color: $TXT; border-color: $LINE; box-shadow: none; }
headerbar { border-bottom: 1px solid $LINE; }
.sidebar, .sidebar row, placessidebar, treeview.sidebar, .view.sidebar { background-color: $SURF; color: $TXT; }
.sidebar row:selected, placessidebar row:selected { background-color: alpha($ACC, 0.22); color: $TXT; border-radius: 10px; }
.view, iconview, treeview.view, textview text, list, row { background-color: $BG; color: $TXT; }
.view:selected, iconview:selected, treeview.view:selected, row:selected, .view:selected:focus {
  background-color: alpha($ACC, 0.30); color: $TXT; border-radius: 10px; }
iconview:hover, treeview.view:hover, row:hover { background-color: alpha($ACC, 0.10); }
treeview.view header button { background-image: none; background-color: $SURF; color: $MUT; border-color: $LINE; border-radius: 0; box-shadow: none; }
button, .path-bar button { background-image: none; background-color: $SURF; color: $TXT; border: 1px solid $LINE; border-radius: 10px; box-shadow: none; text-shadow: none; }
button:hover { background-color: $HI; }
button:active, button:checked { background-color: $ACC; color: $FGA; border-color: $ACC; }
button:disabled { color: $MUT; }
button.suggested-action, .default { background-color: $ACC; color: $FGA; border-color: $ACC; }
entry, spinbutton, .location-entry { background-image: none; background-color: $SURF; color: $TXT; border: 1px solid $LINE; border-radius: 10px; box-shadow: none; caret-color: $ACC; }
entry:focus, spinbutton:focus { border-color: $ACC; box-shadow: 0 0 0 1px $ACC; }
selection, entry selection, textview text selection { background-color: $ACC; color: $FGA; }
menu, .menu, .popup, popover, popover.background, popover contents { background-color: $SURF; color: $TXT; border: 1px solid $LINE; border-radius: 14px; box-shadow: 0 8px 24px alpha(black, 0.35); }
menuitem, modelbutton { color: $TXT; border-radius: 8px; }
menuitem:hover, modelbutton:hover { background-color: alpha($ACC, 0.22); color: $TXT; }
menuitem:disabled { color: $MUT; }
separator { background-color: $LINE; min-width: 1px; min-height: 1px; }
paned > separator { background-color: $LINE; background-image: none; }
scrollbar, scrollbar trough { background-color: transparent; border: none; }
scrollbar slider { background-color: alpha($MUT, 0.45); border-radius: 8px; min-width: 6px; min-height: 6px; border: none; }
scrollbar slider:hover { background-color: alpha($ACC, 0.8); }
notebook, notebook > header, notebook > header > tabs > tab { background-color: $SURF; color: $MUT; border-color: $LINE; }
notebook > header > tabs > tab:checked { color: $TXT; box-shadow: inset 0 -2px $ACC; }
progressbar progress, scale highlight, levelbar block.filled { background-color: $ACC; border-color: $ACC; }
scale trough, progressbar trough { background-color: $HI; border-color: $LINE; }
scale slider { background-color: $ACC; border-color: $ACC; }
switch { background-color: $HI; border-color: $LINE; }
switch:checked { background-color: $ACC; }
switch slider { background-color: $TXT; border-color: transparent; }
checkbutton check, radiobutton radio { background-image: none; background-color: $SURF; border: 1px solid $LINE; color: $FGA; }
checkbutton check:checked, radiobutton radio:checked { background-color: $ACC; border-color: $ACC; }
tooltip, tooltip.background { background-color: $HI; color: $TXT; border: 1px solid $LINE; border-radius: 10px; }
tooltip * { color: $TXT; }
.dialog-action-area, messagedialog, dialog { background-color: $SURF; color: $TXT; }
infobar, .info { background-color: alpha($ACC, 0.25); color: $TXT; }
label.dim-label, .dim-label { color: $MUT; }
/* ---- Thunar and the other GTK 3 file managers: flat toolbar, pill path bar, card-like icon view, soft side pane ---- */
window.background.csd, window.csd { border-radius: 16px; }
toolbar { padding: 4px 6px; border-bottom: 1px solid $LINE; }
toolbar button, headerbar button.flat, headerbar button.image-button { background-color: transparent; border-color: transparent; border-radius: 10px; padding: 4px 8px; }
toolbar button:hover, headerbar button.flat:hover { background-color: alpha($ACC, 0.16); border-color: transparent; }
toolbar button:active, toolbar button:checked { background-color: alpha($ACC, 0.32); color: $TXT; border-color: transparent; }
.path-bar, .path-bar button, .path-bar box { background-color: transparent; }
.path-bar button { margin: 0 2px; padding: 3px 12px; border-radius: 999px; border-color: transparent; background-color: alpha($HI, 0.55); }
.path-bar button:hover { background-color: $HI; }
.path-bar button:checked, .path-bar button.current-dir { background-color: $ACC; color: $FGA; border-color: $ACC; font-weight: 600; }
.path-bar button.slider-button { background-color: transparent; }
menubar { background-color: $SURF; border-bottom: 1px solid $LINE; }
menubar > menuitem { padding: 4px 10px; border-radius: 8px; }
menubar > menuitem:hover { background-color: alpha($ACC, 0.20); }
paned > separator { min-width: 1px; }
.sidebar, placessidebar, placessidebar .view, placessidebar viewport { background-color: $SURF; border-right: 1px solid $LINE; }
placessidebar row, .sidebar row { padding: 5px 8px; margin: 1px 6px; border-radius: 10px; }
placessidebar row:hover, .sidebar row:hover { background-color: alpha($ACC, 0.12); }
placessidebar row:selected, .sidebar row:selected { background-color: alpha($ACC, 0.26); color: $TXT; box-shadow: inset 3px 0 0 $ACC; }
placessidebar row:selected label, placessidebar row:selected image { color: $TXT; }
placessidebar .sidebar-icon, .sidebar image { color: $ACC; }
iconview { padding: 8px; }
iconview:selected, iconview:selected:focus { background-color: alpha($ACC, 0.30); box-shadow: inset 0 0 0 1px alpha($ACC, 0.8); border-radius: 12px; }
iconview:hover { background-color: alpha($ACC, 0.10); border-radius: 12px; }
iconview.cell:selected label, iconview.cell:selected { color: $TXT; }
treeview.view row:hover { background-color: alpha($ACC, 0.10); }
treeview.view:selected, treeview.view row:selected { background-color: alpha($ACC, 0.30); color: $TXT; }
treeview.view:selected:focus { background-color: alpha($ACC, 0.36); }
treeview.view header button { padding: 6px 8px; font-weight: 600; border-bottom: 1px solid $LINE; }
.rubberband, rubberband { background-color: alpha($ACC, 0.18); border: 1px solid $ACC; border-radius: 4px; }
statusbar { padding: 3px 10px; border-top: 1px solid $LINE; color: $MUT; }
statusbar label { color: $MUT; }
notebook > header { border-bottom: 1px solid $LINE; }
notebook > header > tabs > tab { padding: 4px 14px; border-radius: 10px 10px 0 0; }
notebook > header > tabs > tab:hover { color: $TXT; background-color: alpha($ACC, 0.10); }
filechooser, filechooser .sidebar, filechooser placessidebar { background-color: $BG; }
dialog .dialog-action-area button, messagedialog button { min-height: 30px; padding: 2px 16px; }
progressbar trough, progressbar progress { border-radius: 8px; min-height: 6px; }
button.destructive-action { background-color: $ACC2; color: $FGA; border-color: $ACC2; }
scrolledwindow > viewport, scrolledwindow { background-color: transparent; }
C
}
write() {   # write FILE VERSION
  local f="$1" tmp="$1.tmp"
  { strip "$f"; echo "$B"; colors; [ "$2" = 4 ] && colors4; [ "$2" = 3 ] && rules3; echo "$E"; } > "$tmp" && mv "$tmp" "$f"
}
write "$HOME/.config/gtk-3.0/gtk.css" 3
write "$HOME/.config/gtk-4.0/gtk.css" 4

# GTK 3 reads the dark variant of its base theme from settings.ini
ini="$HOME/.config/gtk-3.0/settings.ini"
if [ -f "$ini" ] && grep -q '^gtk-application-prefer-dark-theme' "$ini"; then
  sed -i "s/^gtk-application-prefer-dark-theme.*/gtk-application-prefer-dark-theme=$PREFER/" "$ini"
elif [ -f "$ini" ] && grep -q '^\[Settings\]' "$ini"; then
  sed -i "/^\[Settings\]/a gtk-application-prefer-dark-theme=$PREFER" "$ini"
else
  printf '[Settings]\ngtk-application-prefer-dark-theme=%s\n' "$PREFER" >> "$ini"
fi
exit 0
