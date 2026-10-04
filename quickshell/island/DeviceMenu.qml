import QtQuick
import QtQuick.Layouts

// Drop-down list the bottom-right panel uses for Wi-Fi networks, Bluetooth devices and audio devices.
// items: [{ title, sub, glyph, active }]  or a heading row: { section: "Output" }
Rectangle {
    id: root
    property var pal
    property string title: ""
    property var items: []
    property bool hasPower: false
    property bool powered: true
    property string emptyText: "Nothing found"
    property string footer: ""              // last row, e.g. "Open network settings"
    property int maxHeight: 200
    // Wi-Fi password prompt: set askFor to an SSID and the input row appears
    property string askFor: ""
    signal picked(int index)
    signal powerToggled()
    signal footerClicked()
    signal passwordSubmitted(string pw)
    signal askCancelled()

    readonly property int realCount: {
        var n = 0
        for (var i = 0; i < items.length; i++) if (!items[i].section) n++
        return n
    }

    onAskForChanged: {
        pwIn.text = ""
        if (askFor !== "") Qt.callLater(function () { pwIn.forceActiveFocus() })
    }

    implicitHeight: col.implicitHeight + 24
    radius: pal.rLg
    color: Qt.alpha(pal.surface, 0.55)
    border.width: 1
    border.color: pal.lineSoft

    ColumnLayout {
        id: col
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: root.title
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: pal.tBody
                font.weight: Font.DemiBold
            }
            Chip {
                visible: root.hasPower
                pal: root.pal
                implicitHeight: 26
                label: root.powered ? "On" : "Off"
                on: root.powered
                onClicked: root.powerToggled()
            }
        }

        // password prompt
        Rectangle {
            visible: root.askFor !== ""
            Layout.fillWidth: true
            implicitHeight: 38
            radius: 13
            color: root.pal.bg
            border.width: 1
            border.color: Qt.alpha(root.pal.accent, 0.5)
            RowLayout {
                anchors { fill: parent; leftMargin: 12; rightMargin: 6 }
                spacing: 8
                TextInput {
                    id: pwIn
                    Layout.fillWidth: true
                    echoMode: TextInput.Password
                    color: root.pal.text
                    font.family: root.pal.uiFont
                    font.pixelSize: 13
                    clip: true
                    selectByMouse: true
                    Keys.onReturnPressed: root.passwordSubmitted(text)
                    Keys.onEnterPressed: root.passwordSubmitted(text)
                    Keys.onEscapePressed: root.askCancelled()
                    Text {
                        visible: pwIn.text === ""
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Password for " + root.askFor
                        color: root.pal.muted
                        font: pwIn.font
                        elide: Text.ElideRight
                        width: parent.width
                    }
                }
                Chip { pal: root.pal; implicitHeight: 28; label: "Join"; on: true; onClicked: root.passwordSubmitted(pwIn.text) }
                Chip { pal: root.pal; implicitHeight: 28; label: "✕"; onClicked: root.askCancelled() }
            }
        }

        Text {
            visible: root.realCount === 0
            Layout.fillWidth: true
            Layout.topMargin: 4
            Layout.bottomMargin: 4
            horizontalAlignment: Text.AlignHCenter
            text: root.powered || !root.hasPower ? root.emptyText : "Turned off"
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: 12
        }

        Flickable {
            id: fl
            visible: root.items.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(list.implicitHeight, root.maxHeight)
            contentHeight: list.implicitHeight
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: list
                width: fl.width
                spacing: 2
                Repeater {
                    model: root.items
                    delegate: Item {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool heading: !!modelData.section
                        width: list.width
                        height: heading ? 26 : 42

                        Text {
                            visible: row.heading
                            anchors { left: parent.left; leftMargin: 6; bottom: parent.bottom; bottomMargin: 3 }
                            text: String(row.modelData.section).toUpperCase()
                            color: root.pal.muted
                            font.family: root.pal.uiFont
                            font.pixelSize: 9
                            font.letterSpacing: 1
                        }

                        Rectangle {
                            visible: !row.heading
                            anchors.fill: parent
                            radius: 14
                            color: row.modelData.active ? Qt.alpha(root.pal.accent, 0.18)
                                 : (ma.containsMouse ? Qt.alpha(root.pal.accent, 0.09) : "transparent")
                            border.width: row.modelData.active ? 1 : 0
                            border.color: Qt.alpha(root.pal.accent, 0.45)
                            Behavior on color { ColorAnimation { duration: 120 } }

                            Row {
                                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                spacing: 10
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 22
                                    text: row.modelData.glyph || ""
                                    color: row.modelData.active ? root.pal.accent : root.pal.muted
                                    font.family: root.pal.font
                                    font.pixelSize: 16
                                }
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 22 - 22 - 20
                                    spacing: 0
                                    Text {
                                        width: parent.width
                                        text: row.modelData.title || ""
                                        elide: Text.ElideRight
                                        color: root.pal.text
                                        font.family: root.pal.uiFont
                                        font.pixelSize: 12
                                        font.weight: row.modelData.active ? Font.DemiBold : Font.Normal
                                    }
                                    Text {
                                        visible: !!row.modelData.sub
                                        width: parent.width
                                        text: row.modelData.sub || ""
                                        elide: Text.ElideRight
                                        color: root.pal.muted
                                        font.family: root.pal.uiFont
                                        font.pixelSize: 10
                                    }
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 22
                                    horizontalAlignment: Text.AlignRight
                                    text: row.modelData.active ? String.fromCodePoint(0xF012C) : ""
                                    color: root.pal.accent
                                    font.family: root.pal.font
                                    font.pixelSize: 14
                                }
                            }
                            MouseArea {
                                id: ma
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.picked(row.index)
                            }
                        }
                    }
                }
            }
        }

        Text {
            visible: root.footer !== ""
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 2
            text: root.footer
            color: fma.containsMouse ? root.pal.accent : root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: 11
            MouseArea { id: fma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.footerClicked() }
        }
    }
}
