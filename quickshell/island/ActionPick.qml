import QtQuick
import QtQuick.Layouts

// One "what does this do" row, used by Settings > Touchpad gestures and Settings > Mouse buttons:
//   [ ←  Swipe left      Next workspace  ▾ ]        click the button and the list of every action unfolds below it, grouped.
// Two actions need one more thing: "Open an app" shows the app menu (AppPicker), "Run a command" a text box.
// The page decides which row is unfolded (`unfolded`, `toggled`), and gets the choice in `chosen(action, cmd)`.
ColumnLayout {
    id: root
    property var pal
    property string title: ""
    property string icon: ""                 // a short symbol drawn before the title (an arrow, ...)
    property string action: "none"
    property string cmd: ""
    property var actions: []                 // [{ id, t, g }]  id = what scripts/input-conf.sh knows, t = shown text, g = group heading
    property bool unfolded: false
    property int titleWidth: 112
    signal toggled()
    signal chosen(string action, string cmd)

    spacing: 6

    function textOf(id) {
        for (var i = 0; i < actions.length; i++) if (actions[i].id === id) return actions[i].t
        return id
    }
    readonly property string shown: {
        var t = textOf(action)
        if ((action === "app" || action === "cmd") && cmd !== "") {
            var first = cmd.split(" ")[0].split("/").pop()
            return (action === "app" ? "Open " : "Run ") + first
        }
        return t
    }
    // the group headings, in the order they first appear
    readonly property var groups: {
        var out = []
        for (var i = 0; i < actions.length; i++) if (out.indexOf(actions[i].g) < 0) out.push(actions[i].g)
        return out
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        Text {
            visible: root.icon !== ""
            Layout.preferredWidth: 22
            horizontalAlignment: Text.AlignHCenter
            text: root.icon
            color: root.action === "none" ? root.pal.muted : root.pal.accent
            font.family: root.pal.uiFont; font.pixelSize: 17
        }
        Text {
            Layout.preferredWidth: root.titleWidth
            text: root.title
            elide: Text.ElideRight
            color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            radius: 17
            color: root.unfolded ? Qt.alpha(root.pal.accent, 0.14) : (btnMa.containsMouse ? Qt.alpha(root.pal.surfaceHi, 0.9) : Qt.alpha(root.pal.surface, 0.8))
            border.width: root.pal.zen && !(root.unfolded) ? 0 : 1
            border.color: root.unfolded ? Qt.alpha(root.pal.accent, 0.4) : root.pal.lineSoft
            Behavior on color { ColorAnimation { duration: root.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.34, 0.8, 0.34, 1, 1, 1] } }
            Text {
                anchors.left: parent.left; anchors.leftMargin: 16
                anchors.right: arrow.left; anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: root.shown
                elide: Text.ElideRight
                color: root.action === "none" ? root.pal.muted : root.pal.text
                font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody; font.weight: Font.Medium
            }
            Text {
                id: arrow
                anchors.right: parent.right; anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: root.unfolded ? "▴" : "▾"
                color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: 11
            }
            MouseArea {
                id: btnMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggled()
            }
        }
    }

    // the unfolded list: built only while it is open (a page has up to six of these rows, each with ~45 chips and an app menu;
    // creating all of them up front is what made the Settings search lag when it brought this section up)
    Loader {
        Layout.fillWidth: true
        Layout.preferredHeight: item ? item.implicitHeight : 0
        active: root.unfolded
        visible: active
        sourceComponent: panel
    }
    Component {
      id: panel
      Rectangle {
        width: parent ? parent.width : 0
        implicitHeight: pick.implicitHeight + 24
        radius: 14
        color: Qt.alpha(root.pal.bg, 0.35)
        border.width: root.pal.calm ? 0 : 1
        border.color: root.pal.lineSoft

        ColumnLayout {
            id: pick
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.margins: 12
            spacing: 10

            Repeater {
                model: root.groups
                delegate: ColumnLayout {
                    id: grp
                    required property string modelData
                    Layout.fillWidth: true
                    spacing: 6
                    Text {
                        text: grp.modelData
                        color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.Medium
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 8
                        Repeater {
                            model: root.actions.filter(function (a) { return a.g === grp.modelData })
                            delegate: Chip {
                                id: opt
                                required property var modelData
                                maxLabel: 1000
                                implicitHeight: 30
                                pal: root.pal
                                label: modelData.t
                                on: root.action === modelData.id
                                // "Open an app" / "Run a command" keep what is typed only when they are already the choice
                                onClicked: root.chosen(modelData.id, (modelData.id === root.action) ? root.cmd : "")
                            }
                        }
                    }
                }
            }

            // Open an app: the same menu of installed apps the shortcut editor uses
            ColumnLayout {
                Layout.fillWidth: true
                visible: root.action === "app"
                spacing: 6
                Text {
                    Layout.fillWidth: true
                    text: root.cmd !== "" ? "Now: " + root.cmd : "Pick the app to open"
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                }
                Loader {
                    Layout.fillWidth: true
                    Layout.preferredHeight: item ? item.implicitHeight : 0
                    active: root.action === "app"
                    sourceComponent: Component {
                        AppPicker {
                            width: parent ? parent.width : 0
                            pal: root.pal
                            placeholder: "Search your apps, click one…"
                            onPicked: app => root.chosen("app", app.cmd)
                        }
                    }
                }
            }

            // Run a command: any shell command (cmd = e.g. `foot -e btop` or `notify-send hi`)
            RowLayout {
                Layout.fillWidth: true
                visible: root.action === "cmd"
                spacing: 10
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 34; radius: 17
                    color: root.pal.zen ? root.pal.field : Qt.alpha(root.pal.bg, 0.5); border.width: root.pal.zen && !cmdIn.activeFocus ? 0 : 1
                    border.color: cmdIn.activeFocus ? root.pal.accent : root.pal.lineSoft
                    TextInput {
                        id: cmdIn
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        verticalAlignment: TextInput.AlignVCenter
                        color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                        clip: true; selectByMouse: true
                        text: root.cmd
                        onAccepted: root.chosen("cmd", text.trim())
                        Text {
                            visible: !parent.text && !parent.activeFocus
                            anchors.verticalCenter: parent.verticalCenter
                            text: "a shell command, e.g. foot -e btop"
                            color: root.pal.muted; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody
                        }
                    }
                }
                Chip { pal: root.pal; maxLabel: 1000; label: "Save"; primary: true; onClicked: root.chosen("cmd", cmdIn.text.trim()) }
            }
        }
      }
    }
}
