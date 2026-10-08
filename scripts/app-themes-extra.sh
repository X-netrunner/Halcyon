# shellcheck shell=bash
# app-themes-extra.sh: sourced by app-themes.sh (needs its colour variables and helpers: bg fg surf hi mut acc acc2 red green
# yellow blue magenta cyan, $A_C0..$A_C15, mixv, nh, rgb, have, log, strip_block, $mode, $RICE).
# More apps that wear the rice colours (every one is skipped when it is not installed / never started):
#   VSCodium / Code - OSS / VS Code / Cursor   a "Halcyon" colour theme (a tiny extension, installed once, rewritten on each wallpaper change)
#   Zed                                         ~/.config/zed/themes/halcyon.json  (Zed reloads it live)
#   Firefox / Zen / LibreWolf / Floorp          userChrome.css + userContent.css in every profile (toolbar, tabs, address bar, new tab)
#   Dolphin, Kate and other Qt apps             qt6ct colour scheme + a Kvantum theme "Halcyon" (made from KvFlat)
# Thunar / Nautilus / Nemo / file dialogs are GTK: scripts/gtk-theme.sh does those.

# a quoted-string key in a JSONC settings file (VS Code / Zed settings.json): set it, keep everything else, back the file up once
jsonc_set() {   # jsonc_set FILE KEY STRING-VALUE
  local f=$1 k=$2 v=$3
  mkdir -p "$(dirname "$f")"
  if [ ! -s "$f" ] || [ "$(tr -d '[:space:]' < "$f")" = "{}" ]; then
    printf '{\n    "%s": "%s"\n}\n' "$k" "$v" > "$f"; return 0
  fi
  [ -e "$f.before-halcyon" ] || cp -p "$f" "$f.before-halcyon"
  if grep -qE "^[[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*\{" "$f"; then
    echo "   $(basename "$(dirname "$f")"): \"$k\" is a table in $f: set it to \"$v\" by hand"; return 0
  elif grep -qE "^[[:space:]]*\"$k\"[[:space:]]*:" "$f"; then
    sed -i -E "s|^([[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*)\"[^\"]*\"|\\1\"$v\"|" "$f"
  else
    awk -v k="$k" -v v="$v" 'd==0 && /\{[[:space:]]*$/ { print; printf "    \"%s\": \"%s\",\n", k, v; d=1; next } { print }' "$f" > "$f.new" && mv "$f.new" "$f"
  fi
}
json_ok() { if have jq; then jq -e . "$1" >/dev/null 2>&1; else python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; fi; }

