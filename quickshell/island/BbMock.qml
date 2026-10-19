import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import "BarLayout.js" as BL

// Part of the bar builder window (BarBuilderWindow.qml). `bb` is that window.
Item {
    required property var bb
    id: mw
    property string wid: ""
    height: bb.barH
    width: ld.item ? ld.item.implicitWidth : 0
    Loader { id: ld; height: bb.barH; sourceComponent: bb.mockFor(mw.wid) }
}
