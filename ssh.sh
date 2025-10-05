#!/usr/bin/env bash
# auto_ssh_remote.sh
# Fully automated SSH server setup + ngrok tunnel + EmailJS notification

set -e

### CONFIGURATION ###
EMAILJS_SERVICE_ID="your_service_id"
EMAILJS_TEMPLATE_ID="your_template_id"
EMAILJS_USER_ID="your_public_key"
EMAIL_TO="your_email@example.com"
#####################

echo "[*] Updating system..."
sudo apt update && sudo apt upgrade -y

echo "[*] Installing dependencies..."
sudo apt install -y openssh-server wget unzip curl jq

echo "[*] Enabling SSH..."
sudo systemctl enable ssh
sudo systemctl start ssh

# Generate random strong password
PASSWORD=$(tr -dc 'A-Za-z0-9!@#$%&*' </dev/urandom | head -c 16)

echo "[*] Setting password for $USER"
echo -e "$PASSWORD\n$PASSWORD" | sudo passwd $USER

# Install ngrok if missing
if ! command -v ngrok &>/dev/null; then
  echo "[*] Installing ngrok..."
  wget -q https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-stable-linux-amd64.zip -O ngrok.zip
  unzip ngrok.zip >/dev/null
  sudo mv ngrok /usr/local/bin/
  rm ngrok.zip
fi

# Auto-authenticate ngrok (token must be set in ENV variable)
if [ -z "$NGROK_AUTHTOKEN" ]; then
  echo "[!] Please export NGROK_AUTHTOKEN before running"
  exit 1
fi
ngrok config add-authtoken "$NGROK_AUTHTOKEN"

# Start ngrok tunnel in background
nohup ngrok tcp 22 --log=stdout > ngrok.log 2>&1 &

echo "[*] Waiting for tunnel..."
sleep 10

TUNNEL_JSON=$(curl -s http://127.0.0.1:4040/api/tunnels)
HOST_PORT=$(echo "$TUNNEL_JSON" | jq -r '.tunnels[0].public_url' | sed 's#tcp://##')
HOST=$(echo $HOST_PORT | cut -d: -f1)
PORT=$(echo $HOST_PORT | cut -d: -f2)

SSH_CMD="ssh $USER@$HOST -p $PORT"

echo "============================================"
echo " SSH Server Ready!"
echo " Command: $SSH_CMD"
echo " Password: $PASSWORD"
echo "============================================"

# Send via EmailJS REST API
echo "[*] Sending credentials to $EMAIL_TO via EmailJS..."

curl -s -X POST https://api.emailjs.com/api/v1.0/email/send \
  -H 'Content-Type: application/json' \
  -d "{
    \"service_id\": \"$EMAILJS_SERVICE_ID\",
    \"template_id\": \"$EMAILJS_TEMPLATE_ID\",
    \"user_id\": \"$EMAILJS_USER_ID\",
    \"template_params\": {
        \"to_email\": \"$EMAIL_TO\",
        \"ssh_command\": \"$SSH_CMD\",
        \"ssh_password\": \"$PASSWORD\"
    }
  }"

echo "[*] Done! You’ll receive SSH details by email."
