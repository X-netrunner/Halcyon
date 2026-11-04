import QtQuick
import QtQuick.Layouts

// The actions of one Version Center card: Update, Roll back, Pin, Commits, as a pill. Closed it takes no room (no empty band under the card).
// It only reports what was pressed; VersionCenter does the work.
Item {
    id: ac
    property var pal
    property var comp
    property var lst
    property bool shown: false
    property bool hero: false
    property bool blocked: false      // another operation is running, or a plan is being made
    signal updateClicked()
    signal rollbackClicked()
    signal pinClicked()
    signal commitsClicked()
    Layout.fillWidth: true
    implicitHeight: shown ? 36 : 0
    visible: implicitHeight > 0.5
    clip: true
    opacity: shown ? 1 : 0
    // the pill grows out of the card: height and a small pop of its own, not just a line appearing
    scale: shown ? 1 : 0.94
    transformOrigin: Item.Center
    Behavior on implicitHeight { NumberAnimation { duration: ac.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: ac.pal.curveSoft } }
    Behavior on opacity { NumberAnimation { duration: ac.pal.dFast } }
    Behavior on scale { NumberAnimation { duration: ac.pal.dMed; easing.type: Easing.BezierSpline; easing.bezierCurve: ac.pal.curveSoft } }
    Rectangle {
        width: acRow.implicitWidth + 10
        height: 36
        radius: 12
        color: "transparent"
        border.width: 1
        border.color: ac.pal.line
        RowLayout {
            id: acRow
            anchors.centerIn: parent
            spacing: 2
            VersionPill {
                pal: ac.pal
                label: ac.hero || (ac.comp.pinned && ac.comp.state === "behind") || ac.comp.state === "unreg" ? "Update to main" : "Update"
                primary: ac.comp.state === "behind"
                disabled: ac.blocked || !(ac.comp.state === "behind" || ac.comp.state === "unreg")
                onClicked: ac.updateClicked()
            }
            VersionPill {
                pal: ac.pal
                label: "Roll back"
                disabled: ac.blocked || !ac.comp.previous
                onClicked: ac.rollbackClicked()
            }
            Rectangle { Layout.alignment: Qt.AlignVCenter; implicitWidth: 1; implicitHeight: 14; color: ac.pal.line }
            VersionPill {
                pal: ac.pal
                label: ac.comp.pinned ? "Unpin" : "Pin"
                disabled: ac.blocked || (!ac.comp.pinned && !(ac.comp.installed && ac.comp.installed.sha))
                onClicked: ac.pinClicked()
            }
            Rectangle { Layout.alignment: Qt.AlignVCenter; implicitWidth: 1; implicitHeight: 14; color: ac.pal.line }
            VersionPill {
                pal: ac.pal
                label: (ac.lst && ac.lst.open) ? "Hide commits" : "Commits"
                onClicked: ac.commitsClicked()
            }
        }
    }
}
