import QtQuick
import QtQuick.Layouts

// A companion card in the Version Center (LUNA, ai-antivirus, ai-firewall).
Rectangle {
    property var vc
    id: card
    property var comp
    property bool menuOpen: false
    readonly property bool greyed: comp.state === "not-chosen" || comp.state === "missing"
    readonly property bool pacman: comp.state === "pacman"
    readonly property var lst: vc.lists[comp.id] || null
    readonly property var res: vc.resFor(comp.id)
    readonly property bool mine: vc.isBusyFor(comp.id)
    width: ListView.view ? ListView.view.width : 600
    height: col.implicitHeight + 32
    radius: vc.pal.rLg
    color: vc.pal.fill
    border.width: 1
    border.color: mine ? Qt.alpha(vc.pal.accent, 0.5) : vc.pal.lineSoft
    // a component that is not installed reads quieter by its name only; its Install button stays fully legible
    Behavior on height { NumberAnimation { duration: vc.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: vc.pal.curve } }
    Behavior on border.color { ColorAnimation { duration: vc.pal.dMed } }
    clip: true

    ColumnLayout {
        id: col
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Rectangle {
                implicitWidth: 32
                implicitHeight: 32
                radius: 10
                color: vc.pal.fill
                Text { anchors.centerIn: parent; text: String.fromCodePoint(vc.iconFor(card.comp.id)); color: card.greyed ? vc.pal.muted : vc.pal.accent; font.family: vc.pal.font; font.pixelSize: 17 }
            }
            Text { text: card.comp.name; color: card.greyed ? vc.pal.muted : vc.pal.text; font.family: vc.pal.uiFont; font.pixelSize: vc.pal.tTitle; font.weight: Font.Medium }
            VersionBadge { pal: vc.pal; label: vc.stateText(card.comp); tone: vc.stateColor(card.comp); dot: !card.greyed && (card.comp.state === "up-to-date" || card.comp.state === "behind") }
            VersionBadge { pal: vc.pal; visible: !!card.comp.pinned; label: "pinned " + (card.comp.pinned ? card.comp.pinned.short : ""); tone: vc.pal.warn }
            VersionBadge { pal: vc.pal; visible: card.comp.dirty; label: "local changes"; tone: vc.pal.muted }
            VersionBadge { pal: vc.pal; visible: card.comp.offline && !card.greyed; label: "offline"; tone: vc.pal.muted }
            Item { Layout.fillWidth: true }
            VersionBtn { pal: vc.pal;
                visible: card.greyed
                label: "Install"
                primary: false     // one primary action per window (Update all); these are secondary
                disabled: vc.locked
                onClicked: vc.askInstallNew(card.comp.id)
            }
            VersionCorner {
                pal: vc.pal
                visible: !card.greyed && !card.pacman
                open: card.menuOpen
                onClicked: card.menuOpen = !card.menuOpen
            }
        }

        GridLayout {
            visible: !card.greyed
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 16
            rowSpacing: 4
            VersionText { pal: vc.pal; kind: "label"; text: "Installed" }
            VersionText { pal: vc.pal; kind: "mono"; Layout.fillWidth: true; text: vc.verText(card.comp.installed); elide: Text.ElideRight }
            VersionText { pal: vc.pal; kind: "label"; text: "Latest on main" }
            VersionText { pal: vc.pal; kind: "mono"; Layout.fillWidth: true; text: card.comp.latest ? vc.verText(card.comp.latest) : "not checked yet (Check now)"; elide: Text.ElideRight; color: card.comp.latest ? vc.pal.text : vc.pal.muted }
        }
        VersionText { pal: vc.pal; kind: "small";
            visible: card.pacman
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            elide: Text.ElideNone
            text: "This one came from a pacman package, so pacman keeps it up to date. Nothing here changes it."
        }

        VersionActions {
            pal: vc.pal
            shown: card.menuOpen && !card.greyed && !card.pacman
            comp: card.comp
            lst: card.lst
            blocked: vc.locked || vc.planBusy
            onUpdateClicked: vc.askUpdate(card.comp.id)
            onRollbackClicked: vc.askRollback(card.comp.id)
            onPinClicked: vc.pinToggle(card.comp.id)
            onCommitsClicked: vc.toggleList(card.comp.id)
        }
        VersionLog { vc: card.vc; comp: card.comp; lst: card.lst; res: card.res; mine: card.mine }
        VersionCommits { vc: card.vc; comp: card.comp; lst: card.lst }
    }
}
