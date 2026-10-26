
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="v4.44-9807-rtm"
ARCHIVE="softether-vpnserver-v4.44-9807-rtm-2025.04.16-linux-x64-64bit.tar.gz"
URL="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/${VERSION}/${ARCHIVE}"
INSTALL_DIR="/usr/local/vpnserver"
SERVICE="softether-vpnserver"
HUB="VPN"
VPN_USER="client1"
VPN_PORT="1194"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash setup-softether.sh"
  exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "Error: this script requires an x86_64 VPS."
  exit 1
fi

if [[ -e "$INSTALL_DIR/vpnserver" ]]; then
  echo "SoftEther already exists at $INSTALL_DIR; refusing to overwrite it."
  exit 1
fi

read -r -p "Type YES to install SoftEther VPN Server: " confirm </dev/tty
[[ "$confirm" == "YES" ]] || exit 1

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates wget tar build-essential gcc make \
  libssl-dev libreadline-dev libncurses5-dev \
  libncursesw5-dev zlib1g-dev

WORK="$(mktemp -d /tmp/softether-install.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading SoftEther ${VERSION}..."
wget -q --show-progress "$URL" -O "$WORK/softether.tar.gz"
mkdir "$WORK/extract"
tar -xzf "$WORK/softether.tar.gz" -C "$WORK/extract"

SRC="$WORK/extract/vpnserver"
if [[ ! -d "$SRC" ]]; then
  echo "Error: expected vpnserver directory not found in archive."
  exit 1
fi

echo "Compiling SoftEther. Accept its license prompts if you agree."
cd "$SRC"
make

if [[ ! -x "$SRC/vpnserver" || ! -x "$SRC/vpncmd" ]]; then
  echo "Error: compilation did not produce vpnserver and vpncmd."
  exit 1
fi

install -d -m 700 "$INSTALL_DIR"
cp -a "$SRC/." "$INSTALL_DIR/"
chown -R root:root "$INSTALL_DIR"
chmod 600 "$INSTALL_DIR"/*
chmod 700 "$INSTALL_DIR/vpnserver" "$INSTALL_DIR/vpncmd"

cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=SoftEther VPN Server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/vpnserver start
ExecStop=${INSTALL_DIR}/vpnserver stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE"

for i in $(seq 1 20); do
  if "$INSTALL_DIR/vpncmd" localhost:5555 /SERVER /CMD ServerInfoGet >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! systemctl is-active --quiet "$SERVICE"; then
  journalctl -u "$SERVICE" --no-pager -n 60
  exit 1
fi

# Generate credentials locally; never place secrets in the GitHub repository.
ADMIN_PASS="$(openssl rand -hex 24)"
HUB_PASS="$(openssl rand -hex 24)"
CLIENT_PASS="$(openssl rand -hex 24)"
CREDS="/root/softether-credentials.txt"

# Set the initial server administrator password.
"$INSTALL_DIR/vpncmd" localhost:5555 /SERVER \
  /CMD ServerPasswordSet "$ADMIN_PASS"

# Create the virtual hub.
"$INSTALL_DIR/vpncmd" localhost:5555 /SERVER \
  "/PASSWORD:$ADMIN_PASS" \
  /CMD HubCreate "$HUB" "/PASSWORD:$HUB_PASS"

# Configure the hub in one vpncmd session.
# The temporary file contains secrets and is deleted immediately afterward.
CMDS="$(mktemp /root/softether-commands.XXXXXX)"
chmod 600 "$CMDS"
trap 'rm -rf "$WORK"; rm -f "${CMDS:-}"' EXIT

cat > "$CMDS" <<EOF
Hub $HUB
SecureNatEnable
UserCreate $VPN_USER /GROUP:none /REALNAME:none /NOTE:none
UserPasswordSet $VPN_USER /PASSWORD:$CLIENT_PASS
EOF

"$INSTALL_DIR/vpncmd" localhost:5555 /SERVER \
  "/PASSWORD:$ADMIN_PASS" "/IN:$CMDS"

rm -f "$CMDS"
unset CMDS

# Keep only the chosen TCP listener.
"$INSTALL_DIR/vpncmd" localhost:5555 /SERVER \
  "/PASSWORD:$ADMIN_PASS" /CMD ListenerDisable 443

"$INSTALL_DIR/vpncmd" localhost:5555 /SERVER \
  "/PASSWORD:$ADMIN_PASS" /CMD ListenerDisable 992

# Disable the separately exposed management listener last.
"$INSTALL_DIR/vpncmd" localhost:5555 /SERVER \
  "/PASSWORD:$ADMIN_PASS" /CMD ListenerDisable 5555

cat > "$CREDS" <<EOF
SoftEther VPN Server
Hub: $HUB
Username: $VPN_USER
VPN transport: TCP
VPN port: $VPN_PORT

Server administrator password: $ADMIN_PASS
Virtual Hub administrator password: $HUB_PASS
VPN client password: $CLIENT_PASS

Connect using your VPS public IP and TCP port $VPN_PORT.
Keep this file secret.
EOF
chmod 600 "$CREDS"

echo
echo "Installation finished."
systemctl --no-pager --full status "$SERVICE" || true
echo
echo "Credentials saved to: $CREDS"
echo "Read them with: cat $CREDS"
echo
echo "Check TCP listeners:"
ss -lntp | grep -E ':(1194|443|992|5555)\b' || true
echo
echo "IMPORTANT: allow inbound TCP $VPN_PORT in your VPS provider firewall."
echo "SecureNAT is enabled; verify client connectivity before relying on this server."
