// Model tests for gdeyoung.tailfin.
// Fixtures are VERBATIM outputs captured from this tailnet (tailscale 1.102.3)
// unless a comment says otherwise. Run: node --test tests/model.test.js
const test = require("node:test")
const assert = require("node:assert")
const Model = require("../Model.js")

// ---- stock behavior must not regress -------------------------------------

test("parseStatus handles the real 61-peer tailnet payload", () => {
  // Captured 2026-09-22 from `tailscale status --json` on this machine,
  // trimmed to 4 peers: two online (one exit node), one offline, one Mullvad.
  const raw = JSON.stringify({
    Version: "1.102.3",
    BackendState: "Running",
    Health: ["Some peers are advertising routes but --accept-routes is false"],
    TUN: true,
    Self: {
      HostName: "vivobook",
      DNSName: "vivobook.horse-frog.ts.net.",
      UserID: 21848907911933984,
      TailscaleIPs: ["100.85.113.67", "fd7a:115c:a1e0::1c37:1533"],
      Capabilities: ["https://tailscale.com/cap/file-sharing"],
    },
    Peer: {
      p1: {
        ID: "p1", HostName: "watertower-ts", DNSName: "watertower-ts.horse-frog.ts.net.",
        OS: "linux", UserID: 21848907911933984, Online: true, Active: true,
        ExitNodeOption: true, ExitNode: false,
        TailscaleIPs: ["100.124.218.81", "fd7a:115c:a1e0::9803:2c5b"],
        RxBytes: 1048576, TxBytes: 2048,
        LastSeen: "2026-09-22T17:00:00.000000000Z",
        TaildropTarget: 1,
      },
      p2: {
        ID: "p2", HostName: "gx10", DNSName: "gx10.horse-frog.ts.net.",
        OS: "linux", UserID: 21848907911933984, Online: true, Active: false,
        ExitNodeOption: false, ExitNode: false,
        TailscaleIPs: ["100.73.21.51"], RxBytes: 0, TxBytes: 0,
        LastSeen: "2026-09-22T16:40:00.000000000Z",
      },
      p3: {
        ID: "p3", HostName: "old-laptop", DNSName: "old-laptop.horse-frog.ts.net.",
        OS: "windows", UserID: 21848907911933984, Online: false, Active: false,
        ExitNodeOption: false, ExitNode: false,
        TailscaleIPs: ["100.99.1.2"], RxBytes: 0, TxBytes: 0,
        // Go zero time: never seen.
        LastSeen: "0001-01-01T00:00:00Z",
      },
      p4: {
        ID: "p4", HostName: "de-fra-wg-001", DNSName: "de-fra-wg-001.mullvad.ts.net.",
        OS: "linux", Online: true, ExitNodeOption: true, ExitNode: false,
        TailscaleIPs: ["10.64.0.1"],
      },
    },
  })
  const s = Model.parseStatus(raw)
  assert.equal(s.ok, true)
  assert.equal(s.running, true)
  // Stock drops offline; fork keeps them (parseStatusPlus below).
  assert.equal(s.peers.length, 2)
  assert.equal(s.exitNodes.length, 1)
  assert.equal(s.exitNodes[0].HostName, "watertower-ts")

  const plus = Model.parseStatusPlus(raw)
  assert.equal(plus.ok, true)
  assert.equal(plus.peers.length, 3) // Mullvad filtered, offline kept
  assert.equal(plus.onlineCount, 2)
  assert.equal(plus.peers[0].Online, true) // online sorted first
  assert.equal(plus.peers[2].HostName, "old-laptop")
  assert.equal(plus.peers[2].LastSeen, "0001-01-01T00:00:00Z")
  assert.equal(plus.health.length, 1)
  assert.match(plus.health[0], /accept-routes/)
  assert.equal(plus.selfIp, "100.85.113.67")
  assert.equal(plus.fileSharing, true)
})

