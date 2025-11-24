#!/bin/bash

# GitHub Actions Self-Hosted Runner Setup Script
# Usage: ./setup_runner.sh <GITHUB_TOKEN> <REPO_URL>

set -e

GITHUB_TOKEN="$1"
REPO_URL="$2"
RUNNER_VERSION="2.311.0"

if [ -z "$GITHUB_TOKEN" ] || [ -z "$REPO_URL" ]; then
    echo "Usage: $0 <GITHUB_TOKEN> <REPO_URL>"
    echo "Example: $0 ghp_xxxx https://github.com/username/repo"
    exit 1
fi

echo "🚀 Setting up GitHub Actions Self-Hosted Runner..."

# Update system
echo "📦 Updating system packages..."
sudo apt-get update
sudo apt-get install -y curl wget git jq unzip

# Install Python 3.11
echo "🐍 Installing Python 3.11..."
sudo apt-get install -y software-properties-common
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt-get update
sudo apt-get install -y python3.11 python3.11-pip python3.11-venv python3.11-dev

# Set Python 3.11 as default
sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
sudo update-alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3.11 1

# Install additional tools
echo "🛠️ Installing additional tools..."
sudo apt-get install -y htop tree vim nano

# Create runner user
echo "👤 Creating runner user..."
sudo useradd -m -s /bin/bash runner || true
sudo usermod -aG sudo runner

# Setup runner directory
echo "📁 Setting up runner directory..."
sudo -u runner mkdir -p /home/runner/actions-runner
cd /home/runner/actions-runner

# Download GitHub Actions Runner
echo "⬇️ Downloading GitHub Actions Runner v${RUNNER_VERSION}..."
sudo -u runner curl -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz -L \
    https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz

# Extract runner
echo "📦 Extracting runner..."
sudo -u runner tar xzf actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz
sudo -u runner rm actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz

# Configure runner
echo "⚙️ Configuring runner..."
sudo -u runner ./config.sh \
    --url "$REPO_URL" \
    --token "$GITHUB_TOKEN" \
    --name "self-hosted-$(hostname)" \
    --work "_work" \
    --labels "self-hosted,linux,x64,python" \
    --unattended \
    --replace

# Install as service
echo "🔧 Installing runner as service..."
sudo ./svc.sh install runner

# Start service
echo "▶️ Starting runner service..."
sudo ./svc.sh start

# Create Python virtual environment for tests
echo "🐍 Setting up Python environment for tests..."
sudo -u runner python3 -m venv /home/runner/test-env
sudo -u runner /home/runner/test-env/bin/pip install --upgrade pip

# Set up log rotation
echo "📝 Setting up log rotation..."
sudo tee /etc/logrotate.d/github-runner > /dev/null << EOF
/home/runner/actions-runner/_diag/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 runner runner
}
EOF

# Create health check script
echo "🏥 Creating health check script..."
sudo tee /home/runner/health-check.sh > /dev/null << 'EOF'
#!/bin/bash

LOG_FILE="/var/log/runner-health.log"

check_runner_service() {
    if systemctl is-active --quiet actions.runner.*.service; then
        echo "$(date): ✅ Runner service is active" | tee -a $LOG_FILE
        return 0
    else
        echo "$(date): ❌ Runner service is not active" | tee -a $LOG_FILE
        return 1
    fi
}

check_disk_space() {
    USAGE=$(df /home/runner | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ $USAGE -lt 80 ]; then
        echo "$(date): ✅ Disk usage is acceptable ($USAGE%)" | tee -a $LOG_FILE
        return 0
    else
        echo "$(date): ⚠️ High disk usage: $USAGE%" | tee -a $LOG_FILE
        return 1
    fi
}

check_github_connectivity() {
    if curl -s --max-time 10 https://api.github.com > /dev/null; then
        echo "$(date): ✅ GitHub API is reachable" | tee -a $LOG_FILE
        return 0
    else
        echo "$(date): ❌ Cannot reach GitHub API" | tee -a $LOG_FILE
        return 1
    fi
}

# Run checks
check_runner_service
check_disk_space
check_github_connectivity

echo "$(date): Health check completed" | tee -a $LOG_FILE
EOF

sudo chmod +x /home/runner/health-check.sh
sudo chown runner:runner /home/runner/health-check.sh

# Setup cron job for health checks
echo "⏰ Setting up health check cron job..."
sudo -u runner crontab -l 2>/dev/null | { cat; echo "*/15 * * * * /home/runner/health-check.sh"; } | sudo -u runner crontab -

# Display status
echo ""
echo "🎉 GitHub Actions Runner setup completed!"
echo ""
echo "Runner Status:"
sudo systemctl status actions.runner.*.service --no-pager
echo ""
echo "Runner Logs:"
echo "  - Service logs: journalctl -u actions.runner.*.service -f"
echo "  - Runner logs: tail -f /home/runner/actions-runner/_diag/Runner_*.log"
echo "  - Health logs: tail -f /var/log/runner-health.log"
echo ""
echo "Management Commands:"
echo "  - Stop runner: sudo systemctl stop actions.runner.*.service"
echo "  - Start runner: sudo systemctl start actions.runner.*.service"
echo "  - Restart runner: sudo systemctl restart actions.runner.*.service"
echo "  - Remove runner: cd /home/runner/actions-runner && sudo -u runner ./config.sh remove --token $GITHUB_TOKEN"
