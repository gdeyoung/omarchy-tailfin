# Tailscale+ for Omarchy

A fork of Omarchy's first-party `omarchy.tailscale` bar widget, rebuilt as a
**tabbed panel** — because a tailnet with dozens of peers and Mullvad exit
nodes does not fit one scroll.

Fork of [omarchy](https://github.com/basecamp/omarchy) (MIT) first-party
plugin `omarchy.tailscale`. Service and Model logic are kept close to
upstream so fixes flow both ways.

## What it adds over the stock widget

| Area | Stock `omarchy.tailscale` | Tailscale+ |
|---|---|---|
| Layout | One long scrolling column | **4 tabs** — only Machines scrolls |
| Health | Not shown | **HEALTH section** — live warnings from `status --json` (bar icon gets a warning badge too) |
| Preferences | None | **accept-routes / accept-dns / shields-up / allow-LAN-access toggles** (from `tailscale debug prefs`, written via `tailscale set`) |
| Exit nodes | Tailnet + Mullvad mixed | Dedicated tab: **"None (direct)"**, **`exit-node suggest` row**, tailnet nodes |
| Mullvad | Inline picker | **Own tab** with search over regions |
| Machines | List, no search | **Searchable** (name / DNS / IP), offline peers retained in a collapsed section with last-seen |
| Bar icon | crossed / warn badge | Same, plus warning badge on health issues while connected |

## Tabs

1. **Connection** — hero with on/off toggle, self identity + IPs
   (click-to-copy), health warnings, preference toggles, account switching
   and the operator authorize row.
2. **Exit Nodes** — "None (direct)", Tailscale's suggested node, and the
   tailnet's advertised exit nodes. One click to switch, spin while setting.
3. **Mullvad** — the full region list with search (tab hides itself on
   tailnets without Mullvad).
4. **Machines** — searchable peer list with OS icons, per-peer copy menu
   (name / DNS / IPv6 / IP), Taildrop send button, offline section collapsed
   by default.

## Keyboard

- `h`/`l` or arrows: switch tabs · `1`–`4`: jump to tab
- `t` toggle Tailscale · `r` refresh
- `c`/`n`/`d` copy selected peer's IP/name/DNS · `s` Taildrop to peer
- In Machines/Mullvad search: `j`/`k` move, Enter activates, Esc clears

## First run: operator authorization

Tailscale separates *reading* status (always allowed) from *changing* it
(exit nodes, up/down, preferences). The panel detects the locked state and
shows an **"Authorize Tailscale operator"** row; clicking it runs
`pkexec tailscale set --operator=$USER` — one password prompt, once per
machine. After that every control is one click. (This is the same
one-time-unlock Trayscale uses.)

Requirements: `tailscale` CLI on PATH, `wl-copy` for copy actions. Taildrop
send uses Omarchy's `omarchy-tailscale-send`.

## Install

```sh
omarchy plugin add https://github.com/gdeyoung/omarchy-tailscale
omarchy bar put gdeyoung.tailscale --section right
```

## Development

```sh
node --test tests/model.test.js     # model tests (real captured CLI output)
qmllint -I /usr/share/omarchy/shell Panel.qml Service.qml
omarchy plugin validate .
```

Deploy to `~/.config/omarchy/plugins/gdeyoung.tailscale/` then
`omarchy restart shell`. IPC verbs for testing:
`qs -p /usr/share/omarchy/shell ipc call gdeyoung.tailscale status|open|close|toggle|tab`.