# ================================================================== VS Code family
vsc_theme_json() {   # -> stdout: the colour theme file
  mixv "$bg" "$fg" 4;  local hov=$MIX
  mixv "$bg" "$acc" 14; local sel=$MIX
  mixv "$bg" "$acc" 24; local selact=$MIX
  mixv "$surf" "$hi" 55; local line=$MIX
  cat <<JSON
{
  "name": "Halcyon",
  "type": "dark",
  "semanticHighlighting": true,
  "colors": {
    "focusBorder": "$acc",
    "foreground": "$fg",
    "descriptionForeground": "$mut",
    "errorForeground": "$red",
    "icon.foreground": "$mut",
    "selection.background": "${acc}55",
    "widget.shadow": "#00000066",
    "textLink.foreground": "$acc",
    "textLink.activeForeground": "$acc2",
    "textCodeBlock.background": "$surf",
    "textBlockQuote.background": "$surf",
    "textBlockQuote.border": "$acc",
    "textSeparator.foreground": "$hi",
    "sash.hoverBorder": "$acc",
    "editor.background": "$bg",
    "editor.foreground": "$fg",
    "editorLineNumber.foreground": "$hi",
    "editorLineNumber.activeForeground": "$acc",
    "editorCursor.foreground": "$acc",
    "editor.selectionBackground": "${acc}44",
    "editor.inactiveSelectionBackground": "${acc}22",
    "editor.selectionHighlightBackground": "${acc}22",
    "editor.wordHighlightBackground": "${acc2}22",
    "editor.wordHighlightStrongBackground": "${acc2}33",
    "editor.findMatchBackground": "${yellow}55",
    "editor.findMatchHighlightBackground": "${yellow}2a",
    "editor.lineHighlightBackground": "$hov",
    "editor.rangeHighlightBackground": "${acc}18",
    "editorIndentGuide.background1": "$line",
    "editorIndentGuide.activeBackground1": "$mut",
    "editorWhitespace.foreground": "$line",
    "editorBracketMatch.background": "${acc}30",
    "editorBracketMatch.border": "$acc",
    "editorBracketHighlight.foreground1": "$acc",
    "editorBracketHighlight.foreground2": "$magenta",
    "editorBracketHighlight.foreground3": "$cyan",
    "editorBracketHighlight.foreground4": "$yellow",
    "editorBracketHighlight.foreground5": "$green",
    "editorBracketHighlight.foreground6": "$blue",
    "editorGutter.background": "$bg",
    "editorGutter.addedBackground": "$green",
    "editorGutter.modifiedBackground": "$blue",
    "editorGutter.deletedBackground": "$red",
    "editorError.foreground": "$red",
    "editorWarning.foreground": "$yellow",
    "editorInfo.foreground": "$cyan",
    "editorHint.foreground": "$mut",
    "editorWidget.background": "$surf",
    "editorWidget.border": "$hi",
    "editorSuggestWidget.background": "$surf",
    "editorSuggestWidget.border": "$hi",
    "editorSuggestWidget.selectedBackground": "$selact",
    "editorHoverWidget.background": "$surf",
    "editorHoverWidget.border": "$hi",
    "editorGroup.border": "$hi",
    "editorGroupHeader.tabsBackground": "$bg",
    "editorGroupHeader.noTabsBackground": "$bg",
    "editorOverviewRuler.border": "$bg",
    "peekView.border": "$acc",
    "peekViewEditor.background": "$surf",
    "peekViewResult.background": "$surf",
    "peekViewTitle.background": "$surf",
    "peekViewResult.selectionBackground": "$selact",
    "diffEditor.insertedTextBackground": "${green}22",
    "diffEditor.removedTextBackground": "${red}22",
    "activityBar.background": "$bg",
    "activityBar.foreground": "$acc",
    "activityBar.inactiveForeground": "$mut",
    "activityBar.border": "$bg",
    "activityBar.activeBorder": "$acc",
    "activityBarBadge.background": "$acc",
    "activityBarBadge.foreground": "$bg",
    "sideBar.background": "$bg",
    "sideBar.foreground": "$fg",
    "sideBar.border": "$bg",
    "sideBarTitle.foreground": "$acc",
    "sideBarSectionHeader.background": "$bg",
    "sideBarSectionHeader.foreground": "$mut",
    "sideBarSectionHeader.border": "$hi",
    "list.activeSelectionBackground": "$selact",
    "list.activeSelectionForeground": "$fg",
    "list.inactiveSelectionBackground": "$sel",
    "list.hoverBackground": "$hov",
    "list.focusBackground": "$selact",
    "list.highlightForeground": "$acc",
    "tree.indentGuidesStroke": "$line",
    "titleBar.activeBackground": "$bg",
    "titleBar.activeForeground": "$fg",
    "titleBar.inactiveBackground": "$bg",
    "titleBar.inactiveForeground": "$mut",
    "titleBar.border": "$bg",
    "menu.background": "$surf",
    "menu.foreground": "$fg",
    "menu.selectionBackground": "$selact",
    "menu.selectionForeground": "$fg",
    "menu.separatorBackground": "$hi",
    "menubar.selectionBackground": "$sel",
    "commandCenter.background": "$surf",
    "commandCenter.border": "$hi",
    "tab.activeBackground": "$surf",
    "tab.activeForeground": "$fg",
    "tab.activeBorderTop": "$acc",
    "tab.inactiveBackground": "$bg",
    "tab.inactiveForeground": "$mut",
    "tab.hoverBackground": "$hov",
    "tab.border": "$bg",
    "tab.unfocusedActiveBackground": "$surf",
    "statusBar.background": "$bg",
    "statusBar.foreground": "$mut",
    "statusBar.border": "$bg",
    "statusBar.noFolderBackground": "$bg",
    "statusBar.debuggingBackground": "$magenta",
    "statusBar.debuggingForeground": "$bg",
    "statusBarItem.hoverBackground": "$sel",
    "statusBarItem.remoteBackground": "$acc",
    "statusBarItem.remoteForeground": "$bg",
    "panel.background": "$bg",
    "panel.border": "$hi",
    "panelTitle.activeForeground": "$fg",
    "panelTitle.activeBorder": "$acc",
    "panelTitle.inactiveForeground": "$mut",
    "input.background": "$surf",
    "input.border": "$hi",
    "input.foreground": "$fg",
    "input.placeholderForeground": "$mut",
    "inputOption.activeBorder": "$acc",
    "inputOption.activeBackground": "${acc}33",
    "inputValidation.errorBorder": "$red",
    "inputValidation.warningBorder": "$yellow",
    "inputValidation.infoBorder": "$cyan",
    "dropdown.background": "$surf",
    "dropdown.border": "$hi",
    "dropdown.foreground": "$fg",
    "button.background": "$acc",
    "button.foreground": "$bg",
    "button.hoverBackground": "$acc2",
    "button.secondaryBackground": "$hi",
    "button.secondaryForeground": "$fg",
    "badge.background": "$acc",
    "badge.foreground": "$bg",
    "progressBar.background": "$acc",
    "scrollbar.shadow": "#00000000",
    "scrollbarSlider.background": "${hi}99",
    "scrollbarSlider.hoverBackground": "${mut}88",
    "scrollbarSlider.activeBackground": "${acc}88",
    "minimap.background": "$bg",
    "minimap.selectionHighlight": "${acc}66",
    "notifications.background": "$surf",
    "notifications.border": "$hi",
    "notificationCenterHeader.background": "$surf",
    "gitDecoration.addedResourceForeground": "$green",
    "gitDecoration.modifiedResourceForeground": "$blue",
    "gitDecoration.deletedResourceForeground": "$red",
    "gitDecoration.untrackedResourceForeground": "$cyan",
    "gitDecoration.ignoredResourceForeground": "$mut",
    "gitDecoration.conflictingResourceForeground": "$yellow",
    "terminal.background": "$bg",
    "terminal.foreground": "$fg",
    "terminal.selectionBackground": "${acc}44",
    "terminalCursor.foreground": "$acc",
    "terminal.ansiBlack": "$A_C0",
    "terminal.ansiRed": "$A_C1",
    "terminal.ansiGreen": "$A_C2",
    "terminal.ansiYellow": "$A_C3",
    "terminal.ansiBlue": "$A_C4",
    "terminal.ansiMagenta": "$A_C5",
    "terminal.ansiCyan": "$A_C6",
    "terminal.ansiWhite": "$A_C7",
    "terminal.ansiBrightBlack": "$A_C8",
    "terminal.ansiBrightRed": "$A_C9",
    "terminal.ansiBrightGreen": "$A_C10",
    "terminal.ansiBrightYellow": "$A_C11",
    "terminal.ansiBrightBlue": "$A_C12",
    "terminal.ansiBrightMagenta": "$A_C13",
    "terminal.ansiBrightCyan": "$A_C14",
    "terminal.ansiBrightWhite": "$A_C15"
  },
  "tokenColors": [
    { "scope": ["comment", "punctuation.definition.comment"], "settings": { "foreground": "$mut", "fontStyle": "italic" } },
    { "scope": ["string", "string.quoted", "markup.inline.raw"], "settings": { "foreground": "$green" } },
    { "scope": ["constant.numeric", "constant.language", "constant.character", "support.constant"], "settings": { "foreground": "$yellow" } },
    { "scope": ["keyword", "storage", "storage.type", "storage.modifier", "keyword.control"], "settings": { "foreground": "$acc2" } },
    { "scope": ["keyword.operator", "punctuation.separator", "punctuation.terminator"], "settings": { "foreground": "$cyan" } },
    { "scope": ["entity.name.function", "support.function", "meta.function-call"], "settings": { "foreground": "$acc" } },
    { "scope": ["entity.name.type", "entity.name.class", "support.type", "support.class", "entity.other.inherited-class"], "settings": { "foreground": "$blue" } },
    { "scope": ["variable", "variable.other"], "settings": { "foreground": "$fg" } },
    { "scope": ["variable.parameter", "variable.language"], "settings": { "foreground": "$magenta", "fontStyle": "italic" } },
    { "scope": ["entity.name.tag", "meta.tag"], "settings": { "foreground": "$red" } },
    { "scope": ["entity.other.attribute-name"], "settings": { "foreground": "$yellow", "fontStyle": "italic" } },
    { "scope": ["support.type.property-name", "meta.object-literal.key"], "settings": { "foreground": "$cyan" } },
    { "scope": ["markup.heading", "entity.name.section"], "settings": { "foreground": "$acc", "fontStyle": "bold" } },
    { "scope": ["markup.bold"], "settings": { "fontStyle": "bold" } },
    { "scope": ["markup.italic"], "settings": { "fontStyle": "italic" } },
    { "scope": ["markup.underline.link", "string.other.link"], "settings": { "foreground": "$acc" } },
    { "scope": ["invalid", "invalid.illegal"], "settings": { "foreground": "$red" } }
  ]
}
JSON
}

