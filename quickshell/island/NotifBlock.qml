import QtQuick

// One part of the notification box (NotifBox.qml): the constellation band, the title and buttons, or the list. It sits at the y the
// box works out from the order, slides there when the order changes and fades when it is switched off.
Loader {
    id: blk
    property var host                      // the NotifBox
    property string bid: ""                // sky | header | list

    width: host.width
    y: host.yOf(bid)
    height: item ? item.implicitHeight : 0
    opacity: host.shown(bid) ? 1 : 0
    visible: opacity > 0.01
    Behavior on y { enabled: blk.host.ready; NumberAnimation { duration: blk.host.pal.dSlow; easing.type: Easing.BezierSpline; easing.bezierCurve: blk.host.pal.curve } }
    Behavior on opacity { NumberAnimation { duration: blk.host.pal.dMed; easing.type: Easing.InOutSine } }
}
