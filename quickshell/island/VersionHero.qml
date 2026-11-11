import QtQuick
import QtQuick.Layouts

// The big Halcyon card in the Version Center.
Rectangle {
    property var vc
    id: hero
    property var comp
    readonly property var lst: vc.lists[comp.id] || null
    readonly property var res: vc.resFor(comp.id)
    readonly property bool mine: vc.isBusyFor(comp.id)
    radius: vc.pal.rXl
    color: vc.pal.fill
    border.width: 1
    border.color: mine ? Qt.alpha(vc.pal.accent, 0.5) : vc.pal.lineSoft
    Behavior on border.color { ColorAnimation { duration: vc.pal.dMed } }
    // no clip here: the shadow below the card reaches outside it (the Flickable inside clips its own content)
    // the whole panel tips like a card lifted on one side: the side under the pointer comes up, the far side stays low (it does not grow)
    HoverTilt { id: tilt; pal: vc.pal; lean: 10 }
    // a card on a table: a soft shadow below it at rest, deeper and lower while one side is lifted
    Shadow {
        visible: vc.pal.boxShadow
        z: -1
        anchors.fill: parent
        radius: hero.radius
        spread: 14
        drop: 5 + 5 * tilt.t
        strength: 0.016 + 0.014 * tilt.t
    }
    z: tilt.t > 0.01 ? 2 : 0
    transform: Matrix4x4 { matrix: tilt.matrix }

    VersionActions {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 20
        z: 5
        pal: vc.pal
        mainCard: true
        comp: hero.comp
        lst: hero.lst
        blocked: vc.locked || vc.planBusy
        onUpdateClicked: vc.askUpdate(hero.comp.id)
        onRollbackClicked: vc.askRollback(hero.comp.id)
        onPinClicked: vc.pinToggle(hero.comp.id)
        onCommitsClicked: vc.toggleList(hero.comp.id)
    }

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
            spacing: 16

            RowLayout {
                Layout.fillWidth: true
                HalMark { pal: vc.pal; size: 44; Layout.alignment: Qt.AlignTop }
                Item { Layout.fillWidth: true; Layout.preferredHeight: 32 }   // room for the corner button, which sits above the card
            }
            Text {
                Layout.fillWidth: true
                text: hero.comp.name
                elide: Text.ElideRight
                color: vc.pal.text
                font.family: vc.pal.uiFont
                font.pixelSize: Math.round(Math.max(22, Math.min(28, hf.width * 0.055)))
                font.weight: Font.Medium
            }
            Flow {
                Layout.fillWidth: true
                spacing: 8
                VersionBadge { pal: vc.pal; label: vc.stateText(hero.comp); tone: vc.stateColor(hero.comp); dot: hero.comp.state === "up-to-date" || hero.comp.state === "behind"; fs: vc.pal.tBody + 1; hgt: 32 }
                VersionBadge { pal: vc.pal; visible: vc.tagOf(hero.comp) !== ""; label: vc.tagOf(hero.comp); tone: vc.pal.muted; fs: vc.pal.tBody; hgt: 26 }
                VersionBadge { pal: vc.pal; visible: hero.comp.dirty; label: "local changes"; tone: vc.pal.muted; fs: vc.pal.tBody; hgt: 26 }
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 12
                rowSpacing: 12
                VersionTile { pal: vc.pal; label: "Installed"; mono: true; value: hero.comp.installed ? hero.comp.installed.short : "unknown"; sub: hero.comp.installed ? vc.fmtDate(hero.comp.installed.date) : "" }
                VersionTile { pal: vc.pal; label: "Latest on main"; mono: !!hero.comp.latest; value: hero.comp.latest ? hero.comp.latest.short : "not checked"; sub: hero.comp.latest ? vc.fmtDate(hero.comp.latest.date) : "press Check now when ready" }
                VersionTile { pal: vc.pal; label: "Behind by"; value: vc.behindValue(hero.comp); sub: vc.behindSub(hero.comp) }
                VersionTile { pal: vc.pal; label: "Pin"; value: hero.comp.pinned ? "Pinned" : "Not pinned"; sub: hero.comp.pinned ? hero.comp.pinned.short : "follows main" }
            }

            // how far the installed version is from the newest (flat; the whole card tilts)
            Item {
                id: lagBox
                Layout.fillWidth: true
                implicitHeight: lagCol.implicitHeight
                ColumnLayout {
                    id: lagCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    spacing: 8
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
                            color: vc.pal.accent          // one flat colour, no gradient
                        }
                        Rectangle {
                            x: Math.min(track.width - 16, Math.max(0, track.width * track.pos - 8))
                            width: 16
                            height: 16
                            radius: 8
                            color: vc.pal.bg
                            border.width: 2
                            border.color: vc.pal.accent
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
            }

            Item { Layout.fillHeight: true; Layout.minimumHeight: 0 }

            VersionLog { vc: hero.vc; comp: hero.comp; lst: hero.lst; res: hero.res; mine: hero.mine }
            VersionCommits { vc: hero.vc; comp: hero.comp; lst: hero.lst }
        }
    }
}
