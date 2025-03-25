#!/bin/bash
# Compute OS properties
OS_NAME=""
VERSION=""
DISTRO=""
socketFile=""
containerRuntimeVersion=""

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
# ______________Functions Definitions Ends_____________


if [ -f /etc/os-release ]; then
    source /etc/os-release
    OS_NAME=$NAME
    VERSION=$VERSION_ID
    DISTRO=$ID
fi

PS3="Please select the environment node type: "
envNodeType=("Master" "Worker")
entSelectedOpt=0

select res in "${envNodeType[@]}"; do
    entSelectedOpt=$REPLY
    while [[ $REPLY != "1" && $REPLY != "2" ]]; do
        PS3="Please select a valid option for the environemnt node type: "
        select res in "${envNodeType[@]}"; do
            entSelectedOpt=$REPLY
            break
        done
    done
    break
done

# Check if firewall is enabled
# UFW firewal check
echo  -e "Checking if Firewall is disabled......\n"
disabledFirewall ufw
disabledFirewall firewalld
echo  "Firewall check completed successfully!"


echo -e "\n"
read -p "Please specify the server private IP address: " privateIP
echo -e "\n"

server_name=$(hostname)
server_name=${server_name,,} 

PS3="Please select your preferred container runtime: "
containerRuntimeType=("Containerd" "Containerd with Docker (Not stable yet)" "CRI-O")
crtSelectedOpt=0

select res in "${containerRuntimeType[@]}"; do
    crtSelectedOpt=$REPLY
    while [[ $REPLY != "1" && $REPLY != "2" && $REPLY != "3" ]]; do
        PS3="Please select a valid option for the container runtime type to be used for the setup: "
        select res in "${containerRuntimeType[@]}"; do
            crtSelectedOpt=$REPLY
            break
        done
    done
    break
done

# Compute selected value for containerRuntime 
if [ $crtSelectedOpt == "1" ]; then
    containerRuntime="containerd"
    socketFile="unix:///var/run/containerd/containerd.sock"
elif [[ $crtSelectedOpt == "2"  ]]; then
    containerRuntime="docker"
    socketFile="unix:///var/run/containerd/containerd.sock"
else
    containerRuntime="crio"
    socketFile="unix:///var/run/crio/crio.sock"
fi

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

# Setup directory
setupDir=/tmp/k8s-setup
dependenciesDir=/tmp/k8s-setup/dependencies

if [ ! -d $setupDir ]; then
    mkdir -p $setupDir
    mkdir -p $dependenciesDir
fi

# Compute runtime version to be downloaded

echo -e "\n"
echo -e "Setting up K8S with $containerRuntime.....\n"
if [ $containerRuntime == "crio" ]; then
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

elif [ $containerRuntime == "docker" ]; then
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

elif [ $containerRuntime == "containerd" ]; then
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

        read -p "Your current containerd version is '$installedContainerdVersion', would you like to setup with this version? y/n: " downloadNewVersion

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

echo -e "\nVisit the link (https://github.com/kubernetes/kubernetes/tags) to see the available versions of Kublet to use, and for compatiblity with $containerRuntime version $containerRuntimeVersion see: $compatiblityDocLink \n"

    
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
cat <<EOF | tee /etc/crictl.yaml
runtime-endpoint: $socketFile
image-endpoint: $socketFile
timeout: 2
debug: false
pull-image-on-create: false
EOF


# Forwarding IPv4 and letting iptables see bridged traffic [https://kubernetes.io/docs/setup/production-environment/container-runtimes/#forwarding-ipv4-and-letting-iptables-see-bridged-traffic]
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# > sysctl params required by setup, params persist across reboots
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Disable SELINUX for Redhat
if [ -f "/etc/selinux/config" ]; then
    # Set SELINUX=disabled 
    sed -i 's/\(SELINUX=\).*/\1disabled/' /etc/selinux/config
    setenforce 0
fi

# > Apply sysctl params without reboot
sysctl --system

# Install KubeADM, Kublet and Kubectl
if [ $osFamily == "debian"  ]; then

    apt update -y

    # Install dependencies for CoreDNS
    apt install -y apt-transport-https ca-certificates curl #

    # Set path if not exist
    createPathIfNotExist "/etc/apt/keyrings/"

    # Install kubectl, kubelet and kubeadm
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v$k8sVersion/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$k8sVersion/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
    apt update -y
    apt install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl

elif [ $osFamily == "redhat" ]; then 

    # This overwrites any existing configuration in /etc/yum.repos.d/kubernetes.repo
    echo "[kubernetes]"     >> /etc/yum.repos.d/kubernetes.repo
    echo "name=Kubernetes"  >> /etc/yum.repos.d/kubernetes.repo
    echo "baseurl=https://pkgs.k8s.io/core:/stable:/v$k8sVersion/rpm/" >> /etc/yum.repos.d/kubernetes.repo
    echo "enabled=1" >> /etc/yum.repos.d/kubernetes.repo
    echo "gpgcheck=1" >> /etc/yum.repos.d/kubernetes.repo
    echo "gpgkey=https://pkgs.k8s.io/core:/stable:/v$k8sVersion/rpm/repodata/repomd.xml.key" >> /etc/yum.repos.d/kubernetes.repo

    yum install yum-utils ca-certificates curl
    dnf install dnf-plugins-core &> /dev/null

    yum install -y kubeadm kubelet kubectl

fi


# Pull required containers
kubeadm config images pull --cri-socket="$socketFile"

sleep 20s

systemctl enable kubelet
systemctl start kubelet

if [ $entSelectedOpt == "1" ]; then

    # initialize the master node control plane configurations: (Master node)
    IPADDR=$privateIP
    POD_CIDR="10.244.0.0/16"

    echo -e "\nInitializing the control plane...."
    kubeadm init --apiserver-advertise-address=$IPADDR --pod-network-cidr=$POD_CIDR --cri-socket=$socketFile > worker_node_token.txt
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

        kubectl taint node $server_name node-role.kubernetes.io/control-plane:NoSchedule-

        # Install Helm and run on the master node only
        read -p "Would you like to setup Helm repo manager for this cluster (Y/N)?: " setupHelm
        
        if [[ $setupHelm = "y" || $setupHelm = "Y" ]]; then
            res=0
            while [ $res -eq 0 ]; do
                downloadHelm $setupDir $dependenciesDir
                res=1
            done

        fi

        which helm &> /dev/null
        ec=$?

        if [ $ec -eq 0 ]; then
            # Installed helm
            echo -e "\nPost operation completed successfully...\n"
        else
            # Installation failed helm
            echo -e "\nPost operation failed... Try installing helm manually\n"
        fi

    else
        echo -e "There was a problem initiating the control plane"
    fi

fi