#!/bin/bash
set -euo pipefail
# Compute OS properties
OS_NAME=""
VERSION=""
DISTRO=""
pm=""
osFamily=""

# Setup files
ASSETS_DIR="/k8s/tool"
UPGRADE_STAGE=$ASSETS_DIR"/kube-upgrade-stage" # mounted on /host-scripts/ in container
UPGRADE_FLAG=$ASSETS_DIR"/kube-upgrade-target" # mounted on /host-scripts/ in container
ERROR_LOG=$ASSETS_DIR"/error_log" # mounted on /host-scripts/ in container
UNINSTALL_FLAG=$ASSETS_DIR"/uninstall"
SYSTEM_BIN="/usr/local/bin/kube-upgrade.sh"
SYSTEMD_SERVICE="/etc/systemd/system/kube-upgrade.service"

delay="3"
# ______________Functions Definitions Starts___________
function createPathIfNotExist() {
    if [ ! -d $1 ]; then
        mkdir -p $1
    fi
}
function computeOSInfo(){
    # Compute OS family
    case "$DISTRO" in
        ubuntu|debian)
            osFamily="debian"
            pm="apt"
        ;;
        centos|rhel)
            osFamily="redhat"
            pm="yum"
        ;;
        fedora)
            osFamily="fedora"
            pm="dnf"
        ;;
        opensuse)
            osFamily="opensuse"
            pm="zypper"
        ;;
        *)
        echo "Unsupported OS: $ID"
        exit 1
        ;;
    esac
}
function getLatestPatchVersion(){
    K8S_VERSION_MINOR=$1
    distro=$2
    LATEST=""

    if [ "$distro" = "apt" ]; then
        # List all versions of kubelet
        ALL_VERSIONS=$(apt list -a kubelet 2>/dev/null)

        # Official repo first
        LATEST=$(echo "$ALL_VERSIONS" \
                | awk -v ver="$K8S_VERSION_MINOR" '$1 ~ /unknown/ && $2 ~ ("^" ver) {print $2}' \
                | sort -V \
                | tail -n1)

        # Fallback if official repo not found
        if [ -z "$LATEST" ]; then
            LATEST=$(echo "$ALL_VERSIONS" \
                    | awk -v ver="$K8S_VERSION_MINOR" '$2 ~ ("^" ver) {print $2}' \
                    | sort -V \
                    | tail -n1)
        fi
    elif [ "$distro" = "yum" ]; then
        ALL_VERSIONS=$(yum --showduplicates list kubelet 2>/dev/null | awk '{print $2}')

        # Official repo first (assuming the repo name contains 'kube' or similar)
        LATEST=$(yum --showduplicates list kubelet 2>/dev/null \
                | awk -v ver="$K8S_VERSION_MINOR" '$2 ~ ("^" ver) && $1 ~ /kube/ {print $2}' \
                | sort -V \
                | tail -n1)

        # Fallback if official repo not found
        if [ -z "$LATEST" ]; then
            LATEST=$(echo "$ALL_VERSIONS" | awk -v ver="$K8S_VERSION_MINOR" '$1 ~ ("^" ver)' | sort -V | tail -n1)
        fi

    fi
    echo $LATEST
}
function updateRepo(){
    mgr=$1
    k8sVersion=$2
    if [ $mgr = "apt" ]; then

        # Set path if not exist
        createPathIfNotExist "/etc/apt/keyrings/"

        # Install kubectl, kubelet and kubeadm
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v$k8sVersion/deb/Release.key | gpg --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$k8sVersion/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list &> "/tmp/repo_update_log"
        apt update -y

    elif [ $mgr = "yum" ]; then
        # This overwrites any existing configuration in /etc/yum.repos.d/kubernetes.repo
        echo "[kubernetes]"     >> /etc/yum.repos.d/kubernetes.repo
        echo "name=Kubernetes"  >> /etc/yum.repos.d/kubernetes.repo
        echo "baseurl=https://pkgs.k8s.io/core:/stable:/v$k8sVersion/rpm/" >> /etc/yum.repos.d/kubernetes.repo
        echo "enabled=1" >> /etc/yum.repos.d/kubernetes.repo
        echo "gpgcheck=1" >> /etc/yum.repos.d/kubernetes.repo
        echo "gpgkey=https://pkgs.k8s.io/core:/stable:/v$k8sVersion/rpm/repodata/repomd.xml.key" >> /etc/yum.repos.d/kubernetes.repo
        yum update -y
    fi
    
}
function execUpgrade(){
    k8sVersion=$1
    createPathIfNotExist $ASSETS_DIR
    touch $ERROR_LOG

    if [ $osFamily = "debian" ];then
        # Update repo
        echo "state='Updating repo'" > $UPGRADE_STAGE
        echo "state_id=1" >> $UPGRADE_STAGE
        updateRepo "apt" $k8sVersion &> /tmp/upg1

        # Get the latest patch version fo the minor version
        LATEST=$(getLatestPatchVersion $k8sVersion "apt")

        # Upgrade kubeadm
        echo "state='Upgrading kubeadm'" > $UPGRADE_STAGE
        echo "state_id=2" >> $UPGRADE_STAGE
        {
            apt-mark unhold kubeadm &&
            apt-get update &&
            apt-get install -y kubeadm="$LATEST" &&
            apt-mark hold kubeadm

        } &> /tmp/upg2 || { 
            cat /tmp/upg2 >> $ERROR_LOG
            exit 1; 
        }


        # Apply upgrade
        # Worker
        echo "state='Upgrading node'" > $UPGRADE_STAGE
        if ! kubeadm upgrade node &> /tmp/upg3; then
            echo "state_id=99" >> $UPGRADE_STAGE
            cat /tmp/upg3 >> $ERROR_LOG
            exit 1
        else
            echo "state_id=4" >> $UPGRADE_STAGE
        fi

        # Upgrade the kubelet and kubectl
        echo "state='Upgrading kubectl and kubelet'" > $UPGRADE_STAGE
        echo "state_id=5" >> $UPGRADE_STAGE
        apt-mark unhold kubelet kubectl &> /tmp/upg6.1 && \
        {
            apt-get update && 
            apt-get install -y kubelet="$LATEST" kubectl
            apt-mark hold kubelet kubectl
        } &> /tmp/upg6.2 || { 
            cat /tmp/upg6.2 >> $ERROR_LOG
            exit 1; 
        }

        # restart kubelet 
        echo "state='Restarting kubectl and kubelet'" > $UPGRADE_STAGE
        echo "state_id=6" >> $UPGRADE_STAGE
        systemctl daemon-reload
        if systemctl restart kubelet &> /tmp/upg7; then
            echo "state='Restarting kubectl and kubelet successful'" > $UPGRADE_STAGE
            echo "state_id=7" >> $UPGRADE_STAGE
        else
            cat "/tmp/upg7" >> $ERROR_LOG
            exit 1
        fi


    elif [ $osFamily = "redhat" ]; then
        updateRepo "yum" $k8sVersion
    fi
}
function uninstall(){
    rm -f $SYSTEM_BIN > /dev/null
    rm -f $SYSTEMD_SERVICE > /dev/null
    rm -f $UNINSTALL_FLAG > /dev/null

    systemctl stop kube-upgrade.service
    systemctl disable kube-upgrade.service
    systemctl daemon-reload
   
}
# ______________Functions Definitions Ends_____________

if [ -f /etc/os-release ]; then
    source /etc/os-release
    OS_NAME=$NAME
    VERSION=$VERSION_ID
    DISTRO=$ID
fi

# Watch for upgrade flag
computeOSInfo


function watch_for_upgrade() {
    while true; do
        # Check for uninstall file
        [ -f $UNINSTALL_FLAG ] && { uninstall; exit; }

        # Skip if no signal file
        [ ! -f "$UPGRADE_FLAG" ] && { echo "No signal file, sleeping..."; sleep "$delay"; continue; }

        # Load key=value pairs safely
        set -a
        source "$UPGRADE_FLAG"
        set +a

        # Validate
        if [[ "${upgrade:-no}" != "yes" ]]; then
            echo "Upgrade flag not set, sleeping..."
            sleep "$delay"
            continue
        fi

        if [[ -z "${version:-}" ]]; then
            echo "No version specified, sleeping..."
            sleep "$delay"
            continue
        fi

        echo "Upgrade requested to Kubernetes version $version"

        # reset upgrade stage
        rm -f $UPGRADE_STAGE > /dev/null

        execUpgrade $version
        rm -f $UPGRADE_FLAG > /dev/null
        sleep "$delay"
    done
}

watch_for_upgrade
