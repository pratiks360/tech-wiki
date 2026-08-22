#!/usr/bin/env bash
#
# dietpi-tailscale-bootstrap.sh
# One-shot bootstrap for an unattended DietPi node running Tailscale (optionally as an exit node).
#
# Usage (interactive login link):
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/dietpi-tailscale-bootstrap.sh | sudo bash
#
# Usage (fully unattended, recommended for remote sites):
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/dietpi-tailscale-bootstrap.sh \
#     | sudo TS_AUTHKEY='tskey-auth-xxxx' TS_HOSTNAME='pi-dubai-01' bash
#
# Re-running is safe (idempotent).

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment variables)
# ---------------------------------------------------------------------------
TS_AUTHKEY="${TS_AUTHKEY:-}"                     # tskey-auth-... ; empty = print login URL instead
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname)}"        # name shown in the Tailscale admin console
TS_EXIT_NODE="${TS_EXIT_NODE:-1}"                # 1 = advertise this node as an exit node
TS_SSH="${TS_SSH:-1}"                            # 1 = enable Tailscale SSH (very useful for remote sites)
TS_ACCEPT_DNS="${TS_ACCEPT_DNS:-false}"          # false = do not let Tailscale rewrite /etc/resolv.conf
TS_ADVERTISE_TAGS="${TS_ADVERTISE_TAGS:-}"       # e.g. "tag:exitnode" (tagged nodes never key-expire)
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"               # anything else you want appended to `tailscale up`

STORE_AUTHKEY="${STORE_AUTHKEY:-1}"              # 1 = keep authkey at /etc/ts-node.env (0600) for auto re-auth
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-5min}"   # how often the health check runs
NET_DOWN_REBOOT_MIN="${NET_DOWN_REBOOT_MIN:-20}" # reboot if there is no internet at all for this long
TS_FAIL_REBOOT="${TS_FAIL_REBOOT:-6}"            # reboot after N consecutive failed Tailscale health checks

MAINT_SCHEDULE="${MAINT_SCHEDULE:-Sun *-*-* 04:30:00}"   # apt update/upgrade + cleanup
REBOOT_SCHEDULE="${REBOOT_SCHEDULE:-Sun *-*-* 05:15:00}" # weekly reboot ("" disables)
DIETPI_UPDATE="${DIETPI_UPDATE:-0}"              # 1 = also run dietpi-update during maintenance (see notes)
HW_WATCHDOG="${HW_WATCHDOG:-1}"                  # 1 = enable the BCM hardware watchdog via systemd

