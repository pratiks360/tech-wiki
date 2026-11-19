#!/bin/bash
# Read-only server audit. Run remotely: ssh <host> 'bash -s' < audit.sh
# Prints facts only; never prints env vars, env files, keys or tokens.
echo "## HOST $(hostname) | $(. /etc/os-release; echo $PRETTY_NAME) | $(uname -m)"
echo "## TAILSCALE"; tailscale ip -4 2>/dev/null | head -1
echo "## DOCKER"; (docker ps -a --format '{{.Names}}|{{.Image}}|{{.Ports}}|{{.Status}}|{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null || sudo -n docker ps -a --format '{{.Names}}|{{.Image}}|{{.Ports}}|{{.Status}}' 2>/dev/null) | head -60
echo "## LISTEN"; (ss -tlnpH 2>/dev/null || sudo -n ss -tlnpH 2>/dev/null) | awk '{print $4, $6}' | head -60
echo "## SYSTEMD (running, non-system)"
for u in $(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -vE '^(systemd|dbus|getty|serial|user@|ssh|cron|rsyslog|polkit|snapd|unattended|multipathd|networkd|udisks|ModemManager|packagekit|irqbalance|chrony|cloud|containerd|docker|tailscaled|fwupd|accounts|avahi|NetworkManager|wpa|bluetooth|rtkit|upower|colord|lvm|apparmor|qemu|lxd|ufw|iscsid|open-iscsi|thermald|gdm|switcheroo|power-profiles|low-memory|apport|rpcbind|snap\.oracle|dietpi|ifup|networking|haveged|fail2ban|ntp)'); do
  echo "--- $u"; systemctl cat "$u" 2>/dev/null | grep -E '^(ExecStart|WorkingDirectory|User)='
done
echo "## GIT CHECKOUTS"
for d in /opt/* /srv/* /home/*/* /root/*; do [ -d "$d/.git" ] && echo "$d -> $(git -C "$d" remote get-url origin 2>/dev/null | sed -E 's#(://)[^@/]*@#\1#')"; done
echo "## DIRS"; ls -1 /opt /srv /root /home/* 2>/dev/null | head -80
echo "## CRON"; crontab -l 2>/dev/null | grep -vE '^\s*(#|$)'
echo "## CADDY"; grep -vE '^\s*(#|$)' /etc/caddy/Caddyfile 2>/dev/null | head -40