vsc_build_vsix() {   # vsc_build_vsix OUT.vsix THEME.json
  python3 - "$1" "$2" <<'PY'
import sys, zipfile
out, theme = sys.argv[1], sys.argv[2]
pkg = '{"name":"halcyon-theme","displayName":"Halcyon","description":"The Halcyon rice colours (written by scripts/app-themes.sh)","version":"1.0.0","publisher":"halcyon","engines":{"vscode":"^1.60.0"},"categories":["Themes"],"contributes":{"themes":[{"label":"Halcyon","uiTheme":"vs-dark","path":"./themes/halcyon-color-theme.json"}]}}'
manifest = '''<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="halcyon-theme" Version="1.0.0" Publisher="halcyon"/>
    <DisplayName>Halcyon</DisplayName>
    <Description xml:space="preserve">The Halcyon rice colours</Description>
    <Categories>Themes</Categories>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets>
</PackageManifest>'''
ctypes = '<?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/Content-Types"><Default Extension="json" ContentType="application/json"/><Default Extension="vsixmanifest" ContentType="text/xml"/></Types>'
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("[Content_Types].xml", ctypes)
    z.writestr("extension.vsixmanifest", manifest)
    z.writestr("extension/package.json", pkg)
    z.write(theme, "extension/themes/halcyon-color-theme.json")
PY
}

