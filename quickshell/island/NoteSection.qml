import QtQuick
import QtQuick.Layouts

// One labelled block under a note (Overview, Summary, Picture description, Text in picture ...). The small capital label says what
// it is and who wrote it, so the note's own words stay visually apart from what the computer made of them. The body wraps and is
// never cut off, unless `collapsedLines` is set: then the first lines show and "Show all" opens the rest.
ColumnLayout {
    id: sec
    property var pal
    property string label: ""
    property string body: ""
    property bool italic: false
    property bool pulse: false               // breathes while the AI is still working on it
    property int collapsedLines: 0           // 0 = always the whole text
    property bool expanded: false

    visible: body !== ""
    Layout.fillWidth: true
    Layout.preferredWidth: 0
    spacing: 4

    Text {
        text: sec.label.toUpperCase()
        color: Qt.alpha(sec.pal.muted, 0.75)
        font.family: sec.pal.uiFont
        font.pixelSize: 9
        font.letterSpacing: 1.3
        font.weight: Font.Medium
    }
    Text {
        id: bodyText
        Layout.fillWidth: true
        text: sec.body
        color: Qt.alpha(sec.pal.text, 0.88)
        font.family: sec.pal.uiFont
        font.pixelSize: sec.pal.tCap
        font.italic: sec.italic
        lineHeight: 1.15
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        maximumLineCount: (sec.collapsedLines > 0 && !sec.expanded) ? sec.collapsedLines : 100000
        elide: (sec.collapsedLines > 0 && !sec.expanded) ? Text.ElideRight : Text.ElideNone
        SequentialAnimation on opacity {
            running: sec.pulse
            loops: Animation.Infinite
            NumberAnimation { to: 0.45; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
            onStopped: bodyText.opacity = 1
        }
    }
    Text {
        visible: sec.collapsedLines > 0 && (bodyText.truncated || sec.expanded)
        text: sec.expanded ? "Show less" : "Show all"
        color: moreMa.containsMouse ? sec.pal.accent : sec.pal.muted
        font.family: sec.pal.uiFont
        font.pixelSize: 10
        font.weight: Font.Medium
        MouseArea {
            id: moreMa
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: sec.expanded = !sec.expanded
        }
    }
}
