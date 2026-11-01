---
title: Adding a Non-DietPi Node to the Tailscale Fleet
summary: Reuse the DietPi bootstrap script on an Ubuntu/Debian cloud VM (OCI free e2-micro) with the Pi-only parts switched off, plus swap, firewall and reclamation gotchas.
emoji: ☁️
---

# Adding a Non-DietPi Node to the Tailscale Fleet

[`unattended-tailscale-dietpi.md`](unattended-tailscale-dietpi.md) builds an
unattended Tailscale exit-node fleet out of Raspberry Pis running DietPi. This covers
adding a machine that is **not** one of those: an Ubuntu or Debian cloud VM, written
against an Oracle Cloud (OCI) Always Free `VM.Standard.E2.1.Micro` (1 GB RAM, 2
vCPU, Ubuntu 24.04).

The good news is that the same script works. Most of its Pi-specific parts are
guarded or fail harmlessly. What changes is a handful of environment overrides and a
few cloud-only traps, and those are what this page is for.

---

## 🧭 1. What Carries Over and What Doesn't

| Part of the bootstrap | On a cloud VM | Action |
|---|---|---|
| `apt full-upgrade`, `curl jq ethtool` | Works (Ubuntu is Debian-family) | none |
| IP forwarding sysctl | Works | none |
| Tailscale install + `--auto-update` | Works | none |
| NIC tuning (`rx-udp-gro-forwarding`, EEE off) | Each `ethtool` call ends in `\|\| true`; EEE and GRO tuning mean little on a virtual NIC | none |
| Watchdog timer | Works. It also tries `systemctl restart networking`, which does not exist on Ubuntu, but the call ends in `\|\| true` and `systemd-networkd` is restarted right after | none |
| Maintenance timer | Works, but overlaps Ubuntu's own `unattended-upgrades` | see §4 |
| Weekly reboot timer | Not wanted on a VM that also runs services | `REBOOT_SCHEDULE=""` |
| BCM hardware watchdog | **No `/dev/watchdog` on a cloud VM** | `HW_WATCHDOG=0` |
| `dietpi-update` | Does not exist | `DIETPI_UPDATE=0` (already the default) |
| Wi-Fi power-save | Skipped automatically (no `wlan0`) | none |

---

## 🛠️ 2. Before Running It

### Add swap first (1 GB machines)

`apt full-upgrade` unpacks kernels and rebuilds the initramfs, which will push a 1 GB
VM into heavy swap-less thrashing. On the test node this made SSH sessions drop
(`Connection reset by peer`) and sent the load average above 25. Add swap **before**
the bootstrap, not after:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -m
```

*OCI's Ubuntu images ship with no swap at all, which is why this is needed.*

### Run it inside tmux

A dropped SSH session kills a foreground `apt` run half-way through, which is the
worst way to leave a package database. `tmux` (or `screen`) keeps it alive:

```bash
sudo apt-get install -y tmux
tmux new -s bootstrap
```

Reattach with `tmux attach -t bootstrap` after a disconnect.

### Tag and key

Same as the DietPi guide, §2: a reusable, non-ephemeral auth key with
`tag:exitnode`, after adding the tag to `tagOwners` in the ACL. Tagged nodes do not
key-expire, so there is nothing to disable afterwards.

---

## 🚀 3. Run the Bootstrap

Read the script before piping it to root. This downloads it first:

```bash
curl -fsSL https://raw.githubusercontent.com/pratiks360/tech-wiki/main/vpn/dietpi-tailscale-bootstrap.sh -o /tmp/ts-bootstrap.sh
less /tmp/ts-bootstrap.sh
```

Then, with the three non-DietPi overrides:

```bash
sudo TS_AUTHKEY='tskey-auth-xxxx' \
     TS_HOSTNAME='oci-mum-01' \
     TS_ADVERTISE_TAGS='tag:exitnode' \
     HW_WATCHDOG=0 \
     REBOOT_SCHEDULE='' \
     DIETPI_UPDATE=0 \
     bash /tmp/ts-bootstrap.sh
