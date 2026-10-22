import QtQuick
import QtMultimedia

// A live wallpaper from your own files (Settings > Wallpaper > Live wallpaper; Super + Alt + W switches it on and off).
// Videos (.mp4 .webm .mkv .mov) play muted in a loop, filling the screen; a .gif plays as an animated picture.
// The files live in ~/Pictures/Wallpapers/live (or ~/Pictures/Live); scripts/live-wallpapers.sh lists them and makes the thumbnails.
// `running` false (a game, a fullscreen window, windows over the whole desktop, the lock screen, Focus with quiet visuals) pauses it on the
// frame it is on: no decoding, nothing drawn again. It plays on from there.
Item {
    id: root
    property string path: ""
    property bool running: true
    readonly property bool isGif: /\.gif$/i.test(path)
    readonly property url url: path === "" ? "" : "file://" + encodeURI(path).replace(/#/g, "%23").replace(/\?/g, "%3F")
    signal failed(string why)

    Loader {
        anchors.fill: parent
        active: root.path !== "" && !root.isGif
        sourceComponent: Item {
            MediaPlayer {
                id: mp
                source: root.url
                loops: MediaPlayer.Infinite
                videoOutput: vo                          // no audioOutput: always silent
                onErrorOccurred: (err, msg) => root.failed(msg)
                Component.onCompleted: if (root.running) play()
            }
            VideoOutput {
                id: vo
                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectCrop
            }
            Connections {
                target: root
                function onRunningChanged() { if (root.running) mp.play(); else mp.pause() }
            }
        }
    }

    AnimatedImage {
        anchors.fill: parent
        visible: root.isGif
        source: root.isGif ? root.url : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        playing: root.isGif && root.running
        onStatusChanged: if (status === Image.Error) root.failed("could not read " + root.path)
    }
}
