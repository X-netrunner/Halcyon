import QtQuick

// The Calendar tab of the rail dashboard: the tab the box opens on, in the spotlight (Dashboard.qml).
//   left    today: the weekday, a big date, the month and the time, and the next task when a calendar is connected
//   middle  the month: arrows, "Today", the days (a dot per event, the accent disc is today, a ring is the chosen day)
//   right   the chosen day's events (the same ones CalPage.qml lists), "Open full calendar" at the foot; with no calendar connected
//           yet, a short note and a Connect button that opens the full calendar's connect page
// Everything comes from the Calendar scope (Calendar.qml, shell.qml's `calendar`): nothing is read or invented here.
Item {
    id: root
    property var pal
    property var cal: null
    property bool active: false              // the tab is on screen
    signal openFull()

    implicitWidth: 704
    implicitHeight: 276

    readonly property bool ok: cal !== null && cal !== undefined
    readonly property bool linked: ok && cal.cfg && cal.cfg.configured === true
    readonly property date nowD: new Date(ok ? cal.now : Date.now())
    readonly property var months: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    readonly property var days: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    readonly property int cellW: 41
    readonly property int cellH: 31

    // ------------------------------------------------------------ left: today
    DashCard {
        id: todayCard
        pal: root.pal
        x: 0; y: 0
        width: 128; height: root.height

        Column {
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
            spacing: 0
            Text {
                width: parent.width
                text: Qt.formatDate(root.nowD, "dddd")
                elide: Text.ElideRight
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody
            }
            Text {
                text: root.nowD.getDate()
                color: root.pal.accent
                font.family: root.pal.uiFont
                font.pixelSize: 56
                font.weight: Font.DemiBold
            }
            Text {
                width: parent.width
                text: root.months[root.nowD.getMonth()] + " " + root.nowD.getFullYear()
                elide: Text.ElideRight
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody
            }
            Item { width: 1; height: 10 }
            Rectangle {
                width: parent.width; height: 1
                color: root.pal.line
            }
            Item { width: 1; height: 10 }
            Text {
                text: Qt.formatTime(root.nowD, Qt.locale().timeFormat(Locale.ShortFormat))
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tTitle
                font.weight: Font.DemiBold
            }
        }

        // the next task, when there is one
        Column {
            visible: root.linked && root.cal.nextTask !== null && root.cal.nextTask !== undefined
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 14 }
            spacing: 2
            Text {
                text: "Next task"
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
            }
            Text {
                width: parent.width
                maximumLineCount: 2
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                text: root.linked && root.cal.nextTask ? root.cal.nextTask.title : ""
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody - 1
                font.weight: Font.DemiBold
            }
            Text {
                text: root.linked && root.cal.nextTask ? root.cal.clock(root.cal.nextTask.start) : ""
                color: root.pal.accent
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
            }
        }
    }

    // ------------------------------------------------------------ middle: the month
    DashCard {
        id: monthCard
        pal: root.pal
        x: todayCard.width + 12; y: 0
        width: 308; height: root.height

        Text {
            id: monthTitle
            x: 14; y: 12
            text: root.ok ? root.months[root.cal.viewM] + " " + root.cal.viewY : ""
            color: root.pal.text
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tBody + 3
            font.weight: Font.DemiBold
        }
        Row {
            anchors { right: parent.right; rightMargin: 12; verticalCenter: monthTitle.verticalCenter }
            spacing: 5
            Rectangle {
                width: 26; height: 24; radius: 12
                color: Qt.alpha(root.pal.text, prevMa.containsMouse ? 0.14 : 0.07)
                Text { anchors.centerIn: parent; text: "‹"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 4 }
                MouseArea { id: prevMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (root.ok) root.cal.moveMonth(-1) }
            }
            Rectangle {
                width: 26; height: 24; radius: 12
                color: Qt.alpha(root.pal.text, nextMa.containsMouse ? 0.14 : 0.07)
                Text { anchors.centerIn: parent; text: "›"; color: root.pal.text; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap + 4 }
                MouseArea { id: nextMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (root.ok) root.cal.moveMonth(1) }
            }
            Rectangle {
                width: 48; height: 24; radius: 12
                color: todayMa.containsMouse ? Qt.alpha(root.pal.accent, 0.25) : Qt.alpha(root.pal.accent, 0.13)
                Text { anchors.centerIn: parent; text: "Today"; color: root.pal.accent; font.family: root.pal.uiFont; font.pixelSize: root.pal.tCap; font.weight: Font.Medium }
                MouseArea { id: todayMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (root.ok) root.cal.gotoDay(new Date()) }
            }
        }
        Row {
            id: head
            x: 10; y: 46
            Repeater {
                model: root.days
                delegate: Text {
                    required property string modelData
                    width: root.cellW
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData
                    color: root.pal.muted
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap
                }
            }
        }
        Grid {
            id: grid
            x: 10
            anchors.top: head.bottom; anchors.topMargin: 6
            columns: 7; spacing: 0
            readonly property int offset: root.ok ? (new Date(root.cal.viewY, root.cal.viewM, 1).getDay() + 6) % 7 : 0
            Repeater {
                model: root.ok ? 42 : 0
                delegate: Item {
                    id: cell
                    required property int index
                    readonly property date d: new Date(root.cal.viewY, root.cal.viewM, 1 - grid.offset + index)
                    readonly property bool inMonth: d.getMonth() === root.cal.viewM
                    readonly property bool isSel: root.cal.keyOf(d) === root.cal.keyOf(root.cal.sel)
                    readonly property bool isToday: root.cal.keyOf(d) === root.cal.keyOf(root.cal.today)
                    readonly property var evs: root.cal.dayMap[root.cal.keyOf(d)] || []
                    width: root.cellW; height: root.cellH

                    // today: the accent disc; the chosen day: a ring; the pointer: a soft disc
                    Rectangle {
                        anchors.centerIn: parent
                        width: 27; height: 27; radius: 13.5
                        color: cell.isToday ? root.pal.accent : (cellMa.containsMouse ? Qt.alpha(root.pal.text, 0.10) : "transparent")
                        border.width: (cell.isSel && !cell.isToday) ? 1.5 : 0
                        border.color: root.pal.accent
                    }
                    Text {
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -1
                        text: cell.d.getDate()
                        color: cell.isToday ? root.pal.bg : root.pal.text
                        opacity: cell.inMonth ? 1 : 0.32
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tBody - 1
                        font.weight: (cell.isToday || cell.isSel) ? Font.DemiBold : Font.Normal
                    }
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: root.cellH - 5
                        spacing: 2
                        Repeater {
                            model: Math.min(3, cell.evs.length)
                            delegate: Rectangle {
                                width: 3; height: 3; radius: 1.5
                                color: cell.isToday ? root.pal.bg : root.pal.accent
                                opacity: cell.inMonth ? 0.9 : 0.35
                            }
                        }
                    }
                    MouseArea {
                        id: cellMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.cal.sel = root.cal.midnight(cell.d)
                            if (!cell.inMonth) { root.cal.viewY = cell.d.getFullYear(); root.cal.viewM = cell.d.getMonth() }
                        }
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ right: the chosen day
    DashCard {
        id: dayCard
        pal: root.pal
        x: monthCard.x + monthCard.width + 12; y: 0
        width: root.width - x; height: root.height

        // a calendar is connected: the day's events
        Item {
            anchors.fill: parent
            visible: root.linked

            Text {
                id: dayTitle
                x: 14; y: 12
                width: parent.width - 28
                elide: Text.ElideRight
                text: root.ok ? Qt.formatDate(root.cal.sel, "dddd d MMMM") : ""
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody + 1
                font.weight: Font.DemiBold
            }
            Text {
                id: dayCount
                x: 14
                anchors.top: dayTitle.bottom; anchors.topMargin: 2
                text: !root.linked ? "" : (root.cal.selEvents.length === 0 ? "Free day" : root.cal.selEvents.length + (root.cal.selEvents.length === 1 ? " event" : " events"))
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tCap
            }
            Flickable {
                id: fl
                anchors { top: dayCount.bottom; topMargin: 10; left: parent.left; leftMargin: 10; right: parent.right; rightMargin: 10; bottom: openBtn.top; bottomMargin: 8 }
                clip: true
                contentHeight: col.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                Column {
                    id: col
                    width: fl.width
                    spacing: 6
                    Repeater {
                        model: root.linked ? root.cal.selEvents : []
                        delegate: Rectangle {
                            id: row
                            required property var modelData
                            readonly property bool live: modelData.start * 1000 <= root.cal.now && modelData.end * 1000 > root.cal.now
                            readonly property bool past: modelData.end * 1000 < root.cal.now
                            width: col.width
                            height: Math.max(44, tx.implicitHeight + 18)
                            radius: root.pal.rMd
                            color: live ? Qt.alpha(root.pal.accent, 0.16) : Qt.alpha(root.pal.text, 0.06)
                            opacity: past ? 0.55 : 1
                            Rectangle {
                                x: 0; y: 8
                                width: 3; height: parent.height - 16; radius: 1.5
                                color: row.live ? root.pal.accent : Qt.alpha(root.pal.accent, 0.45)
                            }
                            Column {
                                id: tx
                                x: 14; y: 9
                                width: parent.width - 24 - marks.width - 6
                                spacing: 2
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: modelData.title
                                    font.strikeout: root.cal.isDone(modelData)
                                    color: root.pal.text
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tBody - 1
                                    font.weight: Font.DemiBold
                                }
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: modelData.allDay ? "All day" : root.cal.clock(modelData.start) + " – " + root.cal.clock(modelData.end)
                                    color: row.live ? root.pal.accent : root.pal.muted
                                    font.family: root.pal.uiFont
                                    font.pixelSize: root.pal.tCap
                                }
                            }
                            CalMarks {
                                id: marks
                                pal: root.pal; cal: root.cal; ev: modelData
                                anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                            }
                        }
                    }
                    Text {
                        visible: root.linked && root.cal.selEvents.length === 0
                        text: "Nothing planned"
                        color: root.pal.muted
                        font.family: root.pal.uiFont
                        font.pixelSize: root.pal.tBody
                        topPadding: 14
                    }
                }
            }
            Rectangle {
                id: openBtn
                anchors { left: parent.left; leftMargin: 10; right: parent.right; rightMargin: 10; bottom: parent.bottom; bottomMargin: 10 }
                height: 28; radius: 14
                color: Qt.alpha(root.pal.accent, openMa.containsMouse ? 0.26 : 0.14)
                Text {
                    anchors.centerIn: parent
                    text: "Open full calendar"
                    color: root.pal.accent
                    font.family: root.pal.uiFont
                    font.pixelSize: root.pal.tCap
                    font.weight: Font.Medium
                }
                MouseArea { id: openMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openFull() }
            }
        }

        // no calendar connected yet
        Column {
            visible: !root.linked
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 16 }
            spacing: 10
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "No calendar connected yet."
                color: root.pal.text
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody + 1
                font.weight: Font.DemiBold
            }
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Connect Google Calendar to see your events here."
                color: root.pal.muted
                font.family: root.pal.uiFont
                font.pixelSize: root.pal.tBody - 1
            }
            Rectangle {
                width: connectTxt.implicitWidth + 28; height: 30; radius: 15
                color: Qt.alpha(root.pal.accent, connectMa.containsMouse ? 0.30 : 0.18)
                Text { id: connectTxt; anchors.centerIn: parent; text: "Connect"; color: root.pal.accent; font.family: root.pal.uiFont; font.pixelSize: root.pal.tBody - 1; font.weight: Font.Medium }
                MouseArea { id: connectMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openFull() }
            }
        }
    }
}