vsc_apply() {   # vsc_apply BIN EXTENSIONS-DIR USER-DIR
  local bin=$1 ext=$2 usr=$3 inst
  have "$bin" || return 0
  have python3 || { log "vscode: python3 missing, skipped $bin"; return 0; }
  local tmp="$HOME/.cache/island/halcyon-theme.json"
  vsc_theme_json > "$tmp.new" && json_ok "$tmp.new" && mv "$tmp.new" "$tmp" || { rm -f "$tmp.new"; log "vscode: theme json invalid"; return 0; }
  inst=$(ls -d "$ext"/halcyon.halcyon-theme-* 2>/dev/null | head -n1)
  if [ -n "$inst" ]; then
    mkdir -p "$inst/themes" && cp "$tmp" "$inst/themes/halcyon-color-theme.json"      # picked up when the window is reloaded
  else
    vsc_build_vsix "$HOME/.cache/island/halcyon-theme.vsix" "$tmp" 2>/dev/null \
      && timeout 90 "$bin" --install-extension "$HOME/.cache/island/halcyon-theme.vsix" --force >/dev/null 2>&1 \
      && echo "   $bin: Halcyon colour theme installed" || { log "vscode: could not install the theme into $bin"; return 0; }
  fi
  # choose it once (only --setup): later you can pick another theme and it stays
  [ "$mode" = "--setup" ] && { jsonc_set "$usr/User/settings.json" "workbench.colorTheme" "Halcyon"; echo "   $bin: colour theme Halcyon (reload the window after a wallpaper change to see new colours)"; }
  log "vscode: $bin theme written (accent $acc)"
}
editors_theme() {
  vsc_apply codium    "$HOME/.vscode-oss/extensions" "$HOME/.config/VSCodium"
  vsc_apply code-oss  "$HOME/.vscode-oss/extensions" "$HOME/.config/Code - OSS"
  if [ -d "$HOME/.config/Code" ]; then vsc_apply code "$HOME/.vscode/extensions" "$HOME/.config/Code"          # Microsoft build
  else vsc_apply code "$HOME/.vscode-oss/extensions" "$HOME/.config/Code - OSS"; fi                             # Arch's `code` is Code - OSS
  vsc_apply cursor    "$HOME/.cursor/extensions"     "$HOME/.config/Cursor"
  zed_theme
}

