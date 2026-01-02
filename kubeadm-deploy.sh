#!/bin/bash
# Compute OS properties
OS_NAME=""
VERSION=""
DISTRO=""
socketFile=""
containerRuntimeVersion=""
pm=""
osFamily=""
upgradeVersions=()
validChain=1
allNodes=()
otherNodes=()
CONTROL_PLANES=()
WORKERS=()
ORDERED_NODES=()
declare -A nodeTypes

# Compute variables
NODE_COUNT=""
server_name=$(hostname)
server_name=${server_name,,} 
nodeVersion=""

# Setup directory
trackDir="config"
setupDir=/tmp/k8s-setup
dependenciesDir=/tmp/k8s-setup/dependencies
formatFile=/tmp/k8s-setup/formatFile
error_log=/tmp/k8s-setup/error_log
usedRuntime=""

# ______________Functions Definitions Starts___________
function createPathIfNotExist() {
    if [ ! -d $1 ]; then
        mkdir -p $1
    fi
}
function isTracked(){
    nodeName=$1
    version=$2
    local tracked=0
    trackFile="${trackDir}/${nodeName}_${version}.track"
    if [ -f $trackFile ]; then
        tracked=1
    fi
    
    echo $tracked
}
function trackUpgrade(){
    nodeName=$1
    version=$2
    trackFile="${trackDir}/${nodeName}_${version}.track"
    touch $trackFile
}
function downloadContainerd() {
    # $1 can either be "new" or "upgrade"
    downloadFor=$1
    setupDir=$2
    dependenciesDir=$3

    # Not found
    echo "Visit the link to see the available versions to use, : https://github.com/containerd/containerd/releases/"
    check=0
    repoLink=""
    while [ $check -eq 0 ]; do

        read -p "Please specify the version of Containerd to be installed (e.g. 1.6.24): " containerdVersion
        containerRuntimeVersion=$containerdVersion
        echo "Checking if the Containerd version '$containerdVersion' is avaialble for installation...."
        repoLink="https://github.com/containerd/containerd/releases/download/v$containerdVersion/containerd-$containerdVersion-linux-amd64.tar.gz"
        wget -O $setupDir/ctdf $repoLink | &> /dev/null
        cat $setupDir/ctdf | grep -i "Not Found" &> /dev/null
        ec=$?

        if [ $ec -eq 0 ]; then
            # Not Found
            echo "Containerd with the version '$containerdVersion' is not found, kindly confirm the version specified"
        else
            check=1
            echo -e "Containerd '$containerdVersion' found for installation"
        fi
    done


    # Install your CR (Container Runtime), preferred is containerd [https://github.com/containerd/containerd/blob/main/docs/getting-started.md]
    cp $setupDir/ctdf $dependenciesDir/containerd-$containerdVersion-linux-amd64.tar.gz
    
    targetInstallationPath=/usr/local
    
    if [ $downloadFor = "upgrade" ]; then
        # Get the service file
        serviceFile=$(systemctl show --property=FragmentPath -p FragmentPath "containerd" | cut -d= -f2)
        execPath=$(cat $serviceFile | grep -w "ExecStart")
        trimmed_execPath="${execPath#ExecStart=}"
        
        installedPath=$(dirname $trimmed_execPath)

        trimmed_installedPath="${installedPath%/bin}"

        systemctl stop containerd

        tar -xzvf $dependenciesDir/containerd-$containerdVersion-linux-amd64.tar.gz -C $trimmed_installedPath

    else

        tar -xzvf $dependenciesDir/containerd-$containerdVersion-linux-amd64.tar.gz -C $targetInstallationPath

    fi


    if [ $downloadFor = "new" ]; then
        # Setup containerd service
        wget -O $dependenciesDir/containerd.service --no-check-certificate https://raw.githubusercontent.com/containerd/containerd/main/containerd.service

        install $dependenciesDir/containerd.service /etc/systemd/system

        mkdir -p /etc/containerd
    fi

}
function downloadHelm() {
    setupDir=$1
    dependenciesDir=$2

    # Not found
    echo "Visit the link to see the available Helm versions to use, : https://github.com/helm/helm/releases"
    check=0
    repoLink=""
    while [ $check -eq 0 ]; do

        read -p "Please specify the version of Helm to be installed (e.g. 3.7.2) or press ENTER to install the default version (3.7.2): " HelmVersion

        repoLink="https://get.helm.sh/helm-v$HelmVersion-linux-amd64.tar.gz"

        if [ ${#HelmVersion} -gt 0 ]; then
            # Version specified
            curl -I $repoLink &> $setupDir/hlmf

            cat $setupDir/hlmf | grep -i "404" &> /dev/null
            ec=$?

            if [ $ec -eq 0 ]; then
                # Not Found
                echo -e "\nHelm with the version '$HelmVersion' is not found, kindly confirm the version specified, or press ENTER to install the default version (3.7.2)"
            else
                check=1
                echo -e "Helm '$HelmVersion' found for installation"
            fi

        elif [ ${#HelmVersion} -eq 0  ]; then
            # No version specified, use default version
            HelmVersion="3.7.2"
            repoLink="https://get.helm.sh/helm-v$HelmVersion-linux-amd64.tar.gz"
            check=1
        fi
    done

    # Download Helm
    echo "Installing Helm v$HelmVersion"
    wget -O $dependenciesDir/helm-v$HelmVersion-linux-amd64.tar.gz $repoLink
    tar -xvf $dependenciesDir/helm-v$HelmVersion-linux-amd64.tar.gz -C $dependenciesDir
    mv $dependenciesDir/linux-amd64/helm /usr/bin/
    echo -e "\nHelm installation completed\n"
}
function setupContainerd(){
    # $1 can either be "new", "current" and "upgrade"
    installationType=$1
    which containerd &> /dev/null
    ec=$?

    # Set path if not exist
    createPathIfNotExist "/etc/containerd/"
    
    if [ $ec -eq 1 ]; then 
        # Not found in standard path
        /usr/local/bin/containerd config default > /etc/containerd/config.toml
    else
        # Found  
        containerd config default > /etc/containerd/config.toml
    fi

    # Setup containerd to make use of the CGROUP DRIVER, that is Setting SystemdCgroup = true in /etc/containerd/config.toml

    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

    if [ $installationType = "new" ]; then
        systemctl daemon-reload
        systemctl enable --now containerd
        systemctl start containerd
    elif [ $installationType = "upgrade" ]; then
        systemctl daemon-reload
        systemctl enable --now containerd
        systemctl restart containerd
    else 
        systemctl restart containerd
    fi
    
}
function isRunning(){
    serviceName=$1
    state=$2

    systemctl status $serviceName | grep -w "$state" &> /dev/null
    ec=$?

    if [ $ec -eq 0 ]; then
        status="yes"
    else
        status="no"
    fi
    
    echo $status

}
function disabledFirewall(){
    targetFirewall=$1
    which "$targetFirewall" &> /dev/null
    ec=$?
    if [ $ec -eq 0 ]; then
        # ufw exist, check if it is running
        if [ $(isRunning "$targetFirewall" "Active: active") = "yes" ]; then
            echo "${targetFirewall^^} firewall found running, disabling in progress......"
            systemctl stop "$targetFirewall"
            systemctl disable "$targetFirewall" &&
            echo "${targetFirewall^^}  firewall disabled successfully!"
        else
            echo "${targetFirewall^^}  firewall found not running.......state OK!"
        fi
    fi
}
function getSocket(){

    crtSelectedOpt=$1
    returnType=$2  # 1=> socket, 2=> runtimetype
    containerRuntime=""
    socketFile=""

    if [ $crtSelectedOpt = "1" ]; then
        containerRuntime="containerd"
        socketFile="unix:///var/run/containerd/containerd.sock"
    elif [[ $crtSelectedOpt = "2"  ]]; then
        containerRuntime="docker"
        socketFile="unix:///var/run/containerd/containerd.sock"
    else
        containerRuntime="crio"
        socketFile="unix:///var/run/crio/crio.sock"
    fi

    if [ $returnType = "1" ]; then #Return socket
        echo $socketFile
    else # Return runtime
        echo $containerRuntime
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
function initializeDir(){
    if [ ! -d $setupDir ]; then
        mkdir -p $setupDir
        mkdir -p $dependenciesDir
    fi
}
function updateRepo(){
    mgr=$1
    k8sVersion=$2
    if [ $mgr = "apt" ]; then

        # Set path if not exist
        createPathIfNotExist "/etc/apt/keyrings/"

        # Install kubectl, kubelet and kubeadm
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v$k8sVersion/deb/Release.key | gpg --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$k8sVersion/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
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
function setupK8s(){
    setupType=$1
    PS3="Please select the environment node type: "
    envNodeType=("Master" "Worker")
    entSelectedOpt=0
    intializeCluster=0
    selectedNode=""

    select res in "${envNodeType[@]}"; do
        entSelectedOpt=$((REPLY))
        
        while [ $entSelectedOpt -gt 2 ]; do
            PS3="Please select a valid option for the environment node type: "
            select res in "${envNodeType[@]}"; do
                entSelectedOpt=$((REPLY))
                break
            done
        done
        
        # Set selection
        if [ $entSelectedOpt = "1" ]; then
            selectedNode="master"
        else
            selectedNode="worker"
        fi

        break
    done

    # Check if firewall is enabled
    # UFW firewal check
    echo  -e "Checking if Firewall is disabled......\n"
    disabledFirewall ufw
    disabledFirewall firewalld
    echo  "Firewall check completed successfully!"

    if [[ $setupType = "1"  && $entSelectedOpt = "1" ]]; then
        # setupType 1 = setup and initialize, entSelectedOpt 1 = master
        echo -e "\n"
        read -p "Please specify the server private IP address: " privateIP
        read -p "Please specify this server's public IP address, for accesibility over the internet. To skip press ENTER: " publicIP
        echo -e "\n"
        intializeCluster=1
    fi
   

    

    containerRuntime=""
    socketFile=""

    runtimeType=$(selectContainerRuntime)
    socketFile=$(getSocket $runtimeType 1)
    containerRuntime=$(getSocket $runtimeType 2)
    usedRuntime=$containerRuntime

    # Prerequisite : wget
    which wget &> /dev/null
    ec=$?

    if [ $ec -gt 0 ]; then
        # Install wget
        $pm install wget -y
    fi

    # Prerequisite : gpg
    which gpg &> /dev/null
    ec=$?

    if [ $ec -gt 0 ]; then
        # Install gpg
        $pm install gpg -y
    fi

    initializeDir

    # Compute runtime version to be downloaded

    echo -e "\n"
    echo -e "Setting up K8S with $containerRuntime.....\n"
    if [ $containerRuntime = "crio" ]; then
        # [Setup link: https://cri-o.io/]

        echo "Visit the link to see the available versions to use: https://download.opensuse.org/repositories/isv:/cri-o:/stable:/"
        
        check=0
        repoLink=""
        while [ $check -eq 0 ]; do

            read -p "Please specify the version of CRI-O to be installed (e.g. 1.28): " crioVersion

            containerRuntimeVersion=$crioVersion

            echo "Checking if the CRIO version '$crioVersion' is avaialble for installation...."
            
            repoKey="https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v$crioVersion/deb/Release.key"
            
            if [[ $osFamily == "redhat" || $osFamily == "debian" ]]; then
                wget -O $setupDir/tz $repoKey | &> /dev/null
                cat $setupDir/tz | grep "ERROR 404" &> /dev/null
                ec=$?

                if [ $ec -eq 0 ]; then
                    # Not Found
                    echo "CRI-O with the version '$crioVersion' is not found, kindly confirm the version specified"
                else
                    check=1
                    echo -e "CRI-O version '$crioVersion' found for installation"
                fi
            fi
        done

        # Begin downloading CRI-O runtime
        if [ $osFamily == "redhat" ]; then

            # CentOS       
            
            # Write CRI-O config below to the file /etc/yum.repos.d/cri-o.repo

                # [cri-o]
                # name=CRI-O
                # baseurl=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/rpm/
                # enabled=1
                # gpgcheck=1
            
            printf "[cri-o]\nname=CRI-O\nbaseurl=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v$crioVersion/rpm/\nenabled=1\ngpgcheck=1\ngpgkey=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v$crioVersion/rpm/repodata/repomd.xml.key\n" | tee /etc/yum.repos.d/cri-o.repo > /dev/null
            
            yum update -y
            yum install -y cri-o

        elif [ $osFamily == "debian" ]; then

            # Set path if not exist
            createPathIfNotExist "/etc/apt/keyrings"

            curl -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v$crioVersion/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

            echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v$crioVersion/deb/ /" | tee /etc/apt/sources.list.d/cri-o.list

            apt-get update -y
            apt-get install -y cri-o 

        fi

        # Enable and start crio service
        systemctl enable crio
        systemctl start crio

    elif [ $containerRuntime = "docker" ]; then
        #_____________________Setup docker___________________________

        if [ $osFamily == "redhat" ]; then
            repoFile="/etc/yum.repos.d/docker-ce.repo"

            if [ -e $repoFile ]; then
                sed -i -e 's/baseurl=https:\/\/download\.docker\.com\/linux\/\(fedora\|rhel\)\/$releasever/baseurl\=https:\/\/download.docker.com\/linux\/centos\/$releasever/g' /etc/yum.repos.d/docker-ce.repo
            else
                yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            fi

            yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

            systemctl start docker
            
        elif [ $osFamily == "debian" ]; then
            # Debian installation
            apt update -y
            apt install -y docker.io
        fi

        # Configure containerd
        if [ ! -d "/etc/containerd/" ]; then
            mkdir "/etc/containerd/"
        fi

        containerd config default > /etc/containerd/config.toml

        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

        # Enable containerd service
        systemctl daemon-reload
        systemctl enable --now containerd
        systemctl start containerd

        service containerd start

    elif [ $containerRuntime = "containerd" ]; then
        #_____________________Setup contianerd_______________________   

        # Check if CR (Container Runtime) is installed
        which containerd &> /dev/null
        ec=$?

        if [ $ec -gt 0 ]; then 
            
            # Not found
            downloadContainerd "new" $setupDir $dependenciesDir
            setupContainerd "new"

        else
            # Installed
            installedContainerdVersion=$(containerd --version | cut -d' ' -f3)
            containerRuntimeVersion=$installedContainerdVersion

            read -p "Your current containerd version is '$installedContainerdVersion', would you like to setup with this version, press "ENTER" or "y" for yes, and "n" for No, y/ENTER/n: " downloadNewVersion

            if [[ $downloadNewVersion = "n" || $downloadNewVersion = "N" ]]; then
                downloadContainerd "upgrade" $setupDir $dependenciesDir    
                setupContainerd "upgrade" 
            else
                setupContainerd "current" 
            fi

        fi

    fi

    # Choose kubelet version

    compatiblityDocLink=""

    if [ $containerRuntime = "containerd" ]; then
        compatiblityDocLink="https://containerd.io/releases/#kubernetes-support"
    else
        compatiblityDocLink="https://github.com/cri-o/cri-o?tab=readme-ov-file#compatibility-matrix-cri-o--kubernetes"
    fi

    echo -e "\nVisit the link (https://github.com/kubernetes/kubernetes/tags) to see the available versions of Kubelet to use, and for compatiblity with $containerRuntime version $containerRuntimeVersion see: $compatiblityDocLink \n"

        
    check=0
    k8sKey=""
    k8sVersion=""
    while [ $check -eq 0 ]; do

        read -p "Please specify the version (must be compatible with $containerRuntime v$containerRuntimeVersion) of Kubelet to be installed (Major.Minor only e.g. 1.28): " kubeletVersion
        echo "Checking if the Kubelet version '$kubeletVersion' is avaialble for installation...."
            
        debKeyLink="https://pkgs.k8s.io/core:/stable:/v$kubeletVersion/deb/Release.key"
        
        rpmKeyLink="https://pkgs.k8s.io/core:/stable:/v$kubeletVersion/rpm/repodata/repomd.xml.key"
        
        targetLink=$( [ $osFamily == "redhat" ] && echo $debKeyLink  || echo $rpmKeyLink)
        
        if [[ $osFamily == "redhat" || $osFamily == "debian" ]]; then
            wget -O $setupDir/tz $targetLink | &> /dev/null
            cat $setupDir/tz | grep "END PGP PUBLIC KEY BLOCK" &> /dev/null
            ec=$?

            if [ $ec -eq 0 ]; then
                check=1
                echo -e "Kubelet version '$kubeletVersion' found for installation"
                k8sKey=$targetLink
                k8sVersion=$kubeletVersion
            else
                # Not Found
                echo "Kubelet with the version '$kubeletVersion' is not found, kindly confirm the version specified"
            fi
        fi
    done


    # Disable Swap
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    swapoff -a

    # Update repository
    $pm update -y

    # Install CRI
    if [ $containerRuntime != "docker" ]; then 
        # Setup CRI if docker is not selected for runtime

        #  Install your CRI (Container Runtime Interface), preferred is cri-ctl [https://github.com/kubernetes-sigs/cri-tools/blob/master/docs/crictl.md] 
        VERSION="v1.28.0" # check latest version in /releases page
        wget -O $dependenciesDir/crictl-$VERSION-linux-amd64.tar.gz https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz
        tar -zxvf $dependenciesDir/crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin
    fi

    # Setup CM
    # Check if runc (Container Manager used by container runtime) is installed
    which runc &> /dev/null
    ec=$?

    if [ $ec -eq 1 ]; then 
        # Not found
        # Install runc  (Container Manager used by container runtime)
        wget -O $dependenciesDir/runc.amd64 https://github.com/opencontainers/runc/releases/download/v1.1.9/runc.amd64
        install -m 755 $dependenciesDir/runc.amd64 /usr/local/sbin/runc
    fi


    # REGISTER CRI endpoints [to fix access issue e.g running crictl ps]
    # Write to the file '/etc/crictl.yaml' the below contents
    # runtime-endpoint: $socketFile
    # image-endpoint: $socketFile
    # timeout: 2
    # debug: false
    # pull-image-on-create: false
    printf "runtime-endpoint: $socketFile\nimage-endpoint: $socketFile\ntimeout: 2\ndebug: false\npull-image-on-create: false" | tee /etc/crictl.yaml > /dev/null


    # Forwarding IPv4 and letting iptables see bridged traffic [https://kubernetes.io/docs/setup/production-environment/container-runtimes/#forwarding-ipv4-and-letting-iptables-see-bridged-traffic]
    # Write to the file '/etc/modules-load.d/k8s.conf' the below contents
    # overlay
    # br_netfilter
    printf "overlay\nbr_netfilter\n" | tee /etc/modules-load.d/k8s.conf

    # > sysctl params required by setup, params persist across reboots
    # Write to the file '/etc/sysctl.d/k8s.conf' the below contents
    # net.bridge.bridge-nf-call-iptables  = 1
    # net.bridge.bridge-nf-call-ip6tables = 1
    # net.ipv4.ip_forward                 = 1
    printf "net.bridge.bridge-nf-call-iptables  = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward                 = 1\n" | tee /etc/sysctl.d/k8s.conf
    

    modprobe overlay
    modprobe br_netfilter


    # Disable SELINUX for Redhat
    if [ -f "/etc/selinux/config" ]; then
        # Set SELINUX=disabled 
        sed -i 's/\(SELINUX=\).*/\1disabled/' /etc/selinux/config
        setenforce 0
    fi

    # > Apply sysctl params without reboot
    sysctl --system

    # Install KubeADM, Kubelet and Kubectl
    if [ $osFamily = "debian"  ]; then

        apt update -y

        # Install dependencies for CoreDNS
        apt install -y apt-transport-https ca-certificates curl #

        updateRepo "apt" $k8sVersion

        computeClusterVersionAndInstall "apt" $k8sVersion

    elif [ $osFamily = "redhat" ]; then 

        updateRepo "yum" $k8sVersion

        yum install yum-utils ca-certificates curl
        dnf install dnf-plugins-core &> /dev/null

        computeClusterVersionAndInstall "yum" $k8sVersion

    fi


    # Pull required containers
    kubeadm config images pull --cri-socket="$socketFile"

    sleep 20s

    systemctl enable kubelet
    systemctl start kubelet

    if [ $intializeCluster -eq 1 ]; then

        # initialize the master node control plane configurations: (Master node)
        IPADDR=$privateIP
        POD_CIDR="10.244.0.0/16"

        initializeCluster $IPADDR $socketFile $publicIP

    elif [[ $setupType = "1"  && $selectedNode = "worker" ]]; then
        
        # Worker node with join option
        echo -e "K8s setup on worker completed successfully"
        echo "Initiating Joining Worker to existing cluster...."
        joinWorkerToCluster
    elif [ $setupType = "2" ]; then
         echo -e "\nK8s setup on $selectedNode node completed successfully.... Initialize your cluster when ready\n"
    fi
}
function selectContainerRuntime(){
    prompt1=${1:- "Please select your preferred container runtime: "}
    prompt2=${2:- "Please select a valid option for the container runtime type to be used for the setup: "}

    PS3=$prompt1
    containerRuntimeType=("Containerd" "Containerd with Docker (Not stable yet)" "CRI-O")
    crtSelectedOpt=0

    select res in "${containerRuntimeType[@]}"; do
        crtSelectedOpt=$((REPLY))
        while [ $crtSelectedOpt -gt 3 ]; do
            PS3=$prompt2
            select res in "${containerRuntimeType[@]}"; do
                crtSelectedOpt=$((REPLY))
                break
            done
        done
        break
    done

    echo $crtSelectedOpt

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
function computeClusterVersionAndInstall(){
    distro=$1
    K8S_VERSION_MINOR=$2

    if [ "$distro" = "apt" ]; then

        LATEST=$(getLatestPatchVersion $K8S_VERSION_MINOR $distro)
        echo "Installing Kubernetes version: $LATEST"
        apt install -y kubelet="$LATEST" kubeadm="$LATEST" kubectl="$LATEST"
        apt-mark hold kubelet kubeadm kubectl

    elif [ "$distro" = "yum" ]; then

        LATEST=$(getLatestPatchVersion $K8S_VERSION_MINOR $distro)
        echo "Installing Kubernetes version: $LATEST"
        yum install -y kubelet-$LATEST kubeadm-$LATEST kubectl-$LATEST

    fi
}
function initializeCluster(){
    local IPADDR=$1
    local socketFile=$2
    local publicIP=$3

    POD_CIDR="10.244.0.0/16"

    if [ ${#publicIP} -gt 0 ];then
        # has public IP
        param="--apiserver-cert-extra-sans=$publicIP --control-plane-endpoint=$publicIP:6443"
    fi

    echo -e "\nInitializing the control plane...."
 
    kubeadm init --apiserver-advertise-address=$IPADDR $param --pod-network-cidr=$POD_CIDR --cri-socket=$socketFile > worker_node_token.txt
    cat worker_node_token.txt | grep "initialized successfully!"
    ec=$?
    if [ $ec -eq 0 ]; then

        echo "Control plane initialized successfully... Now performing post operations"

        # Post installation
        mkdir -p $HOME/.kube
        cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        chown $(id -u):$(id -g) $HOME/.kube/config

        # Install any of the network add (Install CNI [Container Network Interface] plugins) on at [https://kubernetes.io/docs/concepts/cluster-administration/addons/] preferably Flannel (Master node)
        echo -e "\nSetting up CNI with Flannel"
        kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

        echo -e "\n"
        # Request to Untaint the master node
        read -p "Would you like to untaint this master node (Y/N)?: " untaintNode

        if [[ $untaintNode = "y" || $untaintNode = "Y" ]]; then
            echo -e "Untainting master node....."
            kubectl taint node $server_name node-role.kubernetes.io/control-plane:NoSchedule-
        fi

        # Install Helm and run on the master node only
        read -p "Would you like to setup Helm repo manager for this cluster (Y/N)?: " setupHelm
        
        if [[ $setupHelm = "y" || $setupHelm = "Y" ]]; then
            res=0
            while [ $res -eq 0 ]; do
                downloadHelm $setupDir $dependenciesDir
                res=1
            done

            which helm &> /dev/null
            ec=$?

            if [ $ec -eq 0 ]; then
                # Installed helm
                echo -e "\nPost operation completed successfully...\n"
            else
                # Installation failed helm
                echo -e "\nPost operation failed... Try installing helm manually\n"
            fi
        fi
    else
        echo -e "There was a problem initiating the control plane"
    fi
}
function joinWorkerToCluster(){

    echo -e "\n"
    read -p "Please specify the master node reachable IP address: " reachableIP
    
    read -p "Please specify the token value: " tokenValue
    read -p "Please specify the token hash (begining with sha256:xxxx): " tokenHash
    echo -e "\n"
    
    kubeadm join "$reachableIP:6443" --token "$tokenValue" --discovery-token-ca-cert-hash "$tokenHash" --cri-socket="$selectContainerRuntime"
}
function xRead(){
    file=$1
    echo ""
    cat $file
}
function computeClusterVersionChain(){
    local current="$1"
    local target="$2"
    local versions=()

    local cur_major=${current%.*}
    local cur_minor=${current#*.}
    local tgt_major=${target%.*}
    local tgt_minor=${target#*.}
    local result=""

    if (( cur_major != tgt_major )); then
        echo "❌ Multi-major upgrade not supported"
        return 1
    fi

    for ((v=cur_minor; v<=tgt_minor; v++)); do
        versions+=("$cur_major.$v")
    done

    upgradeVersions=("${versions[@]}")

    # Remove the 1st element
    unset 'upgradeVersions[0]'
    upgradeVersions=("${upgradeVersions[@]}")

    # Build chain
    for v in "${versions[@]}"; do
        if [[ -z "$result" ]]; then
            result="v$v"
        else
            result+=" → v$v"
        fi
    done

    echo "Upgrade path: $result"
}
function verifyK8sVersion(){
    version=$1
    debKeyLink="https://pkgs.k8s.io/core:/stable:/v$version/deb/Release.key"
    rpmKeyLink="https://pkgs.k8s.io/core:/stable:/v$version/rpm/repodata/repomd.xml.key"
    targetLink=$( [ $osFamily == "redhat" ] && echo $debKeyLink  || echo $rpmKeyLink )
    found=0
    
    if [[ $osFamily == "redhat" || $osFamily == "debian" ]]; then
        wget -q -O $setupDir/ty $targetLink > /dev/null
        cat $setupDir/ty | grep "END PGP PUBLIC KEY BLOCK" > /dev/null 
        ec=$?

        if [ $ec -eq 0 ]; then
            found=1
        else
            # Not Found
            found=0
        fi
    fi

    echo $found
}
function validateVersionChain(){
    result=""
    validChain=1
    for version in "${upgradeVersions[@]}"; do
        versionExist=$(verifyK8sVersion "$version")
        if [ $versionExist == "0" ]; then
            result+="❌ v$version is not available"$'\n'
            validChain=0
        else
            result+="✅ v$version is available"$'\n'
        fi
    done
    printf "%s" "$result" > /tmp/xread1
}
function showProgress(){
    beginMsg=$1

    # Hide cursor
    tput civis
    trap 'tput cnorm; exit' INT TERM EXIT

    (
    while true; do
        for dots in "" "." ".." "..." "...." "....."; do
            printf "\r%s%s\033[K" "$beginMsg" "$dots"
            sleep 0.4
        done
    done
    ) &
    local spinner_pid=$!

    # store pid
    echo $spinner_pid > /tmp/xpid 
    
}
function endProgress(){
    endMsg=$1
    processState=$2 #can be either 'f' for failed or 's' for successful
    pid=$(cat /tmp/xpid 2>/dev/null)
    
    # Stop animation
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    # Restore cursor
    tput cnorm
    status=$( [ $processState == "f" ] && echo "❌"  || echo "✅" )
    printf "\r%s..... done %s\n" "$endMsg" "$status"
    echo ""
}
function computeClusterNodes(){
    # Check if master
    [ ! -f /etc/kubernetes/manifests/kube-apiserver.yaml ] && { exit 1; }

    # Get cluster version
    nodeVersion=$(kubelet --version | awk '{print $2}' | sed 's/^v//' | cut -d. -f1,2)
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l) &> /dev/null

    allNodes+=($server_name)
    nodeTypes[$server_name]="Master"

    # Collect control-plane nodes (excluding self)
    while read -r node; do
        [[ "$node" == "$server_name" ]] && continue
        CONTROL_PLANES+=("$node")
        nodeTypes[$node]="Master"
    done < <(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    # Collect worker nodes
    while read -r node; do
        WORKERS+=("$node")
        nodeTypes[$node]="Worker"
    done < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

     # Final ordered array
    ORDERED_NODES=("$server_name" "${CONTROL_PLANES[@]}" "${WORKERS[@]}")

    allNodes+=("${CONTROL_PLANES[@]}")
    allNodes+=("${WORKERS[@]}")
    otherNodes+=("${CONTROL_PLANES[@]}")
    otherNodes+=("${WORKERS[@]}")
}
function showNodes(){

    displayType=$1 # 1=> Show node types in order from Master to worker, 2 => Show all nodes kubelet version

    if [ $displayType = "1" ]; then
        # Debug
        echo ""
        printf "%-5s %-25s %-10s\n" "STEP" "NODE" "TYPE"
        printf "%-5s %-25s %-10s\n" "----" "-------------------------" "----------"

        for i in "${!ORDERED_NODES[@]}"; do
            index=$(( $i + 1 ))
            printf "%-5s %-15s %-10s\n" "$index" "${ORDERED_NODES[$i]}" "${nodeTypes[${ORDERED_NODES[$i]}]}"
        done
        echo ""
    elif [ $displayType = "2" ]; then
        printf "%-5s %-25s %-10s %-8s\n" "ID" "NODE" "TYPE" "KUBELET"
        printf "%-5s %-25s %-10s %-8s\n" "----" "-------------------------" "----------" "--------"

        for i in "${!otherNodes[@]}"; do
            index=$(( i + 1 ))
            node="${otherNodes[$i]}"
            type="${nodeTypes[$node]}"

            kubelet=$(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.kubeletVersion}')

            printf "%-5s %-25s %-10s %-8s\n" "$index" "$node" "$type" "$kubelet"
        done
    fi

}
function getPodIp(){
    nodeName=$1
    POD_IP=$(kubectl get endpoints -n kube-system kube-upgrade-agent -o jsonpath="{.subsets[*].addresses[?(@.nodeName=='$nodeName')].ip}" 2> $error_log)
    echo $POD_IP
}
function installRemoteAgent(){
    manifestFile="src/kube-upgrade-agent.yaml"
    NAMESPACE="kube-system"       # namespace of your DaemonSet
    DAEMONSET_NAME="kube-upgrade-agent"

    # Mark active master node
    kubectl label node $server_name control-plane-active=true > /dev/null

    # Deploy agent
    echo  -e "⚙️[1/2]: Installing kube upgrade agent"
    showProgress "Installing kube upgrade agent"
    kubectl apply -f $manifestFile &> /tmp/kupg1
    endProgress "Installing kube upgrade agent" "s"

    # Checking pod states
    echo  -e "⚙️[2/2]: Checking pod state"
    showProgress "Checking pod state"
    n=0
    allSet=0
    while [ $n -lt 13 ]; do
        # Get the desired and ready counts, try for 1 minutes
        desired=$(kubectl get ds "$DAEMONSET_NAME" -n "$NAMESPACE" -o jsonpath='{.status.desiredNumberScheduled}')
        ready=$(kubectl get ds "$DAEMONSET_NAME" -n "$NAMESPACE" -o jsonpath='{.status.numberReady}')

        # Print current state
        echo "Pods ready: $ready / $desired"


        # Exit when all pods are ready
        if [ "$ready" -eq "$desired" ]; then
            echo "All agents are running!"
            allSet=1
            break
        fi

        n+=$(( $n + 1 ))

        if [ $n -gt 12 ]; then
            if [ $allSet -eq 0 ]; then
                # Not all the agents are running
                echo "Not all the agents are running, view with kubectl get pods, and investigate"
                break
            fi
        fi

        # Wait before checking again
        sleep 5
    done
    endProgress "Installing kube upgrade agent" "s"

}
function uninstallRemoteAgent(){
    manifestFile="src/kube-upgrade-agent.yaml"
    NAMESPACE="kube-system"       # namespace of your DaemonSet
    DAEMONSET_NAME="kube-upgrade-agent"
    clusterNodes=$1

    if [ $NODE_COUNT -gt 1 ]; then
        # Multiple node
        # Uninstalling remote service
        echo ""
        echo  -e "⚙️[1/2]: Uninstalling remote service"
        showProgress "Uninstalling remote service"

        for n in "${otherNodes[@]}"; do
            targetIp=$(getPodIp $n)
            echo ""
            echo "Initiating service uninstallation on node '${n}'"
            response=$(curl -X POST -s http://$targetIp:8080/uninstall)
            status=$(echo "$response" | jq -r '.status')
            status=${status:-"failed"}
            if [ $status = "ok" ]; then 
                echo "Service uninstallation on node '${n}' done ✅ "
            else
                echo "Agent's is down ❌ or may be uninstalled already"
            fi
        done

        endProgress "Uninstalling remote service" "s"

        # Delete agent
        echo  -e "⚙️[2/2]: Uninstalling kube upgrade agent"
        showProgress "Uninstalling kube upgrade agent"
        kubectl delete -f $manifestFile &> /tmp/kupg2
        endProgress "Uninstalling kube upgrade agent" "s"
    fi   
    
}
function execUpgrade(){
    k8sVersion=$1

    if [ $osFamily = "debian" ];then
        # Update repo
        echo  -e "⚙️[1/8]: Updating repo"
        showProgress "Updating repo"
        updateRepo "apt" $k8sVersion &> /tmp/upg1
        endProgress "Updating repo" "s"

        # Get the latest patch version fo the minor version
        LATEST=$(getLatestPatchVersion $k8sVersion "apt")
        applyVersion=$(echo $LATEST | cut -d'-' -f1)

        # Upgrade kubeadm
        echo -e "⚙️[2/8]: Upgrading Kubeadm"
        showProgress "Upgrading Kubeadm"
        {
            apt-mark unhold kubeadm &&
            apt-get update &&
            apt-get install -y kubeadm="$LATEST" &&
            apt-mark hold kubeadm

        } &> /tmp/upg2 || { 
            echo "Kubeadm upgrade f"; 
            echo -e "Error Reasons: \n"
            cat /tmp/upg2
            exit 1; 
        }
        endProgress "Upgrading Kubeadm" "s"

        # Apply upgrade
        echo -e "⚙️[3/8]: Upgrading control-plane node, this may take up to 5 minutes"
        showProgress "Upgrading control-plane node"
        # Master
        if ! kubeadm upgrade apply "v$applyVersion" --yes &> /tmp/upg3; then
            endProgress "Upgrading control-plane node" "f"
            echo -e "Error Reasons:\n"
            cat /tmp/upg3
            exit 1
        fi
        endProgress "Upgrading control-plane node" "s"

        # Drain node
        echo -e "⚙️[4/8]: Draining node"
        showProgress "Draining node"

        kubectl drain $server_name --ignore-daemonsets &> /tmp/upg4
        endProgress "Draining node" "s"

        # wait for eviction
        echo -e "⚙️[5/8]: Waiting for pods eviction"
        showProgress "Waiting for pods eviction"
        sleep 30s
        endProgress "Waiting for pods eviction" "s"

        # Upgrade the kubelet and kubectl
        echo -e "⚙️[6/8]: Upgrading kubelet and kubectl"
        showProgress "Upgrading kubelet and kubectl"
        apt-mark unhold kubelet kubectl &> /tmp/upg6.1 && \
        {
            apt-get update && 
            apt-get install -y kubelet="$LATEST" kubectl
            apt-mark hold kubelet kubectl
        } &> /tmp/upg6.2 || { 
            echo "kubelet and kubectl upgrade failed"; 
            endProgress "Upgrading kubelet and kubectl" "f"
            echo -e "Error Reasons: \n"
            cat /tmp/upg26.2
            exit 1; 
        }
        endProgress "Upgrading kubelet and kubectl" "s"

        # restart kubelet 
        echo -e "[7/8]: Restarting kubelet"
        showProgress "Restarting kubelet"
        systemctl daemon-reload
        systemctl restart kubelet &> /tmp/upg7
        endProgress "Restarting kubelet" "s"

        # uncordon node
        echo -e "⚙️[8/8]: Uncordoning node"
        showProgress "Uncordoning node"
        kubectl uncordon $server_name &> /tmp/upg8
        endProgress "Uncordoning node" "s"

        # Track upgrade
        trackUpgrade $server_name $k8sVersion

        echo -e "Upgrade process completed\n"

    elif [ $osFamily = "redhat" ]; then
        updateRepo "yum" $k8sVersion
    fi
}
function drainRemoteNode(){
    nodeName=$1
    drained=0
    while [ $drained -eq 0 ]; do
        if [ ! kubectl drain $nodeName --ignore-daemonsets &> /dev/null ]; then
            echo "Drainig node '$nodeName' failed, Trying again...."
        else
            drained=1
        fi
        sleep 3s
    done
}
function execRemoteUpgrade(){
    k8sVersion=$1
    nodeName=$2
    targetNodeIp=$(getPodIp $nodeName)
    completed=0

    # Confirm agent status
    echo  -e "⚙️[1/5]: Checking agent's health state"
    showProgress "Checking agent's health state"
    response=$(curl -s http://$targetNodeIp:8080/health)
    status=$(echo "$response" | jq -r '.status')
    if [ $status = "ok" ]; then 
        echo "Agent's is in OK state ✅ "
        endProgress "Checking agent's health state" "s"
    else
        echo "Agent's is down ❌ "
        echo "Try installing agent and try again "
        endProgress "Checking agent's health state" "f"
        exit 1
    fi
    
    # Drain node
    echo  -e "⚙️[2/5]: Draining node"
    showProgress "Draining node"
    drainRemoteNode $nodeName &> /tmp/rupg1
    endProgress "Draining node" "s"

    # Trigger upgrade
    echo  -e "⚙️[3/5]: Triggering node upgrade on node '$nodeName'"
    showProgress "Triggering node upgrade on node '$nodeName'"
    response=$(curl -s -X POST http://$targetNodeIp:8080/upgrade/node/$k8sVersion)
    status=$(echo "$response" | jq -r '.status')
    version=$(echo "$response" | jq -r '.version')
    echo "Status: $status"
    endProgress "Triggering node upgrade on node" "s"

    # Report upgrade state
    echo  -e "⚙️[4/5]: Monitoring remote upgrade on node '$nodeName'"
    showProgress "Monitoring remote upgrade on node '$nodeName'"

    while [ $completed -eq 0 ]; do
        response=$(curl -s http://$targetNodeIp:8080/upgrade/status)
        status=$(jq -r '.status // empty' <<< "$response")
        upgradeStatus=$(jq -r '.upgrade_status // empty' <<< "$response")
        log=$(jq -r '.log // empty' <<< "$response")

        if [[ "$status" == "ok" && -n "$upgradeStatus" ]]; then

            # Load key=value pairs safely
            set -a
            source <(printf '%s\n' "$upgradeStatus")
            set +a

            echo "Current stage: ${state}"

            if [[ "${state_id}" == "99" ]]; then
                echo "❌ Upgrade failed on node ${targetNodeIp}"
                [[ -n "$log" ]] && echo -e "\n--- ERROR LOG ---\n$log"
                exit 1
            fi

            if [ "${state_id}" == "7" ]; then
                # Upgrade completed
                completed=1
                endProgress "Triggering node upgrade on node" "s"
            fi
        else
            echo "Error encountered while trying to get status, Trying again..."
        fi

        sleep 3s
    done


    # Uncordoning node
    echo  -e "⚙️[5/5]: Uncordoning node"
    showProgress "Uncordoning node"
    kubectl uncordon $nodeName  &> /tmp/rupg2
    endProgress "Uncordoning node" "s"

    # Track upgrade
    trackUpgrade $nodeName $k8sVersion

}
function upgradeCluster(){
    echo -e "\n"

    initializeDir

    suppliedTargetVersion=0
    currentStep=0
    echo "Your current cluster version is: v${nodeVersion}"

    while [  $suppliedTargetVersion -eq 0 ]; do
        read -p "Enter the Kubernetes version to upgrade the cluster to (e.g., 1.30) :" targetVersion

        # Validate version format (X.Y only)
        if ! [[ "$targetVersion" =~ ^[0-9]+\.[0-9]+$ ]]; then
            echo "❌ Invalid version format. Use numeric format like 1.30. Please Try again"
        else
            # Compare versions
            if [ "$(printf "%s\n%s\n" "$nodeVersion" "$targetVersion" | sort -V | head -n1)" = "$nodeVersion" ] \
            && [ "$nodeVersion" != "$targetVersion" ]; then
                echo -e "✅ Upgrade allowed: v$nodeVersion → v$targetVersion\n"

                echo "⚙️ Computing version chain"
                showProgress "Computing version chain"
                computeClusterVersionChain "$nodeVersion" "$targetVersion"
                endProgress "Computing version chain" "s"
                
                # Validating versions availability
                echo "⚙️ Validating version(s) availability"
                showProgress "Validating version(s) availability"
                validateVersionChain
                xRead "/tmp/xread1"
                endProgress "Validating version(s) availability" "s"

                
                # Check if version is broken
                if [ $validChain -eq 0 ]; then
                    echo "Version upgrade chain is broken, and upgrade cannot proceed, supply a valid target version to try again"
                    continue;
                fi

                suppliedTargetVersion=1 

                if [ "$NODE_COUNT" -gt 1 ]; then
                    # Multiple node cluster
                    echo "Multi-node cluster detected"
                    read -p "Has the remote upgrade agent been installed (Y/N)?: " installedRagent
                    installedRagent=${installedRagent,,}

                    while [[ $installedRagent != "y" && $installedRagent != "n" ]]; do
                        echo "$installedRagent is not a valid input, Please supply a valid input: Y or N"
                        read -p "Has the remote upgrade agent been installed (Y/N)?: " installedRagent
                        installedRagent=${installedRagent,,}
                    done

                    if [ $installedRagent = "n" ]; then
                        echo "Remote upgrade agent must be deployed for multiple node cluster"
                        echo "Re execute the script and Select 'Cluster Ops' → 'Install remote upgrade agent'"
                        exit 0
                    fi

                    echo "Computing upgrade order"
                    showNodes "1"
                else
                    # Single node cluster
                    echo "Single-node cluster detected"
                fi
                
                totalVersions=${#upgradeVersions[@]}
                upgradeMode="step"
                lastIndex=$(( $totalVersions - 1 ))
                lastVersion=${upgradeVersions[${lastIndex}]}

                if [ $totalVersions -gt 1 ];then
                    read -p "Total upgrade to be done is a total of $totalVersions, do you want a chain upgrade (Y/N)?: " uMode

                    uMode=${uMode,,}

                    while [[ $uMode != "y" && $uMode != "n" ]]; do
                        echo "$uMode is not a valid input, Please supply a valid input: Y or N"
                        read -p "Do you want a chain upgrade (Y/N)?: " uMode
                        uMode=${uMode,,}
                    done

                    if [ $uMode = "y" ]; then
                        upgradeMode="chain"
                        echo "The system will attempt to auto upgrade consecutively from v$nodeVersion → v$targetVersion "
                    else
                        echo "The system will only upgrade one version at a time "
                    fi

                    # Begin upgrade
                    if [ $upgradeMode = "chain" ]; then
                        # Attempt to auto upgrade step by step to the last version across all nodes if multinode cluster
                        for v in "${upgradeVersions[@]}"; do
                            if [ $NODE_COUNT -gt 1 ]; then
                                # Multiple node
                                for n in "${allNodes[@]}"; do
                                    echo ""
                                    echo "Initiating upgrade process of version $v on ${nodeTypes[${n}]} node '${n}'"
                                    if [ ${n} == $server_name ];then
                                        execUpgrade $v
                                    else
                                        execRemoteUpgrade $v $n
                                    fi
                                    
                                    echo "Upgrade to version $v on ${nodeTypes[${n}]} node '${n}' completed"
                                done
                            else
                                # Single node
                                echo "Initiating upgrade process of version $v"
                                execUpgrade $v
                                echo "Upgrade to version $v completed"
                            fi
                           
                        done
                    else
                        # Attempt to upgrade step by step to the last version across all nodes if multinode cluster, after confirmation                        
                        final=0
                        while [ $final -eq 0 ]; do
                            # Prompt for next upgrade
                            targetVersion=${upgradeVersions[$currentStep]}

                            # Check if at the last version
                            [ $lastVersion = $targetVersion ] && { final=1; }

                            read -p "Do you want to initiate upgrade for version ${targetVersion} (Y/N)? : " uNext

                            uNext=${uNext,,}

                            while [[ $uNext != "y" && $uNext != "n" ]]; do
                                echo "$uNext is not a valid input, Please supply a valid input: Y or N"
                                read -p "Do you want a chain upgrade (Y/N)?: " uNext
                                uNext=${uNext,,}
                            done

                            if [ $uNext = "y" ]; then
                                echo "Initiating upgrade process of version $targetVersion"
                                execUpgrade $targetVersion
                                echo "Upgrade to version $targetVersion completed"

                                if [ $NODE_COUNT -gt 1 ]; then
                                    # Multiple node
                                    for n in "${allNodes[@]}"; do
                                        echo "Initiating upgrade process of version $targetVersion on ${nodeTypes[${n}]} node '${n}'"

                                        if [ ${n} == $server_name ];then
                                            execUpgrade $targetVersion
                                        else
                                            execRemoteUpgrade $targetVersion $n
                                        fi
                                        
                                        echo "Upgrade to version $targetVersion on ${nodeTypes[${n}]} node '${n}' completed"
                                    done

                                else
                                    # Single node
                                    echo "Initiating upgrade process of version $targetVersion"
                                    execUpgrade $targetVersion
                                    echo "Upgrade to version $targetVersion completed"
                                fi

                                currentStep+=$(( $currentStep + 1 ))
                            else
                                final=1
                            fi
                            
                        done
                    fi
                else
                    if [ $NODE_COUNT -gt 1 ]; then
                        # Multiple node
                        for n in "${allNodes[@]}"; do
                            echo "Initiating upgrade process of version $targetVersion on ${nodeTypes[${n}]} node '${n}'"
                            if [ ${n} == $server_name ];then
                                execUpgrade $targetVersion
                            else
                                execRemoteUpgrade $targetVersion $n
                            fi
                            
                            echo -e "Upgrade to version $targetVersion on ${nodeTypes[${n}]} node '${n}' completed\n"
                        done
                    else
                        # Single node
                        echo "Initiating upgrade process of version $targetVersion"
                        execUpgrade $targetVersion
                        echo "Upgrade to version $targetVersion completed"
                    fi
                fi  

                             
            else
                echo "❌ Invalid upgrade target. Target version must be greater than current version: v$nodeVersion. Please try again"
            fi
        fi
    done

}
function checkAgentHeathState(){
    touch $formatFile
    : > $formatFile

    if [ $NODE_COUNT -gt 1 ]; then
        # Multiple node
        # Check agent health across all nodes
        echo ""
        echo  -e "⚙️: Checking agent's health on all nodes"
        showProgress "Checking agent's health on all nodes"

        printf "%-20s %-7s %-10s\n" "NODE" "TYPE" "AGENT'S STATE" >> $formatFile
        printf "%-20s %-7s %-10s\n" "--------------------" "-------" "-------------" >> $formatFile

        for n in "${otherNodes[@]}"; do
            targetIp=$(getPodIp $n)
            nodeType=${nodeTypes[${n}]}
            response=$(curl -s http://$targetIp:8080/health)
            status=$(echo "$response" | jq -r '.status')
            status=${status:-"failed"}
            state=""
            if [ $status = "ok" ]; then 
                state="UP"
            else
                state="DOWN"
            fi
            printf "%-20s %-7s %-10s\n" "$n" "${nodeType}" "${state}" >> $formatFile
        done
        endProgress "Displaying agent's health on for nodes" "s"
        cat $formatFile
        echo ""
    fi   
}
function resetCluster(){
    runtimeType=$(selectContainerRuntime "Please select the container runtime that the cluster was initialized with: " "The selected option is invalid, please select the container runtime that the cluster was initialized with: ")
    socketFile=$(getSocket $runtimeType 1)
    echo -e "\nExecuting cluster reset....."
    kubeadm reset --cri-socket=$socketFile -f &> /dev/null

    echo -e "Executing files clean up...."

    if [ -d "/etc/cni/net.d" ]; then
        rm -fr /etc/cni/net.d
    fi
    
    if [ -d "/etc/kubernetes" ]; then
        rm -fr /etc/kubernetes
    fi

    if [ -d "$HOME/.kube" ]; then
        rm -fr $HOME/.kube
    fi

    echo -e "Restarting Kubelet...."
    systemctl restart kubelet

    echo -e "Cluster reset successfully!\n"
}
function upgradeClusterNode(){
    # Display nodes and their versions
    showNodes "2"
    supplied=0
    maxId=$(( ${#otherNodes[@]} + 1 ))
    
    while [ $supplied -eq 0 ]; do
        nodeIds=()
        supplied=1
        echo ""
        read -p "Supply the nodes ID to be upgraded, separated with comma (,): " ids

        IFS=',' read -ra NODE_IDS <<< "$ids"
        
        for id in "${NODE_IDS[@]}"; do
            id="${id//[[:space:]]/}"

            [[ "$id" =~ ^[0-9]+$ ]] || {
                echo "Invalid node ID: $id. ID must be an integer. Try again" >&2
                supplied=0
                break
            }

            # Validate max id
            if [[ $id -lt 1 || $id -gt $maxId ]]; then
                echo "Invalid node ID: $id. ID is out of range (1-$(($maxId - 1 ))). Try again" >&2
                supplied=0
                break
            fi
            nodeIds+=("$id")
        done
    done

    # Rebuild order
    
    echo "ids = " ${nodeIds[@]}

}

# ______________Functions Definitions Ends_____________

if [ -f /etc/os-release ]; then
    source /etc/os-release
    OS_NAME=$NAME
    VERSION=$VERSION_ID
    DISTRO=$ID
fi

# Compute data
computeOSInfo
computeClusterNodes &> /dev/null
# End Computation

PS3="What would you like to do?: "
taskTypes=("Setup K8S components only" "Setup K8S components and Initialize/Join cluster" "Join Worker node to Cluster" "Cluster Management")
entSelectedOpt=0

select res in "${taskTypes[@]}"; do
    entSelectedOpt=$((REPLY))
    while [ $entSelectedOpt -gt 4 ]; do
        PS3="Please select a valid option for your task type: "
        select res in "${taskTypes[@]}"; do
            entSelectedOpt=$((REPLY))
            break
        done
    done
    break
done

if [ $entSelectedOpt -eq 1 ]; then
    # Setup K8S only 
    echo -e "\nYou are in K8S setup only mode\n"
    setupK8s 2
elif [ $entSelectedOpt -eq 2 ]; then
    # Setup K8S and Initialize cluster
    echo -e "\nYou are in K8S setup and initialization/join mode\n"
    setupK8s 1
elif [ $entSelectedOpt -eq 3 ]; then
    # Join worker node to cluster
    echo -e "\nYou are in K8S cluster join mode\n"
    joinWorkerToCluster
elif [ $entSelectedOpt -eq 4 ]; then
    # Join worker node to cluster
    echo -e "\nYou are in cluster management mode\n"

    PS3="Select a cluster management task?: "
    taskTypes=("Reset cluster" "Initialize cluster" "Cluster upgrade Ops")
    
    entSelectedOpt=0

    select res in "${taskTypes[@]}"; do
        entSelectedOpt=$((REPLY))
        while [ $entSelectedOpt -gt 3 ]; do
            PS3="Please select a valid option for your task type: "
            select res in "${taskTypes[@]}"; do
                entSelectedOpt=$((REPLY))
                break
            done
        done
        break
    done


    if [ $entSelectedOpt -eq 1 ]; then
        # Reset cluster
        echo -e "\nYou are in cluster reset mode\n"
        resetCluster

    elif [ $entSelectedOpt -eq 2 ];then
        # Initialize cluster
        echo -e "\nYou are in cluster initialization mode\n"
        read -p "Please specify this server's private IP address: " privateIP
        read -p "Please specify this server's public IP address, for accesibility over the internet. To skip press ENTER: " publicIP

        runtimeType=$(selectContainerRuntime "Please select the container runtime to initialize the cluster with: " "The selected option is invalid, please select the container runtime to initialize the cluster with: ")
        socketFile=$(getSocket $runtimeType 1)
        k8sRuntime=$(getSocket $runtimeType 2)

        initializeCluster $privateIP $socketFile $publicIP
        systemctl restart $k8sRuntime

    elif [ $entSelectedOpt -eq 3 ]; then
         # Check if executed on a master node
        [ ! -f /etc/kubernetes/manifests/kube-apiserver.yaml ] && { echo "Cluster upgrade Ops feature must be done on the master node, exiting..."; exit 1;  }

        echo  -e "⚙️ Validating required dependencies"
        showProgress "Validating required dependencies"
        # Prerequisite : jq
        if ! command -v jq &> /dev/null; then
            # Install jq
            $pm install jq -y &> /dev/dull
        fi
        endProgress "Validating required dependencies" "s"
        echo ""
        PS3="Select a cluster upgrade task?: "
        taskTypes=("Install remote upgrade agent" "Uninstall remote upgrade agent" "Check agent health status" "Upgrade cluster")
        
        
        entSelectedOpt=0

        select res in "${taskTypes[@]}"; do
            entSelectedOpt=$((REPLY))
            while [ $entSelectedOpt -gt 4 ]; do
                PS3="Please select a valid option for your task type: "
                select res in "${taskTypes[@]}"; do
                    entSelectedOpt=$((REPLY))
                    break
                done
            done
            break
        done

        if [ $entSelectedOpt -eq 1 ]; then
            # Install remote upgrade agent
            installRemoteAgent
        elif [ $entSelectedOpt -eq 2 ]; then
            # Uninstall remote upgrade agent
            uninstallRemoteAgent 
        elif [ $entSelectedOpt -eq 3 ]; then
            # Check agent health
            checkAgentHeathState
        elif [ $entSelectedOpt -eq 4 ]; then
            echo ""
            PS3="Select a cluster upgrade sub task?: "
            taskTypes=("Upgrade all cluster nodes" "Upgrade other cluster nodes" "Upgrade this master node")
            
            entSelectedOpt=0

            select res in "${taskTypes[@]}"; do
                entSelectedOpt=$((REPLY))
                while [ $entSelectedOpt -gt 3 ]; do
                    PS3="Please select a valid option for your sub task type: "
                    select res in "${taskTypes[@]}"; do
                        entSelectedOpt=$((REPLY))
                        break
                    done
                done
                break
            done


            if [ $entSelectedOpt -eq 1 ]; then
                # Upgrade cluster
                upgradeCluster
            elif [ $entSelectedOpt -eq 2 ]; then
                echo ""
                echo "To upgrade a cluster node selectively, the followings must be met:"
                printf "%d. %s\n" "1" "This node '$server_name' kubelet version is already ahead of the node(s) to be upgraded"
                printf "%d. %s\n" "2" "Remote upgrade agent have been deployed to the node(s) to be upgraded, and confirmed running"
                printf "%d. %s\n" "3" "The version to upgrade the target node(s) to, can not be greater than the version ($nodeVersion) on this node '$server_name'"
                echo ""
                upgradeClusterNode
            elif [ $entSelectedOpt -eq 3 ]; then
                echo ""
            fi
            
        fi
        
    fi

fi