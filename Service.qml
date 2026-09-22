import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// gdeyoung.tailfin service — stock omarchy.tailscale Service with fork
// additions (marked): preferences (accept-routes/-dns, shields-up,
// allow-lan-access), exit-node suggest, health warnings, online counts.
Item {
  id: root

  property var settings: ({})

  property bool installed: false
  property bool running: false
  property bool needsLogin: false

  // Optimistic off state so the UI reacts the instant you click, rather than
  // waiting for the next status refresh. _desired is -1 while we just follow
  // the real state, or 0/1 while a toggle is still catching up.
  property int _desired: -1
  readonly property bool active: _desired === -1 ? running : (_desired === 1)
  property bool refreshing: false
  property string backendState: "Unknown"
  property string statusText: "Checking…"
  property string selfName: ""
  property string selfDnsName: ""
  property string selfIp: ""
  property string selfUserId: ""
  property bool fileSharing: false
  property string authUrl: ""
  property var peers: []
  property var exitNodes: []
  property var tailnetExitNodes: []
  property var mullvadExitNodes: []
  property var mullvadRegions: []
  property var accounts: []
  property string selectedAccountId: ""
  property string selectedAccountLabel: ""
  property string switchingAccountId: ""
  property string settingExitNodeId: ""
  property bool accountsAccessDenied: false
  property string actionStatus: ""
  property string lastError: ""

  // ---- fork: health + preferences + suggest -------------------------------
  property var health: []
  property int onlineCount: 0
  property bool prefsOk: false
  property bool routeAll: false          // accept-routes
  property bool corpDns: true            // accept-dns
  property bool shieldsUp: false
  property bool allowLanAccess: false    // exit-node-allow-lan-access
  property string suggestedExitNode: ""
  property bool suggesting: false
  property bool receiveActive: false    // Taildrop receiver service running
  property bool receiveBusy: false

  // fork: acknowledged health warnings (persisted, per-warning) --------------
  property var ackedHealth: []
  readonly property var visibleHealth: health.filter(function(w) {
    return ackedHealth.indexOf(w) < 0
  })
  readonly property int ackedCount: health.length - visibleHealth.length
  // end fork -----------------------------------------------------------------

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  Process {
    id: receiveStateProcess
    running: false
    command: []
    stdout: StdioCollector { id: receiveStateOut; waitForEnd: true; onStreamFinished: root._receiveStateOut = text }
    onExited: function(exitCode) {
      root.receiveActive = String(root._receiveStateOut).trim() === "active"
    }
  }

  Process {
    id: toggleReceiveProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.receiveBusy = false
      root.refreshReceiveState()
    }
  }

  readonly property bool busy: whichProcess.running || statusProcess.running || mullvadExitNodesProcess.running || accountsProcess.running || actionProcess.running || loginProcess.running || switchProcess.running || operatorProcess.running || exitNodeProcess.running || prefsProcess.running || suggestProcess.running || prefSetProcess.running
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")

  property string _statusOutput: ""
  property string _statusError: ""
  property string _accountsOutput: ""
  property string _accountsError: ""
  property string _mullvadExitNodesOutput: ""
  property string _mullvadExitNodesError: ""
  property string _actionOutput: ""
  property string _actionError: ""
  property string _loginOutput: ""
  property string _loginError: ""
  property bool _loginInProgress: false
  property bool _loginUrlOpened: false
  property string _preLoginAuthUrl: ""
  property double _lastAccountsRefreshMs: 0
  property string _switchOutput: ""
  property string _switchError: ""
  property string _exitNodeOutput: ""
  property string _exitNodeError: ""
  property string _operatorOutput: ""
  property string _operatorError: ""
  property string _prefsOutput: ""
  property string _prefsError: ""
  property string _suggestOutput: ""
  property string _suggestError: ""
  property string _prefSetOutput: ""
  property string _prefSetError: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function filterIPv4(ips) {
    return Model.filterIPv4(ips)
  }

  function cleanDnsName(name) {
    return Model.cleanDnsName(name)
  }

  function shortDnsName(name) {
    return Model.shortDnsName(name)
  }

  function displayHostName(hostName, dnsName) {
    return Model.displayHostName(hostName, dnsName)
  }

  function osIcon(os) {
    return Model.osIcon(os)
  }

  function accountLabel(account) {
    return Model.accountLabel(account)
  }

  function copyToClipboard(value, label) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
  }

  function copyPeerIp(peer) {
    if (!peer) return
    var ips = filterIPv4(peer.TailscaleIPs || [])
    copyToClipboard(ips.length > 0 ? ips[0] : "", displayHostName(peer.HostName, peer.DNSName) + " IP")
  }

  function copyPeerName(peer) {
    if (!peer) return
    copyToClipboard(displayHostName(peer.HostName, peer.DNSName), displayHostName(peer.HostName, peer.DNSName) + " name")
  }

  function copyPeerDnsName(peer) {
    if (!peer) return
    copyToClipboard(cleanDnsName(peer.DNSName), displayHostName(peer.HostName, peer.DNSName) + " DNS name")
  }

  function peerAddress(peer) {
    if (!peer) return ""
    if (peer.DNSName) return cleanDnsName(peer.DNSName)
    if (peer.HostName) return String(peer.HostName)
    var ips = filterIPv4(peer.TailscaleIPs || [])
    return ips.length > 0 ? ips[0] : ""
  }

  function canSendFiles(peer) {
    if (!fileSharing || !running || !peer) return false
    return Model.isTaildropTarget(peer, selfUserId)
  }

  function sshPeer(peer) {
    if (!peer || !peer.Online || peer.Mullvad === true) return
    var host = String(peer.HostName || "")
    var dns = String(peer.DNSName || host)
    Quickshell.execDetached(["foot", "-T", "ssh " + host, "-e", "sh", "-lc", "exec tailscale ssh '" + host + "' 2>/dev/null || exec ssh '" + dns + "'"])
  }

  // Taildrop receive toggle (stock omarchy-tailscale-receive.service)
  function refreshReceiveState() {
    if (!receiveStateProcess.running) {
      receiveStateProcess.command = ["systemctl", "--user", "is-active", "omarchy-tailscale-receive.service"]
      receiveStateProcess.running = true
    }
  }

  function toggleReceive(on) {
    toggleReceiveProcess.command = ["systemctl", "--user", on ? "enable" : "disable", "--now", "omarchy-tailscale-receive.service"]
    toggleReceiveProcess.running = true
  }

  function sendFile(peer) {
    if (!canSendFiles(peer)) return
    var target = peerAddress(peer)
    if (target === "") return
    Quickshell.execDetached(["omarchy-tailscale-send", target])
  }

  function refresh(forceAccounts) {
    if (installed) {
      refreshStatusAndAccounts(forceAccounts === true)
      return
    }
    if (!whichProcess.running) {
      refreshing = true
      whichProcess.command = ["which", "tailscale"]
      whichProcess.running = true
    }
  }

  function refreshStatusAndAccounts(forceAccounts) {
    if (!installed) return
    refreshReceiveState()
    var launched = false
    if (!statusProcess.running) {
      _statusOutput = ""
      _statusError = ""
      refreshing = true
      statusProcess.command = ["tailscale", "status", "--json"]
      statusProcess.running = true
      launched = true
    }
    // fork: preferences ride along on every refresh (unprivileged, ~10ms)
    if (!prefsProcess.running) {
      _prefsOutput = ""
      _prefsError = ""
      prefsProcess.command = ["tailscale", "debug", "prefs"]
      prefsProcess.running = true
      launched = true
    }
    // end fork
    if (!mullvadExitNodesProcess.running) {
      _mullvadExitNodesOutput = ""
      _mullvadExitNodesError = ""
      mullvadExitNodesProcess.command = ["tailscale", "exit-node", "list"]
      mullvadExitNodesProcess.running = true
      launched = true
    }
    var now = Date.now()
    var shouldRefreshAccounts = forceAccounts === true || accounts.length === 0 || now - _lastAccountsRefreshMs > 60000
    if (shouldRefreshAccounts && !accountsProcess.running) {
      _accountsOutput = ""
      _accountsError = ""
      _lastAccountsRefreshMs = now
      accountsProcess.command = ["tailscale", "switch", "--list", "--json"]
      accountsProcess.running = true
      launched = true
    }
    // Arm on the launch that needs watching and leave it alone after that.
    // Restarting it every refresh pushes the deadline out ahead of a hung
    // process forever once the refresh interval is shorter than the timeout,
    // and refreshIntervalSec goes down to five seconds.
    if (launched && !pollWatchdog.running) pollWatchdog.start()
  }

  function elideStatus(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  function resetUnavailable(message) {
    running = false
    needsLogin = false
    _desired = -1
    backendState = "Unavailable"
    statusText = message
    selfName = ""
    selfDnsName = ""
    selfIp = ""
    selfUserId = ""
    fileSharing = false
    authUrl = ""
    peers = []
    exitNodes = []
    tailnetExitNodes = []
    mullvadExitNodes = []
    mullvadRegions = []
    accounts = []
    selectedAccountId = ""
    selectedAccountLabel = ""
    switchingAccountId = ""
    settingExitNodeId = ""
    accountsAccessDenied = false
    // fork
    health = []
    onlineCount = 0
    prefsOk = false
    suggestedExitNode = ""
  }

  function parseStatus(raw) {
    var parsed = Model.parseStatusPlus(raw)   // fork: superset of stock parseStatus
    if (!parsed.ok) {
      resetUnavailable(parsed.message || "Status error")
      lastError = parsed.error || "Failed to parse tailscale status"
      console.warn("tailscale", lastError)
      return
    }
    if (parsed.unavailable) {
      resetUnavailable(parsed.message || "Disconnected")
      return
    }

    backendState = parsed.backendState
    running = parsed.running
    // Reality caught up to the pending toggle — stop overriding.
    if (_desired !== -1 && running === (_desired === 1)) _desired = -1
    needsLogin = parsed.needsLogin
    authUrl = parsed.authUrl
    if (needsLogin && _loginInProgress && !_loginUrlOpened && authUrl !== "" && authUrl !== _preLoginAuthUrl) openAuthUrlFrom(authUrl, false)
    selfName = parsed.selfName
    selfDnsName = parsed.selfDnsName
    selfIp = parsed.selfIp
    selfUserId = parsed.selfUserId
    fileSharing = parsed.fileSharing
    peers = parsed.running ? parsed.peers : []
    tailnetExitNodes = parsed.running ? parsed.exitNodes : []
    exitNodes = parsed.running ? tailnetExitNodes.concat(mullvadRegions) : []

    if (needsLogin) statusText = "Needs login"
    else if (running) {
      statusText = "Connected"
      _loginInProgress = false
      _loginUrlOpened = false
      _preLoginAuthUrl = ""
      loginTimeoutTimer.stop()
    } else if (backendState === "Stopped") {
      statusText = "Disconnected"
    } else {
      statusText = backendState
    }
    // fork: health + counts
    health = parsed.health
    onlineCount = parsed.onlineCount
    lastError = ""
  }

  function parseAccounts(raw) {
    var parsed = Model.parseAccounts(raw)
    accounts = parsed.accounts
    selectedAccountId = parsed.selectedAccountId
    selectedAccountLabel = parsed.selectedAccountLabel
    accountsAccessDenied = false
  }

  function parseMullvadExitNodes(raw) {
    mullvadExitNodes = Model.parseExitNodeList(raw)
    mullvadRegions = Model.mullvadRegionOptions(mullvadExitNodes)
    exitNodes = running ? tailnetExitNodes.concat(mullvadRegions) : []
  }

  function toggleTailscale() {
    if (!installed) return
    if (active) down()
    else loginOrUp()
  }

  function down() {
    // No progress status here — the greyed icon and hero line already convey
    // the optimistic off; only surface a message if the command fails.
    _desired = 0
    runAction(["tailscale", "down"])
  }

  function loginOrUp() {
    if (!installed || loginProcess.running) return
    _desired = -1
    var plan = Model.loginPlan(needsLogin, authUrl)
    if (plan.authUrl !== "") {
      _loginUrlOpened = false
      openAuthUrlFrom(plan.authUrl, true)
      return
    }
    _loginOutput = ""
    _loginError = ""
    if (needsLogin) actionStatus = "Starting Tailscale login…"
    else _desired = 1
    _loginInProgress = needsLogin
    _loginUrlOpened = false
    _preLoginAuthUrl = authUrl
    loginProcess.command = plan.command
    loginProcess.running = true
    if (needsLogin) loginTimeoutTimer.restart()
  }

  function switchAccount(id) {
    var accountId = String(id || "")
    if (!installed || accountId === "" || accountId === selectedAccountId || switchProcess.running) return
    _switchOutput = ""
    _switchError = ""
    switchingAccountId = accountId
    switchProcess.command = ["tailscale", "switch", accountId]
    switchProcess.running = true
  }

  function exitNodeTarget(peer) {
    if (!peer) return ""
    if (peer.Mullvad === true) {
      var mullvadIps = filterIPv4(peer.TailscaleIPs || [])
      if (mullvadIps.length > 0) return mullvadIps[0]
    }
    return peerAddress(peer)
  }

  function setExitNode(peer) {
    if (!installed || !running || !peer || exitNodeProcess.running) return
    var active = peer.ExitNode === true
    var target = active ? "" : exitNodeTarget(peer)
    if (!active && target === "") return
    _exitNodeOutput = ""
    _exitNodeError = ""
    settingExitNodeId = String(peer.id || "")
    exitNodeProcess.command = ["tailscale", "set", "--exit-node=" + target]
    exitNodeProcess.running = true
  }

  // fork: set by hostname/FQDN (suggest row, "none" row) — target is used
  // verbatim; empty string clears the exit node.
  function setExitNodeHost(target) {
    if (!installed || !running || exitNodeProcess.running) return
    _exitNodeOutput = ""
    _exitNodeError = ""
    settingExitNodeId = target === "" ? "none" : "host:" + target
    exitNodeProcess.command = ["tailscale", "set", "--exit-node=" + target]
    exitNodeProcess.running = true
  }

  // fork: display name of the active exit node ("" = direct). ExitNodeID
  // in prefs matches the peer NodeID in status, so join on that first, then
  // fall back to the active-exit flag from status.
  function currentExitNodeName() {
    if (!running) return ""
    var activePeer = null
    for (var i = 0; i < peers.length; i++) {
      if (peers[i].ExitNode === true) { activePeer = peers[i]; break }
    }
    return activePeer ? String(activePeer.HostName || "") : ""
  }

  // fork: LAN-access toggle only makes sense while an exit node is in use.
  readonly property bool allowLanRelevant: currentExitNodeName() !== ""

  function authorizeTailscaleOperator() {
    if (!installed || operatorProcess.running || userName === "") return
    _operatorOutput = ""
    _operatorError = ""
    actionStatus = "Authorizing Tailscale operator..."
    operatorProcess.command = ["pkexec", "tailscale", "set", "--operator=" + userName]
    operatorProcess.running = true
  }

  function runAction(command, label) {
    if (actionProcess.running) return
    _actionOutput = ""
    _actionError = ""
    actionStatus = label || ""
    actionProcess.command = command
    actionProcess.running = true
  }

  function openAuthUrlFrom(text, allowFallback) {
    if (_loginUrlOpened) return true
    var match = String(text || "").match(/https?:\/\/\S+/)
    var url = match && match[0] ? match[0] : (allowFallback === true ? authUrl : "")
    if (url !== "") {
      // Turning on ended up needing browser auth — stop pretending we're up.
      _desired = -1
      _loginUrlOpened = true
      _loginInProgress = false
      loginTimeoutTimer.stop()
      Quickshell.execDetached(["omarchy-launch-browser", url])
      return true
    }
    return false
  }

  function handleLoginOutput(data, isError) {
    var text = String(data || "")
    if (isError) _loginError += text + "\n"
    else _loginOutput += text + "\n"
    if (_loginInProgress && !_loginUrlOpened) openAuthUrlFrom(text, false)
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // After a fresh boot the startup poll usually lands before tailscaled has
    // connected, which left the icon stale until the next periodic refresh.
    // Poll quickly until the service shows up, or give up after ~30 seconds.
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    running: true
    onTriggered: {
      ticks += 1
      if (root.running || ticks >= 15) startupRamp.running = false
      else root.refresh()
    }
  }

  Timer {
    id: delayedRefresh
    interval: 600
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    // Every poll is skipped while its own process is still running, so one that
    // never exits — tailscale can hang on a network that is coming and going —
    // silently stops the panel refreshing at all, and it stays stopped. Reap
    // anything still running well inside the refresh interval so the next tick
    // starts clean.
    id: pollWatchdog
    interval: 15000
    repeat: false
    onTriggered: {
      if (statusProcess.running) statusProcess.running = false
      if (mullvadExitNodesProcess.running) mullvadExitNodesProcess.running = false
      if (accountsProcess.running) accountsProcess.running = false
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: loginTimeoutTimer
    interval: 10000
    repeat: false
    onTriggered: {
      if (!root._loginInProgress || root._loginUrlOpened) return
      if (!root.openAuthUrlFrom(root.authUrl, true)) {
        root._loginInProgress = false
        root.actionStatus = "Tailscale login link not available yet"
      }
    }
  }

  Process {
    id: whichProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (root.installed) root.refreshStatusAndAccounts()
      else {
        root.refreshing = false
        root.resetUnavailable("Not installed")
      }
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      root.refreshing = false
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) root.parseStatus(stdout)
      else {
        root.resetUnavailable("Disconnected")
        root.lastError = stderr.trim()
      }
    }
  }

  Process {
    id: accountsProcess
    running: false
    command: []
    stdout: StdioCollector { id: accountsStdout; waitForEnd: true; onStreamFinished: root._accountsOutput = text }
    stderr: StdioCollector { id: accountsStderr; waitForEnd: true; onStreamFinished: root._accountsError = text }
    onExited: function(exitCode) {
      var stdout = String(accountsStdout.text || root._accountsOutput || "")
      var stderr = String(accountsStderr.text || root._accountsError || "")
      if (exitCode === 0) root.parseAccounts(stdout)
      else {
        root.parseAccounts("")
        if (/profiles access denied/i.test(stderr) || /profiles access denied/i.test(stdout)) {
          root.accountsAccessDenied = true
          root.lastError = "Authorize Tailscale operator to show connections"
        } else {
          root.lastError = elideStatus(stderr || stdout || "Could not list Tailscale connections")
        }
      }
    }
  }

  Process {
    id: mullvadExitNodesProcess
    running: false
    command: []
    stdout: StdioCollector { id: mullvadExitNodesStdout; waitForEnd: true; onStreamFinished: root._mullvadExitNodesOutput = text }
    stderr: StdioCollector { id: mullvadExitNodesStderr; waitForEnd: true; onStreamFinished: root._mullvadExitNodesError = text }
    onExited: function(exitCode) {
      var stdout = String(mullvadExitNodesStdout.text || root._mullvadExitNodesOutput || "")
      if (exitCode === 0) root.parseMullvadExitNodes(stdout)
      else root.parseMullvadExitNodes("")
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true; onStreamFinished: root._actionOutput = text }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true; onStreamFinished: root._actionError = text }
    onExited: function(exitCode) {
      var stdout = String(actionStdout.text || root._actionOutput || "")
      var stderr = String(actionStderr.text || root._actionError || "")
      if (exitCode !== 0) {
        root._desired = -1
        root.lastError = elideStatus(stderr || stdout || "Tailscale command failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: loginProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function(data) { root.handleLoginOutput(data, false) } }
    stderr: SplitParser { onRead: function(data) { root.handleLoginOutput(data, true) } }
    onExited: function(exitCode) {
      var combined = String(root._loginOutput || "") + "\n" + String(root._loginError || "")
      var opened = root.openAuthUrlFrom(combined, true)
      if (exitCode !== 0 && !opened) {
        root._desired = -1
        root._loginInProgress = false
        root.lastError = elideStatus(combined || "tailscale up failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else if (!opened) {
        root.lastError = ""
        root.actionStatus = ""
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: switchProcess
    running: false
    command: []
    stdout: StdioCollector { id: switchStdout; waitForEnd: true; onStreamFinished: root._switchOutput = text }
    stderr: StdioCollector { id: switchStderr; waitForEnd: true; onStreamFinished: root._switchError = text }
    onExited: function(exitCode) {
      var stdout = String(switchStdout.text || root._switchOutput || "")
      var stderr = String(switchStderr.text || root._switchError || "")
      if (exitCode !== 0) {
        root.lastError = elideStatus(stderr || stdout || "Account switch failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
        root._lastAccountsRefreshMs = 0
      }
      root.switchingAccountId = ""
      delayedRefresh.restart()
    }
  }

  Process {
    id: exitNodeProcess
    running: false
    command: []
    stdout: StdioCollector { id: exitNodeStdout; waitForEnd: true; onStreamFinished: root._exitNodeOutput = text }
    stderr: StdioCollector { id: exitNodeStderr; waitForEnd: true; onStreamFinished: root._exitNodeError = text }
    onExited: function(exitCode) {
      var stdout = String(exitNodeStdout.text || root._exitNodeOutput || "")
      var stderr = String(exitNodeStderr.text || root._exitNodeError || "")
      if (exitCode !== 0) {
        root.lastError = elideStatus(stderr || stdout || "Exit node selection failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
      }
      root.settingExitNodeId = ""
      delayedRefresh.restart()
    }
  }

  Process {
    id: operatorProcess
    running: false
    command: []
    stdout: StdioCollector { id: operatorStdout; waitForEnd: true; onStreamFinished: root._operatorOutput = text }
    stderr: StdioCollector { id: operatorStderr; waitForEnd: true; onStreamFinished: root._operatorError = text }
    onExited: function(exitCode) {
      var stdout = String(operatorStdout.text || root._operatorOutput || "")
      var stderr = String(operatorStderr.text || root._operatorError || "")
      if (exitCode !== 0) {
        root.lastError = elideStatus(stderr || stdout || "Tailscale authorization failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.accountsAccessDenied = false
        root.lastError = ""
        root.actionStatus = "Tailscale operator authorized"
        actionStatusTimer.restart()
        root._lastAccountsRefreshMs = 0
      }
      delayedRefresh.restart()
    }
  }

  // ---- fork: preferences + suggest ----------------------------------------
  // Writes go through prefSetProcess; each emits its own actionStatus line
  // and ends with delayedRefresh so prefs + status re-read truth.
  // Pref writes REQUIRE the operator (root) — without it tailscale prints
  // "Access denied" and the process exits non-zero, which surfaces as
  // lastError. The panel gates the switches on accountsAccessDenied so the
  // user is offered the pkexec authorize step before the first failure.
  function setPref(flag, value) {
    if (!installed || !running || prefSetProcess.running) return
    _prefSetOutput = ""
    _prefSetError = ""
    prefSetProcess.command = ["tailscale", "set", flag + "=" + (value ? "true" : "false")]
    prefSetProcess.running = true
  }

  function setRouteAll(on) {
    routeAll = on   // optimistic; reverted on failure via prefs re-read
    setPref("--accept-routes", on)
  }

  function setCorpDns(on) {
    corpDns = on
    setPref("--accept-dns", on)
  }

  function setShieldsUp(on) {
    shieldsUp = on
    setPref("--shields-up", on)
  }

  function setAllowLanAccess(on) {
    allowLanAccess = on
    setPref("--exit-node-allow-lan-access", on)
  }

  function refreshSuggest() {
    if (!installed || !running || suggestProcess.running) return
    _suggestOutput = ""
    _suggestError = ""
    suggesting = true
    suggestProcess.command = ["tailscale", "exit-node", "suggest"]
    suggestProcess.running = true
  }

  Process {
    id: prefsProcess
    running: false
    command: []
    stdout: StdioCollector { id: prefsStdout; waitForEnd: true; onStreamFinished: root._prefsOutput = text }
    stderr: StdioCollector { id: prefsStderr; waitForEnd: true; onStreamFinished: root._prefsError = text }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var parsed = Model.parsePrefs(prefsStdout.text || root._prefsOutput || "")
        if (parsed.ok) {
          root.prefsOk = true
          root.routeAll = parsed.routeAll
          root.corpDns = parsed.corpDns
          root.shieldsUp = parsed.shieldsUp
          root.allowLanAccess = parsed.allowLanAccess
        }
      }
      // Non-zero or unparseable: leave last-known prefs; prefsOk stays as-is
      // after first success (a transient failure shouldn't blank the panel).
    }
  }

  Process {
    id: suggestProcess
    running: false
    command: []
    stdout: StdioCollector { id: suggestStdout; waitForEnd: true; onStreamFinished: root._suggestOutput = text }
    stderr: StdioCollector { id: suggestStderr; waitForEnd: true; onStreamFinished: root._suggestError = text }
    onExited: function(exitCode) {
      root.suggesting = false
      if (exitCode === 0) {
        root.suggestedExitNode = Model.parseSuggest(suggestStdout.text || root._suggestOutput || "")
      } else {
        root.suggestedExitNode = ""
      }
    }
  }

  Process {
    id: prefSetProcess
    running: false
    command: []
    stdout: StdioCollector { id: prefSetStdout; waitForEnd: true; onStreamFinished: root._prefSetOutput = text }
    stderr: StdioCollector { id: prefSetStderr; waitForEnd: true; onStreamFinished: root._prefSetError = text }
    onExited: function(exitCode) {
      var stdout = String(prefSetStdout.text || root._prefSetOutput || "")
      var stderr = String(prefSetStderr.text || root._prefSetError || "")
      if (exitCode !== 0) {
        // Access denied = operator not authorized: offer the authorize step.
        if (/access denied/i.test(stderr) || /access denied/i.test(stdout)) {
          root.accountsAccessDenied = true
          root.lastError = "Authorize Tailscale operator to change preferences"
        } else {
          root.lastError = elideStatus(stderr || stdout || "Preference change failed")
        }
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
      }
      delayedRefresh.restart()
    }
  }
  // end fork -----------------------------------------------------------------

  // fork: acknowledged-health persistence ------------------------------------
  // Stock Omarchy pattern (Style.qml): FileView watches the file, loads on
  // change, writes go through Quickshell's file API. Watched both ways so an
  // external rm shows warnings again instantly and acks survive restarts.
  function ackHealth(warning) {
    if (ackedHealth.indexOf(warning) < 0) {
      ackedHealth = ackedHealth.concat([warning])
      _saveAckedHealth()
    }
  }

  function unackAll() {
    if (ackedHealth.length > 0) {
      ackedHealth = []
      _saveAckedHealth()
    }
  }

  function _saveAckedHealth() {
    var s = JSON.stringify(ackedHealth)
    try {
      ackedFile.setText(s)
    } catch (e) {
      // Dir may not exist yet in the first seconds after install; the
      // startup mkdir (ackDirProcess) will land shortly — retry once.
      _ackWritePending = s
      ackRetryTimer.restart()
    }
  }

  property string _ackWritePending: ""
  property string _receiveStateOut: ""
  readonly property string ackStateDir: Quickshell.env("HOME") + "/.local/state/gdeyoung.tailfin"

  // mkdir -p at startup: FileView.setText cannot create parent dirs.
  Component.onCompleted: Quickshell.execDetached(["mkdir", "-p", ackStateDir])

  Timer {
    id: ackRetryTimer
    interval: 800
    repeat: false
    onTriggered: {
      if (root._ackWritePending !== "") {
        try {
          ackedFile.setText(root._ackWritePending)
          root._ackWritePending = ""
        } catch (e) { /* lost ack: warning simply re-appears */ }
      }
    }
  }

  FileView {
    id: ackedFile
    path: root.ackStateDir + "/acked-health.json"
    watchChanges: true
    printErrors: false

    onLoaded: function() {
      try {
        var parsed = JSON.parse(ackedFile.text())
        root.ackedHealth = Array.isArray(parsed) ? parsed : []
      } catch (e) {
        root.ackedHealth = []
      }
    }
    onLoadFailed: function() {
      // Absent/unreadable file = nothing acknowledged.
      root.ackedHealth = []
    }
  }
  // end fork -----------------------------------------------------------------
}
