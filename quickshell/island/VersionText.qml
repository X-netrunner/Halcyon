import QtQuick

// Small texts of the Version Center: kind "label" (muted, medium), "small" (muted, elides), "mono" (the commit ids).
Text {
    property var pal
    property string kind: "small"
    color: kind === "mono" ? pal.text : pal.muted
    font.family: kind === "mono" ? pal.mono : pal.uiFont
    font.pixelSize: kind === "label" ? pal.tCap : pal.tCap + 1
    font.weight: kind === "label" ? Font.Medium : Font.Normal
    elide: kind === "small" ? Text.ElideRight : Text.ElideNone
}
