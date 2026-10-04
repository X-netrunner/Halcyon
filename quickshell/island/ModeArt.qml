import QtQuick
import QtQuick.Shapes

// Faded background art for the two flagship sysmodes, drawn in the wallpaper accent colour:
//   lockdown  a shield (soft fill, rim light on the edges)
//   stealth   a coiled dragon silhouette (original artwork)
// Everything is a vector Shape, so it stays crisp at any size and costs nothing while the box is hidden.
// Sits behind content; `strength` scales the whole thing (the tree wants it quieter than the small boxes).
Item {
    id: root
    property var pal
    property string mode: ""
    property real strength: 1.0
    property real fit: 0.9            // how much of the box the art may fill
    property real tilt: 0             // degrees

    readonly property bool shield: mode === "lockdown"
    readonly property bool dragon: mode === "stealth"
    visible: (shield || dragon) && strength > 0
    opacity: strength
    clip: false

    readonly property color tone: pal.accent
    readonly property color fillSoft: Qt.alpha(tone, 0.055)
    readonly property color edge: Qt.alpha(tone, 0.42)
    readonly property color glow: "transparent"
    readonly property color glowEdge: Qt.alpha(tone, 0.07)

    // design boxes: shield 200 x 250, dragon 320 x 240
    readonly property real dw: shield ? 200 : 320
    readonly property real dh: shield ? 250 : 240

    Item {
        id: stage
        width: root.dw
        height: root.dh
        anchors.centerIn: parent
        rotation: root.tilt
        scale: Math.min(root.width / root.dw, root.height / root.dh) * root.fit

        // slow breathing so it feels lit, not printed
        SequentialAnimation on opacity {
            running: root.visible
            loops: Animation.Infinite
            NumberAnimation { to: 0.78; duration: 4200; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.0; duration: 4200; easing.type: Easing.InOutSine }
        }

        // ---------------------------------------------------------------- shield
        Shape {
            visible: root.shield
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            // wide faint pass first = the rim glow
            ShapePath {
                fillColor: "transparent"
                strokeColor: Qt.alpha(root.tone, 0.08)
                strokeWidth: 9
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M100,10 C128,30 164,34 188,28 L188,128 C188,184 148,222 100,242 C52,222 12,184 12,128 L12,28 C36,34 72,30 100,10 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.4
                joinStyle: ShapePath.RoundJoin
                fillGradient: LinearGradient {
                    x1: 0; y1: 0; x2: 0; y2: 250
                    GradientStop { position: 0.0; color: Qt.alpha(root.tone, 0.13) }
                    GradientStop { position: 1.0; color: Qt.alpha(root.tone, 0.02) }
                }
                PathSvg { path: "M100,10 C128,30 164,34 188,28 L188,128 C188,184 148,222 100,242 C52,222 12,184 12,128 L12,28 C36,34 72,30 100,10 Z" }
            }
            // inner rim
            ShapePath {
                fillColor: "transparent"
                strokeColor: Qt.alpha(root.tone, 0.24)
                strokeWidth: 1.0
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M100,30 C124,47 154,51 174,46 L174,128 C174,174 140,206 100,224 C60,206 26,174 26,128 L26,46 C46,51 76,47 100,30 Z" }
            }
            // centre rib + cross bar, very quiet
            ShapePath {
                fillColor: "transparent"
                strokeColor: Qt.alpha(root.tone, 0.16)
                strokeWidth: 1.0
                PathSvg { path: "M100,34 L100,222 M30,92 C70,100 130,100 170,92" }
            }
        }

        // ---------------------------------------------------------------- dragon
        Shape {
            visible: root.dragon
            x: 0
            y: 26
            width: parent.width
            height: parent.height
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M13.6,176.9 L17.1,180.6 L21.2,183.1 L25.3,185.1 L29.5,186.5 L33.8,187.5 L38.0,188.0 L42.2,188.2 L46.3,187.9 L50.4,187.3 L54.4,186.4 L58.3,185.1 L62.1,183.6 L65.8,181.9 L69.4,180.0 L72.9,177.9 L76.3,175.7 L79.6,173.3 L82.9,170.9 L86.0,168.5 L89.1,166.0 L92.2,163.5 L95.2,161.0 L98.1,158.5 L101.0,156.1 L103.8,153.8 L106.6,151.6 L109.3,149.5 L112.0,147.6 L114.7,145.8 L117.3,144.2 L119.8,142.8 L122.2,141.6 L124.6,140.7 L126.9,139.9 L129.1,139.4 L131.3,139.0 L133.5,138.9 L135.7,139.0 L138.6,139.4 L142.8,139.9 L147.2,140.1 L151.5,139.9 L155.6,139.2 L159.6,138.2 L163.3,136.8 L166.7,135.0 L169.9,132.9 L172.7,130.5 L175.2,127.9 L177.5,125.2 L179.5,122.4 L181.3,119.5 L182.9,116.6 L184.3,113.6 L185.6,110.7 L186.8,107.7 L187.9,104.7 L188.9,101.7 L189.9,98.8 L190.9,95.9 L191.8,93.1 L192.8,90.3 L193.8,87.6 L194.7,85.1 L195.8,82.6 L196.8,80.3 L197.9,78.1 L199.0,76.1 L200.2,74.2 L201.4,72.5 L202.7,71.0 L204.1,69.6 L205.6,68.4 L207.2,67.3 L208.9,66.3 L210.9,65.5 L213.2,64.8 L216.2,64.3 L218.6,63.8 L221.0,63.2 L223.3,62.5 L225.6,61.9 L227.8,61.2 L229.9,60.4 L232.0,59.6 L234.0,58.8 L235.9,58.0 L237.8,57.1 L239.6,56.3 L241.3,55.4 L243.0,54.5 L244.6,53.7 L246.2,52.8 L247.7,52.0 L249.1,51.1 L250.4,50.3 L251.7,49.5 L253.0,48.7 L254.2,48.0 L255.3,47.3 L256.3,46.6 L257.4,46.0 L258.3,45.4 L259.2,44.9 L260.0,44.4 L260.8,44.0 L261.5,43.6 L262.2,43.3 L262.8,42.9 L263.0,46.0 L263.2,46.1 L263.3,46.1 L263.3,46.1 L263.4,46.1 L263.4,46.2 L263.5,46.3 L263.9,46.8 L272.1,41.2 L271.5,40.3 L270.6,39.2 L269.5,38.2 L268.3,37.4 L267.0,36.8 L265.7,36.4 L264.3,36.1 L263.0,39.1 L261.9,38.8 L260.8,38.6 L259.7,38.6 L258.5,38.6 L257.3,38.6 L256.1,38.8 L254.8,39.0 L253.5,39.2 L252.1,39.5 L250.8,39.8 L249.3,40.2 L247.9,40.6 L246.4,41.0 L244.9,41.4 L243.3,41.9 L241.8,42.3 L240.1,42.8 L238.5,43.2 L236.8,43.7 L235.1,44.2 L233.3,44.6 L231.5,45.0 L229.7,45.5 L227.8,45.9 L225.9,46.2 L224.0,46.6 L222.1,46.9 L220.1,47.2 L218.0,47.4 L216.0,47.6 L213.8,47.7 L210.2,48.1 L206.2,48.8 L202.5,49.9 L199.0,51.4 L195.7,53.1 L192.6,55.2 L189.8,57.4 L187.3,59.9 L185.0,62.5 L182.8,65.2 L180.9,68.0 L179.2,70.9 L177.6,73.8 L176.1,76.8 L174.7,79.8 L173.4,82.7 L172.2,85.6 L171.0,88.5 L169.9,91.4 L168.8,94.1 L167.7,96.8 L166.6,99.3 L165.5,101.8 L164.3,104.0 L163.2,106.1 L162.1,108.0 L160.9,109.7 L159.8,111.2 L158.6,112.5 L157.5,113.6 L156.3,114.5 L155.2,115.2 L153.9,115.8 L152.6,116.3 L151.0,116.7 L149.2,117.0 L147.1,117.1 L144.7,117.0 L141.4,116.6 L137.5,116.1 L133.0,116.0 L128.6,116.4 L124.4,117.1 L120.3,118.2 L116.4,119.7 L112.6,121.3 L109.0,123.3 L105.6,125.4 L102.3,127.6 L99.1,130.0 L96.0,132.5 L92.9,135.1 L90.0,137.7 L87.1,140.4 L84.3,143.1 L81.5,145.8 L78.7,148.5 L76.0,151.2 L73.3,153.8 L70.6,156.4 L68.0,158.8 L65.3,161.2 L62.6,163.4 L60.0,165.5 L57.3,167.4 L54.7,169.2 L52.0,170.8 L49.3,172.3 L46.5,173.5 L43.7,174.6 L40.7,175.4 L37.7,176.0 L34.5,176.4 L31.1,176.6 L27.5,176.5 L23.6,176.0 L19.4,175.4 L14.4,175.1 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M273.9,29.5 L284.0,36.7 L290.5,46.3 L297.1,66.3 L301.6,80.8 L298.4,86.4 L292.4,80.0 L292.0,87.3 L281.9,80.1 L268.6,68.1 L259.2,56.9 L252.3,44.1 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M281.2,35.1 L283.8,5.3 L273.3,-5.1 L275.1,18.2 L275.6,31.9 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M287.3,41.5 L300.8,14.8 L296.7,3.6 L285.6,28.6 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M37.7,176.0 L40.5,170.0 L46.5,173.5 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M52.0,170.8 L52.0,163.4 L60.0,165.5 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M65.3,161.2 L63.2,153.4 L73.3,153.8 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M78.7,148.5 L75.5,140.4 L87.1,140.4 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M92.9,135.1 L89.6,126.4 L102.3,127.6 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M109.0,123.3 L107.1,113.5 L120.3,118.2 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M172.2,85.6 L163.0,79.0 L176.1,76.8 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M179.2,70.9 L171.0,63.2 L185.0,62.5 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M189.8,57.4 L184.6,47.6 L199.0,51.4 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M206.2,48.8 L206.3,38.1 L216.0,47.6 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M220.1,47.2 L221.0,36.8 L225.9,46.2 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M229.7,45.5 L229.7,35.6 L235.1,44.2 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M238.5,43.2 L238.0,33.9 L243.3,41.9 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M246.4,41.0 L245.9,32.3 L250.8,39.8 Z" }
            }
            ShapePath {
                fillColor: root.glow
                strokeColor: root.glowEdge
                strokeWidth: 4.5
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M253.5,39.2 L253.6,31.1 L257.3,38.6 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M13.6,176.9 L17.1,180.6 L21.2,183.1 L25.3,185.1 L29.5,186.5 L33.8,187.5 L38.0,188.0 L42.2,188.2 L46.3,187.9 L50.4,187.3 L54.4,186.4 L58.3,185.1 L62.1,183.6 L65.8,181.9 L69.4,180.0 L72.9,177.9 L76.3,175.7 L79.6,173.3 L82.9,170.9 L86.0,168.5 L89.1,166.0 L92.2,163.5 L95.2,161.0 L98.1,158.5 L101.0,156.1 L103.8,153.8 L106.6,151.6 L109.3,149.5 L112.0,147.6 L114.7,145.8 L117.3,144.2 L119.8,142.8 L122.2,141.6 L124.6,140.7 L126.9,139.9 L129.1,139.4 L131.3,139.0 L133.5,138.9 L135.7,139.0 L138.6,139.4 L142.8,139.9 L147.2,140.1 L151.5,139.9 L155.6,139.2 L159.6,138.2 L163.3,136.8 L166.7,135.0 L169.9,132.9 L172.7,130.5 L175.2,127.9 L177.5,125.2 L179.5,122.4 L181.3,119.5 L182.9,116.6 L184.3,113.6 L185.6,110.7 L186.8,107.7 L187.9,104.7 L188.9,101.7 L189.9,98.8 L190.9,95.9 L191.8,93.1 L192.8,90.3 L193.8,87.6 L194.7,85.1 L195.8,82.6 L196.8,80.3 L197.9,78.1 L199.0,76.1 L200.2,74.2 L201.4,72.5 L202.7,71.0 L204.1,69.6 L205.6,68.4 L207.2,67.3 L208.9,66.3 L210.9,65.5 L213.2,64.8 L216.2,64.3 L218.6,63.8 L221.0,63.2 L223.3,62.5 L225.6,61.9 L227.8,61.2 L229.9,60.4 L232.0,59.6 L234.0,58.8 L235.9,58.0 L237.8,57.1 L239.6,56.3 L241.3,55.4 L243.0,54.5 L244.6,53.7 L246.2,52.8 L247.7,52.0 L249.1,51.1 L250.4,50.3 L251.7,49.5 L253.0,48.7 L254.2,48.0 L255.3,47.3 L256.3,46.6 L257.4,46.0 L258.3,45.4 L259.2,44.9 L260.0,44.4 L260.8,44.0 L261.5,43.6 L262.2,43.3 L262.8,42.9 L263.0,46.0 L263.2,46.1 L263.3,46.1 L263.3,46.1 L263.4,46.1 L263.4,46.2 L263.5,46.3 L263.9,46.8 L272.1,41.2 L271.5,40.3 L270.6,39.2 L269.5,38.2 L268.3,37.4 L267.0,36.8 L265.7,36.4 L264.3,36.1 L263.0,39.1 L261.9,38.8 L260.8,38.6 L259.7,38.6 L258.5,38.6 L257.3,38.6 L256.1,38.8 L254.8,39.0 L253.5,39.2 L252.1,39.5 L250.8,39.8 L249.3,40.2 L247.9,40.6 L246.4,41.0 L244.9,41.4 L243.3,41.9 L241.8,42.3 L240.1,42.8 L238.5,43.2 L236.8,43.7 L235.1,44.2 L233.3,44.6 L231.5,45.0 L229.7,45.5 L227.8,45.9 L225.9,46.2 L224.0,46.6 L222.1,46.9 L220.1,47.2 L218.0,47.4 L216.0,47.6 L213.8,47.7 L210.2,48.1 L206.2,48.8 L202.5,49.9 L199.0,51.4 L195.7,53.1 L192.6,55.2 L189.8,57.4 L187.3,59.9 L185.0,62.5 L182.8,65.2 L180.9,68.0 L179.2,70.9 L177.6,73.8 L176.1,76.8 L174.7,79.8 L173.4,82.7 L172.2,85.6 L171.0,88.5 L169.9,91.4 L168.8,94.1 L167.7,96.8 L166.6,99.3 L165.5,101.8 L164.3,104.0 L163.2,106.1 L162.1,108.0 L160.9,109.7 L159.8,111.2 L158.6,112.5 L157.5,113.6 L156.3,114.5 L155.2,115.2 L153.9,115.8 L152.6,116.3 L151.0,116.7 L149.2,117.0 L147.1,117.1 L144.7,117.0 L141.4,116.6 L137.5,116.1 L133.0,116.0 L128.6,116.4 L124.4,117.1 L120.3,118.2 L116.4,119.7 L112.6,121.3 L109.0,123.3 L105.6,125.4 L102.3,127.6 L99.1,130.0 L96.0,132.5 L92.9,135.1 L90.0,137.7 L87.1,140.4 L84.3,143.1 L81.5,145.8 L78.7,148.5 L76.0,151.2 L73.3,153.8 L70.6,156.4 L68.0,158.8 L65.3,161.2 L62.6,163.4 L60.0,165.5 L57.3,167.4 L54.7,169.2 L52.0,170.8 L49.3,172.3 L46.5,173.5 L43.7,174.6 L40.7,175.4 L37.7,176.0 L34.5,176.4 L31.1,176.6 L27.5,176.5 L23.6,176.0 L19.4,175.4 L14.4,175.1 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M273.9,29.5 L284.0,36.7 L290.5,46.3 L297.1,66.3 L301.6,80.8 L298.4,86.4 L292.4,80.0 L292.0,87.3 L281.9,80.1 L268.6,68.1 L259.2,56.9 L252.3,44.1 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M281.2,35.1 L283.8,5.3 L273.3,-5.1 L275.1,18.2 L275.6,31.9 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M287.3,41.5 L300.8,14.8 L296.7,3.6 L285.6,28.6 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M37.7,176.0 L40.5,170.0 L46.5,173.5 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M52.0,170.8 L52.0,163.4 L60.0,165.5 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M65.3,161.2 L63.2,153.4 L73.3,153.8 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M78.7,148.5 L75.5,140.4 L87.1,140.4 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M92.9,135.1 L89.6,126.4 L102.3,127.6 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M109.0,123.3 L107.1,113.5 L120.3,118.2 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M172.2,85.6 L163.0,79.0 L176.1,76.8 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M179.2,70.9 L171.0,63.2 L185.0,62.5 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M189.8,57.4 L184.6,47.6 L199.0,51.4 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M206.2,48.8 L206.3,38.1 L216.0,47.6 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M220.1,47.2 L221.0,36.8 L225.9,46.2 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M229.7,45.5 L229.7,35.6 L235.1,44.2 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M238.5,43.2 L238.0,33.9 L243.3,41.9 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M246.4,41.0 L245.9,32.3 L250.8,39.8 Z" }
            }
            ShapePath {
                fillColor: root.fillSoft
                strokeColor: root.edge
                strokeWidth: 1.1
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M253.5,39.2 L253.6,31.1 L257.3,38.6 Z" }
            }
            ShapePath {
                fillColor: "transparent"
                strokeColor: root.edge
                strokeWidth: 1.0
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M290.0,81.7 L289.7,99.4 L301.0,105.7 L297.4,118.6" }
            }
            ShapePath {
                fillColor: "transparent"
                strokeColor: root.edge
                strokeWidth: 1.0
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M287.6,83.3 L287.3,101.0 L298.6,107.3 L295.0,120.2" }
            }
            // eye
            ShapePath {
                fillColor: Qt.alpha(root.tone, 0.8)
                strokeColor: "transparent"
                PathSvg { path: "M281.0,58.4 a2,2 0 1,0 4,0 a2,2 0 1,0 -4,0 Z" }
            }
        }
    }
}
