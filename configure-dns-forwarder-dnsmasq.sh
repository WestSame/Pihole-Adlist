#!/bin/bash
# DNS Forwarder Configuration Script for Oulun Energia - DNSmasq Version
# This script configures DNSmasq as a DNS forwarder for Azure services
# Usage: sudo ./configure-dns-forwarder-dnsmasq.sh

set -e  # Exit on any error

# Configuration variables
SQL_DOMAIN="${1:-database.windows.net}"
SERVER_IP="10.12.17.70"
ONPREM_NETWORK="10.32.86.0/24"
LOCAL_SUBNET="10.12.17.64/26"

echo "=== DNS Forwarder Configuration Script (DNSmasq) ==="
echo "SQL Domain: $SQL_DOMAIN"
echo "Server IP: $SERVER_IP"
echo "On-premises Network: $ONPREM_NETWORK"
echo "Local Subnet: $LOCAL_SUBNET"
echo "=================================================="

# Create log file
LOG_FILE="/var/log/dns-setup.log"
touch $LOG_FILE
echo "$(date): Starting DNSmasq DNS forwarder configuration" >> $LOG_FILE

# Update system packages
echo "Updating system packages..."
apt-get update -y >> $LOG_FILE 2>&1
apt-get upgrade -y >> $LOG_FILE 2>&1

# Remove BIND9 if it's installed and causing conflicts
echo "Removing any existing BIND9 installation..."
systemctl stop named >> $LOG_FILE 2>&1 || true
systemctl stop bind9 >> $LOG_FILE 2>&1 || true
systemctl disable named >> $LOG_FILE 2>&1 || true
systemctl disable bind9 >> $LOG_FILE 2>&1 || true
apt-get remove --purge -y bind9 bind9utils bind9-doc >> $LOG_FILE 2>&1 || true
apt-get autoremove -y >> $LOG_FILE 2>&1

# Install DNSmasq
echo "Installing DNSmasq..."
apt-get install -y dnsmasq dnsutils >> $LOG_FILE 2>&1

# Stop and disable systemd-resolved to avoid port 53 conflicts
echo "Stopping systemd-resolved..."
systemctl stop systemd-resolved >> $LOG_FILE 2>&1
systemctl disable systemd-resolved >> $LOG_FILE 2>&1
systemctl mask systemd-resolved >> $LOG_FILE 2>&1

# Handle resolv.conf configuration
echo "Configuring resolv.conf..."
# Remove immutable attribute if it exists
chattr -i /etc/resolv.conf 2>/dev/null || true

# Handle if resolv.conf is a symbolic link
if [ -L /etc/resolv.conf ]; then
    echo "Removing symlink /etc/resolv.conf..." >> $LOG_FILE
    unlink /etc/resolv.conf
elif [ -f /etc/resolv.conf ]; then
    echo "Backing up existing /etc/resolv.conf..." >> $LOG_FILE
    cp /etc/resolv.conf /etc/resolv.conf.backup
    rm -f /etc/resolv.conf
fi

# Create new resolv.conf pointing to localhost for DNSmasq
cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver 168.63.129.16
search internal.cloudapp.net
EOF

# Make resolv.conf immutable to prevent systemd-resolved from overwriting it
chattr +i /etc/resolv.conf 2>/dev/null || echo "Could not make resolv.conf immutable" >> $LOG_FILE

# Backup original DNSmasq configuration
echo "Backing up original DNSmasq configuration..."
cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup

# Create DNSmasq configuration
echo "Creating DNSmasq configuration..."
cat > /etc/dnsmasq.conf << EOF
# DNSmasq configuration for Azure DNS forwarding
# Oulun Energia DNS Forwarder

# Listen on all interfaces
interface=*
bind-interfaces

# Listen on port 53
port=53

# Don't read /etc/hosts
no-hosts

# Don't read /etc/resolv.conf for upstream servers (we'll specify them)
no-resolv

# Upstream DNS servers - Azure DNS
server=168.63.129.16

# Cache size (small for cost optimization)
cache-size=1000

# Log queries for debugging
log-queries

# Log to syslog
log-facility=/var/log/dnsmasq.log

# Don't forward queries for local domains
domain-needed

# Don't forward reverse lookups for private IP ranges
bogus-priv

# Expand simple names (add domain if not FQDN)
expand-hosts

# Set local domain
local=/local/

# Specific forwarding rules for Azure services
# Forward all database.windows.net queries to Azure DNS
server=/$SQL_DOMAIN/168.63.129.16

# Azure Storage Account domains
server=/blob.core.windows.net/168.63.129.16
server=/file.core.windows.net/168.63.129.16
server=/table.core.windows.net/168.63.129.16
server=/queue.core.windows.net/168.63.129.16
server=/dfs.core.windows.net/168.63.129.16

# Additional Azure domains that might be needed
server=/windows.net/168.63.129.16
server=/azure.com/168.63.129.16
server=/azure.net/168.63.129.16
server=/azurewebsites.net/168.63.129.16
server=/cloudapp.net/168.63.129.16
server=/cloudapp.azure.com/168.63.129.16

