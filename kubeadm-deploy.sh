#!/bin/bash
# Compute OS properties
OS_NAME=""
VERSION=""
DISTRO=""
socketFile=""
containerRuntimeVersion=""
# Setup directory
setupDir=/tmp/k8s-setup
dependenciesDir=/tmp/k8s-setup/dependencies

# ______________Functions Definitions Starts___________
function createPathIfNotExist() {
    if [ ! -d $1 ]; then
        mkdir -p $1
    fi
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
   

    server_name=$(hostname)
    server_name=${server_name,,} 

    containerRuntime=""
    socketFile=""

    runtimeType=$(selectContainerRuntime)
    socketFile=$(getSocket $runtimeType 1)
    containerRuntime=$(getSocket $runtimeType 2)

    # Compute OS family
    pm=""
    osFamily=""
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

    if [ ! -d $setupDir ]; then
        mkdir -p $setupDir
        mkdir -p $dependenciesDir
    fi

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

        # Set path if not exist
        createPathIfNotExist "/etc/apt/keyrings/"

        # Install kubectl, kubelet and kubeadm
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v$k8sVersion/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$k8sVersion/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
        apt update -y

        computeClusterVersionAndInstall "apt" $k8sVersion

    elif [ $osFamily = "redhat" ]; then 

        # This overwrites any existing configuration in /etc/yum.repos.d/kubernetes.repo
        echo "[kubernetes]"     >> /etc/yum.repos.d/kubernetes.repo
        echo "name=Kubernetes"  >> /etc/yum.repos.d/kubernetes.repo
        echo "baseurl=https://pkgs.k8s.io/core:/stable:/v$k8sVersion/rpm/" >> /etc/yum.repos.d/kubernetes.repo
        echo "enabled=1" >> /etc/yum.repos.d/kubernetes.repo
        echo "gpgcheck=1" >> /etc/yum.repos.d/kubernetes.repo
        echo "gpgkey=https://pkgs.k8s.io/core:/stable:/v$k8sVersion/rpm/repodata/repomd.xml.key" >> /etc/yum.repos.d/kubernetes.repo

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
function computeClusterVersionAndInstall(){
    distro=$1
    K8S_VERSION_MINOR=$2

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
        echo "Installing Kubernetes version: $LATEST"

        apt install -y kubelet="$LATEST" kubeadm="$LATEST" kubectl="$LATEST"
        apt-mark hold kubelet kubeadm kubectl
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
            server_name=$(hostname)
            server_name=${server_name,,} 
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

    local containerRuntime=$(selectContainerRuntime)

    local socketFile=$(getSocket $containerRuntime 1)
    echo -e "\n"
    
    kubeadm join "$reachableIP:6443" --token "$tokenValue" --discovery-token-ca-cert-hash "$tokenHash" --cri-socket="$socketFile"
}
# ______________Functions Definitions Ends_____________


if [ -f /etc/os-release ]; then
    source /etc/os-release
    OS_NAME=$NAME
    VERSION=$VERSION_ID
    DISTRO=$ID
fi

PS3="What would you like to do?: "
taskTypes=("Setup K8S components only" "Setup K8S components and Initialize/Join cluster" "Reset cluster" "Initialize cluster" "Join Worker node to Cluster")
entSelectedOpt=0

select res in "${taskTypes[@]}"; do
    entSelectedOpt=$((REPLY))
    while [ $entSelectedOpt -gt 5 ]; do
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
    # Reset cluster
    echo -e "\nYou are in cluster reset mode\n"
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

elif [ $entSelectedOpt -eq 4 ]; then

    # Initialize cluster
    # Reset cluster
    echo -e "\nYou are in cluster initialization mode\n"
    read -p "Please specify this server's private IP address: " privateIP
    read -p "Please specify this server's public IP address, for accesibility over the internet. To skip press ENTER: " publicIP

    runtimeType=$(selectContainerRuntime "Please select the container runtime to initialize the cluster with: " "The selected option is invalid, please select the container runtime to initialize the cluster with: ")
    socketFile=$(getSocket $runtimeType 1)
    k8sRuntime=$(getSocket $runtimeType 2)

    initializeCluster $privateIP $socketFile $publicIP
    systemctl restart $k8sRuntime

elif [ $entSelectedOpt -eq 5 ]; then

    # Join worker node to cluster
    joinWorkerToCluster

fi