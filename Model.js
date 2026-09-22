function filterIPv4(ips) {
  var result = []
  if (!ips || typeof ips.length !== "number") return result
  for (var i = 0; i < ips.length; i++) {
    var ip = String(ips[i] || "")
    if (/^100\./.test(ip)) result.push(ip)
  }
  return result
}

function filterIPv6(ips) {
  var result = []
  if (!ips || typeof ips.length !== "number") return result
  for (var i = 0; i < ips.length; i++) {
    var ip = String(ips[i] || "")
    if (/^fd7a:115c:a1e0:/i.test(ip)) result.push(ip)
  }
  return result
}

function cleanDnsName(name) {
  var value = String(name || "")
  return value.charAt(value.length - 1) === "." ? value.slice(0, -1) : value
}

function shortDnsName(name) {
  var clean = cleanDnsName(name)
  if (clean === "") return ""
  return clean.split(".")[0] || clean
}

function displayHostName(hostName, dnsName) {
  var host = String(hostName || "")
  if (host !== "" && host.toLowerCase() !== "localhost") return host
  return shortDnsName(dnsName) || host || "Unknown"
}

function isMullvadHost(name) {
  var value = String(name || "").toLowerCase()
  var suffix = ".mullvad.ts.net"
  return value.length > suffix.length && value.indexOf(suffix) === value.length - suffix.length
}

function isMullvadPeer(peer) {
  var hostName = String((peer && peer.HostName) || "")
  var dnsName = cleanDnsName((peer && peer.DNSName) || "")
  return isMullvadHost(dnsName) || isMullvadHost(hostName)
}

function osIcon(os) {
  var value = String(os || "").toLowerCase()
  if (value === "linux") return "󰌽"
  if (value === "macos" || value === "ios") return "󰀵"
  if (value === "windows") return "󰍲"
  if (value === "android") return "󰀲"
  if (value === "mullvad") return "󰖂"
  return "󰟀"
}

function accountLabel(account) {
  if (!account) return "Unknown account"
  if (account.nickname) return String(account.nickname)
  if (account.tailnet) return String(account.tailnet)
  if (account.account) return String(account.account)
  return String(account.id || "Unknown account")
}

function loginPlan(needsLogin, authUrl) {
  var url = String(authUrl || "").trim()
  if (needsLogin === true && /^https?:\/\//.test(url)) {
    return { authUrl: url, command: [] }
  }
  return { authUrl: "", command: ["tailscale", "up"] }
}

// Taildrop is a tailnet feature the admin can turn off, so the button for it
// only makes sense when this profile actually carries the capability.
function hasFileSharing(self) {
  var capability = "https://tailscale.com/cap/file-sharing"
  var capMap = (self && self.CapMap) || null
  if (capMap && capMap[capability] !== undefined) return true
  var capabilities = (self && self.Capabilities) || []
  for (var i = 0; i < capabilities.length; i++) {
    if (String(capabilities[i]) === capability) return true
  }
  return false
}

// Tailscale grades every peer itself — offline, wrong owner, an OS without
// Taildrop, no peer API — so take its word when the status carries one, and
// fall back to same-owner for daemons too old to say.
function isTaildropTarget(peer, selfUserId) {
  var target = peer && peer.TaildropTarget
  if (typeof target === "number" && target !== 0) return target === 1
  var owner = String((peer && peer.UserID) || "")
  return owner !== "" && owner === String(selfUserId || "")
}

function peerFromStatus(id, peer) {
  return {
    id: id,
    HostName: displayHostName(peer.HostName, peer.DNSName),
    UserID: String(peer.UserID || ""),
    TaildropTarget: typeof peer.TaildropTarget === "number" ? peer.TaildropTarget : 0,
    DNSName: cleanDnsName(peer.DNSName),
    DisplayName: displayHostName(peer.HostName, peer.DNSName),
    TailscaleIPs: filterIPv4(peer.TailscaleIPs || []),
    TailscaleIPv6: filterIPv6(peer.TailscaleIPs || []),
    Online: peer.Online === true,
    OS: String(peer.OS || ""),
    Tags: peer.Tags || [],
    ExitNodeOption: peer.ExitNodeOption === true,
    ExitNode: peer.ExitNode === true,
    Mullvad: isMullvadPeer(peer)
  }
}

function sliceTableColumn(line, start, end) {
  var text = String(line || "")
  if (start < 0 || start >= text.length) return ""
  if (end < 0) return text.substring(start).trim()
  return text.substring(start, Math.min(end, text.length)).trim()
}

