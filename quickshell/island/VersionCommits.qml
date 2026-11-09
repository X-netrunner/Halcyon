import QtQuick
import QtQuick.Layouts

// The commit list of one Version Center card (loaded on demand by VersionCenter).
ColumnLayout {
    property var vc
    id: card
    property var comp
    property var lst
    visible: !!(card.lst && card.lst.open)
    Layout.fillWidth: true
    spacing: 4
    Flow {
        visible: !!(card.lst && card.lst.tags.length > 0)
        Layout.fillWidth: true
        spacing: 8
        VersionText { pal: vc.pal; kind: "label"; text: "Tags"; height: 24; verticalAlignment: Text.AlignVCenter }
        Repeater {
            model: card.lst ? card.lst.tags : []
            delegate: Rectangle {
                required property var modelData
                implicitWidth: tgTxt.implicitWidth + 18
                implicitHeight: 24
                radius: 8
                color: tgMa.containsMouse ? vc.pal.fillHover : vc.pal.fill
                Text { id: tgTxt; anchors.centerIn: parent; text: modelData.tag; color: vc.pal.text; font.family: vc.pal.mono; font.pixelSize: vc.pal.tCap }
                MouseArea { id: tgMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !vc.locked; onClicked: vc.ask("install", card.comp.id, modelData.tag, modelData.tag) }
            }
        }
    }
    VersionText { pal: vc.pal; kind: "small"; visible: !!(card.lst && card.lst.offline); text: "You are offline, so this is the list saved last time." }
    Repeater {
        model: card.lst ? card.lst.commits : []
        delegate: Rectangle {
            id: cr
            required property var modelData
            Layout.fillWidth: true
            implicitHeight: 34
            radius: vc.pal.rSm
            color: crMa.containsMouse ? vc.pal.fillHover : (modelData.rel === "installed" ? Qt.alpha(vc.pal.accent, 0.12) : "transparent")
            Behavior on color { ColorAnimation { duration: vc.pal.dFast } }
            MouseArea { id: crMa; anchors.fill: parent; hoverEnabled: true }
            RowLayout {
                anchors { fill: parent; leftMargin: 10; rightMargin: 8 }
                spacing: 12
                VersionText { pal: vc.pal; kind: "mono"; text: cr.modelData.short; color: vc.pal.accent; Layout.preferredWidth: 64 }
                Text {
                    Layout.fillWidth: true
                    text: cr.modelData.subject
                    color: vc.pal.text
                    elide: Text.ElideRight
                    font.family: vc.pal.uiFont
                    font.pixelSize: vc.pal.tBody - 1
                }
                VersionBadge { pal: vc.pal; visible: cr.modelData.tags.length > 0; label: cr.modelData.tags.length > 0 ? cr.modelData.tags[0] : ""; tone: vc.pal.muted }
                VersionBadge { pal: vc.pal; visible: cr.modelData.rel === "installed"; label: "installed"; tone: vc.pal.good }
                VersionText { pal: vc.pal; kind: "small"; text: vc.fmtDate(cr.modelData.date); Layout.preferredWidth: 84; horizontalAlignment: Text.AlignRight }
                VersionText { pal: vc.pal; kind: "small"; text: cr.modelData.author; Layout.preferredWidth: 90 }
                VersionBtn { pal: vc.pal;
                    visible: cr.modelData.rel !== "installed"
                    label: "Install"
                    implicitHeight: 26
                    disabled: vc.locked || vc.planBusy
                    onClicked: vc.ask("install", card.comp.id, cr.modelData.sha, cr.modelData.short)
                }
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        visible: !!(card.lst && (card.lst.more || card.lst.loading))
        VersionBtn { pal: vc.pal; label: card.lst && card.lst.loading ? "Loading…" : "Load 30 more"; disabled: !!(card.lst && card.lst.loading); onClicked: vc.loadLog(card.comp.id, card.lst.commits.length) }
    }
    VersionText { pal: vc.pal; kind: "small"; visible: !!(card.lst && !card.lst.loading && card.lst.commits.length === 0); text: "No history yet. Check now will bring it in." }
}
