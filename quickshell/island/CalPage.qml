import QtQuick

// The calendar as a page of the bar (a click on the clock, Settings > Calendar > Clock click). It is the bar's own container grown
// downward: in the island style the pill, in the notch style the notch, so it looks like the media / performance pages. The data
// and the actions come from the Calendar scope (Calendar.qml); the big window (Super + R) is the same calendar, full size.
Item {
    id: pg
    property var pal
    property var cal
    property bool notchStyle: false
    signal openFull()

    readonly property var months: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    readonly property var days: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    readonly property int topPad: notchStyle ? 22 : 18

    // ---------------- left: the month
    Item {
        id: left
        x: 20; y: pg.topPad; width: 7 * 34; height: parent.height - pg.topPad - 16

        Text {
            id: title
            text: pg.months[pg.cal.viewM] + " " + pg.cal.viewY
            color: pg.pal.text; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tBody + 3; font.weight: Font.DemiBold
        }
        Row {
            anchors { right: parent.right; verticalCenter: title.verticalCenter }
            spacing: 5
            Rectangle {
                width: 26; height: 24; radius: 12
                color: prevM.containsMouse ? Qt.alpha(pg.pal.surfaceHi, 0.95) : Qt.alpha(pg.pal.surface, 0.8)
                border.width: pg.pal.calm ? 0 : 1; border.color: pg.pal.line
                Text { anchors.centerIn: parent; text: "‹"; color: pg.pal.text; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tCap + 4 }
                MouseArea {
                    id: prevM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: pg.cal.moveMonth(-1)
                }
            }
            Rectangle {
                width: 26; height: 24; radius: 12
                color: nextM.containsMouse ? Qt.alpha(pg.pal.surfaceHi, 0.95) : Qt.alpha(pg.pal.surface, 0.8)
                border.width: pg.pal.calm ? 0 : 1; border.color: pg.pal.line
                Text { anchors.centerIn: parent; text: "›"; color: pg.pal.text; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tCap + 4 }
                MouseArea {
                    id: nextM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: pg.cal.moveMonth(1)
                }
            }
            Rectangle {
                width: 48; height: 24; radius: 12
                color: todayM.containsMouse ? Qt.alpha(pg.pal.accent, 0.25) : Qt.alpha(pg.pal.surface, 0.8)
                border.width: 1; border.color: todayM.containsMouse ? pg.pal.accent : pg.pal.line
                Text { anchors.centerIn: parent; text: "Today"; color: todayM.containsMouse ? pg.pal.accent : pg.pal.text; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tCap; font.weight: Font.Medium }
                MouseArea {
                    id: todayM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: pg.cal.gotoDay(new Date())
                }
            }
        }
        Row {
            id: head
            y: 34
            Repeater {
                model: pg.days
                delegate: Text {
                    required property string modelData
                    width: 34; horizontalAlignment: Text.AlignHCenter
                    text: modelData; color: pg.pal.muted; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tCap
                }
            }
        }
        Grid {
            id: grid
            anchors.top: head.bottom; anchors.topMargin: 4
            columns: 7; spacing: 0
            readonly property int offset: (new Date(pg.cal.viewY, pg.cal.viewM, 1).getDay() + 6) % 7
            Repeater {
                model: 42
                delegate: Item {
                    id: cell
                    required property int index
                    readonly property date d: new Date(pg.cal.viewY, pg.cal.viewM, 1 - grid.offset + index)
                    readonly property bool inMonth: d.getMonth() === pg.cal.viewM
                    readonly property bool isSel: pg.cal.keyOf(d) === pg.cal.keyOf(pg.cal.sel)
                    readonly property bool isToday: pg.cal.keyOf(d) === pg.cal.keyOf(pg.cal.today)
                    readonly property var evs: pg.cal.dayMap[pg.cal.keyOf(d)] || []
                    width: 34; height: 38
                    Rectangle {
                        anchors.centerIn: parent; width: 30; height: 32; radius: 10
                        color: cell.isSel ? Qt.alpha(pg.pal.accent, 0.22) : (cm.containsMouse ? Qt.alpha(pg.pal.surfaceHi, 0.7) : "transparent")
                        border.width: cell.isSel ? 1.5 : (cell.isToday ? 1 : 0)
                        border.color: cell.isSel ? pg.pal.accent : Qt.alpha(pg.pal.accent, 0.6)
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter; y: 6
                        text: cell.d.getDate()
                        color: cell.isToday ? pg.pal.accent : pg.pal.text
                        opacity: cell.inMonth ? 1 : 0.35
                        font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tBody - 1
                        font.weight: cell.isToday || cell.isSel ? Font.DemiBold : Font.Normal
                    }
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter; y: 25; spacing: 2
                        Repeater {
                            model: Math.min(3, cell.evs.length)
                            delegate: Rectangle { width: 3; height: 3; radius: 1.5; color: pg.pal.accent; opacity: cell.inMonth ? 0.9 : 0.35 }
                        }
                    }
                    MouseArea {
                        id: cm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { pg.cal.sel = pg.cal.midnight(cell.d); if (!cell.inMonth) { pg.cal.viewY = cell.d.getFullYear(); pg.cal.viewM = cell.d.getMonth() } }
                    }
                }
            }
        }
    }

    Rectangle { x: left.x + left.width + 16; y: pg.topPad + 4; width: 1; height: parent.height - pg.topPad - 24; color: Qt.alpha(pg.pal.text, 0.10) }

    // ---------------- right: the selected day
    Item {
        id: right
        x: left.x + left.width + 34; y: pg.topPad
        width: parent.width - x - 20; height: parent.height - pg.topPad - 16
        visible: pg.cal.cfg.configured

        Text {
            id: dayTitle
            text: Qt.formatDate(pg.cal.sel, "dddd d MMMM")
            color: pg.pal.text; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tBody + 3; font.weight: Font.DemiBold
        }
        Text {
            id: dayCount
            anchors { top: dayTitle.bottom; topMargin: 2 }
            text: pg.cal.selEvents.length === 0 ? "Free day" : pg.cal.selEvents.length + (pg.cal.selEvents.length === 1 ? " event" : " events")
            color: pg.pal.muted; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tCap
        }
        Flickable {
            id: fl
            anchors { top: dayCount.bottom; topMargin: 10; left: parent.left; right: parent.right; bottom: foot.top; bottomMargin: 8 }
            clip: true; contentHeight: col.implicitHeight; boundsBehavior: Flickable.StopAtBounds
            Column {
                id: col
                width: fl.width; spacing: 6
                Repeater {
                    model: pg.cal.selEvents
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        readonly property bool live: modelData.start * 1000 <= pg.cal.now && modelData.end * 1000 > pg.cal.now
                        readonly property bool past: modelData.end * 1000 < pg.cal.now
                        width: col.width; height: Math.max(46, tx.implicitHeight + 20); radius: pg.pal.rMd
                        color: live ? Qt.alpha(pg.pal.accent, 0.14) : Qt.alpha(pg.pal.surface, 0.75)
                        border.width: 1; border.color: live ? Qt.alpha(pg.pal.accent, 0.6) : pg.pal.line
                        opacity: past ? 0.55 : 1
                        Column {
                            id: tx
                            x: 12; y: 10; width: parent.width - 24 - marks.width - 8; spacing: 2
                            Text {
                                width: parent.width; elide: Text.ElideRight
                                text: modelData.title; font.strikeout: pg.cal.isDone(modelData)
                                color: pg.pal.text; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tBody; font.weight: Font.DemiBold
                            }
                            Text {
                                width: parent.width; elide: Text.ElideRight
                                text: modelData.allDay ? "All day" : pg.cal.clock(modelData.start) + " – " + pg.cal.clock(modelData.end)
                                color: row.live ? pg.pal.accent : pg.pal.muted; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tCap
                            }
                        }
                        CalMarks {
                            id: marks
                            pal: pg.pal; cal: pg.cal; ev: modelData
                            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                        }
                    }
                }
                Text {
                    visible: pg.cal.selEvents.length === 0
                    text: "Nothing planned"; color: pg.pal.muted
                    font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tBody; topPadding: 20
                }
            }
        }
        Item {
            id: foot
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 28
            Text {
                anchors { left: parent.left; verticalCenter: parent.verticalCenter; right: bdayQuickBtn.left; rightMargin: 8 }
                elide: Text.ElideRight
                text: pg.cal.nextTask ? "Next task: " + pg.cal.nextTask.title + " · " + pg.cal.clock(pg.cal.nextTask.start) : ""
                color: pg.pal.muted; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tCap
            }
            Rectangle {
                id: bdayQuickBtn
                anchors { right: full.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                width: bqTxt.implicitWidth + 18; height: 26; radius: 13
                color: bqMa.containsMouse ? Qt.alpha(pg.pal.accent, 0.22) : Qt.alpha(pg.pal.surface, 0.8)
                border.width: 1; border.color: bqMa.containsMouse ? pg.pal.accent : pg.pal.line
                Text { id: bqTxt; anchors.centerIn: parent; text: "Birthdays"; color: pg.pal.text; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tCap }
                MouseArea {
                    id: bqMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        pg.openFull()
                        if (pg.cal) { pg.cal.bdayModalOpen = true; if (pg.cal.loadBdayList) pg.cal.loadBdayList() }
                    }
                }
            }
            Rectangle {
                id: full
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                width: fl2.implicitWidth + 22; height: 26; radius: 13
                color: fm.containsMouse ? Qt.alpha(pg.pal.surfaceHi, 0.95) : Qt.alpha(pg.pal.surface, 0.8)
                border.width: pg.pal.calm ? 0 : 1; border.color: pg.pal.line
                Text { id: fl2; anchors.centerIn: parent; text: "Open full calendar"; color: pg.pal.text; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tCap }
                MouseArea { id: fm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pg.openFull() }
            }
        }
    }

    // not connected yet
    Column {
        visible: !pg.cal.cfg.configured
        x: left.x + left.width + 34; y: pg.topPad + 40
        width: parent.width - x - 20; spacing: 12
        Text {
            width: parent.width; wrapMode: Text.WordWrap
            text: "No calendar connected yet."
            color: pg.pal.text; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tBody + 2; font.weight: Font.DemiBold
        }
        Text {
            width: parent.width; wrapMode: Text.WordWrap
            text: "Connect Google Calendar to see your events here."
            color: pg.pal.muted; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tBody
        }
        Rectangle {
            width: cl.implicitWidth + 28; height: 32; radius: 16
            color: Qt.alpha(pg.pal.accent, cmx.containsMouse ? 0.32 : 0.22); border.width: 1; border.color: pg.pal.accent
            Text { id: cl; anchors.centerIn: parent; text: "Connect"; color: pg.pal.accent; font.family: pg.pal.uiFont; font.pixelSize: pg.pal.tBody }
            MouseArea { id: cmx; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pg.openFull() }
        }
    }
}
