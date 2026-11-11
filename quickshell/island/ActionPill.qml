import QtQuick

Item {
    id: ap
    property var pal
    property var actions: []
    property string tip: "Actions"
    property bool expandLeft: true
    property bool open: false
    property int cursor: -1
    signal triggered(string id)

    implicitWidth: pal.hitMin + 4
    implicitHeight: pal.hitMin + 4
    activeFocusOnTab: true
    z: open ? 50 : 0

    function close() {
        open = false
        cursor = -1
    }
    function step(from, dir) {
        for (var i = 1; i <= actions.length; i++) {
            var j = (from + dir * i + actions.length * 2) % actions.length
            if (actions[j] && !actions[j].disabled) return j
        }
        return -1
    }
    function expand() {
        open = true
        cursor = step(-1, 1)
    }
    function pick(i) {
        var a = actions[i]
        if (!a || a.disabled) return
        close()
        ap.triggered(a.id)
    }

    onActiveFocusChanged: if (!activeFocus) close()
    Keys.onPressed: event => {
        var k = event.key
        if (!open) {
            if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space || k === Qt.Key_Down) {
                expand()
                event.accepted = true
            }
            return
        }
        var back = expandLeft ? Qt.Key_Right : Qt.Key_Left
        var fwd = expandLeft ? Qt.Key_Left : Qt.Key_Right
        if (k === Qt.Key_Escape) close()
        else if (k === fwd) cursor = step(cursor, 1)
        else if (k === back) cursor = step(cursor, -1)
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) pick(cursor)
        else return
        event.accepted = true
    }

    Rectangle {
        id: btn
        anchors.centerIn: parent
        width: ap.pal.hitMin
        height: ap.pal.hitMin
        radius: width / 2
        color: ap.open || btnMa.containsMouse ? ap.pal.fillHover : "transparent"
        border.width: ap.activeFocus && !ap.open ? ap.pal.focusRing : 0
        border.color: ap.pal.lineFocus
        Behavior on color { ColorAnimation { duration: ap.pal.dFast } }
        Text {
            anchors.centerIn: parent
            text: String.fromCodePoint(ap.open ? 0xF0156 : 0xF01D8)
            color: ap.pal.text
            font.family: ap.pal.font
            font.pixelSize: 16
        }
        MouseArea {
            id: btnMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                ap.forceActiveFocus()
                if (ap.open) ap.close()
                else ap.expand()
            }
        }
        Tip { pal: ap.pal; target: btn; text: ap.tip; shown: btnMa.containsMouse && !ap.open }
    }

    Item {
        id: tray
        visible: opacity > 0.01
        opacity: ap.open ? 1 : 0
        width: row.implicitWidth + 8
        height: ap.pal.hitMin + 4
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: ap.expandLeft ? btn.left : undefined
        anchors.left: ap.expandLeft ? undefined : btn.right
        anchors.rightMargin: 6
        anchors.leftMargin: 6
        transform: Scale {
            origin.x: ap.expandLeft ? tray.width : 0
            origin.y: tray.height / 2
            xScale: ap.open ? 1 : 0.7
            Behavior on xScale {
                NumberAnimation {
                    duration: ap.open ? ap.pal.dMed : ap.pal.dClose
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: ap.open ? ap.pal.curveOut : ap.pal.curveIn
                }
            }
        }
        Behavior on opacity {
            NumberAnimation {
                duration: ap.open ? ap.pal.dMed : ap.pal.dClose
                easing.type: Easing.BezierSpline
                easing.bezierCurve: ap.open ? ap.pal.curveOut : ap.pal.curveIn
            }
        }
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: ap.pal.surface
            border.width: 1
            border.color: ap.pal.line
        }
        Row {
            id: row
            anchors.centerIn: parent
            spacing: 2
            layoutDirection: ap.expandLeft ? Qt.RightToLeft : Qt.LeftToRight
            Repeater {
                model: ap.actions
                delegate: Rectangle {
                    id: act
                    required property var modelData
                    required property int index
                    readonly property bool lit: itemMa.containsMouse || ap.cursor === index
                    width: lbl.implicitWidth + 24
                    height: ap.pal.hitMin
                    radius: height / 2
                    opacity: modelData.disabled ? 0.4 : 1
                    color: modelData.primary ? (lit && !modelData.disabled ? Qt.lighter(ap.pal.accent, 1.08) : ap.pal.accent)
                                             : (lit && !modelData.disabled ? ap.pal.fillHover : "transparent")
                    border.width: ap.cursor === index ? ap.pal.focusRing : 0
                    border.color: ap.pal.lineFocus
                    Behavior on color { ColorAnimation { duration: ap.pal.dFast } }
                    Text {
                        id: lbl
                        anchors.centerIn: parent
                        text: act.modelData.label
                        color: act.modelData.primary ? ap.pal.primaryText : ap.pal.text
                        font.family: ap.pal.uiFont
                        font.pixelSize: ap.pal.tBody
                    }
                    MouseArea {
                        id: itemMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: act.modelData.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: ap.pick(act.index)
                    }
                    Tip { pal: ap.pal; target: act; text: act.modelData.tip || ""; shown: itemMa.containsMouse && ap.open }
                }
            }
        }
    }

    MouseArea {
        parent: ap.open && ap.Window.window ? ap.Window.window.contentItem : ap
        anchors.fill: parent
        z: 100000
        enabled: ap.open
        visible: ap.open
        onPressed: mouse => {
            var p = mapToItem(ap, mouse.x, mouse.y)
            var inBtn = p.x >= 0 && p.y >= 0 && p.x <= ap.width && p.y <= ap.height
            var q = mapToItem(tray, mouse.x, mouse.y)
            var inTray = q.x >= 0 && q.y >= 0 && q.x <= tray.width && q.y <= tray.height
            if (!inBtn && !inTray) ap.close()
            mouse.accepted = false
        }
    }
}
