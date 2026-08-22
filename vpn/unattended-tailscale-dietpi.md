---
title: Unattended Tailscale Exit Nodes on DietPi
summary: Why headless Pi exit nodes silently drop off the tailnet, and a bootstrap script with watchdog and maintenance timers that keeps a fleet online without manual reboots.
emoji: 🛰️
---

# Unattended Tailscale Exit Nodes on DietPi

Headless Raspberry Pi exit nodes have a habit of quietly disappearing from the
tailnet and only coming back after someone power-cycles them. That is fine for a Pi
on your desk and useless for one deployed in another region.

This covers the two real causes of the drop-off, a one-shot bootstrap script, and
the watchdog and maintenance timers that keep nodes online unattended.

**Setup this was written against:** DietPi on a Raspberry Pi, 32GB SD card, wired
LAN to a router that reboots on a 24-hour schedule.

---

## 🔑 1. Why Nodes Drop Off

Two causes. Neither is fixed by generating a "non-expiring" auth key, which is the
usual first attempt.

### Node key expiry is not auth key expiry

These are two different keys and it is an easy trap.

| Key | What it controls | Default lifetime |
|---|---|---|
| **Auth key** (`tskey-auth-…`) | How long the key can be used to *enrol new machines* | 1–90 days, capped at 90 |
| **Node key** | The device's own identity on the tailnet | 180 days |

Setting an auth key to "no expiry" does nothing for a machine that is already
enrolled. The node's own key still expires on its own schedule and the device goes
silently offline.

> **Fix:** admin console → **Machines** → the device → `…` → **Disable key expiry**.
> Tagged devices skip this entirely — they do not key-expire by default.

Note the inverse is also true and useful: if an auth key expires, devices it already
authorised stay authorised until *their* node key expires. A dead auth key only
blocks enrolling new nodes.

### The router reboot leaves a stale connection

When the router drops, `tailscaled` can hold a socket open against a path that no
longer exists. It usually recovers on its own; occasionally it does not.

The diagnostic that separates the two causes:

```bash
sudo systemctl restart tailscaled
```

If that brings the node back, it is the stale-connection case and a watchdog fixes
it. If only a full reboot works, suspect the NIC or link layer — disabling Energy
Efficient Ethernet and enabling the hardware watchdog (both in the script) cover
that.

---

## 🎟️ 2. Getting an Auth Key

Admin console → **Settings** → **Keys** → **Generate auth key**
(`https://login.tailscale.com/admin/settings/keys`).

| Field | Set to | Why |
|---|---|---|
| Description | `pi-fleet-bootstrap` | so it can be found and revoked later |
| **Reusable** | **ON** | otherwise it is consumed by the first Pi |
| Expiration | 90 (the max) | see the cap below |
| Ephemeral | **OFF** | ephemeral nodes are *deleted* when they go offline — the opposite of the goal |
| Pre-approved | ON, only if device approval is enabled | skips a manual approve step |
| Tags | `tag:exitnode` | tagged nodes do not key-expire |

The key looks like `tskey-auth-kXXXXXXXXX-XXXXXXXXXXXXXX` and is shown once.

### Tags need an ACL entry first

Generating a tagged key fails unless the tag already exists. Admin console →
**Access controls**:

```json
"tagOwners": {
  "tag:exitnode": ["autogroup:admin"]
}
```

Save that, *then* generate the key with Tags enabled.

### For a long-lived fleet, use an OAuth client instead

Auth keys cap at 90 days, so a key-based workflow means rotating every quarter
forever. Settings → **OAuth clients**, scope `auth_keys` (write), tag
`tag:exitnode`. The client secret does not expire and can be passed straight to
`tailscale up --authkey=` — Tailscale mints a real auth key behind the scenes. Tags
are mandatory with OAuth.

---

## 📜 3. The Bootstrap Script

[`dietpi-tailscale-bootstrap.sh`](dietpi-tailscale-bootstrap.sh) — idempotent, safe
to re-run, configured entirely through environment variables.