# Enable DNSSEC if supported
dnssec

# Don't poll /etc/resolv.conf for changes
no-poll

# Set TTL for local replies
local-ttl=3600

# Maximum number of concurrent DNS queries
dns-forward-max=1000

# Enable logging of upstream servers used
log-async

# Security: Only allow queries from specific networks
# This is handled by firewall rules, but adding here too
# Note: DNSmasq doesn't have sophisticated ACLs like BIND, 
# so we rely primarily on firewall rules
EOF

# Create DNSmasq hosts file for any local overrides
echo "Creating DNSmasq hosts configuration..."
cat > /etc/dnsmasq.hosts << 'EOF'
# Local DNS overrides for DNSmasq
# Format: IP_ADDRESS HOSTNAME
# Example: 192.168.1.100 myserver.local
EOF

# Update DNSmasq config to use the hosts file
echo "addn-hosts=/etc/dnsmasq.hosts" >> /etc/dnsmasq.conf

# Set proper permissions
chown root:root /etc/dnsmasq.conf
chmod 644 /etc/dnsmasq.conf
chown root:root /etc/dnsmasq.hosts
chmod 644 /etc/dnsmasq.hosts

# Create log file and set permissions
touch /var/log/dnsmasq.log
chown root:root /var/log/dnsmasq.log
chmod 644 /var/log/dnsmasq.log

# Configure log rotation for DNSmasq
cat > /etc/logrotate.d/dnsmasq << 'EOF'
/var/log/dnsmasq.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 root root
    postrotate
        systemctl reload dnsmasq
    endscript
}
EOF

# Test DNSmasq configuration
echo "Testing DNSmasq configuration..."
dnsmasq --test >> $LOG_FILE 2>&1
if [ $? -ne 0 ]; then
    echo "ERROR: DNSmasq configuration test failed!" | tee -a $LOG_FILE
    dnsmasq --test
    exit 1
fi

echo "DNSmasq configuration test passed!" | tee -a $LOG_FILE

# Check if port 53 is available
echo "Checking if port 53 is available..." | tee -a $LOG_FILE
if ss -tulpn | grep -q ":53 "; then
    echo "WARNING: Something is already listening on port 53:" | tee -a $LOG_FILE
    ss -tulpn | grep ":53 " | tee -a $LOG_FILE
    
    # Try to identify and stop conflicting services
    PROCESS_ON_53=$(ss -tulpn | grep ":53 " | head -1)
    echo "Process details: $PROCESS_ON_53" >> $LOG_FILE
    
    if echo "$PROCESS_ON_53" | grep -q "systemd-resolve"; then
        echo "systemd-resolved is still running, forcing stop..." | tee -a $LOG_FILE
        systemctl stop systemd-resolved >> $LOG_FILE 2>&1
        sleep 2
    fi
    
    # Final check
    if ss -tulpn | grep -q ":53 "; then
        echo "ERROR: Port 53 still in use after cleanup attempts" | tee -a $LOG_FILE
        ss -tulpn | grep ":53 "
        exit 1
    fi
fi

# Enable and start DNSmasq service
echo "Enabling DNSmasq service..."
systemctl enable dnsmasq >> $LOG_FILE 2>&1

echo "Starting DNSmasq service..."
systemctl start dnsmasq >> $LOG_FILE 2>&1

# Check if DNSmasq started successfully
sleep 3
if systemctl is-active --quiet dnsmasq; then
    echo "SUCCESS: DNSmasq started successfully!" | tee -a $LOG_FILE
else
    echo "ERROR: DNSmasq failed to start, checking logs..." | tee -a $LOG_FILE
    systemctl status dnsmasq --no-pager >> $LOG_FILE 2>&1
    journalctl -u dnsmasq --no-pager -n 20 >> $LOG_FILE 2>&1
    
    # Try to start with verbose logging for debugging
    echo "Attempting to start DNSmasq with debug logging..." | tee -a $LOG_FILE
    dnsmasq --no-daemon --log-queries --log-dhcp -d >> $LOG_FILE 2>&1 &
    DNSMASQ_PID=$!
    sleep 5
    kill $DNSMASQ_PID 2>/dev/null || true
    
    exit 1
fi

# Configure firewall to allow DNS traffic
echo "Configuring firewall..."
ufw allow from $ONPREM_NETWORK to any port 53 comment "DNS from on-premises" >> $LOG_FILE 2>&1
ufw allow from $LOCAL_SUBNET to any port 53 comment "DNS from local subnet" >> $LOG_FILE 2>&1
ufw allow 22/tcp comment "SSH access" >> $LOG_FILE 2>&1
ufw --force enable >> $LOG_FILE 2>&1

# Test DNS resolution
echo "Testing DNS resolution..."
echo "Testing general DNS resolution:" | tee -a $LOG_FILE
nslookup google.com 127.0.0.1 >> $LOG_FILE 2>&1
if [ $? -eq 0 ]; then
    echo "✓ General DNS resolution works" | tee -a $LOG_FILE
else
    echo "✗ General DNS resolution failed" | tee -a $LOG_FILE
