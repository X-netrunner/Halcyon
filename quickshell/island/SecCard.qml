import QtQuick
import QtQuick.Layouts

// One section of a builder window's controls: a hairline above it (`line: false` for the first one) and its rows in a column.
// The lighter panel behind all the sections together is drawn by the window, so the sections read as one block, not as separate cards.
Item {
    id: card
    property var pal
    property bool line: true
    default property alias content: col.data
    Layout.fillWidth: true
    implicitHeight: col.implicitHeight + (line ? 16 : 0) + 4

    Rectangle {
        visible: card.line
        width: parent.width; height: 1
        color: card.pal.lineSoft
    }
    ColumnLayout {
        id: col
        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: card.line ? 16 : 0 }
        spacing: 12
    }
}
