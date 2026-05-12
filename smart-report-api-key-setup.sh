cat > "$HOME/install-api-key.sh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

KEY_FILE="/root/smart-report-api-key"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run this script with sudo or as root."
  echo "Example: sudo bash install-api-key.sh"
  exit 1
fi

echo "This will create/update:"
echo "  $KEY_FILE"
echo

read -r -s -p "Paste TrueNAS API key: " API_KEY
echo

if [[ -z "${API_KEY}" ]]; then
  echo "ERROR: API key cannot be empty."
  exit 1
fi

install -m 600 /dev/null "$KEY_FILE"

printf '%s\n' "$API_KEY" > "$KEY_FILE"

chown root:root "$KEY_FILE"
chmod 600 "$KEY_FILE"

echo
echo "API key saved."
echo

ls -l "$KEY_FILE"

echo
echo "Testing that root can read the file..."

if [[ -s "$KEY_FILE" ]]; then
  echo "OK: API key file exists and is not empty."
else
  echo "ERROR: API key file is empty."
  exit 1
fi
EOF

chmod +x install-api-key.sh
