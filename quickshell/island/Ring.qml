import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property var pal
    property real value: 0
    property string label: ""
    property string text: ""
    property real shown: value

    Behavior on shown { enabled: root.visible; NumberAnimation { duration: 700; easing.type: Easing.BezierSpline; easing.bezierCurve: root.pal.curve } }

    implicitWidth: 80
    implicitHeight: 80

    Shape {
        anchors.fill: parent
        layer.enabled: true
        layer.samples: 4

        ShapePath {
            strokeColor: root.pal.surface
            strokeWidth: 5
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc { centerX: 40; centerY: 40; radiusX: 34; radiusY: 34; startAngle: -90; sweepAngle: 359.9 }
        }
        ShapePath {
            strokeColor: root.pal.accent
            strokeWidth: 5
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: 40; centerY: 40; radiusX: 34; radiusY: 34
                startAngle: -90
                sweepAngle: 359.9 * Math.min(1, Math.max(0.004, root.shown))
            }
        }
    }
    Column {
        anchors.centerIn: parent
        spacing: 0
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.text
            color: root.pal.text
            font.family: root.pal.uiFont
            font.pixelSize: root.pal.tTitle
            font.weight: Font.DemiBold
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.label
            color: root.pal.muted
            font.family: root.pal.uiFont
            font.pixelSize: 10
            font.letterSpacing: 0.8
        }
    }
}
