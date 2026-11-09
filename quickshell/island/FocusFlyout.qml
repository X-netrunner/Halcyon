import QtQuick
import QtQuick.Layouts

// The Focus card that opens to the side of the utilities box. Panel.qml places it (toward the middle of the screen) and shows it while
// the Focus tile is lit. It is only the frame: the controls are FocusBody.qml.
//
// With the border around the screen on (and the box joined to it) the card is a second piece of the same shape: flush with the box,
// painted in the border's colour, with the same concave flares where it meets the box and the border, and it slides out from under the
// box the way the box slides out from under the border. Without the border it is a floating pane next to the box that fades in.
Item {
    id: root
    property var pal
    property bool shown: false
    property bool toLeft: true             // the card sits left of the box (its right side touches the box)
    property bool atBottom: true         // it lines up with the box's bottom edge (else its top edge)
    property string joinV: ""            // the box's own join with the top / bottom border ("" = it floats)
    readonly property bool attached: !!pal && pal.frameOn === true && joinV !== ""
    readonly property bool hovered: hov.hovered
    readonly property real cardW: 300
    readonly property real pad: 20       // room around the card for the flares (they reach 16 px outside it); clipped away while it slides
    readonly property int inset: 12

    property var focusInfo: ({ on: false })
    property int focusSecs: 0
    property string focusText: "00:00"
    property int focusMins: 25
    property bool focusPomo: false
    property int focusBlocked: 0
    signal focusStart(int mins, bool pomo)
    signal focusCommand(string what)
    signal focusPick(int mins, bool pomo)
    signal openFocusSettings()

    width: cardW + pad
    height: card.height + 2 * pad
    clip: attached && prog < 0.999       // only while it slides: the clip is what hides the part still under the box
    visible: prog > 0.002

    // 0 = tucked under the box, 1 = out
    property real prog: shown ? 1 : 0
    Behavior on prog { NumberAnimation { duration: root.shown ? root.pal.dSlow : root.pal.dClose; easing.type: Easing.BezierSpline; easing.bezierCurve: root.shown ? root.pal.curve : root.pal.curveClose } }

    Glass {
        id: card
        pal: root.pal
        x: root.toLeft ? root.pad : 0
        y: root.pad
        width: root.cardW
        height: body.implicitHeight + 2 * root.inset
        radius: root.pal.rXl
        opacityBody: root.pal.glassSolid - 0.06
        joinH: root.attached ? (root.toLeft ? "r" : "l") : ""
        joinV: root.attached ? root.joinV : ""
        opacity: root.attached ? 1 : root.prog
        transform: Translate {
            x: (root.toLeft ? 1 : -1) * (1 - root.prog) * (root.attached ? root.cardW + 4 : 16)
        }

        MouseArea { anchors.fill: parent }       // swallow clicks
        HoverHandler { id: hov }

        FocusBody {
            id: body
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.margins: root.inset
            pal: root.pal
            focusInfo: root.focusInfo; focusSecs: root.focusSecs; focusText: root.focusText
            focusMins: root.focusMins; focusPomo: root.focusPomo; focusBlocked: root.focusBlocked
            onFocusStart: (m, p) => root.focusStart(m, p)
            onFocusCommand: w => root.focusCommand(w)
            onFocusPick: (m, p) => root.focusPick(m, p)
            onOpenFocusSettings: root.openFocusSettings()
        }
    }
}