```bash
# interactive — prints the login link
curl -fsSL https://raw.githubusercontent.com/pratiks360/tech-wiki/main/vpn/dietpi-tailscale-bootstrap.sh \
  | sudo bash

# unattended, for a remote node
curl -fsSL https://raw.githubusercontent.com/pratiks360/tech-wiki/main/vpn/dietpi-tailscale-bootstrap.sh \
  | sudo TS_AUTHKEY='tskey-auth-xxxx' TS_HOSTNAME='pi-riyadh-01' TS_ADVERTISE_TAGS='tag:exitnode' bash
```

What it sets up:

- `apt full-upgrade`, plus `curl jq ethtool`
- `net.ipv4.ip_forward` / IPv6 forwarding, required for exit-node routing
- Tailscale, with `tailscale set --auto-update` so the client patches itself
- `rx-udp-gro-forwarding on rx-gro-list off` on the default NIC — Tailscale's
  recommended exit-node throughput tuning — and EEE off to stop link flaps
- The watchdog, maintenance, and reboot timers described below
- The BCM hardware watchdog via systemd

### Key options

| Variable | Default | Notes |
|---|---|---|
| `TS_AUTHKEY` | *(empty)* | empty = print a login URL and wait |
| `TS_HOSTNAME` | `$(hostname)` | name in the admin console |
| `TS_EXIT_NODE` | `1` | advertise as exit node |
| `TS_SSH` | `1` | Tailscale SSH — the lifeline for a remote node |
| `TS_ACCEPT_DNS` | `false` | see the caveat in §7 |
| `DIETPI_UPDATE` | `0` | off on purpose — see §6 |
| `REBOOT_SCHEDULE` | `Sun *-*-* 05:15:00` | offset from the maintenance window |

---

## 🐕 4. The Watchdog

`/usr/local/sbin/ts-watchdog.sh`, fired by `ts-watchdog.timer` every 5 minutes. The
important design point is that it **distinguishes a dead WAN from a broken
Tailscale**, so the nightly router reboot does not trigger an escalation storm.

```
1. Ping 1.1.1.1 / 9.9.9.9 / 8.8.8.8
   └─ all fail → count a strike, restart networking after ~20 min, reboot if still dead
2. Is tailscaled active?          → no  → systemctl restart tailscaled
3. tailscale status --json
   ├─ BackendState=Running + Self.Online=true → healthy, reset counters
   ├─ Stopped     → tailscale up
   └─ NeedsLogin  → re-auth with stored key, or log loudly
4. Escalate on consecutive failures: 3 → restart tailscaled, 6 → reboot
```

Check on it:

```bash
systemctl list-timers ts-watchdog.timer
cat /var/lib/ts-node/watchdog.log
```

> **Logs live in `/var/lib/ts-node/`, not `/var/log/`.** DietPi mounts `/var/log`
> as tmpfs (DietPi-RAMlog), so anything written there vanishes on reboot — exactly
> the events you need after an unexplained restart. Both log files are self-trimming.

---

## 🧹 5. Maintenance and Cleanup

`pi-maintenance.timer`, weekly at `Sun 04:30` with up to 15 minutes of random jitter
so a whole fleet does not hit the mirrors simultaneously.

```bash
apt-get update -q
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
apt-get -y autoremove --purge
apt-get -y clean
journalctl --vacuum-time=7d --vacuum-size=64M
```

> **The `--force-confold` flags are what make this genuinely unattended.** Without
> them, a package whose config file changed will stop and wait for a keypress that
> will never come, and the upgrade hangs indefinitely.

Log cleanup is mostly free: DietPi-RAMlog clears `/var/log` on every reboot. The
`journalctl --vacuum` is belt-and-braces.

```bash
sudo systemctl start pi-maintenance.service   # force a run
cat /var/lib/ts-node/maintenance.log
```

---

## ⚠️ 6. dietpi-update — Off By Default

The script supports it but ships disabled:

```bash
if [ "$DIETPI_UPDATE" = "1" ] && [ -x /boot/dietpi/dietpi-update ]; then
  /boot/dietpi/dietpi-update 1 || echo "dietpi-update returned $?"
fi
```

*`/boot/dietpi/dietpi-update 1` is the non-interactive form — `1` means apply
without prompting.*