```

Omit `TS_AUTHKEY` to get a login link instead. Pick a hostname that names the
provider and region (`oci-mum-01`), so the admin console stays readable next to
`pi-riyadh-01`.

> **`TS_SSH` defaults to `1`.** That turns on Tailscale SSH, which is useful, but the
> normal `sshd` on port 22 stays as it is. Keep it that way until Tailscale SSH has
> been tested from another device. Do not close the public SSH path first.

---

## 🧱 4. Cloud-Specific Gotchas

### No scheduled reboot means pending kernels

The Pi fleet reboots weekly, which is how kernel updates take effect. With
`REBOOT_SCHEDULE=""` a new kernel installed by `full-upgrade` sits unused until
someone reboots. Check and reboot at a time that suits the services on the box:

```bash
[ -f /var/run/reboot-required ] && echo "reboot needed"
```

### Two updaters

Ubuntu already runs `unattended-upgrades`. If it and `pi-maintenance.timer` run at
the same moment, one waits on the `dpkg` lock or fails. Either keep both (the
maintenance timer carries a random delay of up to 15 minutes) or turn the Ubuntu one
off: `sudo systemctl disable --now unattended-upgrades`. Do not leave the choice
implicit.

### `/var/log` is not volatile here

The DietPi guide keeps its logs in `/var/lib/ts-node/` because DietPi puts `/var/log`
on tmpfs. That reason does not apply on Ubuntu, but the script still writes to
`/var/lib/ts-node/`, so look there:

```bash
cat /var/lib/ts-node/watchdog.log
systemctl list-timers | grep -E 'ts-watchdog|pi-maintenance'
```

### Cloud firewall and the VM's own firewall

- **OCI security list / NSG:** Tailscale needs no inbound rule. Outbound UDP 41641
  helps nodes reach each other directly. Without it traffic still works through
  Tailscale's relay servers (DERP), only slower. The default VCN allows all egress.
- **Guest firewall:** OCI's Ubuntu images ship an iptables ruleset that ends the
  `FORWARD` chain with a `REJECT`. Tailscale inserts its own rules ahead of it, so
  an exit node normally works. If a client connects to the exit node but loads
  nothing, look here first:

  ```bash
  sudo iptables -S FORWARD | head
  ```

### Free-tier idle reclamation

Oracle says it may reclaim Always Free compute instances that sit idle for a
sustained period. Check Oracle's current Always Free terms for the exact thresholds,
since they change. An exit node that carries real traffic helps; one that does
nothing for weeks may not be safe.

---

## ✅ 5. Post-Install Checklist

1. Admin console → **Machines** → the node → `…` → **Edit route settings** → approve
   the **Exit Node**.
2. Confirm it is tagged (`tag:exitnode`), which means no key-expiry step.
3. Verify on the box:

```bash
tailscale status
tailscale ip -4
systemctl list-timers | grep -E 'ts-watchdog|pi-maintenance'
sudo systemctl status ts-net-tune.service
```

4. From another tailnet device, pick the node as the exit node and check the public
   IP at a site such as `https://ifconfig.me`.

---

## 🐛 6. Troubleshooting

**SSH drops during the upgrade.**
Memory pressure. Add swap (§2) and run inside `tmux`.

**The script stopped half-way through `apt`.**
Re-run it. It is idempotent. If `dpkg` reports it was interrupted, run
`sudo dpkg --configure -a` first.

**Exit node approved but clients get no internet.**
Check the `FORWARD` chain (§4) and that `net.ipv4.ip_forward` is `1`.

**`hw watchdog` warnings in the log.**
You ran without `HW_WATCHDOG=0`. Remove `/etc/systemd/system.conf.d/99-watchdog.conf`
and run `sudo systemctl daemon-reexec`.

---

## 🩹 Already Ran It Without the Overrides?

The first run on `mumbai-oci-2` used the DietPi defaults. It installed a weekly
reboot timer and a systemd hardware-watchdog config, neither of which a cloud VM
wants (there is no `/dev/watchdog`). Remove them:

```bash
sudo systemctl disable --now pi-reboot.timer
sudo rm -f /etc/systemd/system/pi-reboot.{timer,service} /etc/systemd/system.conf.d/99-watchdog.conf
sudo systemctl daemon-reload && sudo systemctl daemon-reexec
```

Everything else the script installed (`ts-watchdog.timer`, `pi-maintenance.timer`,
`ts-net-tune.service`) is fine to keep.

---

## 📌 What Has and Has Not Been Verified

- **Verified by running it** on an OCI `e2-micro` (Ubuntu 24.04, 1 GB, with 2 GB swap):
  the script completes and registers the node as a tagged exit node with Tailscale
  SSH on; `ts-watchdog.timer`, `pi-maintenance.timer` and `ts-net-tune.service` are
  active; IP forwarding is on; and the cleanup above removes the reboot timer and
  watchdog config without affecting Tailscale.
- **Verified:** swap fixes the SSH drops and thrashing seen during large `apt` or build
  jobs on a 1 GB VM.
- **Verified:** on this image `FORWARD` ends in a `REJECT`, with Tailscale's
  `ts-forward` chain jumped to before it (§4).
- **Verified:** after approving the route, a client connected through the node as its
  exit node and traffic flowed (§5, step 4). The `FORWARD` `REJECT` did not get in the way.
- **Not yet verified:** the Oracle idle-reclamation thresholds, and the run with the §3
  overrides from the start (the first run used the defaults).