LOGDIR="/var/lib/ts-node"
ENVFILE="/etc/ts-node.env"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[1;32m[ok]\033[0m %s\n' "$*"; }
warn(){ printf '    \033[1;33m[!!]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this as root (sudo)."

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Firmware config path differs between DietPi/RPi OS releases
BOOT_CONFIG=""
for f in /boot/firmware/config.txt /boot/config.txt; do
  [[ -f $f ]] && { BOOT_CONFIG="$f"; break; }
done

mkdir -p "$LOGDIR"

# ---------------------------------------------------------------------------
# 1. Base packages
# ---------------------------------------------------------------------------
say "Updating base system"
apt-get update -q
apt-get "${APT_OPTS[@]}" full-upgrade
apt-get "${APT_OPTS[@]}" install curl jq ethtool iputils-ping ca-certificates
ok "base packages installed"

# ---------------------------------------------------------------------------
# 2. Kernel settings needed for exit-node / subnet routing
# ---------------------------------------------------------------------------
say "Configuring IP forwarding"
cat > /etc/sysctl.d/99-tailscale.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null
ok "ip_forward enabled"

# ---------------------------------------------------------------------------
# 3. Install Tailscale
# ---------------------------------------------------------------------------
if command -v tailscale >/dev/null 2>&1; then
  say "Tailscale already installed ($(tailscale version | head -n1))"
else
  say "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled
ok "tailscaled running"

# Let Tailscale keep itself patched
tailscale set --auto-update 2>/dev/null && ok "tailscale auto-update on" || warn "auto-update not supported on this version"

# ---------------------------------------------------------------------------
# 4. Exit-node throughput tuning (UDP GRO forwarding)
# ---------------------------------------------------------------------------
if [[ $TS_EXIT_NODE == 1 ]]; then
  say "Applying exit-node network tuning"
  cat > /usr/local/sbin/ts-net-tune.sh <<'EOF'
#!/usr/bin/env bash
IFACE=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
[ -n "$IFACE" ] || exit 0
ethtool -K "$IFACE" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true
# Ethernet link flap protection: disable EEE if the NIC supports it
ethtool --set-eee "$IFACE" eee off 2>/dev/null || true
exit 0
EOF
  chmod 755 /usr/local/sbin/ts-net-tune.sh
  cat > /etc/systemd/system/ts-net-tune.service <<'EOF'
[Unit]
Description=Tailscale exit-node NIC tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ts-net-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ts-net-tune.service >/dev/null
  ok "NIC tuning applied"
fi

# ---------------------------------------------------------------------------
# 5. Save config for the watchdog
# ---------------------------------------------------------------------------
UP_ARGS="--hostname=${TS_HOSTNAME} --accept-dns=${TS_ACCEPT_DNS} --reset"
[[ $TS_EXIT_NODE == 1 ]] && UP_ARGS+=" --advertise-exit-node"
[[ $TS_SSH == 1 ]]       && UP_ARGS+=" --ssh"
[[ -n $TS_ADVERTISE_TAGS ]] && UP_ARGS+=" --advertise-tags=${TS_ADVERTISE_TAGS}"
[[ -n $TS_EXTRA_ARGS ]]     && UP_ARGS+=" ${TS_EXTRA_ARGS}"

{
  echo "TS_UP_ARGS=\"${UP_ARGS}\""
  echo "NET_DOWN_REBOOT_MIN=${NET_DOWN_REBOOT_MIN}"
  echo "TS_FAIL_REBOOT=${TS_FAIL_REBOOT}"
  if [[ $STORE_AUTHKEY == 1 && -n $TS_AUTHKEY ]]; then
    echo "TS_AUTHKEY=\"${TS_AUTHKEY}\""
  fi
} > "$ENVFILE"
chmod 600 "$ENVFILE"
ok "config written to $ENVFILE"

# ---------------------------------------------------------------------------
# 6. Bring the node up
# ---------------------------------------------------------------------------
say "Connecting to Tailscale"
# shellcheck disable=SC2086
if [[ -n $TS_AUTHKEY ]]; then
  tailscale up --authkey="$TS_AUTHKEY" $UP_ARGS
  ok "authenticated with auth key"
else
  ( tailscale up $UP_ARGS >/tmp/ts-up.log 2>&1 || true ) &
  UP_PID=$!
  AUTHURL=""
  for _ in $(seq 1 45); do
    AUTHURL=$(tailscale status --json 2>/dev/null | jq -r '.AuthURL // empty')
    [[ -n $AUTHURL ]] && break
    kill -0 "$UP_PID" 2>/dev/null || break
    sleep 2
  done
  if [[ -n $AUTHURL ]]; then
    printf '\n\033[1;33m######################################################\033[0m\n'
    printf '  OPEN THIS LINK TO AUTHENTICATE THIS NODE:\n\n  %s\n' "$AUTHURL"
    printf '\033[1;33m######################################################\033[0m\n\n'
    echo "Waiting up to 10 minutes for you to approve..."
  else
    warn "No auth URL captured. Check: cat /tmp/ts-up.log"
  fi
  for _ in $(seq 1 300); do
    [[ $(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty') == "Running" ]] && break
    sleep 2
  done
  wait "$UP_PID" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 7. Health watchdog
# ---------------------------------------------------------------------------
say "Installing Tailscale health watchdog"
cat > /usr/local/sbin/ts-watchdog.sh <<'EOF'
#!/usr/bin/env bash
# Keeps a headless Tailscale node online. Escalates: re-up -> restart daemon -> reboot.
set -uo pipefail

ENVFILE=/etc/ts-node.env
STATE=/var/lib/ts-node
LOG="$STATE/watchdog.log"
mkdir -p "$STATE"

# shellcheck disable=SC1090
[ -f "$ENVFILE" ] && . "$ENVFILE"
TS_UP_ARGS="${TS_UP_ARGS:---accept-dns=false}"
NET_DOWN_REBOOT_MIN="${NET_DOWN_REBOOT_MIN:-20}"
TS_FAIL_REBOOT="${TS_FAIL_REBOOT:-6}"

log() {
  printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"
  logger -t ts-watchdog -- "$*"
  # keep the on-disk log small (survives reboots; /var/log is tmpfs on DietPi)
  if [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

count_get() { cat "$STATE/$1" 2>/dev/null || echo 0; }
count_inc() { echo $(( $(count_get "$1") + 1 )) > "$STATE/$1"; }
count_rst() { echo 0 > "$STATE/$1"; }

internet_up() {
  for host in 1.1.1.1 9.9.9.9 8.8.8.8; do
    ping -c1 -W3 "$host" >/dev/null 2>&1 && return 0
  done
  return 1
}

# --- 1. Is the WAN even alive? Router reboots are expected, don't fight them.
if ! internet_up; then
  count_inc net_fail
  n=$(count_get net_fail)
  # watchdog runs every WATCHDOG_INTERVAL; convert minutes to run count (5 min default)
  limit=$(( NET_DOWN_REBOOT_MIN / 5 )); [ "$limit" -lt 1 ] && limit=1
  log "no internet (strike $n/$limit)"
  if [ "$n" -ge "$limit" ]; then
    log "internet down too long -> restarting networking"
    systemctl restart networking 2>/dev/null || true
    systemctl restart systemd-networkd 2>/dev/null || true
    sleep 20
    if ! internet_up; then
      log "still down -> rebooting"
      count_rst net_fail
      /sbin/reboot
    fi
  fi
  exit 0
fi
count_rst net_fail

# --- 2. Is the daemon running at all?
if ! systemctl is-active --quiet tailscaled; then
  log "tailscaled not active -> restarting"
  systemctl restart tailscaled
  exit 0
fi

# --- 3. What does the control plane think?
JSON=$(tailscale status --json 2>/dev/null)
STATE_STR=$(echo "$JSON" | jq -r '.BackendState // "Unknown"')
ONLINE=$(echo "$JSON" | jq -r '.Self.Online // false')

healthy=0
case "$STATE_STR" in
  Running)
    if [ "$ONLINE" = "true" ]; then healthy=1; else log "Running but Self.Online=false"; fi
    ;;
  Stopped)
    log "backend Stopped -> tailscale up"
    # shellcheck disable=SC2086
    tailscale up $TS_UP_ARGS >/dev/null 2>&1 || true
    ;;
  NeedsLogin)
    if [ -n "${TS_AUTHKEY:-}" ]; then
      log "NeedsLogin -> re-authenticating with stored key"
      # shellcheck disable=SC2086
      tailscale up --authkey="$TS_AUTHKEY" $TS_UP_ARGS >/dev/null 2>&1 || true
    else
      log "NeedsLogin and no stored auth key - MANUAL ACTION REQUIRED"
    fi
    ;;
  *)
    log "backend state: $STATE_STR"
    ;;
esac

if [ "$healthy" = "1" ]; then
  [ "$(count_get ts_fail)" != "0" ] && log "recovered, tailscale healthy"
  count_rst ts_fail
  exit 0
fi

count_inc ts_fail
n=$(count_get ts_fail)
log "unhealthy (strike $n/$TS_FAIL_REBOOT)"

if [ "$n" -ge "$TS_FAIL_REBOOT" ]; then
  log "too many failures -> rebooting"
  count_rst ts_fail
  /sbin/reboot
elif [ "$n" -ge 3 ]; then
  log "restarting tailscaled"
  systemctl restart tailscaled
fi
exit 0
EOF
chmod 755 /usr/local/sbin/ts-watchdog.sh

cat > /etc/systemd/system/ts-watchdog.service <<'EOF'
[Unit]
Description=Tailscale connectivity watchdog
After=tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ts-watchdog.sh
EOF

cat > /etc/systemd/system/ts-watchdog.timer <<EOF
[Unit]
Description=Run Tailscale watchdog every ${WATCHDOG_INTERVAL}

[Timer]
OnBootSec=3min
OnUnitActiveSec=${WATCHDOG_INTERVAL}
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now ts-watchdog.timer >/dev/null
ok "watchdog every ${WATCHDOG_INTERVAL}"

# ---------------------------------------------------------------------------
# 8. Maintenance (apt, logs, optional dietpi-update)
# ---------------------------------------------------------------------------
say "Installing maintenance job"
cat > /usr/local/sbin/pi-maintenance.sh <<EOF
#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
LOG=${LOGDIR}/maintenance.log
DIETPI_UPDATE=${DIETPI_UPDATE}
EOF
cat >> /usr/local/sbin/pi-maintenance.sh <<'EOF'
mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1
echo "=== $(date -Is) maintenance start ==="

apt-get update -q
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
apt-get -y autoremove --purge
apt-get -y clean

journalctl --vacuum-time=7d --vacuum-size=64M

if [ "$DIETPI_UPDATE" = "1" ] && [ -x /boot/dietpi/dietpi-update ]; then
  echo "--- dietpi-update ---"
  /boot/dietpi/dietpi-update 1 || echo "dietpi-update returned $?"
fi

# trim the maintenance log
tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
echo "=== $(date -Is) maintenance done ==="
EOF
chmod 755 /usr/local/sbin/pi-maintenance.sh

cat > /etc/systemd/system/pi-maintenance.service <<'EOF'
[Unit]
Description=Unattended system maintenance
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pi-maintenance.sh
EOF

cat > /etc/systemd/system/pi-maintenance.timer <<EOF
[Unit]
Description=Weekly unattended maintenance

[Timer]
OnCalendar=${MAINT_SCHEDULE}
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now pi-maintenance.timer >/dev/null
ok "maintenance: ${MAINT_SCHEDULE}"

# ---------------------------------------------------------------------------
# 9. Scheduled reboot
# ---------------------------------------------------------------------------
if [[ -n $REBOOT_SCHEDULE ]]; then
  say "Scheduling weekly reboot"
  cat > /etc/systemd/system/pi-reboot.service <<'EOF'
[Unit]
Description=Scheduled reboot

[Service]
Type=oneshot
ExecStart=/sbin/shutdown -r +1 "Scheduled maintenance reboot"
EOF
  cat > /etc/systemd/system/pi-reboot.timer <<EOF
[Unit]
Description=Scheduled reboot timer

[Timer]
OnCalendar=${REBOOT_SCHEDULE}
RandomizedDelaySec=5min
Persistent=false

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now pi-reboot.timer >/dev/null
  ok "reboot: ${REBOOT_SCHEDULE}"
fi

# ---------------------------------------------------------------------------
# 10. Hardware watchdog (recovers from kernel hangs)
# ---------------------------------------------------------------------------
if [[ $HW_WATCHDOG == 1 ]]; then
  say "Enabling hardware watchdog"
  mkdir -p /etc/systemd/system.conf.d
  cat > /etc/systemd/system.conf.d/99-watchdog.conf <<'EOF'
[Manager]
RuntimeWatchdogSec=15
RebootWatchdogSec=2min
EOF
  if [[ ! -e /dev/watchdog && -n $BOOT_CONFIG ]]; then
    grep -q '^dtparam=watchdog=on' "$BOOT_CONFIG" || echo 'dtparam=watchdog=on' >> "$BOOT_CONFIG"
    warn "watchdog enabled in $BOOT_CONFIG - active after next reboot"
  fi
  systemctl daemon-reexec || true
  ok "hardware watchdog configured"
fi

# ---------------------------------------------------------------------------
# 11. Wi-Fi power save off (harmless on ethernet-only nodes)
# ---------------------------------------------------------------------------
if command -v iw >/dev/null 2>&1 && ip link show wlan0 >/dev/null 2>&1; then
  cat > /etc/systemd/system/wifi-powersave-off.service <<'EOF'
[Unit]
Description=Disable Wi-Fi power saving
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iw dev wlan0 set power_save off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now wifi-powersave-off.service >/dev/null 2>&1 || true
  ok "wifi power save disabled"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
say "Done"
echo
tailscale status || true
echo
cat <<EOF
Node name : ${TS_HOSTNAME}
Tailscale : $(tailscale ip -4 2>/dev/null || echo 'not connected yet')
Watchdog  : systemctl list-timers ts-watchdog.timer
Logs      : ${LOGDIR}/watchdog.log , ${LOGDIR}/maintenance.log

Remaining manual steps in the Tailscale admin console (https://login.tailscale.com/admin/machines):
  1. Machine -> "..." -> Disable key expiry   <-- do this, it is the #1 cause of silent drop-offs
  2. Machine -> "..." -> Edit route settings -> approve the Exit Node
EOF