`apt` updates packages. `dietpi-update` updates DietPi's own scripts and can bump
the whole DietPi version — it restarts services through `dietpi-services`,
occasionally changes config file formats, and a failed run on a headless box with no
console access is unrecoverable remotely. On a Pi within arm's reach, run it by hand
over Tailscale SSH. On a Pi in another country, the downside of an automated failure
is a flight or a mailed SD card.

Enable it per-node if you want it:

```bash
sudo sed -i 's/^DIETPI_UPDATE=.*/DIETPI_UPDATE=1/' /usr/local/sbin/pi-maintenance.sh
```

---

## 🔧 7. Two Defaults Worth Knowing

**`TS_ACCEPT_DNS=false`.** Letting Tailscale rewrite `/etc/resolv.conf` on DietPi is
a known source of odd DNS behaviour. The cost is that MagicDNS names will not
resolve *on the Pi itself*; everything else works. Set it to `true` if the node
needs to resolve tailnet hostnames locally.

**Hardware watchdog on.** `RuntimeWatchdogSec=15` in
`/etc/systemd/system.conf.d/99-watchdog.conf`. This is the one failure a software
watchdog cannot fix — if the kernel hangs, nothing in userspace runs, including the
Tailscale watchdog. If `/dev/watchdog` is absent, the script appends
`dtparam=watchdog=on` to `config.txt` and it becomes active after the next reboot.

---

## 🚀 8. Zero-Touch Provisioning via dietpi.txt

For a Pi being shipped somewhere, skip the `curl` entirely. Before first boot, edit
`dietpi.txt` on the SD card's boot partition:

```ini
AUTO_SETUP_GLOBAL_PASSWORD=<yourpass>
AUTO_SETUP_NET_ETHERNET_ENABLED=1
AUTO_SETUP_AUTOMATED=1
AUTO_SETUP_CUSTOM_SCRIPT_EXEC=https://raw.githubusercontent.com/pratiks360/tech-wiki/main/vpn/dietpi-tailscale-bootstrap.sh
```

Flash → insert card → the node appears on the tailnet with no console session.

> **This requires `TS_AUTHKEY` to be reachable by the script**, which means either a
> private repo or a short-lived key rotated per deployment. Do not commit a
> long-lived key to a public repo.

---

## ✅ 9. Post-Install Checklist

Two things the script cannot do, both in the admin console:

1. **Machines → the device → `…` → Disable key expiry** *(skip if the node is tagged)*
2. **Machines → the device → `…` → Edit route settings → approve the Exit Node**

Then verify:

```bash
tailscale status
tailscale ip -4
systemctl list-timers | grep -E 'ts-watchdog|pi-maintenance|pi-reboot'
```

---

## 🐛 10. Troubleshooting

**Node shows offline but the Pi is up and pingable on LAN.**
Check `tailscale status` on the box. `NeedsLogin` means the node key expired — see
§1. `Stopped` means someone ran `tailscale down`.

**Exit node option is greyed out for clients.**
The route was never approved. §9, step 2.

**Exit node connects but throughput is poor.**
Confirm the NIC tuning applied: `systemctl status ts-net-tune.service`. On a Pi the
ceiling is often the USB-attached Ethernet on older models rather than Tailscale.

**Watchdog log shows repeated "no internet" strikes at the same time daily.**
That is the router's own 24-hour reboot. Expected; the watchdog counts strikes and
waits rather than escalating. Shift `REBOOT_SCHEDULE` if it overlaps.

**Everything looks healthy but the node still vanished overnight.**
Read `/var/lib/ts-node/watchdog.log` — it survives reboots, unlike `/var/log`.

---

## 📌 What Has and Has Not Been Verified

Being explicit, since this is meant to be pasted back into a terminal months later:

- **Verified:** the script is syntax-clean (`bash -n`, including both embedded
  heredoc scripts) and the Tailscale key-expiry behaviour is confirmed against
  Tailscale's current documentation.
- **Not yet run end to end on hardware.** The script has not been executed on a real
  DietPi install. Run it on a Pi you can physically reach before pointing a remote
  deployment at it.
- **Not yet tested:** the `dietpi.txt` zero-touch path in §8, and the OAuth-client
  variant of §2.
