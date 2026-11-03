import QtQuick
import QtQuick.Layouts

// Settings custom leaf "aiCovers" (Settings > AI > Master switch): every AI feature in one list, so it is clear what the
// master switch stops. A dot is lit while the switch is on. `root` is the Settings scope.
ColumnLayout {
    property var root                  // the Settings scope (it hands itself in)
    id: ac
    width: parent ? parent.width : 0
    spacing: 6

    readonly property bool on: !(root && root.ai && root.ai.enabled === false)
    readonly property var pal: root ? root.pal : null
    readonly property var rows: [
        { n: "Notes", d: "overview, task sorting, long-note summaries, picture descriptions" },
        { n: "Chat", d: "the `ai` chat and the AI chatbox with every provider (Luna, Ollama and the hosted ones)" },
        { n: "Launcher", d: ">ask and >do, the clipboard and lyrics helpers" },
        { n: "Luna and the Study Center", d: "their answers and chats" },
        { n: "Advisor and error explainer", d: "the AI / LLM advisor and the explanations of failed services" },
        { n: "Antivirus alert review", d: "the analyzer is stopped; the antivirus itself keeps protecting" },
        { n: "Security and Firewall centers", d: "their Ask boxes; the firewall keeps protecting" }
    ]

    Repeater {
        model: ac.rows
        delegate: RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Rectangle {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 4
                width: 8; height: 8; radius: 4
                color: ac.on ? (ac.pal ? ac.pal.accent : "#88aaff") : (ac.pal ? ac.pal.muted : "#777777")
                opacity: ac.on ? 1 : 0.5
            }
            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: modelData.n + "  \u2014  " + modelData.d
                color: ac.pal ? (ac.on ? ac.pal.text : ac.pal.muted) : "#ffffff"
                font.family: ac.pal ? ac.pal.uiFont : "sans-serif"
                font.pixelSize: ac.pal ? ac.pal.tBody : 13
            }
        }
    }
    Text {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: ac.on ? "All of these are on." : "AI features are off: none of the above asks any model anything."
        color: ac.pal ? ac.pal.muted : "#888888"
        font.family: ac.pal ? ac.pal.uiFont : "sans-serif"
        font.pixelSize: ac.pal ? ac.pal.tBody : 13
    }
}