# ================================================================== Zed
zed_theme() {
  local zed=""; have zeditor && zed=zeditor; [ -z "$zed" ] && have zed && zed=zed
  [ -n "$zed" ] || return 0
  local d="$HOME/.config/zed/themes"; mkdir -p "$d"
  mixv "$bg" "$fg" 4; local hov=$MIX
  mixv "$bg" "$acc" 20; local sel=$MIX
  mixv "$bg" "$surf" 60; local panel=$MIX
  cat > "$d/halcyon.json.tmp" <<JSON
{
  "\$schema": "https://zed.dev/schema/themes/v0.2.0.json",
  "name": "Halcyon",
  "author": "Halcyon (written by scripts/app-themes.sh from the wallpaper colours)",
  "themes": [
    {
      "name": "Halcyon",
      "appearance": "dark",
      "style": {
        "border": "$hi", "border.variant": "$surf", "border.focused": "$acc", "border.selected": "$acc",
        "border.transparent": "#00000000", "border.disabled": "$hi",
        "elevated_surface.background": "$surf", "surface.background": "$panel", "background": "$bg",
        "element.background": "$surf", "element.hover": "$hi", "element.active": "$sel", "element.selected": "$sel", "element.disabled": "$surf",
        "drop_target.background": "${acc}33",
        "ghost_element.background": "#00000000", "ghost_element.hover": "$hov", "ghost_element.active": "$sel",
        "ghost_element.selected": "$sel", "ghost_element.disabled": "$surf",
        "text": "$fg", "text.muted": "$mut", "text.placeholder": "$mut", "text.disabled": "$hi", "text.accent": "$acc",
        "icon": "$fg", "icon.muted": "$mut", "icon.disabled": "$hi", "icon.placeholder": "$mut", "icon.accent": "$acc",
        "status_bar.background": "$bg", "title_bar.background": "$bg", "title_bar.inactive_background": "$bg",
        "toolbar.background": "$bg", "tab_bar.background": "$bg", "tab.inactive_background": "$bg", "tab.active_background": "$surf",
        "search.match_background": "${yellow}55", "panel.background": "$panel", "panel.focused_border": "$acc",
        "pane.focused_border": "$acc",
        "scrollbar.thumb.background": "${hi}99", "scrollbar.thumb.hover_background": "${mut}88", "scrollbar.thumb.border": "#00000000",
        "scrollbar.track.background": "#00000000", "scrollbar.track.border": "#00000000",
        "editor.foreground": "$fg", "editor.background": "$bg", "editor.gutter.background": "$bg",
        "editor.subheader.background": "$surf", "editor.active_line.background": "$hov",
        "editor.highlighted_line.background": "${acc}18", "editor.line_number": "$hi", "editor.active_line_number": "$acc",
        "editor.invisible": "$hi", "editor.wrap_guide": "$surf", "editor.active_wrap_guide": "$hi",
        "editor.document_highlight.read_background": "${acc}22", "editor.document_highlight.write_background": "${acc2}33",
        "terminal.background": "$bg", "terminal.foreground": "$fg", "terminal.bright_foreground": "$A_C15", "terminal.dim_foreground": "$mut",
        "terminal.ansi.black": "$A_C0", "terminal.ansi.red": "$A_C1", "terminal.ansi.green": "$A_C2", "terminal.ansi.yellow": "$A_C3",
        "terminal.ansi.blue": "$A_C4", "terminal.ansi.magenta": "$A_C5", "terminal.ansi.cyan": "$A_C6", "terminal.ansi.white": "$A_C7",
        "terminal.ansi.bright_black": "$A_C8", "terminal.ansi.bright_red": "$A_C9", "terminal.ansi.bright_green": "$A_C10",
        "terminal.ansi.bright_yellow": "$A_C11", "terminal.ansi.bright_blue": "$A_C12", "terminal.ansi.bright_magenta": "$A_C13",
        "terminal.ansi.bright_cyan": "$A_C14", "terminal.ansi.bright_white": "$A_C15",
        "link_text.hover": "$acc2",
        "conflict": "$yellow", "conflict.background": "${yellow}22", "conflict.border": "$yellow",
        "created": "$green", "created.background": "${green}22", "created.border": "$green",
        "deleted": "$red", "deleted.background": "${red}22", "deleted.border": "$red",
        "modified": "$blue", "modified.background": "${blue}22", "modified.border": "$blue",
        "error": "$red", "error.background": "${red}22", "error.border": "$red",
        "warning": "$yellow", "warning.background": "${yellow}22", "warning.border": "$yellow",
        "info": "$cyan", "info.background": "${cyan}22", "info.border": "$cyan",
        "success": "$green", "success.background": "${green}22", "success.border": "$green",
        "hint": "$mut", "hint.background": "${mut}22", "hint.border": "$hi",
        "predictive": "$mut", "predictive.background": "${mut}22", "predictive.border": "$hi",
        "players": [
          { "cursor": "$acc", "background": "$acc", "selection": "${acc}44" },
          { "cursor": "$magenta", "background": "$magenta", "selection": "${magenta}44" },
          { "cursor": "$cyan", "background": "$cyan", "selection": "${cyan}44" },
          { "cursor": "$yellow", "background": "$yellow", "selection": "${yellow}44" },
          { "cursor": "$green", "background": "$green", "selection": "${green}44" }
        ],
        "syntax": {
          "comment": { "color": "$mut", "font_style": "italic" },
          "comment.doc": { "color": "$mut", "font_style": "italic" },
          "string": { "color": "$green" }, "string.escape": { "color": "$cyan" }, "string.regex": { "color": "$cyan" },
          "string.special": { "color": "$cyan" }, "string.special.symbol": { "color": "$cyan" },
          "number": { "color": "$yellow" }, "boolean": { "color": "$yellow" }, "constant": { "color": "$yellow" },
          "keyword": { "color": "$acc2" }, "preproc": { "color": "$acc2" }, "attribute": { "color": "$yellow" },
          "operator": { "color": "$cyan" }, "punctuation": { "color": "$mut" },
          "punctuation.bracket": { "color": "$mut" }, "punctuation.delimiter": { "color": "$mut" },
          "punctuation.special": { "color": "$cyan" }, "punctuation.list_marker": { "color": "$acc" },
          "function": { "color": "$acc" }, "function.method": { "color": "$acc" }, "constructor": { "color": "$blue" },
          "type": { "color": "$blue" }, "variant": { "color": "$blue" }, "enum": { "color": "$blue" }, "title": { "color": "$acc", "font_weight": 700 },
          "variable": { "color": "$fg" }, "variable.special": { "color": "$magenta", "font_style": "italic" },
          "property": { "color": "$cyan" }, "tag": { "color": "$red" }, "label": { "color": "$acc" },
          "link_text": { "color": "$acc" }, "link_uri": { "color": "$cyan" }, "emphasis": { "font_style": "italic" },
          "emphasis.strong": { "font_weight": 700 }, "text.literal": { "color": "$green" }, "embedded": { "color": "$fg" }
        }
      }
    }
  ]
}
JSON
  if json_ok "$d/halcyon.json.tmp"; then mv "$d/halcyon.json.tmp" "$d/halcyon.json"; log "zed: theme written (accent $acc)"
  else rm -f "$d/halcyon.json.tmp"; log "zed: theme json invalid, kept the old one"; return 0; fi
  [ "$mode" = "--setup" ] && { jsonc_set "$HOME/.config/zed/settings.json" "theme" "Halcyon"; echo "   zed: theme Halcyon (reloads live when the wallpaper changes)"; }
  return 0
}

