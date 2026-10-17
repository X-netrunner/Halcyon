import QtQuick

// "Text & greeting": a greeting with your name that follows the time of day, or any words you like.   greeting | plain | quote
WBase {
    id: root

    property date now: new Date()
    // the greeting only depends on the hour: `now` changes when the hour does, and the moment the widget is back on screen
    Timer {
        running: root.live; repeat: true; interval: 300000; triggeredOnStart: true
        onTriggered: { var n = new Date(); if (n.getHours() !== root.now.getHours() || n.getDate() !== root.now.getDate()) root.now = n }
    }
    readonly property string who: env && env.starName ? String(env.starName) : ""
    readonly property string hello: {
        var h = now.getHours()
        return (h < 5 ? "Good night" : (h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")))
    }
    readonly property string words: String(opt("text", ""))
    readonly property string by: String(opt("by", "")).trim()

    TextMetrics { id: tm; font.family: root.face; font.pixelSize: root.sz(root.style === "quote" ? 20 : 18); text: root.words }
    readonly property real maxW: sz(360)

    implicitWidth: body.item ? body.item.implicitWidth : 100
    implicitHeight: body.item ? body.item.implicitHeight : 30
    Loader { id: body; sourceComponent: root.style === "plain" ? plainC : (root.style === "quote" ? quoteC : (root.style === "epigraph" ? epiC : (root.style === "caption" ? capC : greetC))) }

    // a few quiet lines with a thin rule above and below, said by someone (or not)
    Component {
        id: epiC
        Column {
            spacing: root.sz(10)
            width: Math.min(tm.width, root.maxW)
            Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: root.sz(30); height: 1; color: Qt.alpha(root.accent, 0.75) }
            WLbl { b: root; width: parent.width; horizontalAlignment: Text.AlignHCenter; text: root.words; font.pixelSize: root.sz(20); font.italic: true; font.weight: Font.Light; font.letterSpacing: 0.5; lineHeight: 1.2; wrapMode: Text.WordWrap }
            WLbl { b: root; visible: root.by !== ""; width: parent.width; horizontalAlignment: Text.AlignHCenter; text: root.by.toUpperCase(); color: root.dim; font.pixelSize: root.sz(10); font.letterSpacing: 3 }
            Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: root.sz(30); height: 1; color: Qt.alpha(root.accent, 0.75) }
        }
    }
    // small spaced capitals with one lit point in front, like a game's subtitle
    Component {
        id: capC
        Row {
            spacing: root.sz(12)
            Rectangle { width: root.sz(5); height: width; radius: width / 2; color: root.accent; anchors.verticalCenter: parent.verticalCenter }
            WLbl { b: root; width: Math.min(tm.width, root.maxW); text: root.words.toUpperCase(); color: root.fg; font.pixelSize: root.sz(13); font.letterSpacing: 5; wrapMode: Text.WordWrap; anchors.verticalCenter: parent.verticalCenter }
        }
    }

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