function parseExitNodeList(raw) {
  var lines = String(raw || "").split(/\r?\n/)
  var header = ""
  var headerIndex = -1
  for (var i = 0; i < lines.length; i++) {
    if (/^\s*IP\s+HOSTNAME\s+COUNTRY\s+CITY\s+STATUS\s*$/.test(lines[i])) {
      header = lines[i]
      headerIndex = i
      break
    }
  }
  if (headerIndex === -1) return []

  var ipStart = header.indexOf("IP")
  var hostStart = header.indexOf("HOSTNAME")
  var countryStart = header.indexOf("COUNTRY")
  var cityStart = header.indexOf("CITY")
  var statusStart = header.indexOf("STATUS")
  var byHost = {}

  for (var j = headerIndex + 1; j < lines.length; j++) {
    var line = lines[j]
    if (/^\s*$/.test(line) || /^\s*#/.test(line)) continue

    var ip = sliceTableColumn(line, ipStart, hostStart)
    var host = sliceTableColumn(line, hostStart, countryStart)
    var country = sliceTableColumn(line, countryStart, cityStart)
    var city = sliceTableColumn(line, cityStart, statusStart)
    var status = sliceTableColumn(line, statusStart, -1)
    if (!isMullvadHost(host)) continue

    byHost[host] = {
      id: "mullvad:" + host,
      HostName: host,
      DNSName: host,
      DisplayName: (city && city !== "Any" ? city + ", " : "") + country,
      TailscaleIPs: ip ? [ip] : [],
      TailscaleIPv6: [],
      Online: true,
      OS: "mullvad",
      Tags: [],
      ExitNodeOption: true,
      ExitNode: status !== "" && status !== "-",
      Mullvad: true,
      Country: country,
      City: city,
      Status: status
    }
  }

  var result = []
  for (var hostName in byHost) result.push(byHost[hostName])
  result.sort(function(a, b) {
    var countryCompare = String(a.Country).localeCompare(String(b.Country))
    if (countryCompare !== 0) return countryCompare
    return String(a.DisplayName).localeCompare(String(b.DisplayName))
  })
  return result
}

function mullvadRegionOptions(nodes) {
  var byRegion = {}
  var values = Array.isArray(nodes) ? nodes : []
  for (var i = 0; i < values.length; i++) {
    var node = values[i] || {}
    if (node.Mullvad !== true) continue
    var country = String(node.Country || "").trim()
    var city = String(node.City || "").trim()
    if (country === "") continue
    if (city === "" || city === "Any") continue

    var key = country + "\n" + city
    // Keep the selected node when a city has several servers: the region's
    // ON state must reflect the node actually in use, not whichever sorted
    // first. (existing selected → keep; new unselected → keep; otherwise
    // replace an unselected entry with the selected node.)
    if (byRegion[key]) {
      if (byRegion[key].ExitNode || node.ExitNode !== true) continue
    }

    var option = {}
    for (var propertyName in node) option[propertyName] = node[propertyName]
    option.id = "mullvad-region:" + key
    option.DisplayName = city + ", " + country
    option.Country = country
    option.City = city
    option.MullvadRegion = true
    byRegion[key] = option
  }

  var result = []
  for (var name in byRegion) result.push(byRegion[name])
  result.sort(function(a, b) {
    var countryCompare = String(a.Country).localeCompare(String(b.Country))
    if (countryCompare !== 0) return countryCompare
    return String(a.City).localeCompare(String(b.City))
  })
  return result
}

function mullvadCountryOptions(nodes) {
  return mullvadRegionOptions(nodes)
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: true, unavailable: true, message: "Disconnected" }

  try {
    var data = JSON.parse(text)
    var backendState = String(data.BackendState || "Unknown")
    var self = data.Self || {}
    var selfIps = filterIPv4(self.TailscaleIPs || data.TailscaleIPs || [])
    var peers = []
    var exitNodes = []
    var rawPeers = data.Peer || {}

    for (var id in rawPeers) {
      var peer = rawPeers[id] || {}
      var normalized = peerFromStatus(id, peer)
      if (normalized.Mullvad) continue
      if (normalized.Online) {
        peers.push(normalized)
        if (normalized.ExitNodeOption) exitNodes.push(normalized)
      }
    }

    peers.sort(function(a, b) {
      return String(a.HostName).localeCompare(String(b.HostName))
    })
    exitNodes.sort(function(a, b) {
      return String(a.HostName).localeCompare(String(b.HostName))
    })

    return {
      ok: true,
      unavailable: false,
      backendState: backendState,
      running: backendState === "Running",
      needsLogin: backendState === "NeedsLogin",
      authUrl: String(data.AuthURL || ""),
      selfName: displayHostName(self.HostName, self.DNSName),
      selfDnsName: cleanDnsName(self.DNSName),
      selfIp: selfIps.length > 0 ? selfIps[0] : "",
      selfUserId: String(self.UserID || ""),
      fileSharing: hasFileSharing(self),
      peers: peers,
      exitNodes: exitNodes
    }
  } catch (e) {
    return { ok: false, unavailable: true, message: "Status error", error: "Failed to parse tailscale status" }
  }
}

