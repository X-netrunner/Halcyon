import QtQuick
import QtQuick.Layouts

// The log of a running or finished operation on one Version Center card.
Rectangle {
    property var vc
    id: card
    property var comp
    property var lst
    property var res
    property bool mine: false
    visible: card.mine || card.res !== null
    Layout.fillWidth: true
    implicitHeight: logCol.implicitHeight + 24
    radius: vc.pal.rSm
    color: Qt.alpha(vc.pal.bg, 0.45)
    border.width: 1
    border.color: vc.pal.lineSoft
    ColumnLayout {
        id: logCol
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
        spacing: 8
        RowLayout {
            visible: card.mine
            Layout.fillWidth: true
            Text { text: vc.opStep !== "" ? vc.opStep : "Taking care of it…"; color: vc.pal.text; font.family: vc.pal.uiFont; font.pixelSize: vc.pal.tBody - 1; font.weight: Font.Normal; Layout.fillWidth: true; elide: Text.ElideRight }
            VersionBtn { pal: vc.pal; label: "Cancel"; onClicked: vc.cancelOp() }
        }
        Text {
            visible: card.mine && vc.opLines.length > 0
            Layout.fillWidth: true
            text: vc.lastLines(7)
            color: vc.pal.muted
            font.family: vc.pal.mono
            font.pixelSize: vc.pal.tCap
            elide: Text.ElideRight
            maximumLineCount: 7
            wrapMode: Text.NoWrap
        }
        Text {
            visible: !card.mine && card.res !== null
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            lineHeight: 1.2
            text: card.res ? (card.res.skipped ? (vc.cap(card.res.skipped) + ": skipped") : (card.res.ok ? (card.res.changed ? "All done. Now at " + String(card.res.to || "").substring(0, 7) + (card.res.older ? " (an older version)" : "") : "Everything was already in place.") : (card.res.error || "That did not quite finish."))) : ""
            color: card.res && card.res.ok ? vc.pal.good : vc.pal.warn
            font.family: vc.pal.uiFont
            font.pixelSize: vc.pal.tBody - 1
        }
        Text {
            visible: !card.mine && card.res !== null && !!card.res.restored
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            lineHeight: 1.2
            text: "Your previous version is safely back, just as it was."
            color: vc.pal.warn
            font.family: vc.pal.uiFont
            font.pixelSize: vc.pal.tBody - 1
        }
        Flow {
            visible: !card.mine && card.res !== null && !!card.res.health
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: card.res && card.res.health ? card.res.health.checks : []
                delegate: VersionBadge { pal: vc.pal;
                    required property var modelData
                    label: (modelData.ok ? "ok  " : "worth a look  ") + modelData.name + ": " + modelData.detail
                    tone: modelData.ok ? vc.pal.good : vc.pal.warn
                }
            }
        }
        VersionBtn { pal: vc.pal;
            visible: !card.mine && card.res !== null && !!card.res.backup && card.comp.id === "ai-antivirus"
            label: "Restore the database copy"
            disabled: vc.locked
            onClicked: vc.askRestore("ai-antivirus")
        }
    }
}
