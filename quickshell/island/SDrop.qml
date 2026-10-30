import QtQuick

// A drop-down menu for Settings (used on the Bar page instead of a long row of buttons).
// Closed: one pill with what is chosen and a small arrow. Open: the list unfolds right under it, INSIDE the row, so the
// page's scroll area never clips it and the rows below simply move down while it is open.
//   items    [{ t: text, on: bool, hint: text }]  single: the one with on = true is the choice; multi: every one with on = true is switched on
//   multi    true: a click flips that item and the menu stays open (a tick box per item); false: a click picks it and the menu folds
//   summary  the text on the closed pill ("Rail", "5 of 7 shown" ...)
//   picked(index) is sent for every click; the owner (Settings.qml) writes the setting
Item {
    id: dd
    property var pal
    property var items: []
    property bool multi: false
    property string summary: ""
    property bool open: false
    signal picked(int index)

    readonly property int cols: items.length > 7 ? 2 : 1
    readonly property int rows: Math.ceil(items.length / cols)
    readonly property int rowH: 34
    readonly property int fullH: rows * rowH + 12

    implicitWidth: 300
    implicitHeight: head.height + (list.height > 0 ? 6 + list.height : 0)

    Rectangle {
        id: head
        width: parent.width
        height: 36
        radius: height / 2
        color: dd.open ? Qt.alpha(dd.pal.accent, dd.pal.calm ? 0.17 : 0.18)
             : (hdMa.pressed ? dd.pal.surfaceHi : (hdMa.containsMouse ? Qt.alpha(dd.pal.surfaceHi, 0.9) : (dd.pal.zen ? dd.pal.fill : Qt.alpha(dd.pal.surface, 0.8))))
        border.width: dd.pal.calm ? 0 : 1
        border.color: dd.open ? Qt.alpha(dd.pal.accent, 0.40) : dd.pal.lineSoft
        Behavior on color { ColorAnimation { duration: dd.pal.dFast } }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            x: 16
            width: parent.width - 52
            text: dd.summary
            elide: Text.ElideRight
            color: dd.open ? dd.pal.accent : dd.pal.text
            font.family: dd.pal.uiFont
            font.pixelSize: dd.pal.tBody
            font.weight: Font.Medium
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 16
            text: "\u25be"
            rotation: dd.open ? 180 : 0
            color: dd.open ? dd.pal.accent : dd.pal.muted
            font.family: dd.pal.uiFont
            font.pixelSize: 13
            Behavior on rotation { NumberAnimation { duration: dd.pal.dFast; easing.type: Easing.InOutSine } }
        }
        MouseArea {
            id: hdMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: dd.open = !dd.open
        }
    }

    Rectangle {
        id: list
        y: head.height + 6
        width: parent.width
        height: dd.open ? dd.fullH : 0
        visible: height > 0.5
        clip: true
        radius: dd.pal.rSm
        color: Qt.alpha(dd.pal.bg, 0.55)
        border.width: 1
        border.color: dd.pal.lineSoft
        Behavior on height { NumberAnimation { duration: dd.pal.dMed; easing.type: Easing.InOutSine } }

        Grid {
            x: 6; y: 6
            columns: dd.cols
            Repeater {
                model: dd.items
                delegate: Rectangle {
                    id: opt
                    required property var modelData
                    required property int index
                    width: (list.width - 12) / dd.cols
                    height: dd.rowH
                    radius: 10
                    color: opt.modelData.on ? Qt.alpha(dd.pal.accent, 0.16) : (optMa.containsMouse ? Qt.alpha(dd.pal.surfaceHi, 0.9) : "transparent")
                    Behavior on color { ColorAnimation { duration: dd.pal.dFast } }

                    // single: a round dot; multi: a small tick box
                    Rectangle {
                        id: mark
                        x: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16; height: 16
                        radius: dd.multi ? 5 : 8
                        color: opt.modelData.on ? dd.pal.accent : "transparent"
                        border.width: 1.5
                        border.color: opt.modelData.on ? dd.pal.accent : Qt.alpha(dd.pal.text, 0.35)
                        Text {
                            visible: dd.multi && opt.modelData.on
                            anchors.centerIn: parent
                            text: "\u2713"
                            color: dd.pal.bg
                            font.pixelSize: 11
                            font.weight: Font.Bold
                        }
                        Rectangle {
                            visible: !dd.multi && opt.modelData.on
                            anchors.centerIn: parent
                            width: 6; height: 6; radius: 3
                            color: dd.pal.bg
                        }
                    }
                    Text {
                        x: 38
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 48
                        text: opt.modelData.t + ((opt.modelData.hint || "") !== "" ? "   " : "")
                        elide: Text.ElideRight
                        color: opt.modelData.on ? dd.pal.text : Qt.alpha(dd.pal.text, 0.82)
                        font.family: dd.pal.uiFont
                        font.pixelSize: dd.pal.tBody
                        font.weight: opt.modelData.on ? Font.Medium : Font.Normal
                    }
                    Text {
                        visible: (opt.modelData.hint || "") !== "" && dd.cols === 1
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        text: opt.modelData.hint || ""
                        color: dd.pal.muted
                        font.family: dd.pal.uiFont
                        font.pixelSize: dd.pal.tBody - 2
                    }
                    MouseArea {
                        id: optMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { dd.picked(opt.index); if (!dd.multi) dd.open = false }
                    }
                }
            }
        }
    }
}