function parseAccounts(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { accounts: [], selectedAccountId: "", selectedAccountLabel: "" }

  try {
    var parsed = JSON.parse(text)
    var next = []
    var selected = null
    if (parsed && typeof parsed.length === "number") {
      for (var i = 0; i < parsed.length; i++) {
        var rawAccount = parsed[i] || {}
        var account = {
          id: String(rawAccount.id || rawAccount.ID || ""),
          nickname: String(rawAccount.nickname || rawAccount.Nickname || rawAccount.name || rawAccount.Name || ""),
          tailnet: String(rawAccount.tailnet || rawAccount.Tailnet || ""),
          account: String(rawAccount.account || rawAccount.Account || rawAccount.loginName || rawAccount.LoginName || rawAccount.user || rawAccount.User || ""),
          selected: rawAccount.selected === true || rawAccount.Selected === true
        }
        next.push(account)
        if (account.selected === true) selected = account
      }
    }
    return {
      accounts: next,
      selectedAccountId: selected ? String(selected.id || "") : "",
      selectedAccountLabel: selected ? accountLabel(selected) : ""
    }
  } catch (e) {
    return { accounts: [], selectedAccountId: "", selectedAccountLabel: "" }
  }
}

// ------------------------------------------------------- fork additions --
// Everything below is gdeyoung.tailfin on top of the stock omarchy.tailscale
// Model. Stock functions above are kept verbatim so diffs against upstream
// stay clean.

// Health warnings from status --json: non-empty strings, order preserved.
function healthList(raw) {
  var list = raw && typeof raw.length === "number" ? raw : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var item = String(list[i] || "").trim()
    if (item !== "") out.push(item)
  }
  return out
}

// parseStatusPlus — parseStatus, plus what the tabbed panel needs:
// offline peers retained (flagged Online:false) and per-peer activity,
// an online count, and health warnings. Exit-node candidates stay
// online-only: advertising an exit node from an offline peer is not a
// connection you can make.
function peerPlusFromStatus(id, peer) {
  var base = peerFromStatus(id, peer)
  base.Active = peer.Active === true
  base.RxBytes = Number(peer.RxBytes || 0)
  base.TxBytes = Number(peer.TxBytes || 0)
  base.LastSeen = String(peer.LastSeen || "")
  return base
}

function parseStatusPlus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: true, unavailable: true, message: "Disconnected" }
  try {
    var data = JSON.parse(text)
    var backendState = String(data.BackendState || "Unknown")
    var self = data.Self || {}
    var selfIps = filterIPv4(self.TailscaleIPs || data.TailscaleIPs || [])
    var all = []
    var exitNodes = []
    var onlineCount = 0
    var activeMullvadExit = ""
    var rawPeers = data.Peer || {}

    for (var id in rawPeers) {
      var peer = rawPeers[id] || {}
      var normalized = peerPlusFromStatus(id, peer)
      if (normalized.Mullvad) {
        // Mullvad nodes are excluded from the peer list, but if one is the
        // active exit node its name must still surface for the banner /
        // "None" row state.
        if (normalized.ExitNode) activeMullvadExit = String(normalized.HostName || "")
        continue
      }
      all.push(normalized)
      if (normalized.Online) {
        onlineCount += 1
        if (normalized.ExitNodeOption) exitNodes.push(normalized)
      }
    }

    all.sort(function(a, b) {
      if (a.Online !== b.Online) return a.Online ? -1 : 1
      return String(a.HostName).localeCompare(String(b.HostName))
    })
    exitNodes.sort(function(a, b) {
      return String(a.HostName).localeCompare(String(b.HostName))
    })

    return {
      ok: true,
      unavailable: false,
      backendState: backendState,
      running: backendState === "Running",
      needsLogin: backendState === "NeedsLogin",
      authUrl: String(data.AuthURL || ""),
      selfName: displayHostName(self.HostName, self.DNSName),
      selfDnsName: cleanDnsName(self.DNSName),
      selfIp: selfIps.length > 0 ? selfIps[0] : "",
      selfUserId: String(self.UserID || ""),
      fileSharing: hasFileSharing(self),
      peers: all,
      onlineCount: onlineCount,
      exitNodes: exitNodes,
      activeMullvadExit: activeMullvadExit,
      health: healthList(data.Health)
    }
  } catch (e) {
    return { ok: false, unavailable: true, message: "Status error", error: "Failed to parse tailscale status" }
  }
}

