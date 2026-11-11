import QtQuick
import QtTest
import "."

Rectangle {
    width: 760
    height: 160
    color: pal.bg
    Pal { id: pal }
    Item {
        id: win
        anchors.fill: parent
        property var fired: []
        ActionPill {
            id: ap
            x: 680
            y: 60
            pal: pal
            actions: [
                { id: "update", label: "Update", tip: "Install the newest", primary: true },
                { id: "rollback", label: "Roll back", tip: "Go back", disabled: true },
                { id: "pin", label: "Pin", tip: "Keep this version" },
                { id: "commits", label: "Commits", tip: "What changed" }
            ]
            onTriggered: id => win.fired.push(id)
        }
        Rectangle { id: elsewhere; x: 20; y: 20; width: 40; height: 40; color: pal.surface }
        TestCase {
            name: "ActionPill"
            when: windowShown
            function test_1_keyboard() {
                ap.forceActiveFocus()
                compare(ap.open, false)
                keyClick(Qt.Key_Return)
                compare(ap.open, true, "Enter opens")
                compare(ap.cursor, 0, "cursor starts on the first enabled action")
                keyClick(Qt.Key_Left)
                compare(ap.cursor, 2, "disabled Roll back is skipped")
                keyClick(Qt.Key_Escape)
                compare(ap.open, false, "Esc closes")
            }
            function test_2_select_closes() {
                ap.forceActiveFocus()
                keyClick(Qt.Key_Space)
                keyClick(Qt.Key_Left)
                keyClick(Qt.Key_Return)
                compare(ap.open, false, "a selection closes the pill")
                compare(win.fired[win.fired.length - 1], "pin")
                ap.pick(1)
                compare(win.fired[win.fired.length - 1], "pin", "a disabled action never fires")
            }
            function test_3_outside_click() {
                ap.expand()
                compare(ap.open, true)
                wait(300)
                mousePress(elsewhere, 10, 10)
                mouseRelease(elsewhere, 10, 10)
                compare(ap.open, false, "a click elsewhere closes the pill")
            }
        }
    }
}
