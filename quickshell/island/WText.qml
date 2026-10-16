import QtQuick

// "Text & greeting": a greeting with your name that follows the time of day, or any words you like.   greeting | plain | quote
WBase {
    id: root

    property date now: new Date()
    Timer { running: root.live; repeat: true; interval: 300000; onTriggered: root.now = new Date() }
    readonly property string who: env && env.starName ? String(env.starName) : ""
    readonly property string hello: {
        var h = now.getHours()
        return (h < 5 ? "Good night" : (h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")))
    }
    readonly property string words: String(opt("text", ""))

    TextMetrics { id: tm; font.family: root.face; font.pixelSize: root.sz(root.style === "quote" ? 20 : 18); text: root.words }
    readonly property real maxW: sz(360)

    implicitWidth: body.item ? body.item.implicitWidth : 100
    implicitHeight: body.item ? body.item.implicitHeight : 30
    Loader { id: body; sourceComponent: root.style === "plain" ? plainC : (root.style === "quote" ? quoteC : greetC) }

    Component {
        id: greetC
        Column {
            spacing: 0
            WLbl { b: root; text: root.hello + (root.who !== "" ? "," : ""); color: root.dim; font.pixelSize: root.sz(18) }
            WLbl { b: root; visible: root.who !== ""; text: root.who; font.pixelSize: root.sz(40); font.weight: Font.DemiBold }
            WLbl { b: root; visible: root.words !== ""; width: Math.min(tm.width, root.maxW); text: root.words; color: root.accent; font.pixelSize: root.sz(14); wrapMode: Text.WordWrap }
        }
    }
    Component {
        id: plainC
        WLbl { b: root; width: Math.min(tm.width, root.maxW); text: root.words; font.pixelSize: root.sz(18); wrapMode: Text.WordWrap }
    }
    Component {
        id: quoteC
        Row {
            spacing: root.sz(12)
            Rectangle { width: 3; height: q.height; radius: 1.5; color: root.accent }
            WLbl { id: q; b: root; width: Math.min(tm.width, root.maxW); text: root.words; font.pixelSize: root.sz(20); font.italic: true; wrapMode: Text.WordWrap }
        }
    }
}
