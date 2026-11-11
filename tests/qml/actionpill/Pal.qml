import QtQuick
QtObject {
    property int hitMin: 32
    property int focusRing: 2
    property int dFast: 120
    property int dMed: 180
    property int dClose: 160
    property var curveOut: [0.2, 0, 0, 1, 1, 1]
    property var curveIn: [0.4, 0, 1, 1, 1, 1]
    property color bg: "#14161f"
    property color surface: "#1e2130"
    property color text: "#dcdde8"
    property color accent: "#9aa9d4"
    property color primaryText: "#14161f"
    property color fillHover: "#33ffffff"
    property color line: "#22ffffff"
    property color lineFocus: "#889aa9d4"
    property string font: "Sans"
    property string uiFont: "Sans"
    property int tBody: 13
}
