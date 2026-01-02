#!/bin/bash
set -euo pipefail

HOST_TOOL_DIR="/host-scripts/k8s/tool"
id
# Ensure host directory exists
mkdir -p "$HOST_TOOL_DIR"

# Copy scripts to hostPath
cp /install.sh "$HOST_TOOL_DIR/install.sh"
cp /kube-upgrade.sh "$HOST_TOOL_DIR/kube-upgrade.sh"

# Set execution permission for container user (non-root)
chmod 0500 "$HOST_TOOL_DIR/install.sh" "$HOST_TOOL_DIR/kube-upgrade.sh"

echo "Scripts copied to host path: $HOST_TOOL_DIR"