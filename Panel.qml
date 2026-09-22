import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// gdeyoung.tailfin panel — forked from Omarchy's first-party
// omarchy.tailscale Panel.qml (MIT). Layout rebuilt: the stock single-scroll
// column becomes four tabs; only Machines scrolls.
//   connection : hero + toggle, self info, health warnings, preferences
//   exitNodes  : tailnet nodes + suggest row + "none (direct)"
//   mullvad    : region picker (tab hidden when the tailnet has no Mullvad)
//   machines   : searchable peer list, offline collapsed
Panel {
  id: root
  moduleName: "gdeyoung.tailfin"
  ipcTarget: "gdeyoung.tailfin"
  manageIpc: false

  property string tab: "connection"
  property bool cursorActive: false
  property bool copyMenuOpen: false
  property string peerQuery: ""
  property bool offlineOpen: false
  property string ackPending: ""   // warning row armed for acknowledge
  property int peerIndex: 0
  property int exitNodeIndex: 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool hasMullvad: tailscale.mullvadRegions.length > 0
  readonly property var filteredPeers: Model.filterPeers(tailscale.peers, peerQuery)
  readonly property var filteredOnline: Model.filterOnline(filteredPeers, true)
  readonly property var filteredOffline: Model.filterOnline(filteredPeers, false)
  readonly property var tabList: {
    var tabs = ["connection", "exitNodes"]
    if (hasMullvad) tabs.push("mullvad")
    tabs.push("machines")
    return tabs
  }
  readonly property color barIconColor: tailscale.active ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property string toggleHint: tailscale.active ? "Turn Tailscale off" : (tailscale.needsLogin ? "Authorize this device" : "Turn Tailscale on")

  function heroPhrase() {
    var phrases = [
      "Encrypting connections",
      "Sending secrets",
      "Guarding wires",
      "Braiding packets",
      "Polishing tunnels",
      "Hiding routes",
      "Sealing ports",
      "Sorting tailnets",
      "Shuffling keys",
      "Watching machines"
    ]
    return phrases[root._phraseTick % phrases.length]
  }
  property int _phraseTick: 0

  // Mullvad tab state
  property string mullvadQuery: ""
  property int mullvadRegionIndex: 0
  readonly property var filteredMullvadRegions: {
    var q = mullvadQuery.trim().toLowerCase()
    var out = []
    var regions = tailscale.mullvadRegions
    for (var i = 0; i < regions.length; i++) {
      var label = (String(regions[i].City || "") + " " + String(regions[i].Country || "")).toLowerCase()
      if (q === "" || label.indexOf(q) !== -1) out.push(regions[i])
    }
    return out
  }

  function selectedMullvadRegion() {
    if (filteredMullvadRegions.length === 0) return null
    return filteredMullvadRegions[Math.max(0, Math.min(mullvadRegionIndex, filteredMullvadRegions.length - 1))]
  }

  function moveMullvadCursor(delta) {
    if (filteredMullvadRegions.length === 0) return
    mullvadRegionIndex = Math.max(0, Math.min(filteredMullvadRegions.length - 1, mullvadRegionIndex + delta))
  }

  function activateMullvadRegion() {
    var region = selectedMullvadRegion()
    if (region) tailscale.setExitNode(region)
  }

  function sendPeerFile(peer) {
    if (!tailscale.canSendFiles(peer)) return
    tailscale.sendFile(peer)
    close()
  }

  function tabTitle(key) {
    if (key === "connection") return "Connection"
    if (key === "exitNodes") return "Exit Nodes"
    if (key === "mullvad") return "Mullvad"
    return "Machines"
  }

  function switchTab(delta) {
    var index = tabList.indexOf(tab)
    if (index === -1) index = 0
    index = (index + delta + tabList.length) % tabList.length
    setTab(tabList[index])
  }

  function setTab(name) {
    tab = name
    cursorActive = false
    exitNodeIndex = 0
    if (name === "exitNodes") tailscale.refreshSuggest()
    Qt.callLater(function() { if (panelFlick) panelFlick.contentY = 0 })
  }

  function selectedPeer() {
    var total = filteredOnline.length + (offlineOpen ? filteredOffline.length : 0)
    if (total === 0) return null
    var i = Math.max(0, Math.min(peerIndex, total - 1))
    return i < filteredOnline.length ? filteredOnline[i] : filteredOffline[i - filteredOnline.length]
  }

  // Vertical cursor walk inside the active tab.
  function moveCursor(dx, dy) {
    cursorActive = true
    if (tab === "machines") {
      var total = filteredOnline.length + (offlineOpen ? filteredOffline.length : 0)
      if (total > 0) peerIndex = Math.max(0, Math.min(total - 1, peerIndex + dy))
    } else if (tab === "exitNodes") {
      var n = exitRowCount()
      if (n > 0) exitNodeIndex = Math.max(0, Math.min(n - 1, exitNodeIndex + dy))
    }
  }

  function exitRowCount() {
    return 1 + tailscale.tailnetExitNodes.length + (suggestVisible() ? 1 : 0)
  }

  function suggestVisible() {
    return tailscale.suggestedExitNode !== ""
  }

  function activateCursor() {
    if (tab === "machines") {
      // keyboard: copy the selected peer's IP (c is the shortcut anyway)
      var peer = selectedPeer()
      if (peer) tailscale.copyPeerIp(peer)
    } else if (tab === "exitNodes") {
      if (exitNodeIndex === 0) tailscale.setExitNodeHost("")
      else if (suggestVisible() && exitNodeIndex === 1) tailscale.setExitNodeHost(tailscale.suggestedExitNode)
      else {
        var offset = 1 + (suggestVisible() ? 1 : 0)
        var node = tailscale.tailnetExitNodes[exitNodeIndex - offset]
        if (node) tailscale.setExitNode(node)
      }
    }
  }

  Service {
    id: tailscale
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { tailscale.refresh(); return "ok" }
    function tab(name: string): string { root.setTab(name); return "ok" }
    function ack(warning: string): string { tailscale.ackHealth(warning); return "ok" }
    function unack(): string { tailscale.unackAll(); return "ok" }
    function status(): string {
      return JSON.stringify({
        tab: root.tab,
        opened: root.opened,
        installed: tailscale.installed,
        running: tailscale.running,
        backendState: tailscale.backendState,
        health: tailscale.health.length,
        acked: tailscale.ackedCount,
        onlineCount: tailscale.onlineCount,
        peers: tailscale.peers.length,
        prefsOk: tailscale.prefsOk,
        routeAll: tailscale.routeAll,
        corpDns: tailscale.corpDns,
        shieldsUp: tailscale.shieldsUp,
        allowLanAccess: tailscale.allowLanAccess,
        suggestedExitNode: tailscale.suggestedExitNode,
        exitNodes: tailscale.exitNodes.length,
        mullvad: tailscale.mullvadRegions.length,
        accounts: tailscale.accounts.length,
        operatorDenied: tailscale.accountsAccessDenied,
        peerQuery: root.peerQuery,
        filteredOnline: root.filteredOnline.length,
        filteredOffline: root.filteredOffline.length,
        offlineOpen: root.offlineOpen
      })
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    peerIndex = 0
    ackPending = ""
    if (panelFlick) panelFlick.contentY = 0
    tailscale.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Slow phrase rotation for the hero line (stock has an animation; a timer
  // keeps it simple and stateless in the fork).
  Timer {
    interval: 2800
    running: root.opened && tailscale.active
    repeat: true
    onTriggered: root._phraseTick += 1
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        TailscaleIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor
          badgeColor: root.urgent
          crossed: !tailscale.active && !tailscale.needsLogin
          warning: tailscale.needsLogin || (tailscale.running && tailscale.visibleHealth.length > 0)
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) tailscale.toggleTailscale()
      else if (buttonCode === Qt.MiddleButton) tailscale.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.copyMenuOpen
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.switchTab(dx)
        else if (dy !== 0 && !root.cursorActive) root.cursorActive = true
        else if (dy !== 0) root.moveCursor(0, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "t" || t === "T") tailscale.toggleTailscale()
        else if (t === "r" || t === "R") tailscale.refresh()
        else if (t === "c" || t === "C") tailscale.copyPeerIp(root.selectedPeer())
        else if (t === "n" || t === "N") tailscale.copyPeerName(root.selectedPeer())
        else if (t === "d" || t === "D") tailscale.copyPeerDnsName(root.selectedPeer())
        else if (t === "1") root.setTab("connection")
        else if (t === "2") root.setTab("exitNodes")
        else if (t === "3" && root.hasMullvad) root.setTab("mullvad")
        else if (t === "3" || t === "4") root.setTab("machines")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---- Tab bar (always visible) ------------------------------------
          Row {
            spacing: Style.space(6)

            Repeater {
              model: root.tabList
              TabButton {
                required property string modelData
                key: modelData
                label: root.tabTitle(modelData)
              }
            }
          }
          // ================= EXIT NODES TAB ==================================
          Column {
            id: exitCol
            visible: root.tab === "exitNodes"
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "ROUTE ALL TRAFFIC THROUGH"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // "None" row — direct connection, no exit node
            ExitNodeRow {
              width: parent.width
              glyph: "󰒃"
              name: "None (direct)"
              detail: "Use your own internet connection"
              activeNode: tailscale.currentExitNodeName() === ""
              settingNode: false
              rowKey: "none"
              onChosen: tailscale.setExitNodeHost("")
            }

            // Suggested row
            ExitNodeRow {
              visible: root.suggestVisible()
              width: parent.width
              glyph: "󰓅"
              name: "Suggested: " + (tailscale.suggestedExitNode !== "" ? tailscale.suggestedExitNode.split(".")[0] : "")
              detail: "Lowest latency per Tailscale"
              activeNode: tailscale.currentExitNodeName() !== "" && tailscale.suggestedExitNode !== "" && tailscale.currentExitNodeName().indexOf(tailscale.suggestedExitNode.split(".")[0]) === 0
              settingNode: false
              rowKey: "suggest"
              onChosen: tailscale.setExitNodeHost(tailscale.suggestedExitNode)
            }

            Column {
              id: exitNodeColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: tailscale.tailnetExitNodes
                ExitNodeRow {
                  required property var modelData
                  required property int index
                  width: exitNodeColumn.width
                  glyph: "󱇢"
                  name: modelData.HostName
                  detail: modelData.TailscaleIPs.length > 0 ? modelData.TailscaleIPs[0] : ""
                  activeNode: modelData.ExitNode === true
                  settingNode: tailscale.settingExitNodeId === String(modelData.id || "")
                  rowKey: "node-" + index
                  onChosen: tailscale.setExitNode(modelData)
                }
              }
            }

            Text {
              visible: tailscale.tailnetExitNodes.length === 0 && !root.suggestVisible()
              width: parent.width
              text: "No exit nodes advertised on this tailnet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }
          }
          Column {
            id: connCol
            visible: root.tab === "connection"
            width: parent.width
            spacing: Style.space(12)

            PanelHero {
              id: hero
              width: parent.width
              title: tailscale.installed ? (tailscale.selfName || "Tailscale") : "Tailscale"
              meta: tailscale.active ? root.heroPhrase() : "Tailscale is disconnected"
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: tailscale.active ? 1.0 : 0.5
              iconComponent: Component {
                TailscaleIcon {
                  iconSize: Style.font.display
                  color: tailscale.active ? root.foreground : root.dim
                  badgeColor: root.urgent
                  crossed: !tailscale.active && !tailscale.needsLogin
                  warning: tailscale.needsLogin || (tailscale.running && tailscale.visibleHealth.length > 0)
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  visible: tailscale.installed
                  checked: tailscale.active
                  busy: tailscale.busy
                  foreground: hero.foreground
                  onToggled: tailscale.toggleTailscale()
                  PanelToolTip {
                    visible: parent.containsMouse
                    text: root.toggleHint
                    fontFamily: root.fontFamily
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: tailscale.actionStatus !== "" || tailscale.lastError !== ""
              width: parent.width
              text: tailscale.actionStatus !== "" ? tailscale.actionStatus : tailscale.lastError
              color: tailscale.lastError !== "" && tailscale.actionStatus === "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            CursorSurface {
              visible: !tailscale.installed
              width: parent.width
              implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
              foreground: root.foreground

              Text {
                id: missingText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(12)
                text: "Tailscale CLI is not installed or not on PATH."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
            }

            // Authorize operator row (pkexec popup, Trayscale-style first-run)
            AuthRow {
              visible: tailscale.accountsAccessDenied
              width: parent.width
            }

            // Self identity + IPs
            Column {
              visible: tailscale.installed && tailscale.running
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "THIS DEVICE"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              InfoRow {
                width: parent.width
                glyph: tailscale.osIcon("linux")
                label: tailscale.selfName
                sub: tailscale.selfDnsName !== "" ? tailscale.selfDnsName : ""
                copyValue: tailscale.selfDnsName
              }

              InfoRow {
                width: parent.width
                glyph: "󰖂"
                label: tailscale.selfIp
                sub: tailscale.onlineCount + " of " + tailscale.peers.length + " machines online"
                copyValue: tailscale.selfIp
              }
            }

            // Health warnings
            Column {
              visible: tailscale.installed && tailscale.running && (tailscale.visibleHealth.length > 0 || tailscale.ackedCount > 0)
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "HEALTH"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: tailscale.visibleHealth
                Rectangle {
                  required property string modelData
                  width: parent.width
                  height: warnLabel.implicitHeight + Style.space(6)
                  radius: Style.space(3)
                  color: warnMouse.containsMouse || root.ackPending === modelData
                         ? root.selectedFill : "transparent"
                  Behavior on color { ColorAnimation { duration: 120 } }

                  Text {
                    id: warnLabel
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(6)
                    anchors.right: root.ackPending === modelData ? ackButton.left : ackGlyph.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "⚠ " + modelData
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }

                  // Idle: subtle dismiss glyph hints the row is clickable.
                  Text {
                    id: ackGlyph
                    visible: root.ackPending !== modelData
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰅂"
                    color: warnMouse.containsMouse ? root.foreground : root.dim
                    font.family: Style.font.iconFamily
                    font.pixelSize: Style.font.body
                    Behavior on color { ColorAnimation { duration: 120 } }
                  }

                  MouseArea {
                    id: warnMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // Click arms the inline Acknowledge button (second click disarms).
                    onClicked: root.ackPending = root.ackPending === modelData ? "" : modelData
                  }

                  // Armed: the actual acknowledge action, explicit and labeled.
                  Rectangle {
                    id: ackButton
                    visible: root.ackPending === modelData
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    width: ackButtonText.implicitWidth + Style.space(10)
                    height: ackButtonText.implicitHeight + Style.space(4)
                    radius: height / 2
                    color: root.urgent

                    Text {
                      id: ackButtonText
                      anchors.centerIn: parent
                      text: "Acknowledge"
                      color: Color.background
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        tailscale.ackHealth(modelData)
                        root.ackPending = ""
                      }
                    }
                  }
                }
              }

              // Acked-warnings footer: click restores all acknowledged rows.
              Item {
                width: parent.width
                height: ackedLabel.implicitHeight + Style.space(4)
                visible: tailscale.ackedCount > 0

                Text {
                  id: ackedLabel
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: tailscale.ackedCount === 1
                        ? tailscale.ackedCount + " warning acknowledged — re-arm"
                        : tailscale.ackedCount + " warnings acknowledged — re-arm"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: tailscale.unackAll()
                }
              }
            }

            // Preferences
            Column {
              visible: tailscale.installed && tailscale.running && tailscale.prefsOk
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "PREFERENCES"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Toggle {
                width: parent.width
                label: "Accept routed addresses"
                description: "--accept-routes: use subnet routes advertised by peers"
                checked: tailscale.routeAll
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: tailscale.setRouteAll(!tailscale.routeAll)
              }

              Toggle {
                width: parent.width
                label: "Accept DNS"
                description: "--accept-dns: use the tailnet DNS configuration"
                checked: tailscale.corpDns
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: tailscale.setCorpDns(!tailscale.corpDns)
              }

              Toggle {
                width: parent.width
                label: "Shields up"
                description: "Block incoming connections from the tailnet"
                checked: tailscale.shieldsUp
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: tailscale.setShieldsUp(!tailscale.shieldsUp)
              }

              Toggle {
                visible: tailscale.allowLanRelevant
                width: parent.width
                label: "Allow LAN access"
                description: "While using an exit node, reach local devices directly"
                checked: tailscale.allowLanAccess
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: tailscale.setAllowLanAccess(!tailscale.allowLanAccess)
              }
            }
          }

          // ================= MULLVAD TAB =====================================
          Column {
            id: mullCol
            visible: root.tab === "mullvad" && root.hasMullvad
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "MULLVAD REGIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: mullvadSearch
              width: parent.width
              foreground: root.foreground
              placeholderText: "Search " + tailscale.mullvadRegions.length + " regions…"
              text: root.mullvadQuery
              onTextChanged: { root.mullvadQuery = text; root.mullvadRegionIndex = 0 }
              onAccepted: root.activateMullvadRegion()
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Down || event.text === "j") { root.moveMullvadCursor(1); event.accepted = true }
                else if (event.key === Qt.Key_Up || event.text === "k") { root.moveMullvadCursor(-1); event.accepted = true }
                else if (event.key === Qt.Key_Escape) { root.tab = "exitNodes"; event.accepted = true }
              }
            }

            Column {
              id: mullvadRegionColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.filteredMullvadRegions
                MullvadRegionRow {
                  required property var modelData
                  required property int index
                  width: mullvadRegionColumn.width
                  peer: modelData
                  rowIndex: index
                }
              }
            }

            Text {
              visible: root.filteredMullvadRegions.length === 0
              width: parent.width
              text: "No regions match."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ================= MACHINES TAB ====================================
          Column {
            id: machCol
            visible: root.tab === "machines"
            width: parent.width
            spacing: Style.space(10)

            TextField {
              id: machineSearch
              width: parent.width
              foreground: root.foreground
              placeholderText: "Search " + tailscale.peers.length + " machines…"
              text: root.peerQuery
              onTextChanged: { root.peerQuery = text; root.peerIndex = 0 }
              onAccepted: root.activateCursor()
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape && root.peerQuery !== "") {
                  root.peerQuery = ""
                  machineSearch.text = ""
                  event.accepted = true
                }
              }
            }

            Text {
              visible: root.filteredOnline.length === 0 && root.filteredOffline.length === 0
              width: parent.width
              text: "No machines match."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: peerColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.filteredOnline
                PeerRow {
                  required property var modelData
                  required property int index
                  width: peerColumn.width
                  peer: modelData
                  rowIndex: index
                }
              }
            }

            CursorSurface {
              visible: root.filteredOffline.length > 0
              width: parent.width
              implicitHeight: offRow.implicitHeight + Style.space(4)
              foreground: root.foreground

              Row {
                id: offRow
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                spacing: Style.space(8)

                Text {
                  text: root.offlineOpen ? "󰅀" : "󰅂"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  text: root.filteredOffline.length + " offline — hidden"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.offlineOpen = !root.offlineOpen
              }
            }

            Column {
              id: offlineColumn
              visible: root.offlineOpen
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.offlineOpen ? root.filteredOffline : 0
                PeerRow {
                  required property var modelData
                  required property int index
                  width: offlineColumn.width
                  peer: modelData
                  rowIndex: root.filteredOnline.length + index
                }
              }
            }
          }
        }
      }
    }
  }

  // ================= components ============================================

  component TabButton: Rectangle {
    id: tb
    property string key: ""
    property string label: ""
    readonly property bool active: root.tab === key
    width: tabText.implicitWidth + Style.space(20)
    height: Style.space(24)
    radius: Style.cornerRadius
    color: active ? Qt.rgba(1, 1, 1, 0.10) : "transparent"
    border.width: active ? 1 : 0
    border.color: root.dim

    Text {
      id: tabText
      anchors.centerIn: parent
      text: tb.label
      color: tb.active ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: tb.active
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.setTab(tb.key)
    }
  }

  component AuthRow: CursorSurface {
    id: authRow
    implicitHeight: row.implicitHeight + Style.spacing.rowPaddingX
    foreground: root.foreground

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: tailscale.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
      enabled: !tailscale.busy
      onClicked: tailscale.authorizeTailscaleOperator()
    }

    Row {
      id: row
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: "󰒓"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        spacing: Style.space(1)

        Text {
          text: "Authorize Tailscale operator"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          text: "Allow this user to switch connections and preferences"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component InfoRow: CursorSurface {
    id: infoRow
    property string glyph: ""
    property string label: ""
    property string sub: ""
    property string copyValue: ""
    implicitHeight: row.implicitHeight + Style.spacing.rowPaddingX
    foreground: root.foreground

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: infoRow.copyValue !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (infoRow.copyValue !== "") tailscale.copyToClipboard(infoRow.copyValue, infoRow.label)
    }

    Row {
      id: row
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: infoRow.glyph
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - Style.space(30)
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: infoRow.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: infoRow.sub
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component ExitNodeRow: CursorSurface {
    id: exitRow
    signal chosen()
    property string glyph: "󱇢"
    property string name: ""
    property string detail: ""
    property bool activeNode: false
    property bool settingNode: false
    property string rowKey: ""
    readonly property string actionTooltip: activeNode ? "Disconnect" : "Connect"

    current: activeNode || settingNode
    foreground: root.foreground
    fill: Qt.rgba(1, 1, 1, 0.06)
    currentFill: Qt.rgba(1, 1, 1, 0.12)
    implicitHeight: exitInner.implicitHeight + Style.spacing.xl

    Row {
      id: exitInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        id: exitNodeGlyph
        text: exitRow.glyph
        color: exitRow.current ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter

        NumberAnimation on rotation {
          running: exitRow.settingNode
          from: 0
          to: 360
          duration: 900
          loops: Animation.Infinite
        }

        onRotationChanged: if (!exitRow.settingNode && rotation !== 0) rotation = 0
      }

      Column {
        width: parent.width - Style.space(30)
        spacing: Style.space(1)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: exitRow.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: exitRow.activeNode
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: exitRow.detail
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      id: exitNodeMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: exitRow.chosen()
    }

    PanelToolTip {
      visible: exitNodeMouse.containsMouse
      text: exitRow.actionTooltip
      fontFamily: root.fontFamily
    }
  }

  component PeerRow: CursorSurface {
    id: peerRow
    property var peer: null
    property int rowIndex: 0
    readonly property string peerName: peer ? String(peer.DisplayName || peer.HostName || "Unknown") : "Unknown"
    readonly property string peerIp: peer && peer.TailscaleIPs && peer.TailscaleIPs.length > 0 ? String(peer.TailscaleIPs[0]) : ""
    readonly property string peerDns: peer ? String(peer.DNSName || "") : ""
    readonly property string peerIpv6: peer && peer.TailscaleIPv6 && peer.TailscaleIPv6.length > 0 ? String(peer.TailscaleIPv6[0]) : ""
    readonly property bool online: peer ? peer.Online === true : false
    readonly property string lastSeenText: peer ? Model.fmtLastSeen(peer.LastSeen) : "never"
    readonly property string subLine: {
      var parts = []
      if (peerIp !== "") parts.push(peerIp)
      if (peerDns !== "") parts.push(peerDns)
      if (!online && lastSeenText !== "") parts.push("last seen " + lastSeenText)
      return parts.join(" \u00b7 ")
    }

    opacity: online ? 1.0 : 0.62
    implicitHeight: Math.max(peerContent.implicitHeight, copyButton.implicitHeight) + Style.spacing.rowPaddingX
    foreground: root.foreground

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onClicked: peerRow.openCopyMenu()
    }

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: tailscale.osIcon(peer ? peer.OS : "")
        color: online ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: peerContent
        width: parent.width - Style.space(60)
        spacing: Style.space(1)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: peerRow.peerName
          color: online ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          visible: text !== ""
          text: peerRow.subLine
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        id: sendButton
        visible: online && tailscale.canSendFiles(peerRow.peer)
        iconText: "󰒊"
        tooltipText: "Send files"
        foreground: root.foreground
        fontFamily: root.fontFamily
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.sendPeerFile(peerRow.peer)
      }

      PanelActionButton {
        id: copyButton
        iconText: "󰆏"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: peerRow.peerIp !== "" || peerRow.peerName !== "" || peerRow.peerDns !== "" || peerRow.peerIpv6 !== ""
        anchors.verticalCenter: parent.verticalCenter
        onClicked: peerRow.openCopyMenu()
      }
    }

    property int copyIndex: 0
    readonly property var copyOptions: {
      var options = []
      if (peerName !== "") options.push({ kind: "name", label: peerName })
      if (peerDns !== "") options.push({ kind: "dns", label: peerDns })
      if (peerIpv6 !== "") options.push({ kind: "ipv6", label: peerIpv6 })
      if (peerIp !== "") options.push({ kind: "ip", label: peerIp })
      return options
    }

    function clampCopyIndex() {
      copyIndex = Math.max(0, Math.min(copyIndex, copyOptions.length - 1))
    }

    function openCopyMenu() {
      if (copyOptions.length === 0) return
      clampCopyIndex()
      copyPopup.open()
    }

    function copyOption(kind) {
      if (kind === "name") tailscale.copyPeerName(peer)
      else if (kind === "dns") tailscale.copyPeerDnsName(peer)
      else if (kind === "ipv6") tailscale.copyToClipboard(peerIpv6, peerName + " IPv6")
      else if (kind === "ip") tailscale.copyPeerIp(peer)
      copyPopup.close()
    }

    Popup {
      id: copyPopup
      x: copyButton.x + copyButton.width - width
      y: copyButton.y + copyButton.height + Style.space(4)
      width: Style.space(280)
      padding: 0
      modal: false
      focus: true
      closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

      onOpenedChanged: {
        root.copyMenuOpen = opened
        if (!opened && root.opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      }

      background: BorderSurface {
        color: Color.background
        borderSpec: Border.flat(root.dim, 1)
        radius: Style.cornerRadius
      }

      contentItem: Column {
        width: parent.width
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Down || event.text === "j") { peerRow.copyIndex = Math.min(peerRow.copyOptions.length - 1, peerRow.copyIndex + 1); event.accepted = true }
          else if (event.key === Qt.Key_Up || event.text === "k") { peerRow.copyIndex = Math.max(0, peerRow.copyIndex - 1); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { peerRow.copyOption(peerRow.copyOptions[peerRow.copyIndex].kind); event.accepted = true }
          else if (event.key === Qt.Key_Escape) { copyPopup.close(); event.accepted = true }
        }

        Repeater {
          model: peerRow.copyOptions
          CopyChoice {
            required property var modelData
            required property int index
            width: parent.width
            label: String(modelData.label || "")
            selected: peerRow.copyIndex === index
            onHovered: peerRow.copyIndex = index
            onChosen: peerRow.copyOption(String(modelData.kind || ""))
          }
        }
      }
    }
  }

  component CopyChoice: CursorSurface {
    id: copyChoice
    signal chosen()
    signal hovered()
    property string label: ""
    property bool selected: false

    visible: enabled
    foreground: root.foreground
    hasCursor: selected
    implicitHeight: Style.space(36)
    radius: 0

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: copyChoice.hovered()
      onClicked: copyChoice.chosen()
    }

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(10)

      Text {
        width: parent.width - Style.space(34)
        textFormat: Text.PlainText
        text: copyChoice.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        text: "󰆏"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
    }
  }

  component MullvadRegionRow: CursorSurface {
    id: regionRow
    property var peer: null
    property int rowIndex: 0
    readonly property string regionName: peer ? (String(peer.City || "") === "Any" || String(peer.City || "") === "" ? String(peer.Country || "") : String(peer.City || "")) : ""
    readonly property string regionDetail: peer ? String(peer.Country || "") : ""
    readonly property bool activeExitNode: peer && peer.ExitNode === true
    readonly property bool settingExitNode: peer && tailscale.settingExitNodeId === String(peer.id || "")
    readonly property string actionTooltip: activeExitNode ? "Disconnect" : "Connect"

    foreground: root.foreground
    fill: Qt.rgba(1, 1, 1, 0.06)
    currentFill: Qt.rgba(1, 1, 1, 0.12)
    current: activeExitNode || settingExitNode
    implicitHeight: row.implicitHeight + Style.spacing.lg

    Row {
      id: row
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󱇢"
        color: regionRow.current ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - Style.space(30)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: regionRow.regionName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: regionRow.activeExitNode
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: regionRow.regionDetail
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      id: regionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tailscale.setExitNode(regionRow.peer)
    }

    PanelToolTip {
      visible: regionMouse.containsMouse
      text: regionRow.actionTooltip
      fontFamily: root.fontFamily
    }
  }
}
