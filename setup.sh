#!/data/data/com.termux/files/usr/bin/bash
# create_env_termux.sh
# Interactive script to create ~/.termux_status.env safely

ENV_FILE="$HOME/.termux_status.env"

echo "Creating secure .env file at $ENV_FILE"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "# Termux dashboard environment file" > "$ENV_FILE"

read -rp "Enter your GitHub Personal Access Token: " GITHUB_TOKEN
read -rp "Enter your Vercel API Token: " VERCEL_TOKEN
read -rp "Enter your Render API Token: " RENDER_TOKEN
read -rp "Enter refresh interval (seconds, default 30): " REFRESH_INTERVAL
REFRESH_INTERVAL=${REFRESH_INTERVAL:-30}

read -rp "Enter your projects URLs (space-separated, optional): " PROJECTS
read -rp "Enter path to OSINT script (default $HOME/nightmare_pro.sh): " OSINT_SCRIPT
OSINT_SCRIPT=${OSINT_SCRIPT:-$HOME/nightmare_pro.sh}

read -rp "Enter path to WiFi tool (default $HOME/wifitool.py): " WIFI_TOOL_PY
WIFI_TOOL_PY=${WIFI_TOOL_PY:-$HOME/wifitool.py}

# Write to .env file
cat > "$ENV_FILE" <<EOF
GITHUB_TOKEN="$GITHUB_TOKEN"
VERCEL_TOKEN="$VERCEL_TOKEN"
RENDER_TOKEN="$RENDER_TOKEN"
REFRESH_INTERVAL="$REFRESH_INTERVAL"
PROJECTS="$PROJECTS"
OSINT_SCRIPT="$OSINT_SCRIPT"
WIFI_TOOL_PY="$WIFI_TOOL_PY"
EOF

echo
echo "✅ .env file created and secured with chmod 600 at $ENV_FILE"
echo "You can now run your Termux TUI dashboard script."
