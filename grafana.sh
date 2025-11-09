#!/bin/bash
set -e
echo "=============================="
echo " Installing Prometheus, Grafana, Alertmanager & Node Exporter"
echo "=============================="

# ============ 0. System Update & Swap ============

# Update packages safely
sudo dnf clean all -y
sudo dnf makecache
sudo dnf update -y
sudo dnf install -y wget tar curl vim shadow-utils systemd

# Ensure enough memory by adding 1GB swap if not exists
if [ ! -f /swapfile ]; then
  echo "Creating 1GB swap file..."
  sudo fallocate -l 1G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# ============ 1. Install Prometheus ============

# Stop existing Prometheus if running
sudo systemctl stop prometheus 2>/dev/null || true

sudo useradd --no-create-home --shell /bin/false prometheus 2>/dev/null || true
sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo chown prometheus:prometheus /etc/prometheus /var/lib/prometheus

cd /tmp
curl -LO https://github.com/prometheus/prometheus/releases/download/v2.55.1/prometheus-2.55.1.linux-amd64.tar.gz
tar -xvf prometheus-2.55.1.linux-amd64.tar.gz
cd prometheus-2.55.1.linux-amd64

sudo cp -f prometheus promtool /usr/local/bin/
sudo chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool

sudo cp -r consoles/ console_libraries/ /etc/prometheus/
sudo cp -f prometheus.yml /etc/prometheus/prometheus.yml
sudo chown -R prometheus:prometheus /etc/prometheus/*

sudo tee /etc/systemd/system/prometheus.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus/ \
  --web.console.templates=/etc/prometheus/consoles \
  --web.console.libraries=/etc/prometheus/console_libraries
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl enable --now prometheus

# ============ 2. Install Grafana ============

sudo tee /etc/yum.repos.d/grafana.repo >/dev/null <<'EOF'
[grafana]
name=Grafana OSS
baseurl=https://packages.grafana.com/oss/rpm
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://packages.grafana.com/gpg.key
EOF

sudo dnf install -y grafana
sudo systemctl enable --now grafana-server

# ============ 3. Install Alertmanager ============

cd /tmp
curl -LO https://github.com/prometheus/alertmanager/releases/download/v0.27.0/alertmanager-0.27.0.linux-amd64.tar.gz
tar -xvf alertmanager-0.27.0.linux-amd64.tar.gz
cd alertmanager-0.27.0.linux-amd64

sudo cp -f alertmanager amtool /usr/local/bin/
sudo mkdir -p /etc/alertmanager /var/lib/alertmanager
sudo cp -f alertmanager.yml /etc/alertmanager/
sudo chown -R prometheus:prometheus /etc/alertmanager /var/lib/alertmanager

sudo tee /etc/systemd/system/alertmanager.service >/dev/null <<'EOF'
[Unit]
Description=Alertmanager
After=network.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager/
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl enable --now alertmanager

# ============ 4. Prometheus Alert Rules ============

sudo tee /etc/prometheus/alert.rules.yml >/dev/null <<'EOF'
groups:
  - name: example-alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Instance {{ $labels.instance }} is down"
          description: "Prometheus target {{ $labels.instance }} has been unreachable for more than 1 minute."

      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 40
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "High CPU usage detected on {{ $labels.instance }}"
          description: "CPU usage > 40% for more than 2 minutes. VALUE = {{ $value }}%"

      - alert: UnauthorizedRequests
        expr: increase(http_requests_total{status=~"401|403"}[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Unauthorized requests on {{ $labels.instance }}"
          description: "Detected unauthorized (401/403) requests in the past 5 minutes."
EOF

# ============ 5. PagerDuty Integration (Optional) ============

sudo tee /etc/alertmanager/alertmanager.yml >/dev/null <<'EOF'
route:
  receiver: pagerduty
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h

receivers:
  - name: pagerduty
    pagerduty_configs:
      - routing_key: "50d89a73e5e4490cc00564f8767e9a71"
        severity: "critical"
EOF

sudo systemctl restart alertmanager

# ============ 6. Install Node Exporter ============

sudo useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true
cd /tmp
curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
tar -xvf node_exporter-1.8.2.linux-amd64.tar.gz
cd node_exporter-1.8.2.linux-amd64
sudo cp -f node_exporter /usr/local/bin/
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

sudo tee /etc/systemd/system/node_exporter.service >/dev/null <<'EOF'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl enable --now node_exporter

# ============ 7. Final Prometheus Config ============

sudo tee /etc/prometheus/prometheus.yml >/dev/null <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]

rule_files:
  - "alert.rules.yml"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node-exporter"
    static_configs:
      - targets: ["localhost:9100"]
EOF

sudo systemctl restart prometheus

echo "=============================="
echo " Installation Completed ✅"
echo " Grafana → http://<your-ec2-public-ip>:3000 (default: admin / admin)"
echo " Prometheus → http://<your-ec2-public-ip>:9090"
echo " Alertmanager → http://<your-ec2-public-ip>:9093"
echo " Node Exporter → http://<your-ec2-public-ip>:9100/metrics"
echo "=============================="

