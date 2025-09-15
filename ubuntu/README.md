#!/usr/bin/env bash
set -e

# Ask for password
read -s -p "Enter password for ansible user: " PASSWORD
echo
read -s -p "Confirm password: " PASSWORD2
echo
if [ "$PASSWORD" != "$PASSWORD2" ]; then
    echo "Passwords do not match"
    exit 1
fi

# Hash the password
HASH=$(openssl passwd -6 "$PASSWORD")

# Generate user-data from template
sed "s|{{PASSWORD_HASH}}|$HASH|g" user-data.template > user-data

# Create minimal meta-data
echo "instance-id: ansible-test-01" > meta-data
echo "local-hostname: ansible-vm" >> meta-data

# Create seed ISO
genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data

echo "ISO created: seed.iso"
