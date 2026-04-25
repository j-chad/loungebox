#!/bin/bash
set -euo pipefail

# Get the SSH public key — prompt if not provided via env
if [ -n "${SSH_KEY:-}" ]; then
  echo "Using SSH key from environment."
else
  echo "Paste your SSH public key (from Bitwarden, etc.):"
  read -r SSH_KEY
fi

if [[ ! "$SSH_KEY" =~ ^ssh- ]]; then
  echo "Error: That doesn't look like an SSH public key (should start with ssh-)."
  exit 1
fi
echo "Using key: ${SSH_KEY:0:40}..."

# Build the seed ISO
rm -f seed.iso
mkdir -p seed
sed "s|ssh-ed25519 PLACEHOLDER_REPLACE_WITH_YOUR_PUBLIC_KEY|$SSH_KEY|" user-data.yaml > seed/user-data
cp meta-data.yaml seed/meta-data
hdiutil makehybrid -o seed.iso seed -iso -joliet -default-volume-name cidata
rm -rf seed

echo "Created seed.iso with your SSH key embedded."
