#!/bin/bash
set -euo pipefail

SYSTEM_BIN="/usr/local/bin/kube-upgrade.sh"
SYSTEMD_SERVICE="/etc/systemd/system/kube-upgrade.service"

install -o root -g root -m 0500 \
  "/k8s/tool/kube-upgrade.sh" "$SYSTEM_BIN"

cat <<EOF > "$SYSTEMD_SERVICE"
[Unit]
Description=Kubernetes Worker Upgrade
Before=kubelet.service

[Service]
Type=simple
ExecStart=$SYSTEM_BIN

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl disable kube-upgrade.service
systemctl enable kube-upgrade.service
systemctl start kube-upgrade.service