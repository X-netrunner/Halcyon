import QtQuick
import QtQuick.Layouts

// The Wi-Fi connection card that opens to the side of the utilities box, in the same slot as the Focus card (FocusFlyout.qml; Panel.qml
// shows this one instead of it while a connection log is on screen, and the Focus card comes back after). It shows what the connection
// is doing step by step (scripts/wifi-connect.sh): finding the network, authenticating, obtaining the IP, gateway, DNS, internet check.
//
// With the border around the screen on (and the box joined to it) the card is a second piece of the same shape: flush with the box,
// painted in the border's colour, with the same concave flares where it meets the box and the border, and it slides out from under the
// box the way the box slides out from under the border. Without the border it is a floating pane next to the box that fades in.
Item {
    id: root
    property var pal
    property bool shown: false
    property bool toLeft: true             // the card sits left of the box (its right side touches the box)
    property bool atBottom: true         // it lines up with the box's bottom edge (else its top edge)
    property string joinV: ""            // the box's own join with the top / bottom border ("" = it floats)
    readonly property bool attached: !!pal && pal.frameOn === true && joinV !== ""
    readonly property bool hovered: hov.hovered
    readonly property real cardW: 300
    readonly property real pad: 20       // room around the card for the flares (they reach 16 px outside it); clipped away while it slides
    readonly property int inset: 12

    // [{ lvl: "i" | "o" | "w" | "e", secs, text }] as Panel.wifiLog; logBusy = the connection is still being made
    property var log: []
    property bool logBusy: false
    property string logTitle: ""
    signal dismissed()

    width: cardW + pad
    height: card.height + 2 * pad
    clip: attached && prog < 0.999
    visible: prog > 0.002

    property real prog: shown ? 1 : 0
    Behavior on prog { NumberAnimation { duration: root.shown ? root.pal.dSlow : root.pal.dClose; easing.type: Easing.BezierSpline; easing.bezierCurve: root.shown ? root.pal.curve : root.pal.curveClose } }

    Glass {
        id: card
        pal: root.pal
        x: root.toLeft ? root.pad : 0
        y: root.pad
        width: root.cardW
        height: body.implicitHeight + 2 * root.inset
        radius: root.pal.rXl
        opacityBody: root.pal.glassSolid - 0.06
        joinH: root.attached ? (root.toLeft ? "r" : "l") : ""
        joinV: root.attached ? root.joinV : ""
        opacity: root.attached ? 1 : root.prog
        transform: Translate {
            x: (root.toLeft ? 1 : -1) * (1 - root.prog) * (root.attached ? root.cardW + 4 : 16)
        }

        MouseArea { anchors.fill: parent }       // swallow clicks
        HoverHandler { id: hov }

        ColumnLayout {
            id: body
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.margins: root.inset
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    visible: root.logBusy
                    text: String.fromCodePoint(0xF0450)
                    color: root.pal.accent
                    font.family: root.pal.font
                    font.pixelSize: 14
                    NumberAnimation on rotation { running: root.logBusy && root.visible; from: 0; to: 360; duration: 1200; loops: Animation.Infinite }
                }
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: root.logBusy ? "Connecting to " + root.logTitle : root.logTitle
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tBody
                }
                Text {
                    visible: !root.logBusy
                    text: "\u2715"
                    color: xma.containsMouse ? root.pal.text : root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: 13
                    MouseArea { id: xma; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.dismissed() }
                }
            }

            Flickable {
                id: logFl
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(220, logCol.implicitHeight)
                contentHeight: logCol.implicitHeight
                clip: true
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                onContentHeightChanged: contentY = Math.max(0, contentHeight - height)      // follow the newest line
                Column {
                    id: logCol
                    width: logFl.width
                    spacing: 3
                    Repeater {
                        model: root.log
                        delegate: Row {
                            required property var modelData
                            width: logCol.width
                            spacing: 8
                            Text {
                                width: 32
                                horizontalAlignment: Text.AlignRight
                                text: modelData.secs + "s"
                                color: Qt.alpha(root.pal.muted, 0.7)
                                font.family: root.pal.mono
                                font.pixelSize: 11
                            }
                            Text {
                                width: parent.width - 40
                                wrapMode: Text.Wrap
                                text: (modelData.lvl === "o" ? "\u2713 " : (modelData.lvl === "e" ? "\u2717 " : (modelData.lvl === "w" ? "! " : "\u00b7 "))) + modelData.text
                                color: modelData.lvl === "o" ? root.pal.good : (modelData.lvl === "e" ? root.pal.bad : (modelData.lvl === "w" ? root.pal.warn : root.pal.text))
                                font.family: root.pal.mono
                                font.pixelSize: 11
                            }
                        }
                    }
                }
            }
        }
    }
}
