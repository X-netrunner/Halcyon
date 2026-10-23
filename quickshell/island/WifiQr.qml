import QtQuick
import Quickshell
import Quickshell.Wayland

// The Wi-Fi QR code, big in the middle of the screen (scripts/halcyon-tools.py wifi-qr calls `island wifiqr <png> <ssid>`).
// It used to open in an image viewer, and without one only a notification icon was left. Esc or a click closes it; it closes by
// itself after 2 minutes, when the picture (it holds the password) is deleted anyway.
Scope {
    id: root
    property var pal
    property bool open: false
    property string png: ""
    property string ssid: ""
    property int stamp: 0                  // a new code each time: the image is read again, not taken from the cache

    function show(path, name) {
        png = path
        ssid = name
        stamp++
        open = true
        closeT.restart()
    }
    function hide() { open = false }
    Timer { id: closeT; interval: 120000; onTriggered: root.hide() }

    LazyLoader {
        active: root.open
        PanelWindow {
            visible: true
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "island-wifiqr"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

            Rectangle {
                anchors.fill: parent
                color: Qt.alpha(root.pal.bg, 0.6)
                focus: true
                Keys.onPressed: e => { root.hide(); e.accepted = true }
                MouseArea { anchors.fill: parent; onClicked: root.hide() }
            }

            Rectangle {
                anchors.centerIn: parent
                width: 380
                height: col.implicitHeight + 48
                radius: root.pal.rXl
                color: Qt.alpha(root.pal.bg, 0.98)
                border.width: 1
                border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.35)
                MouseArea { anchors.fill: parent; onClicked: root.hide() }

                Column {
                    id: col
                    anchors.centerIn: parent
                    width: parent.width - 48
                    spacing: 14
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: root.ssid
                        elide: Text.ElideRight
                        color: root.pal.text
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tTitle + 3
                        font.weight: Font.DemiBold
                    }
                    // a white square around the code: phone cameras need the contrast, also in the dark theme
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 300; height: 300
                        radius: root.pal.rMd
                        color: "white"
                        Image {
                            anchors.fill: parent
                            anchors.margins: 14
                            source: root.png !== "" ? "file://" + root.png + "?" + root.stamp : ""
                            fillMode: Image.PreserveAspectFit
                            smooth: false              // keep the modules sharp
                            cache: false
                        }
                    }
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        text: "Scan with a phone camera to join"
                        color: root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tBody
                    }
                }
            }
        }
    }
}