# ================================================================== Firefox family (Firefox, Zen, LibreWolf, Floorp, Waterfox)
browser_profiles() {   # prints every profile folder that exists
  local base ini p
  for base in "$HOME/.mozilla/firefox" "$HOME/.config/mozilla/firefox" "$HOME/.zen" "$HOME/.librewolf" "$HOME/.floorp" "$HOME/.waterfox"; do
    ini="$base/profiles.ini"; [ -f "$ini" ] || continue
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in /*) ;; *) p="$base/$p" ;; esac
      [ -d "$p" ] && echo "$p"
    done < <(sed -n 's/^Path=//p' "$ini")
  done
}
browser_theme() {
  local prof B="/* >>> halcyon >>> */" E="/* <<< halcyon <<< */" n=0 f
  mixv "$bg" "$acc" 16; local sel=$MIX
  while IFS= read -r prof; do
    [ -n "$prof" ] || continue
    mkdir -p "$prof/chrome"
    f="$prof/chrome/userChrome.css"
    {
      strip_block "$f" "$B" "$E"
      cat <<CSS
$B
/* written by scripts/app-themes.sh from the wallpaper colours: do not edit this block */
:root {
  --halcyon-bg: $bg; --halcyon-surf: $surf; --halcyon-hi: $hi; --halcyon-fg: $fg; --halcyon-mut: $mut; --halcyon-acc: $acc; --halcyon-sel: $sel;
  --lwt-accent-color: $bg !important; --lwt-text-color: $fg !important;
  --toolbar-bgcolor: $bg !important; --toolbar-color: $fg !important; --toolbar-field-background-color: $surf !important;
  --toolbar-field-color: $fg !important; --toolbar-field-focus-background-color: $surf !important; --toolbar-field-focus-color: $fg !important;
  --toolbar-field-border-color: transparent !important; --toolbar-field-focus-border-color: $acc !important;
  --tab-selected-bgcolor: $surf !important; --tab-selected-textcolor: $fg !important; --tab-loading-fill: $acc !important;
  --arrowpanel-background: $surf !important; --arrowpanel-color: $fg !important; --arrowpanel-border-color: $hi !important;
  --sidebar-background-color: $bg !important; --sidebar-text-color: $fg !important; --sidebar-border-color: $hi !important;
  --urlbar-box-bgcolor: $surf !important; --urlbar-box-hover-bgcolor: $hi !important; --urlbar-box-text-color: $fg !important;
  --focus-outline-color: $acc !important; --toolbarbutton-icon-fill-attention: $acc !important; --button-primary-bgcolor: $acc !important;
  --button-primary-color: $bg !important; --autocomplete-popup-highlight-background: $sel !important;
  --autocomplete-popup-background: $surf !important; --autocomplete-popup-color: $fg !important;
}
#navigator-toolbox { background: $bg !important; border-bottom: 1px solid $hi !important; }
#nav-bar { background: $bg !important; box-shadow: none !important; }
#TabsToolbar { background: $bg !important; }
.tab-background { border-radius: 10px !important; margin-block: 3px !important; }
.tab-background[selected] { background: $surf !important; box-shadow: inset 0 -2px 0 $acc !important; }
#urlbar-background, #searchbar { border-radius: 12px !important; border: 1px solid transparent !important; background: $surf !important; box-shadow: none !important; }
#urlbar[focused] > #urlbar-background { border-color: $acc !important; }
.urlbarView { background: $surf !important; border-radius: 12px !important; }
.urlbarView-row[selected] { background: $sel !important; border-radius: 8px !important; }
menupopup, panel { --panel-background: $surf !important; --panel-color: $fg !important; --panel-border-color: $hi !important; --panel-border-radius: 12px !important; }
$E
CSS
    } > "$f.tmp" && mv "$f.tmp" "$f"
    f="$prof/chrome/userContent.css"
    {
      strip_block "$f" "$B" "$E"
      cat <<CSS
$B
@-moz-document url(about:home), url(about:newtab), url(about:privatebrowsing), url-prefix(about:blank) {
  :root, body { --newtab-background-color: $bg !important; --newtab-background-color-secondary: $surf !important;
    --newtab-text-primary-color: $fg !important; --newtab-primary-action-background: $acc !important; --newtab-border-color: $hi !important;
    --in-content-page-background: $bg !important; --in-content-page-color: $fg !important; --in-content-primary-button-background: $acc !important; background: $bg !important; }
}
@-moz-document url-prefix(about:), url-prefix(chrome:) {
  :root { --in-content-page-background: $bg !important; --in-content-page-color: $fg !important; --in-content-box-background: $surf !important;
    --in-content-border-color: $hi !important; --in-content-accent-color: $acc !important; --in-content-primary-button-background: $acc !important;
    --in-content-primary-button-text-color: $bg !important; --in-content-link-color: $acc !important; }
}
$E
CSS
    } > "$f.tmp" && mv "$f.tmp" "$f"
    # the two prefs that make Firefox read those files (needs a restart once) + dark pages
    f="$prof/user.js"
    {
      strip_block "$f" "// >>> halcyon >>>" "// <<< halcyon <<<"
      printf '%s\n' '// >>> halcyon >>>' \
        'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' \
        'user_pref("browser.theme.content-theme", 0);' 'user_pref("browser.theme.toolbar-theme", 0);' \
        'user_pref("layout.css.prefers-color-scheme.content-override", 0);' 'user_pref("browser.in-content.dark-mode", true);' \
        'user_pref("ui.systemUsesDarkTheme", 1);' '// <<< halcyon <<<'
    } > "$f.tmp" && mv "$f.tmp" "$f"
    n=$((n + 1))
  done < <(browser_profiles)
  [ "$n" -gt 0 ] && log "browser: $n profile(s) themed (accent $acc)"
  [ "$n" -gt 0 ] && [ "$mode" = "--setup" ] && echo "   browser: $n profile(s) themed (restart the browser once)"
  return 0
}

