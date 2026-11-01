import QtQuick
import QtQuick.Layouts

// The notification box's header, used by the notification centre (NotifBox.qml) and the bar's drop-down (NotifCentre.qml):
//
//     (switch)        Notifications        (clear)
//                    3 notifications
//
// Both buttons are icon-only and the same size, so the title sits exactly in the middle (it stays there when Clear is hidden: the
// space is kept). The left button is Do not disturb or Airplane mode, as chosen in Settings > Panels & notifications > Header switch.
RowLayout {
    id: hd
    property var pal
    property int count: 0
    property bool dnd: false
    property bool airplane: false
    property string quick: "dnd"            // dnd | airplane
    signal quickClicked()
    signal clearClicked()
    readonly property bool plane: quick === "airplane"
    readonly property bool quickOn: plane ? airplane : dnd

    spacing: 8

    Chip {
        Layout.preferredWidth: 32
        Layout.preferredHeight: 32
        pal: hd.pal
        padX: 0
        glyph: String.fromCodePoint(hd.plane ? 0xF001D : 0xF009B)
        on: hd.quickOn
        tipAlign: "left"
        tip: hd.plane ? (hd.airplane ? "Airplane mode on  ·  click to bring Wi-Fi and Bluetooth back" : "Airplane mode  ·  switches Wi-Fi and Bluetooth off")
                      : (hd.dnd ? "Do not disturb is on  ·  click to turn it off" : "Do not disturb  ·  stops the popups")
        onClicked: hd.quickClicked()
    }
    BoxTitle {
        pal: hd.pal
        title: "Notifications"
        sub: hd.count === 0 ? "You are all caught up"
            : hd.count + (hd.count === 1 ? " notification" : " notifications") + (hd.dnd ? "  ·  muted" : "") + (hd.plane && hd.airplane ? "  ·  airplane mode" : "")
    }
    Chip {
        Layout.preferredWidth: 32
        Layout.preferredHeight: 32
        pal: hd.pal
        padX: 0
        glyph: String.fromCodePoint(0xF01B4)
        enabled: hd.count > 0
        opacity: hd.count > 0 ? 1 : 0           // hidden but its room is kept: the title stays in the middle
        tipAlign: "right"
        tip: "Clear all"
        onClicked: hd.clearClicked()
    }
}