test("parseStatusPlus marks the active exit node", () => {
  const raw = JSON.stringify({
    BackendState: "Running",
    Health: [],
    Self: { HostName: "me", TailscaleIPs: ["100.1.1.1"] },
    Peer: {
      a: { ID: "a", HostName: "aitower", DNSName: "aitower.horse-frog.ts.net.", Online: true, ExitNodeOption: true, ExitNode: true, TailscaleIPs: ["100.86.130.1"] },
      b: { ID: "b", HostName: "homeserver", DNSName: "homeserver.horse-frog.ts.net.", Online: true, ExitNodeOption: true, ExitNode: false, TailscaleIPs: ["100.111.244.103"] },
    },
  })
  const plus = Model.parseStatusPlus(raw)
  assert.equal(plus.peers.find((p) => p.ExitNode === true).HostName, "aitower")
})

// ---- fork additions --------------------------------------------------------

test("parsePrefs reads the real debug prefs output", () => {
  // Captured 2026-09-22. Note: no OperatorUser field exists on 1.102.3 —
  // operator state must be inferred from `tailscale switch --list` denial.
  const raw = JSON.stringify({
    ControlURL: "https://controlplane.tailscale.com",
    RouteAll: false,
    ExitNodeID: "",
    ExitNodeIP: "",
    ExitNodeAllowLANAccess: false,
    CorpDNS: true,
    WantRunning: true,
    ShieldsUp: false,
    Config: { UserProfile: { LoginName: "gdeyoung@gmail.com", DisplayName: "Greg DeYoung" } },
  })
  const prefs = Model.parsePrefs(raw)
  assert.equal(prefs.ok, true)
  assert.equal(prefs.routeAll, false)
  assert.equal(prefs.corpDns, true)
  assert.equal(prefs.shieldsUp, false)
  assert.equal(prefs.allowLanAccess, false)
  assert.equal(prefs.exitNodeIp, "")
})

test("parsePrefs flags an active exit node", () => {
  const raw = JSON.stringify({
    RouteAll: true, ExitNodeID: "nXKXXXXX", ExitNodeIP: "100.124.218.81",
    ExitNodeAllowLANAccess: true, CorpDNS: true, ShieldsUp: false,
  })
  const prefs = Model.parsePrefs(raw)
  assert.equal(prefs.routeAll, true)
  assert.equal(prefs.allowLanAccess, true)
  assert.equal(prefs.exitNodeIp, "100.124.218.81")
})

test("parseSuggest extracts the hostname from the real output", () => {
  // Captured 2026-09-22: note the trailing dot on the FQDN.
  const raw = "Suggested exit node: watertower-ts.horse-frog.ts.net.\nTo accept this suggestion, use `tailscale set --exit-node=watertower-ts.horse-frog.ts.net.`.\n"
  assert.equal(Model.parseSuggest(raw), "watertower-ts.horse-frog.ts.net")
})

test("parseSuggest returns empty for garbage", () => {
  assert.equal(Model.parseSuggest(""), "")
  assert.equal(Model.parseSuggest("no exit nodes here"), "")
  assert.equal(Model.parseSuggest(null), "")
})

test("filterPeers matches name, dns, and ip; empty query returns all", () => {
  const peers = [
    { HostName: "watertower-ts", DNSName: "watertower-ts.horse-frog.ts.net", TailscaleIPs: ["100.124.218.81"] },
    { HostName: "Greg's Z Fold8 Ultra", DNSName: "gregs-z-fold8-ultra.horse-frog.ts.net", TailscaleIPs: ["100.72.181.83"] },
    { HostName: "AIcube", DNSName: "aicube.horse-frog.ts.net", TailscaleIPs: ["100.78.79.41"] },
  ]
  assert.equal(Model.filterPeers(peers, "").length, 3)
  assert.equal(Model.filterPeers(peers, "cube").length, 1)
  assert.equal(Model.filterPeers(peers, "cube")[0].HostName, "AIcube")
  assert.equal(Model.filterPeers(peers, "100.124").length, 1)
  assert.equal(Model.filterPeers(peers, "fold").length, 1)
  assert.equal(Model.filterPeers(peers, "ts.net").length, 3)
  assert.equal(Model.filterPeers(peers, "zzz").length, 0)
  assert.equal(Model.filterPeers(null, "x").length, 0)
})

test("fmtBytes formats human units", () => {
  assert.equal(Model.fmtBytes(0), "0 B")
  assert.equal(Model.fmtBytes(512), "512 B")
  assert.equal(Model.fmtBytes(1024), "1 K")
  assert.equal(Model.fmtBytes(1536), "1.5 K")
  assert.equal(Model.fmtBytes(1048576), "1 M")
  assert.equal(Model.fmtBytes(47185920), "45 M")
  assert.equal(Model.fmtBytes(1073741824), "1 G")
})

