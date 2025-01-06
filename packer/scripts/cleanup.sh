#!/bin/bash

################################################################################
# cleanup.sh
#
# This script performs final cleanup and security hardening before template
# creation. It removes unnecessary packages, temporary files, and logs.
################################################################################

set -euo pipefail

echo "Starting cleanup process..."

# Function to safely remove packages
remove_packages() {
    for pkg in "$@"; do
        if dpkg -l | grep -q "^ii  $pkg "; then
            echo "Removing package: $pkg"
            apt-get remove -y "$pkg"
        fi
    done
}

echo "Cleaning package manager..."
# Clean package manager
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*

echo "Removing unnecessary packages..."
# Remove packages that aren't needed in a template
remove_packages \
    popularity-contest \
    installation-report \
    wireless-tools \
    wpasupplicant

echo "Cleaning system logs..."
# Clean up log files
find /var/log -type f -exec truncate --size=0 {} \;
rm -rf /var/log/*.gz /var/log/*.[0-9] /var/log/*-????????
truncate -s 0 /var/log/lastlog || true
truncate -s 0 /var/log/wtmp || true
truncate -s 0 /var/log/btmp || true

echo "Removing temporary and cache files..."
# Clean temporary and cache directories
rm -rf /tmp/* /var/tmp/*
rm -rf /var/cache/apt/*.bin
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/debconf/*-old
rm -rf /var/lib/dpkg/*-old

echo "Clearing SSH keys and host data..."
# Remove SSH host keys (will be regenerated on first boot)
rm -f /etc/ssh/ssh_host_*

# Remove any existing SSH config overrides
rm -f /etc/ssh/sshd_config.d/*.conf

# Set up SSH configuration that only allows key authentication
cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
# Security hardening for SSH
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

echo "Cleaning cloud-init data..."
# Clean cloud-init
cloud-init clean --logs
rm -rf /var/lib/cloud/*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo "Cleaning network configuration..."
# Clean network configuration
rm -f /etc/netplan/*.yaml
rm -f /etc/networkd-dispatcher/off.d/*
rm -f /etc/udev/rules.d/70-persistent-net.rules
rm -f /etc/hostname
rm -f /etc/resolv.conf

echo "Securing the system..."
# Security hardening
find /root /home -type f -name ".bash_history" -exec rm -f {} \;
find /root /home -type f -name ".viminfo" -exec rm -f {} \;
rm -f /root/.wget-hsts

# Clear command history and vim info
history -c
> ~/.bash_history
rm -f ~/.viminfo

echo "Setting up first-boot configuration..."
# Create first boot script
cat > /etc/systemd/system/firstboot.service << 'EOF'
[Unit]
Description=First Boot Setup
After=network.target cloud-init.service
ConditionPathExists=!/var/lib/firstboot-done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Create firstboot script
cat > /usr/local/sbin/firstboot.sh << 'EOF'
#!/bin/bash
set -e

# Regenerate SSH host keys
rm -f /etc/ssh/ssh_host_*
dpkg-reconfigure openssh-server

# Ensure password authentication is disabled
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/99-hardening.conf
systemctl restart sshd

# Mark first boot as done
touch /var/lib/firstboot-done

# Remove the first boot service
systemctl disable firstboot.service
rm /etc/systemd/system/firstboot.service
rm -- "$0"
EOF

# Make firstboot script executable
chmod +x /usr/local/sbin/firstboot.sh

# Enable firstboot service
systemctl enable firstboot.service

echo "Final system cleanup..."
# Final cleanup
sync
echo "Cleanup complete!"