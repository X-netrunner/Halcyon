#!/usr/bin/env bash
# thunar-look.sh [small | medium | large | status | auto]   how big and how readable the icons are in Thunar.
# Sets Thunar's own icon sizes (xfconf channel "thunar"): the side bar, the folder tree, the list / compact / icon views
# and the toolbar. The colours and the icon theme (Papirus) come from gtk-theme.sh.
#   small    side bar 16, lists 18 px, icon view 36 px
#   medium   side bar 22, lists 24 px, icon view 48 px          (default)
#   large    side bar 24, lists 36 px, icon view 72 px
#   status   prints the saved choice
#   auto     what gtk-theme.sh runs: applies the choice ONCE (so a size you set by hand in Thunar is not undone later)
# The choice is saved in ~/.local/state/island/file-icons ; Settings > Default apps > File manager icons runs this.
# Needs xfconf-query (the xfconf package, installed with Thunar). Open Thunar windows follow the side bar / toolbar size
# at once; the zoom of a window that is already open changes when it is reopened (thunar -q).
state="$HOME/.local/state/island"; f="$state/file-icons"; done_mark="$state/file-icons-applied"; ver=2   # bump when the sizes above change: auto then applies them once more
cur() { local v; v=$(head -n1 "$f" 2>/dev/null); case "$v" in small|medium|large) echo "$v" ;; *) echo medium ;; esac; }
case "${1:-status}" in
  status) cur; exit 0 ;;
  auto)   [ "$(head -n1 "$done_mark" 2>/dev/null)" = "$ver" ] && exit 0; set -- "$(cur)" ;;
esac
size="$1"
case "$size" in small|medium|large) ;; *) echo "usage: thunar-look.sh small | medium | large | status | auto" >&2; exit 2 ;; esac
mkdir -p "$state"; echo "$size" > "$f"
command -v xfconf-query >/dev/null 2>&1 || exit 0
case "$size" in
  small)  side=16; tree=16; list=38;  compact=38;  icons=75;  smalltb=true  ;;
  medium) side=22; tree=22; list=50;  compact=50;  icons=100; smalltb=true  ;;
  large)  side=24; tree=24; list=75;  compact=75;  icons=150; smalltb=false ;;
esac
xset() { xfconf-query -c thunar -p "$1" -n -t "$2" -s "$3" >/dev/null 2>&1; }   # xset PROPERTY TYPE VALUE
ok=0
xset /shortcuts-icon-size string "THUNAR_ICON_SIZE_$side" && ok=1
xset /tree-icon-size string "THUNAR_ICON_SIZE_$tree"
xset /last-details-view-zoom-level string "THUNAR_ZOOM_LEVEL_${list}_PERCENT"
xset /last-compact-view-zoom-level string "THUNAR_ZOOM_LEVEL_${compact}_PERCENT"
xset /last-icon-view-zoom-level string "THUNAR_ZOOM_LEVEL_${icons}_PERCENT"
xset /misc-small-toolbar-icons bool "$smalltb"
[ "$ok" = 1 ] && echo "$ver" > "$done_mark"
exit 0