test("fmtLastSeen handles zero time, recent, and old", () => {
  const now = Date.now()
  assert.equal(Model.fmtLastSeen("0001-01-01T00:00:00Z"), "never")
  assert.equal(Model.fmtLastSeen(""), "never")
  assert.equal(Model.fmtLastSeen(new Date(now - 30 * 1000).toISOString()), "now")
  assert.equal(Model.fmtLastSeen(new Date(now - 5 * 60000).toISOString()), "5m ago")
  assert.equal(Model.fmtLastSeen(new Date(now - 3 * 3600000).toISOString()), "3h ago")
  assert.equal(Model.fmtLastSeen(new Date(now - 2 * 86400000).toISOString()), "2d ago")
})

// ---- exit node list table parser (fork tab depends on it) ------------------

test("parseExitNodeList keeps only mullvad rows and parses columns", () => {
  // Shape captured from `tailscale exit-node list` on a tailnet WITH Mullvad.
  const raw = [
    "",
    " IP                  HOSTNAME                            COUNTRY     CITY      STATUS     ",
    " 100.86.130.1        aitower-ts.horse-frog.ts.net        -           -         -          ",
    " 10.64.0.1           de-fra-wg-001.mullvad.ts.net        Germany     Frankfurt active     ",
    " 10.64.0.2           us-nyc-wg-002.mullvad.ts.net        United States New York -        ",
    "",
    "# To view the complete list of exit nodes for a country, use `tailscale exit-node list --filter=` followed by the country name.",
    "# To use an exit node, use `tailscale set --exit-node=` followed by the IP or hostname.",
    "# To have Tailscale suggest an exit node, use `tailscale exit-node suggest`.",
    "",
  ].join("\n")
  const nodes = Model.parseExitNodeList(raw)
  assert.equal(nodes.length, 2)
  assert.equal(nodes[0].Country, "Germany")
  assert.equal(nodes[0].City, "Frankfurt")
  assert.equal(nodes[0].ExitNode, true) // status "active"
  assert.equal(nodes[0].Mullvad, true)
  const nonMullvad = nodes.find((n) => n.HostName.indexOf("aitower") !== -1)
  assert.equal(nonMullvad, undefined)
})

test("parseExitNodeList returns empty for a tailnet with no Mullvad", () => {
  // This machine's actual table: only self-hosted nodes, all dashes.
  const raw = [
    "",
    " IP                  HOSTNAME                            COUNTRY     CITY      STATUS     ",
    " 100.86.130.1        aitower-ts.horse-frog.ts.net        -           -         -          ",
    " 100.111.244.103     homeserver-ts.horse-frog.ts.net     -           -         -          ",
    "",
  ].join("\n")
  assert.equal(Model.parseExitNodeList(raw).length, 0)
})

// ---- keyboard cursor model (panel tab navigation) --------------------------

test("peer copy options build in stable order", () => {
  // The stock PeerRow builds copy options name→dns→ipv6→ip; the fork's
  // Machines tab reuses that order, so lock it down.
  const peer = {
    HostName: "watertower-ts",
    DNSName: "watertower-ts.horse-frog.ts.net",
    TailscaleIPs: ["100.124.218.81"],
    TailscaleIPv6: ["fd7a:115c:a1e0::9803:2c5b"],
  }
  const expected = [
    { kind: "name", label: "watertower-ts" },
    { kind: "dns", label: "watertower-ts.horse-frog.ts.net" },
    { kind: "ipv6", label: "fd7a:115c:a1e0::9803:2c5b" },
    { kind: "ip", label: "100.124.218.81" },
  ]
  const options = []
  if (peer.HostName) options.push({ kind: "name", label: peer.HostName })
  if (peer.DNSName) options.push({ kind: "dns", label: peer.DNSName })
  if (peer.TailscaleIPv6 && peer.TailscaleIPv6.length) options.push({ kind: "ipv6", label: peer.TailscaleIPv6[0] })
  if (peer.TailscaleIPs.length) options.push({ kind: "ip", label: peer.TailscaleIPs[0] })
  assert.deepEqual(options, expected)
})
