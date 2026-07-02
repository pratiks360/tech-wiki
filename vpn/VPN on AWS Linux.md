# WireGuard on Amazon Linux 2023: The Bulletproof Guide

Getting WireGuard to run flawlessly on AWS can be tricky due to hidden network traps. This guide incorporates every fix required for a stable connection (MTU sizing, UDP enforcement, DNS fallback, and the Source/Destination check).

## Phase 1: AWS Console Configuration
Before touching the terminal, AWS must be configured to allow VPN traffic to flow through the instance.

### 1. Open the Security Group (Firewall)
* Go to the **EC2 Dashboard** > **Security Groups**.
* Edit the inbound rules for your instance.
* Add a rule: **Type** = `Custom UDP`, **Port** = `51820`, **Source** = `0.0.0.0/0`. 
> **Crucial:** Ensure it is UDP, not TCP.

### 2. Disable Source/Destination Check
* Go to **EC2 Dashboard** > **Instances**.
* Check the box next to your instance.
* Click **Actions** > **Networking** > **Change source/destination check**.
* Check the box to **Stop** (disable) the check and click Save. 
> **Note:** If this is left on, AWS will silently drop all internet traffic coming from your phone.

---

## Phase 2: Server Preparation
Log into your EC2 instance via SSH to install the necessary tools and generate the master server keys.

### 1. Install packages
```bash
sudo dnf update -y
sudo dnf install wireguard-tools qrencode iptables -y
```

### 2. Generate the Server's Master Keys
```bash
mkdir -p ~/wireguard-keys && cd ~/wireguard-keys
wg genkey | tee server_private.key | wg pubkey > server_public.key
```

### 3. Create the Base Server Configuration
Copy and paste this entire block into your terminal to safely create the `/etc/wireguard/wg0.conf` file. *(This automatically inserts your server's private key and configures the `ens5` firewall rules).*

```bash
SERVER_PRIV=$(cat ~/wireguard-keys/server_private.key)
sudo bash -c "cat <<EOF> /etc/wireguard/wg0.conf
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV
MTU = 1420
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ens5 -j MASQUERADE
EOF"
```

---

## Phase 3: The Client Generator Script
To avoid formatting errors, missing newlines, or conflicting IP addresses, use this script to generate client configurations and QR codes. 

### 1. Create the script file
```bash
nano ~/wireguard-keys/add_client.sh
```

### 2. Paste the generator code
*(This is the syntax-safe version that prevents text-editor indentation errors).*

```bash
#!/bin/bash

DIR="/home/ec2-user/wireguard-keys"
read -p "Enter a name for this client (e.g., phone): " CLIENT_NAME
CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -dc 'a-zA-Z0-9_-')

if [ -z "$CLIENT_NAME" ]; then
    echo "Error: Name cannot be empty."
    exit 1
fi

SERVER_PUB=$(cat $DIR/server_public.key | tr -d '\n ')
PUBLIC_IP=$(curl -s [http://169.254.169.254/latest/meta-data/public-ipv4](http://169.254.169.254/latest/meta-data/public-ipv4))

# Find the next available IP
LAST_IP=$(sudo grep "AllowedIPs = 10.0.0." /etc/wireguard/wg0.conf | awk -F'.' '{print $4}' | awk -F'/' '{print $1}' | sort -n | tail -1)
if [ -z "$LAST_IP" ]; then LAST_IP=1; fi
CLIENT_IP="10.0.0.$((LAST_IP + 1))"

echo "Generating keys for '$CLIENT_NAME' with IP $CLIENT_IP..."

wg genkey | tee $DIR/${CLIENT_NAME}_private.key | wg pubkey > $DIR/${CLIENT_NAME}_public.key
CLIENT_PRIV=$(cat $DIR/${CLIENT_NAME}_private.key | tr -d '\n ')
CLIENT_PUB=$(cat $DIR/${CLIENT_NAME}_public.key | tr -d '\n ')

# Append to Server Config
echo "" | sudo tee -a /etc/wireguard/wg0.conf > /dev/null
echo "[Peer]" | sudo tee -a /etc/wireguard/wg0.conf > /dev/null
echo "# Client: $CLIENT_NAME" | sudo tee -a /etc/wireguard/wg0.conf > /dev/null
echo "PublicKey = $CLIENT_PUB" | sudo tee -a /etc/wireguard/wg0.conf > /dev/null
echo "AllowedIPs = $CLIENT_IP/32" | sudo tee -a /etc/wireguard/wg0.conf > /dev/null

# Create Client Config
CONF_FILE="$DIR/${CLIENT_NAME}.conf"
echo "[Interface]" > $CONF_FILE
echo "PrivateKey = $CLIENT_PRIV" >> $CONF_FILE
echo "Address = $CLIENT_IP/24" >> $CONF_FILE
echo "DNS = 208.67.222.222, 8.8.8.8" >> $CONF_FILE
echo "MTU = 1420" >> $CONF_FILE
echo "" >> $CONF_FILE
echo "[Peer]" >> $CONF_FILE
echo "PublicKey = $SERVER_PUB" >> $CONF_FILE
echo "Endpoint = ${PUBLIC_IP}:51820" >> $CONF_FILE
echo "AllowedIPs = 0.0.0.0/0" >> $CONF_FILE
echo "PersistentKeepalive = 25" >> $CONF_FILE

# Apply and Print QR
sudo systemctl enable wg-quick@wg0
sudo systemctl restart wg-quick@wg0
echo "========================================="
echo "Done! Scan the QR code below for $CLIENT_NAME:"
echo "========================================="
qrencode -t ansiutf8 < $CONF_FILE
```

### 3. Make it executable
```bash
chmod +x ~/wireguard-keys/add_client.sh
```

---

## Phase 4: Connecting Devices
Whenever you want to add a new phone, laptop, or tablet to your VPN, simply run the script:

```bash
~/wireguard-keys/add_client.sh
```

1. Type a name for the device (e.g., `ipad`).
2. Scan the massive QR code that prints to your terminal using the WireGuard app.
3. Toggle the connection on.

> **Verification:** You can verify the tunnel is actively passing data at any time by running `sudo wg show` and looking for the **latest handshake** and **transfer** statistics!