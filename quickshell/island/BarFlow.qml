import QtQuick

// A row (top / bottom bar) or a column (left / right bar) of the same repeated delegate, for CustomBar.qml.
// Only the list that matches the bar's direction is filled; the other one is empty and takes no room.
//   along   how long it is in the bar's direction (a row's width, a column's height)
// Its implicit size is the size of whichever list is in use, so a parent can centre it or measure it.
Item {
    id: bf
    property bool vert: false
    property real spacing: 0
    property var model: []
    property Component delegate: null

    readonly property real along: vert ? col.height : row.width
    implicitWidth: vert ? col.width : row.width
    implicitHeight: vert ? col.height : row.height

    Row {
        id: row
        visible: !bf.vert
        spacing: bf.spacing
        Repeater {
            model: bf.vert ? [] : bf.model
            delegate: bf.delegate
        }
    }
    Column {
        id: col
        visible: bf.vert
        spacing: bf.spacing
        Repeater {
            model: bf.vert ? bf.model : []
            delegate: bf.delegate
        }
    }
}
