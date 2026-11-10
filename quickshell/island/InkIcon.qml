import QtQuick

// A symbol (icon-font glyph) centred by what is DRAWN, not by the box the font gives it. Many icon glyphs sit a little to one side of
// their box, so an icon that is "centred" with Text.AlignHCenter still looks off-centre in a capsule. Used by the status icons of a rail.
//   glyph  the symbol      color  its colour      fontFamily / px  its font      width  the room across (height follows the symbol)
Item {
    id: ic
    property string glyph: ""
    property color color: "white"
    property string fontFamily: ""
    property int px: 14
    implicitWidth: px
    implicitHeight: px + 2

    TextMetrics {
        id: tm
        text: ic.glyph
        font.family: ic.fontFamily
        font.pixelSize: ic.px
    }
    Text {
        text: ic.glyph
        color: ic.color
        font.family: ic.fontFamily
        font.pixelSize: ic.px
        // ink box (tightBoundingRect) centred across; the line box centred along
        x: Math.round((ic.width - tm.tightBoundingRect.width) / 2 - tm.tightBoundingRect.x)
        y: Math.round((ic.height - height) / 2)
    }
}
