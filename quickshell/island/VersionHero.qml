import QtQuick
import QtQuick.Layouts

// The big Halcyon card in the Version Center.
Rectangle {
    property var vc
    id: hero
    property var comp
    property bool menuOpen: false
    readonly property var lst: vc.lists[comp.id] || null
    readonly property var res: vc.resFor(comp.id)
    readonly property bool mine: vc.isBusyFor(comp.id)
    radius: vc.pal.rXl
    color: vc.pal.fill
    border.width: 1
    border.color: mine ? Qt.alpha(vc.pal.accent, 0.5) : vc.pal.lineSoft
    Behavior on border.color { ColorAnimation { duration: vc.pal.dMed } }
    clip: true

    // The light in the card follows the pointer while it is over the card and stays where it was left when the pointer goes out: it never
    // leaves the card. It starts in the top right corner, and the move is eased so it glides instead of jumping.
    property real gx: width - 70
    property real gy: 60
    Behavior on gx { NumberAnimation { duration: vc.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: vc.pal.curveSoft } }
    Behavior on gy { NumberAnimation { duration: vc.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: vc.pal.curveSoft } }
    HoverHandler {
        id: hh
        onPointChanged: {
            if (!hh.hovered) return
            hero.gx = Math.max(0, Math.min(hero.width, hh.point.position.x))
            hero.gy = Math.max(0, Math.min(hero.height, hh.point.position.y))
        }
    }
    WGlow { x: hero.gx - 170; y: hero.gy - 170; width: 340; height: 340; color: vc.pal.accent2; strength: 0.2 * vc.pal.decor }

    Flickable {
        id: hf
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: heroCol.height + 40
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: heroCol
            x: 20
            y: 20
            width: hf.width - 40
            height: Math.max(implicitHeight, hf.height - 40)
            spacing: 14

            RowLayout {
                Layout.fillWidth: true
                HalMark { pal: vc.pal; size: 44; Layout.alignment: Qt.AlignTop }
                Item { Layout.fillWidth: true }
                VersionCorner { pal: vc.pal; Layout.alignment: Qt.AlignTop; open: hero.menuOpen; onClicked: hero.menuOpen = !hero.menuOpen }
            }
            Text {
                Layout.fillWidth: true
                text: hero.comp.name
                elide: Text.ElideRight
                color: vc.pal.text
                font.family: vc.pal.uiFont
                font.pixelSize: Math.round(Math.max(36, Math.min(64, hf.width * 0.16)))
                font.weight: Font.Light
            }
            Flow {
                Layout.fillWidth: true
                spacing: 8
                VersionBadge { pal: vc.pal; label: vc.stateText(hero.comp); tone: vc.stateColor(hero.comp); dot: hero.comp.state === "up-to-date" || hero.comp.state === "behind"; fs: vc.pal.tBody + 1; hgt: 32 }
                VersionBadge { pal: vc.pal; visible: vc.tagOf(hero.comp) !== ""; label: vc.tagOf(hero.comp); tone: vc.pal.muted; fs: vc.pal.tBody; hgt: 26 }
                VersionBadge { pal: vc.pal; visible: hero.comp.dirty; label: "local changes"; tone: vc.pal.muted; fs: vc.pal.tBody; hgt: 26 }
                VersionBadge { pal: vc.pal; visible: hero.comp.offline; label: "offline"; tone: vc.pal.muted; fs: vc.pal.tBody; hgt: 26 }
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 10
                rowSpacing: 10
                VersionTile { pal: vc.pal; label: "Installed"; mono: true; value: hero.comp.installed ? hero.comp.installed.short : "unknown"; sub: hero.comp.installed ? vc.fmtDate(hero.comp.installed.date) : "" }
                VersionTile { pal: vc.pal; label: "Latest on main"; mono: !!hero.comp.latest; value: hero.comp.latest ? hero.comp.latest.short : "not checked"; sub: hero.comp.latest ? vc.fmtDate(hero.comp.latest.date) : "press Check now" }
                VersionTile { pal: vc.pal; label: "Behind by"; value: vc.behindValue(hero.comp); sub: vc.behindSub(hero.comp) }
                VersionTile { pal: vc.pal; label: "Pin"; value: hero.comp.pinned ? "Pinned" : "Not pinned"; sub: hero.comp.pinned ? hero.comp.pinned.short : "follows main" }
            }

            // how far the installed version is from the newest
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                RowLayout {
                    Layout.fillWidth: true
                    VersionText { pal: vc.pal; kind: "small"; text: "Installed" }
                    Item { Layout.fillWidth: true }
                    VersionText { pal: vc.pal; kind: "small"; text: "Latest" }
                }
                Item {
                    id: track
                    Layout.fillWidth: true
                    implicitHeight: 16
                    property real pos: vc.lagPos(hero.comp)
                    Behavior on pos { NumberAnimation { duration: vc.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: vc.pal.curveSoft } }
                    Rectangle { y: 5; width: track.width; height: 6; radius: 3; color: Qt.alpha(vc.pal.text, 0.08) }
                    Rectangle {
                        y: 5
                        width: Math.max(6, track.width * track.pos)
                        height: 6
                        radius: 3
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: vc.pal.accent }
                            GradientStop { position: 1; color: vc.pal.accent2 }
                        }
                    }
                    Rectangle {
                        x: Math.min(track.width - 16, Math.max(0, track.width * track.pos - 8))
                        width: 16
                        height: 16
                        radius: 8
                        color: vc.pal.bg
                        border.width: 2
                        border.color: vc.pal.accent2
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: !!hero.comp.latest && hero.comp.latest.subject !== ""
                    spacing: 6
                    VersionText { pal: vc.pal; kind: "small"; text: "Newest change:" }
                    Text { Layout.fillWidth: true; text: hero.comp.latest ? hero.comp.latest.subject : ""; elide: Text.ElideRight; color: vc.pal.text; font.family: vc.pal.uiFont; font.pixelSize: vc.pal.tCap + 1 }
                }
            }

            Item { Layout.fillHeight: true; Layout.minimumHeight: 0 }

            VersionActions {
                pal: vc.pal
                hero: true
                shown: hero.menuOpen
                comp: hero.comp
                lst: hero.lst
                blocked: vc.locked || vc.planBusy
                onUpdateClicked: vc.askUpdate(hero.comp.id)
                onRollbackClicked: vc.askRollback(hero.comp.id)
                onPinClicked: vc.pinToggle(hero.comp.id)
                onCommitsClicked: vc.toggleList(hero.comp.id)
            }
            VersionLog { vc: hero.vc; comp: hero.comp; lst: hero.lst; res: hero.res; mine: hero.mine }
            VersionCommits { vc: hero.vc; comp: hero.comp; lst: hero.lst }
        }
    }
}