# ================================================================== Qt apps: Dolphin, Kate, ... (qt6ct palette + Kvantum theme)
ini_set() {   # ini_set FILE SECTION KEY VALUE : set a key, adding the section / key when missing
  local f=$1 s=$2 k=$3 v=$4
  mkdir -p "$(dirname "$f")"; [ -f "$f" ] || : > "$f"
  awk -v s="$s" -v k="$k" -v v="$v" '
    BEGIN { insec = 0; seen = 0; done = 0 }
    /^\[.*\]$/ { if (insec && !done) { print k "=" v; done = 1 } insec = ($0 == "[" s "]"); if (insec) seen = 1 }
    insec && $0 ~ "^" k "=" { if (!done) { print k "=" v; done = 1 } next }
    { print }
    END { if (insec && !done) print k "=" v; else if (!seen) { print "[" s "]"; print k "=" v } }' "$f" > "$f.new" && mv "$f.new" "$f"
}
qt_theme() {
  have qt6ct || have kvantummanager || have dolphin || have kate || return 0
  mixv "$bg" "$fg" 14; local midlight=$MIX
  mixv "$bg" "$fg" 6;  local light=$MIX
  mixv "$bg" "#000000" 35; local dark=$MIX
  mixv "$bg" "$hi" 60; local mid=$MIX
  # qt6ct: palette order = WindowText Button Light Midlight Dark Mid Text BrightText ButtonText Base Window Shadow Highlight HighlightedText Link LinkVisited AlternateBase NoRole ToolTipBase ToolTipText PlaceholderText
  local pal="$fg, $surf, $light, $midlight, $dark, $mid, $fg, $A_C15, $fg, $bg, $bg, #000000, $acc, $bg, $acc, $acc2, $surf, #000000, $surf, $fg, $mut"
  local dis="$mut, $surf, $light, $midlight, $dark, $mid, $mut, $A_C15, $mut, $bg, $bg, #000000, $hi, $mut, $mut, $mut, $surf, #000000, $surf, $mut, $mut"
  if have qt6ct; then
    mkdir -p "$HOME/.config/qt6ct/colors"
    printf '[ColorScheme]\nactive_colors=%s\ninactive_colors=%s\ndisabled_colors=%s\n' "$pal" "$pal" "$dis" > "$HOME/.config/qt6ct/colors/halcyon.conf"
    if [ "$mode" = "--setup" ] || [ ! -f "$HOME/.config/qt6ct/qt6ct.conf" ] || grep -q 'halcyon.conf' "$HOME/.config/qt6ct/qt6ct.conf" 2>/dev/null; then
      ini_set "$HOME/.config/qt6ct/qt6ct.conf" Appearance color_scheme_path "$HOME/.config/qt6ct/colors/halcyon.conf"
      ini_set "$HOME/.config/qt6ct/qt6ct.conf" Appearance custom_palette true
      ini_set "$HOME/.config/qt6ct/qt6ct.conf" Appearance style kvantum
    fi
    log "qt6ct: palette written (accent $acc)"
  fi
  # Kvantum draws the widgets (QT_STYLE_OVERRIDE=kvantum): a copy of KvFlat with the Halcyon colours
  local kv="/usr/share/Kvantum/KvFlat" kd="$HOME/.config/Kvantum/Halcyon"
  if [ -f "$kv/KvFlat.kvconfig" ] && [ -f "$kv/KvFlat.svg" ]; then
    mkdir -p "$kd"; [ -f "$kd/Halcyon.svg" ] || cp "$kv/KvFlat.svg" "$kd/Halcyon.svg"
    {
      awk '/^\[GeneralColors\]/ { skip = 1; next } /^\[/ { skip = 0 } !skip' "$kv/KvFlat.kvconfig"
      cat <<KV

[GeneralColors]
window.color=$bg
base.color=$bg
alt.base.color=$surf
button.color=$surf
light.color=$light
mid.light.color=$midlight
dark.color=$dark
mid.color=$mid
highlight.color=$acc
inactive.highlight.color=$hi
text.color=$fg
window.text.color=$fg
button.text.color=$fg
disabled.text.color=$mut
tooltip.base.color=$surf
tooltip.text.color=$fg
highlight.text.color=$bg
link.color=$acc
link.visited.color=$acc2
progress.indicator.text.color=$bg
KV
    } > "$kd/Halcyon.kvconfig.tmp" && mv "$kd/Halcyon.kvconfig.tmp" "$kd/Halcyon.kvconfig"
    if [ "$mode" = "--setup" ] || ! [ -f "$HOME/.config/Kvantum/kvantum.kvconfig" ]; then
      ini_set "$HOME/.config/Kvantum/kvantum.kvconfig" General theme Halcyon
    fi
    log "kvantum: theme Halcyon written"
  fi
  return 0
}
