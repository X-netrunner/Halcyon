import QtQuick
import QtQuick.Layouts

// The Focus controls (a timer with do-not-disturb): the calm picker while idle, the countdown card while a session runs.
// Used twice by Panel.qml: folded into the utilities box (drop-down / when there is no room beside it) and in the card
// that opens to the side of the box (FocusFlyout.qml). Pure view: the host holds the state and handles the signals.
ColumnLayout {
    id: root
    property var pal
    property var focusInfo: ({ on: false })
    property int focusSecs: 0
    property string focusText: "00:00"
    property int focusMins: 25
    property bool focusPomo: false
    property int focusBlocked: 0
    signal focusStart(int mins, bool pomo)
    signal focusCommand(string what)
    signal focusPick(int mins, bool pomo)
    signal openFocusSettings()
    spacing: 0

            // idle: one calm card: pick a length, optional Pomodoro, then start
            Rectangle {
                Layout.fillWidth: true
                visible: !root.focusInfo.on
                implicitHeight: idleCol.implicitHeight + 28
                radius: root.pal.rLg
                color: Qt.alpha(root.pal.accent, 0.08)
                border.width: root.pal.bw
                border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.30)

                ColumnLayout {
                    id: idleCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 14
                    spacing: 12

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Text {
                            text: "Focus"
                            color: root.pal.text
                            font.family: root.pal.uiFont; font.pixelSize: root.pal.tTitle; font.weight: Font.DemiBold
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "A timer with do-not-disturb"
                            elide: Text.ElideRight
                            color: root.pal.muted
                            font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1
                        }
                    }

                    // length: three tiles in one rounded track, the picked one filled
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        radius: 14
                        color: Qt.alpha(root.pal.text, 0.07)
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 4
                            spacing: 4
                            Repeater {
                                model: [25, 50, 90]
                                delegate: Rectangle {
                                    id: lenTile
                                    required property int modelData
                                    readonly property bool sel: root.focusMins === modelData
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    radius: 10
                                    color: sel ? root.pal.accent : (lenMa.containsMouse ? Qt.alpha(root.pal.text, 0.10) : "transparent")
                                    Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                                    Text {
                                        anchors.centerIn: parent
                                        text: lenTile.modelData + " min"
                                        color: lenTile.sel ? root.pal.bg : root.pal.text
                                        font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody + 1; font.weight: Font.DemiBold
                                    }
                                    MouseArea {
                                        id: lenMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.focusPick(lenTile.modelData, root.focusPomo)
                                    }
                                }
                            }
                        }
                    }

                    // Pomodoro: a labelled switch
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text {
                                text: "Pomodoro"
                                color: root.pal.text
                                font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "Rounds with short breaks in between"
                                elide: Text.ElideRight
                                color: root.pal.muted
                                font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap
                            }
                        }
                        Toggle { pal: root.pal; on: root.focusPomo; onToggled: root.focusPick(root.focusMins, !root.focusPomo) }
                    }

                    Chip {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        pal: root.pal
                        primary: true
                        glyph: String.fromCodePoint(0xF040A)
                        label: "Start focus"
                        onClicked: root.focusStart(root.focusMins, root.focusPomo)
                    }

                    // blocked apps: a quiet link under the button
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 22
                        Text {
                            anchors.centerIn: parent
                            text: root.focusBlocked > 0 ? "Blocked apps · " + root.focusBlocked + "   ›" : "Choose apps to block   ›"
                            color: blkMa.containsMouse ? root.pal.text : root.pal.muted
                            font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 1
                            Behavior on color { ColorAnimation { duration: root.pal.dFast } }
                        }
                        MouseArea {
                            id: blkMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.openFocusSettings()
                        }
                    }
                }
            }

            // running: a countdown card with the phase, a progress line and the controls
            Rectangle {
                Layout.fillWidth: true
                visible: root.focusInfo.on
                implicitHeight: runCol.implicitHeight + 24
                radius: root.pal.rLg
                color: Qt.alpha(root.pal.accent, 0.10)
                border.width: root.pal.bw
                border.color: root.pal.calm ? root.pal.line : Qt.alpha(root.pal.accent, 0.35)

                ColumnLayout {
                    id: runCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 10

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Text {
                            text: root.focusText
                            color: root.pal.text
                            font.family: root.pal.uiFont; font.pixelSize: 30; font.weight: Font.DemiBold
                            opacity: root.focusInfo.paused ? 0.55 : 1
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: root.focusInfo.paused ? "Paused" : (root.focusInfo.phase === "work" ? "Focusing" : (root.focusInfo.phase === "long" ? "Long break" : "Break"))
                                color: root.pal.accent
                                font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.DemiBold
                            }
                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: (root.focusInfo.pomodoro ? "Round " + root.focusInfo.cycle + " of " + root.focusInfo.cycles + " · " : "")
                                      + (root.focusInfo.blocking ? "apps blocked" : "apps allowed")
                                      + (root.focusInfo.closed > 0 ? " · " + root.focusInfo.closed + " closed" : "")
                                color: root.pal.muted
                                font.family: root.pal.uiFont; font.pixelSize: 11
                            }
                        }
                    }

                    // progress of the running phase
                    Rectangle {
                        Layout.fillWidth: true
                        height: 4; radius: 2
                        color: Qt.alpha(root.pal.text, 0.10)
                        Rectangle {
                            height: parent.height; radius: 2
                            color: root.pal.accent
                            width: parent.width * (root.focusInfo.total > 0 ? Math.max(0, Math.min(1, 1 - root.focusSecs / root.focusInfo.total)) : 0)
                            Behavior on width { NumberAnimation { duration: 900; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Chip { Layout.fillWidth: true; pal: root.pal; label: root.focusInfo.paused ? "Resume" : "Pause"; onClicked: root.focusCommand(root.focusInfo.paused ? "resume" : "pause") }
                        Chip { Layout.fillWidth: true; pal: root.pal; label: "+5 min"; onClicked: root.focusCommand("add 5") }
                        Chip { Layout.fillWidth: true; pal: root.pal; label: root.focusInfo.pomodoro ? "Skip" : "Done"; onClicked: root.focusCommand("skip") }
                        RoundBtn { pal: root.pal; glyph: String.fromCodePoint(0xF0156); size: 36; onClicked: root.focusCommand("stop") }
                    }
                }
            }
}