fi

echo "Testing Azure SQL domain resolution:" | tee -a $LOG_FILE
nslookup $SQL_DOMAIN 127.0.0.1 >> $LOG_FILE 2>&1
if [ $? -eq 0 ]; then
    echo "✓ Azure SQL domain resolution works" | tee -a $LOG_FILE
else
    echo "✗ Azure SQL domain resolution failed" | tee -a $LOG_FILE
fi

echo "Testing Azure Storage Account domain resolution:" | tee -a $LOG_FILE
nslookup blob.core.windows.net 127.0.0.1 >> $LOG_FILE 2>&1
if [ $? -eq 0 ]; then
    echo "✓ Azure Storage Account domain resolution works" | tee -a $LOG_FILE
else
    echo "✗ Azure Storage Account domain resolution failed" | tee -a $LOG_FILE
fi

# Create monitoring script for DNS health
echo "Creating DNS health monitoring script..."
cat > /usr/local/bin/dns-health-check.sh << EOF
#!/bin/bash
# DNS Health Check Script for DNSmasq

LOG_FILE="/var/log/dns-health.log"
DATE=\$(date '+%Y-%m-%d %H:%M:%S')

# Test DNS resolution
if nslookup $SQL_DOMAIN localhost > /dev/null 2>&1; then
    echo "[\$DATE] DNS resolution test: PASS" >> \$LOG_FILE
else
    echo "[\$DATE] DNS resolution test: FAIL" >> \$LOG_FILE
    systemctl restart dnsmasq
fi

# Check DNSmasq service status
if systemctl is-active --quiet dnsmasq; then
    echo "[\$DATE] DNSmasq service: RUNNING" >> \$LOG_FILE
else
    echo "[\$DATE] DNSmasq service: STOPPED - Attempting restart" >> \$LOG_FILE
    systemctl restart dnsmasq
fi

# Check if port 53 is listening
if ss -tulpn | grep -q ":53.*dnsmasq"; then
    echo "[\$DATE] Port 53 check: PASS" >> \$LOG_FILE
else
    echo "[\$DATE] Port 53 check: FAIL - DNSmasq not listening" >> \$LOG_FILE
    systemctl restart dnsmasq
fi
EOF

chmod +x /usr/local/bin/dns-health-check.sh

# Add health check to crontab (every 5 minutes)
echo "Setting up cron job for health monitoring..."
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/dns-health-check.sh") | crontab -

# Configure automatic security updates
echo "Configuring automatic security updates..."
apt-get install -y unattended-upgrades >> $LOG_FILE 2>&1
echo 'Unattended-Upgrade::Automatic-Reboot "false";' >> /etc/apt/apt.conf.d/50unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades >> $LOG_FILE 2>&1

# Final verification
echo "Performing final verification..."

# Check service status
echo "Final DNSmasq service verification:" >> $LOG_FILE
systemctl status dnsmasq --no-pager >> $LOG_FILE
ss -tulpn | grep :53 >> $LOG_FILE

# Final status check
if systemctl is-active --quiet dnsmasq; then
    echo ""
    echo "SUCCESS: DNSmasq DNS Forwarder configuration completed successfully!"
    echo "DNSmasq is running and listening on port 53"
    
    # Show final status
    echo ""
    echo "=== Final Status ==="
    echo "Service Status:"
    systemctl is-active dnsmasq
    echo ""
    echo "Listening Ports:"
    ss -tulpn | grep :53
    echo ""
    echo "Test DNS Resolution:"
    echo "- Testing general DNS..."
    nslookup google.com 127.0.0.1 | head -5
    echo ""
    echo "- Testing Azure SQL domain..."
    nslookup $SQL_DOMAIN 127.0.0.1 | head -5
    echo ""
    echo "- Testing Azure Storage Account domain..."
    nslookup blob.core.windows.net 127.0.0.1 | head -5
    echo ""
    echo "Configuration files created:"
    echo "  - /etc/dnsmasq.conf"
    echo "  - /etc/dnsmasq.hosts"
    echo "  - /etc/resolv.conf"
    echo ""
    echo "Log files:"
    echo "  - Setup log: $LOG_FILE"
    echo "  - DNSmasq queries: /var/log/dnsmasq.log"
    echo "  - Health checks: /var/log/dns-health.log"
    echo ""
    echo "Health monitoring: Cron job runs every 5 minutes"
    echo ""
    echo "To test from on-premises network:"
    echo "  nslookup $SQL_DOMAIN $SERVER_IP"
    echo "  nslookup google.com $SERVER_IP"
    echo ""
    echo "To view live DNS queries:"
    echo "  tail -f /var/log/dnsmasq.log"
    echo ""
    echo "Firewall configured to allow DNS from:"
    echo "  - On-premises: $ONPREM_NETWORK"
    echo "  - Local subnet: $LOCAL_SUBNET"
    
else
    echo "ERROR: DNSmasq DNS Forwarder configuration failed!"
    echo "Check the log file: $LOG_FILE"
    echo "Check service status: systemctl status dnsmasq"
    exit 1
fi
