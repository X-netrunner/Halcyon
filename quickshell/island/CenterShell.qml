import QtQuick
import QtQuick.Layouts

// "Shell B": the one layout every centre window (Study, Luna, Security, Version) wears. Vertical options on the left, browser-style tabs on top.
//
//   +----------+-----------------------------------------+---+
//   | [*] Name | [file] Tab one  x | [file] Tab two  x | + |  X |   top bar (64 px, a little darker than the content)
//   +----------+-----------------------------------------+---+
//   | OPTIONS  |                                                |
//   | [] Ask   |   the content: whatever the centre puts in     |
//   | [] Quiz  |   here (its own pages, shown by its own `tab`) |
//   |  ...     |                                                |
//   | status   |                                                |
//   +----------+------------------------------------------------+
//
// This file only draws and reports clicks. It owns no centre logic: the centre keeps its `tab` / `view`, its chats, its scripts, and answers
// the signals below. Nothing here runs at rest (no timers, no processes); the only animation is the Halcyon button's.
//   name            the centre's name, in the corner cell next to the Halcyon star
//   tabs            the open items as browser tabs: [{ id, title, glyph (a code point), confirm (bool: asking "delete?") }]; empty = just `tabsHint`
//   activeTab       the id of the tab in front            renamingId   the tab whose title is an edit field right now
//   addVisible      show the "+" after the tabs (false for a centre with no open items)
//   options         the vertical rows: [{ key, label, glyph }]            activeOption   the key of the lit row
//   status          the line at the bottom of the left column (the old header's note / scope); statusTone (muted | accent | warn | bad) colours it
//   footnote        a second, quieter line under it ("on this computer ...")
//   hasModel        the Halcyon pill gets the model chip (centres with a model choice)       modelLabel   "Auto" / the picked model
//   modelsOpen      the centre's own model sheet is open (lights the chip)                    popped   the centre's `popped` (lights Pop out)
//   menuOpen        the Halcyon pill is out. The centre closes it on Esc (see closeMenu()), a click anywhere else closes it here
//   popItem         false for a centre that can not pop out (it still hides the icon when pal.deskWin)
// Signals: tabClicked(id) tabClosed(id) tabConfirmed(id) tabRenameRequested(id) tabRenamed(id, title) renameCancelled() addClicked()
//          optionClicked(key) modelClicked() popClicked() extraClicked() closeRequested()
// Content goes inside: `CenterShell { ...; Item { anchors.fill: parent } }` (it lands in the content area, below the top bar, right of the left column).
Item {
    id: cs
    property var pal
    property string name: ""
    property var tabs: []
    property string activeTab: ""
    property string renamingId: ""
    property string tabsHint: ""
    property bool addVisible: true
    property string optionsLabel: "Options"
    property var options: []
    property string activeOption: ""
    property string status: ""
    property string statusTone: "muted"                       // muted | accent | warn | bad
    property string footnote: ""
    property bool hasModel: false
    property string modelLabel: "Auto"
    property bool modelsOpen: false
    property bool popped: false
    property bool popItem: true
    property bool busy: false
    property alias menuOpen: hal.menuOpen
    property real radius: 0                                  // the panel's own corner radius: the dark top bar and left column follow it
    property real bodyOpacity: 0.97                          // the panel's glass body, so the front tab is exactly the content's colour
    readonly property real cornerW: 208
    readonly property real topH: 64
    readonly property real tabH: 46
    readonly property color chrome: Qt.alpha(Qt.darker(pal.bg, pal.light ? 1.06 : 1.32), Math.min(1, bodyOpacity + 0.02))
    readonly property color contentColor: Qt.alpha(pal.bg, bodyOpacity)
    readonly property bool pillNeeded: hasModel || (popItem && !pal.deskWin)
    default property alias content: contentArea.data

    signal tabClicked(string id)
    signal tabClosed(string id)
    signal tabConfirmed(string id)
    signal tabRenameRequested(string id)
    signal tabRenamed(string id, string title)
    signal renameCancelled()
    signal addClicked()
    signal optionClicked(string key)
    signal modelClicked()
    signal popClicked()
    signal closeRequested()

    // Esc: the centre calls this first; true = it closed the Halcyon pill (so Esc does nothing else this time)
    function closeMenu() { if (menuOpen) { menuOpen = false; return true } return false }

    // ---- the dark chrome: top bar and left column. Two pieces that meet at the corner cell, so the translucent colour is painted once.
    // The outer corners are round like the panel: one shape, taller than the strip and clipped.
    Item {
        x: 0; y: 0; width: cs.width; height: cs.topH
        clip: true
        Rectangle { width: parent.width; height: parent.height + cs.radius + 2; radius: cs.radius; color: cs.chrome }
    }
    Item {
        x: 0; y: cs.topH; width: cs.cornerW; height: cs.height - cs.topH
        clip: true
        Rectangle { y: -(cs.radius + 2); width: parent.width + cs.radius + 2; height: parent.height + cs.radius + 2; radius: cs.radius; color: cs.chrome }
    }
    // a hairline between the left column and the content
    Rectangle { x: cs.cornerW - 1; y: cs.topH; width: 1; height: cs.height - cs.topH - Math.max(0, cs.radius * 0.5); color: cs.pal.lineSoft }

    // ---- the content
    Item {
        id: contentArea
        x: cs.cornerW; y: cs.topH
        width: cs.width - cs.cornerW
        height: cs.height - cs.topH
        clip: true
    }

    // ---- the left column: label, options, status
    Item {
        x: 0; y: cs.topH; width: cs.cornerW; height: cs.height - cs.topH
        Column {
            id: optCol
            x: 14; y: 16
            width: parent.width - 28
            spacing: 4
            Text {
                visible: cs.optionsLabel !== ""
                bottomPadding: 4
                leftPadding: 6
                text: cs.optionsLabel
                color: cs.pal.muted
                font.family: cs.pal.uiFont
                font.pixelSize: cs.pal.tCap
                font.weight: Font.Medium
                font.letterSpacing: cs.pal.calm ? 0.2 : 0.9
                font.capitalization: cs.pal.calm ? Font.MixedCase : Font.AllUppercase
            }
            Repeater {
                model: cs.options
                delegate: Rectangle {
                    id: orow
                    required property var modelData
                    readonly property bool on: modelData.key === cs.activeOption
                    width: optCol.width
                    height: 46
                    radius: cs.pal.rMd
                    color: on ? Qt.alpha(cs.pal.accent, 0.12) : (oMa.containsMouse ? cs.pal.fill : "transparent")
                    border.width: on && !cs.pal.calm ? 1 : 0
                    border.color: Qt.alpha(cs.pal.accent, 0.7)
                    Behavior on color { ColorAnimation { duration: cs.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: cs.pal.curveCalm } }
                    Row {
                        anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                        spacing: 14
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: String.fromCodePoint(orow.modelData.glyph)
                            color: orow.on ? cs.pal.accent : cs.pal.muted
                            font.family: cs.pal.font
                            font.pixelSize: 18
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: orow.modelData.label
                            color: orow.on ? cs.pal.text : cs.pal.muted
                            font.family: cs.pal.uiFont
                            font.pixelSize: cs.pal.tBody + 1
                            font.weight: orow.on ? Font.Medium : Font.Medium
                        }
                    }
                    MouseArea { id: oMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: cs.optionClicked(orow.modelData.key) }
                }
            }
        }
        // the status: what the old header said (a note, or what the open item is about), always visible and never elided away
        Column {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 20; rightMargin: 20; bottomMargin: 20 }
            spacing: 4
            Text {
                width: parent.width
                visible: cs.status !== ""
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                text: cs.status
                color: cs.statusTone === "bad" ? cs.pal.bad : (cs.statusTone === "warn" ? cs.pal.warn : (cs.statusTone === "accent" ? cs.pal.accent : cs.pal.muted))
                font.family: cs.pal.uiFont
                font.pixelSize: cs.pal.tCap + 1
                lineHeight: 1.2
            }
            Text {
                width: parent.width
                visible: cs.footnote !== ""
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                text: cs.footnote
                color: Qt.alpha(cs.pal.muted, 0.8)
                font.family: cs.pal.uiFont
                font.pixelSize: cs.pal.tCap
                lineHeight: 1.2
            }
        }
    }

    // ---- the tab strip (browser-style): the open items, then "+"
    Item {
        id: strip
        x: cs.cornerW; y: 0
        width: cs.width - cs.cornerW - 60
        height: cs.topH
        readonly property real plusW: cs.addVisible ? 44 : 0
        readonly property real avail: width - plusW - 8
        readonly property real tabW: Math.max(120, Math.min(220, avail / Math.max(1, cs.tabs.length)))

        Text {
            visible: cs.tabs.length === 0
            // after the + button (it sits where the first tab would be), not under it
            anchors { left: parent.left; leftMargin: (cs.addVisible ? parent.plusW : 0) + 12; verticalCenter: parent.verticalCenter }
            text: cs.tabsHint
            color: cs.pal.muted
            font.family: cs.pal.uiFont
            font.pixelSize: cs.pal.tBody + 1
            font.weight: Font.Medium
        }

        ListView {
            id: tabList
            anchors { left: parent.left; leftMargin: 6; bottom: parent.bottom }
            height: cs.tabH
            width: Math.min(contentWidth, strip.avail)
            orientation: ListView.Horizontal
            spacing: 2
            clip: true
            interactive: contentWidth > width
            boundsBehavior: Flickable.StopAtBounds
            model: cs.tabs
            onCountChanged: positionViewAtIndex(Math.max(0, currentIndexOf(cs.activeTab)), ListView.Contain)
            Connections { target: cs; function onActiveTabChanged() { tabList.positionViewAtIndex(Math.max(0, tabList.currentIndexOf(cs.activeTab)), ListView.Contain) } }
            function currentIndexOf(id) { for (var i = 0; i < cs.tabs.length; i++) if (cs.tabs[i].id === id) return i; return -1 }
            delegate: Item {
                id: td
                required property var modelData
                readonly property bool on: modelData.id === cs.activeTab
                readonly property bool ren: modelData.id === cs.renamingId
                readonly property bool ask: modelData.confirm === true
                width: strip.tabW
                height: cs.tabH
                onRenChanged: if (ren) { renIn.text = modelData.title; renIn.forceActiveFocus(); renIn.selectAll() }

                // the tab's body: rounded top corners only (the bottom edge is the content's)
                Item {
                    anchors.fill: parent
                    clip: true
                    Rectangle {
                        width: parent.width
                        height: parent.height + 14
                        radius: 14
                        color: td.on ? cs.contentColor : (tMa.containsMouse ? Qt.alpha(cs.pal.text, 0.05) : "transparent")
                        Behavior on color { ColorAnimation { duration: cs.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: cs.pal.curveCalm } }
                    }
                }
                MouseArea {
                    id: tMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (!td.ren) cs.tabClicked(td.modelData.id)
                    onDoubleClicked: if (!td.ren) cs.tabRenameRequested(td.modelData.id)
                }
                Text {
                    id: tIcon
                    x: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: String.fromCodePoint(td.modelData.glyph || 0xF0214)
                    color: td.on ? cs.pal.accent : cs.pal.muted
                    font.family: cs.pal.font
                    font.pixelSize: 18
                }
                Text {
                    visible: !td.ren
                    anchors { left: tIcon.right; leftMargin: 10; right: tAct.left; rightMargin: 4; verticalCenter: parent.verticalCenter }
                    elide: Text.ElideRight
                    text: td.ask ? "Delete this chat?" : td.modelData.title
                    color: td.ask ? cs.pal.warn : (td.on ? cs.pal.text : cs.pal.muted)
                    font.family: cs.pal.uiFont
                    font.pixelSize: cs.pal.tBody
                    font.weight: td.on ? Font.Medium : Font.Medium
                }
                TextInput {
                    id: renIn
                    visible: td.ren
                    anchors { left: tIcon.right; leftMargin: 10; right: tAct.left; rightMargin: 4; verticalCenter: parent.verticalCenter }
                    clip: true
                    color: cs.pal.text
                    selectionColor: Qt.alpha(cs.pal.accent, 0.4)
                    font.family: cs.pal.uiFont
                    font.pixelSize: cs.pal.tBody
                    maximumLength: 80
                    onAccepted: cs.tabRenamed(td.modelData.id, text)
                    Keys.onEscapePressed: cs.renameCancelled()
                }
                // the close x of this tab (36 px target); while it asks "delete?" the check confirms and the x cancels
                Row {
                    id: tAct
                    anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                    spacing: 0
                    visible: !td.ren && (td.on || tMa.containsMouse || xMa.containsMouse || okMa.containsMouse || td.ask)
                    Rectangle {
                        width: 36; height: 36; radius: 18
                        visible: td.ask
                        color: okMa.containsMouse ? Qt.alpha(cs.pal.bad, 0.22) : "transparent"
                        Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF012C); color: cs.pal.bad; font.family: cs.pal.font; font.pixelSize: 16 }
                        MouseArea { id: okMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: cs.tabConfirmed(td.modelData.id) }
                    }
                    Rectangle {
                        width: 36; height: 36; radius: 18
                        color: xMa.containsMouse ? Qt.alpha(cs.pal.text, 0.1) : "transparent"
                        Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF0156); color: xMa.containsMouse ? cs.pal.text : cs.pal.muted; font.family: cs.pal.font; font.pixelSize: 15 }
                        MouseArea { id: xMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: cs.tabClosed(td.modelData.id) }
                    }
                }
            }
        }

        // "+": open another item
        Rectangle {
            visible: cs.addVisible
            anchors { left: tabList.right; leftMargin: 6; verticalCenter: parent.verticalCenter; verticalCenterOffset: 6 }
            width: 38; height: 38; radius: 19
            color: plusMa.containsMouse ? cs.pal.fillHover : "transparent"
            Behavior on color { ColorAnimation { duration: cs.pal.dFast; easing.type: Easing.BezierSpline; easing.bezierCurve: cs.pal.curveCalm } }
            Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF0415); color: plusMa.containsMouse ? cs.pal.text : cs.pal.muted; font.family: cs.pal.font; font.pixelSize: 20 }
            MouseArea { id: plusMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: cs.addClicked() }
        }
    }

    // ---- the window's close button, far right
    RoundBtn {
        anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.top; verticalCenterOffset: cs.topH / 2 }
        pal: cs.pal
        size: 36
        glyph: String.fromCodePoint(0xF0156)
        onClicked: cs.closeRequested()
    }

    // ---- click anywhere else closes the Halcyon pill (the corner cell sits above this and keeps working)
    MouseArea {
        anchors.fill: parent
        z: 20
        enabled: cs.menuOpen
        visible: cs.menuOpen
        onPressed: m => { cs.menuOpen = false; m.accepted = true }
    }

    // ---- the Halcyon button + its pill (replaces the old model pill and Pop out button)
    HalcyonButton {
        id: hal
        z: 30
        x: 14
        y: (cs.topH - 44) / 2
        width: cs.cornerW - 14 - 12
        pal: cs.pal
        name: cs.name
        busy: cs.busy
        canOpen: cs.pillNeeded
        maxPill: cs.cornerW - 14 - 44 - 8 - 12

        HalPillBtn {
            visible: cs.hasModel
            pal: cs.pal
            glyph: 0xF06A9
            label: cs.modelLabel
            active: cs.modelsOpen
            onClicked: { cs.menuOpen = false; cs.modelClicked() }
        }
        HalPillBtn {
            visible: cs.popItem && !cs.pal.deskWin
            pal: cs.pal
            glyph: cs.popped ? 0xF0141 : 0xF03CC
            active: cs.popped
            onClicked: { cs.menuOpen = false; cs.popClicked() }
        }
    }
}
