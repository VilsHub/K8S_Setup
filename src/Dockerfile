FROM python:3.11-slim

# Install runtime deps only (NO sudo)
RUN apt-get update && apt-get install -y \
      curl \
      iproute2 \
    && pip install --no-cache-dir fastapi uvicorn \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Image-only location for installer artifacts
RUN mkdir -p /opt/kube-installer

# Copy agent and scripts
COPY agent.py /opt/kube-installer/agent.py
COPY install.sh /opt/kube-installer/install.sh
COPY kube-upgrade.sh /opt/kube-installer/kube-upgrade.sh

# Ensure scripts are executable
RUN chmod 500 /opt/kube-installer/*.sh

# Create non-root user for runtime
RUN useradd -u 1001 -m -s /usr/sbin/nologin kubeuser

# Runtime container is non-root
USER 1001

WORKDIR /opt/kube-installer

# ONLY start the API here
CMD ["uvicorn", "agent:app", "--host", "0.0.0.0", "--port", "8080"]