// parsePrefs — tailscale debug prefs (unprivileged on every version probed).
// Returns the four preference switches the panel exposes plus the active
// exit node identity. Operator state is NOT here: 1.102.3's prefs carry no
// OperatorUser field, so the panel infers it from `tailscale switch --list`
// being denied (the same signal the stock panel uses for its Authorize row).
function parsePrefs(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false }
  try {
    var data = JSON.parse(text)
    return {
      ok: true,
      routeAll: data.RouteAll === true,
      corpDns: data.CorpDNS === true,
      shieldsUp: data.ShieldsUp === true,
      allowLanAccess: data.ExitNodeAllowLANAccess === true,
      exitNodeIp: String(data.ExitNodeIP || ""),
      exitNodeId: String(data.ExitNodeID || "")
    }
  } catch (e) {
    return { ok: false }
  }
}

// parseSuggest — `tailscale exit-node suggest` prints plain text:
//   "Suggested exit node: watertower-ts.horse-frog.ts.net.\nTo accept..."
// The hostname is a valid --exit-node target by itself.
function parseSuggest(raw) {
  var match = String(raw || "").match(/Suggested exit node:\s*(\S+)/)
  if (!match || !match[1]) return ""
  var host = match[1]
  if (host.charAt(host.length - 1) === ".") host = host.slice(0, -1)
  return host
}

// filterPeers — Machines tab search. Matches name, DNS name, or any
// Tailscale v4 address, case-insensitively, substring semantics.
function filterPeers(peers, query) {
  var q = String(query || "").trim().toLowerCase()
  var list = Array.isArray(peers) ? peers : []
  if (q === "") return list
  var out = []
  for (var i = 0; i < list.length; i++) {
    var peer = list[i] || {}
    var haystack = (
      String(peer.HostName || "") + " " +
      String(peer.DNSName || "") + " " +
      (peer.TailscaleIPs || []).join(" ")
    ).toLowerCase()
    if (haystack.indexOf(q) !== -1) out.push(peer)
  }
  return out
}

// filterOnline — split a peer list into online/offline views (the Machines
// tab keeps offline peers in a collapsed section).
function filterOnline(peers, online) {
  var list = Array.isArray(peers) ? peers : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (!!(list[i] && list[i].Online) === !!online) out.push(list[i])
  }
  return out
}

function fmtBytes(n) {
  var value = Number(n) || 0
  if (value < 1024) return value + " B"
  var units = ["K", "M", "G", "T"]
  var u = -1
  do {
    value = value / 1024
    u += 1
  } while (value >= 1024 && u < units.length - 1)
  return (value >= 10 ? Math.round(value) : Math.round(value * 10) / 10) + " " + units[u]
}

// fmtLastSeen — Go zero time ("0001-01-01…") means tailscale has never
// seen the peer; render "never" rather than a 2000-year-old date.
function fmtLastSeen(iso) {
  var text = String(iso || "")
  if (text === "" || text.indexOf("0001-") === 0) return "never"
  var t = Date.parse(text)
  if (isNaN(t)) return "never"
  var diff = Date.now() - t
  if (diff < 0) return "now"
  var minutes = Math.floor(diff / 60000)
  if (minutes < 1) return "now"
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 30) return days + "d ago"
  return new Date(t).toISOString().slice(0, 10)
}

if (typeof module !== "undefined") {
  module.exports = {
    filterIPv4: filterIPv4,
    filterIPv6: filterIPv6,
    cleanDnsName: cleanDnsName,
    shortDnsName: shortDnsName,
    displayHostName: displayHostName,
    osIcon: osIcon,
    accountLabel: accountLabel,
    loginPlan: loginPlan,
    hasFileSharing: hasFileSharing,
    isTaildropTarget: isTaildropTarget,
    isMullvadPeer: isMullvadPeer,
    peerFromStatus: peerFromStatus,
    parseExitNodeList: parseExitNodeList,
    mullvadRegionOptions: mullvadRegionOptions,
    mullvadCountryOptions: mullvadCountryOptions,
    parseStatus: parseStatus,
    parseAccounts: parseAccounts,
    healthList: healthList,
    peerPlusFromStatus: peerPlusFromStatus,
    parseStatusPlus: parseStatusPlus,
    parsePrefs: parsePrefs,
    parseSuggest: parseSuggest,
    filterPeers: filterPeers,
    filterOnline: filterOnline,
    fmtBytes: fmtBytes,
    fmtLastSeen: fmtLastSeen
  }
}
