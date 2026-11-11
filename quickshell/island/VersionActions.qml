import QtQuick

Item {
    id: ac
    property var pal
    property var comp
    property var lst
    property bool mainCard: false
    property bool blocked: false
    signal updateClicked()
    signal rollbackClicked()
    signal pinClicked()
    signal commitsClicked()
    implicitWidth: pill.implicitWidth
    implicitHeight: pill.implicitHeight

    ActionPill {
        id: pill
        anchors.fill: parent
        pal: ac.pal
        tip: "Update, roll back, pin or see commits"
        actions: [
            {
                id: "update",
                label: ac.mainCard || (ac.comp.pinned && ac.comp.state === "behind") || ac.comp.state === "unreg" ? "Update to main" : "Update",
                tip: "Install the newest version from main",
                primary: ac.comp.state === "behind",
                disabled: ac.blocked || !(ac.comp.state === "behind" || ac.comp.state === "unreg")
            },
            {
                id: "rollback",
                label: "Roll back",
                tip: "Go back to the version that was installed before",
                disabled: ac.blocked || !ac.comp.previous
            },
            {
                id: "pin",
                label: ac.comp.pinned ? "Unpin" : "Pin",
                tip: ac.comp.pinned ? "Let updates move this again" : "Keep this exact version",
                disabled: ac.blocked || (!ac.comp.pinned && !(ac.comp.installed && ac.comp.installed.sha))
            },
            {
                id: "commits",
                label: ac.lst && ac.lst.open ? "Hide commits" : "Commits",
                tip: "What changed between versions"
            }
        ]
        onTriggered: id => {
            if (id === "update") ac.updateClicked()
            else if (id === "rollback") ac.rollbackClicked()
            else if (id === "pin") ac.pinClicked()
            else if (id === "commits") ac.commitsClicked()
        }
    }
}
