#!/bin/bash
# Compute OS properties
OS_NAME=""
VERSION=""
DISTRO=""
socketFile=""

# ______________Functions Definitions Starts___________
function createPathIfNotExist () {
    if [ ! -d $1 ]; then
        mkdir -p $1
    fi
}

function downloadContainerd () {
    # $1 can either be "new" or "upgrade"
    downloadFor=$1
    setupDir=$2
    dependenciesDir=$3

    # Not found
    echo "Visit the link to see the available versions to use, : https://github.com/containerd/containerd/releases/"
    check=0
    repoLink=""
    while [ $check -eq 0 ]; do

        read -p "Please specify the version of Containerd to be installed: " containerdVersion
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

function setupContainerd (){
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
echo -e "\n"
read -p "Please specify the server private IP address: " privateIP
echo -e "\n"

# Checking if hostname is resolved to private IP
echo -e "Checking if hostname is resolved to private IP......\n"
server_name=$(hostname)
grepResult=$(grep -E "^\s*$privateIP\s+$server_name\s*$" /etc/hosts)

if [ -n "$grepResult" ]; then
    echo -e "The hostname '$(hostname)' is set to the IP address '$privateIP' in '/etc/hosts' file, proceeding to setup....\n"
else
    echo "The hostname '$(hostname)' is not set to the IP address '$privateIP' in '/etc/hosts', please set this and try again"
    exit 1
fi

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
    echo "Visit the link to see the available versions to use, then click on your target version to get the OS label: https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/"
    check=0
    repoLink=""
    while [ $check -eq 0 ]; do

        read -p "Please specify the version of CRI-O to be installed: " crioVersion
        read -p "Please specify the OS label for this environment: " osLabel
        echo "Checking if the CRIO version '$crioVersion' is avaialble for installation...."
        repoLink="https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:$crioVersion/$osLabel/devel:kubic:libcontainers:stable:cri-o:$crioVersion.repo"
        baseLink="https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$crioVersion/$osLabel"
        
        targetLink=$( [ $osFamily == "redhat" ] && echo $repoLink  || echo $baseLink)
        
        if [[ $osFamily == "redhat" || $osFamily == "debian" ]]; then
            wget -O $setupDir/tz $targetLink | &> /dev/null
            cat $setupDir/tz | grep "ERROR 404" &> /dev/null
            ec=$?

            if [ $ec -eq 0 ]; then
                # Not Found
                echo "CRI-O with the version '$crioVersion' is not found, kindly confirm the OS label and the version specified"
            else
                check=1
                echo -e "CRI-O version '$crioVersion' found for $osLabel"
            fi
        fi
    done

    # Begin downloading CRI-O runtime
    if [ $osFamily == "redhat" ]; then

        # CentOS
        curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$osLabel/devel:kubic:libcontainers:stable.repo
        cp $setupDir/tz /etc/yum.repos.d/devel:kubic:libcontainers:stable:cri-o:$crioVersion.repo 
        yum update -y
        yum install -y cri-o

    elif [ $osFamily == "debian" ]; then

        # Ubuntu
        echo 'deb http://deb.debian.org/debian buster-backports main' > /etc/apt/sources.list.d/backports.list
        apt update -y
        apt install -y -t buster-backports libseccomp2 || apt update -y -t buster-backports libseccomp2

        # Set path if not exist
        createPathIfNotExist "/usr/share/keyrings"

        echo "deb [signed-by=/usr/share/keyrings/libcontainers-archive-keyring.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$osLabel/ /" > /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
        echo "deb [signed-by=/usr/share/keyrings/libcontainers-crio-archive-keyring.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$crioVersion/$osLabel/ /" > /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$osLabel.list

        mkdir -p /usr/share/keyrings
        curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$osLabel/Release.key | gpg --dearmor -o /usr/share/keyrings/libcontainers-archive-keyring.gpg
        curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$crioVersion/$osLabel/Release.key | gpg --dearmor -o /usr/share/keyrings/libcontainers-crio-archive-keyring.gpg

        apt-get update -y
        apt-get install -y cri-o cri-o-runc

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

        read -p "Your current containerd version is '$installedContainerdVersion', would you like to setup with this version? y/n: " downloadNewVersion

        if [[ $downloadNewVersion = "n" || $downloadNewVersion = "N" ]]; then
            downloadContainerd "upgrade" $setupDir $dependenciesDir    
            setupContainerd "upgrade" 
        else
            setupContainerd "current" 
        fi

    fi

fi

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
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
    apt update -y
    apt install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl

elif [ $osFamily == "redhat" ]; then 

    # This overwrites any existing configuration in /etc/yum.repos.d/kubernetes.repo
    echo "[kubernetes]"     >> /etc/yum.repos.d/kubernetes.repo
    echo "name=Kubernetes"  >> /etc/yum.repos.d/kubernetes.repo
    echo "baseurl=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/" >> /etc/yum.repos.d/kubernetes.repo
    echo "enabled=1" >> /etc/yum.repos.d/kubernetes.repo
    echo "gpgcheck=1" >> /etc/yum.repos.d/kubernetes.repo
    echo "gpgkey=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/repodata/repomd.xml.key" >> /etc/yum.repos.d/kubernetes.repo

    yum install yum-utils ca-certificates curl
    dnf install dnf-plugins-core &> /dev/null

    yum install -y kubeadm kubelet

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
        kubectl taint node $(hostname) node-role.kubernetes.io/control-plane:NoSchedule-

        echo -e "Post operation completed successfully...\n"

        # Install Helm and run on the master node only
        echo "Installing Helm repo v3.7.2"
        wget -O $dependenciesDir/helm-v3.7.2-linux-amd64.tar.gz https://get.helm.sh/helm-v3.7.2-linux-amd64.tar.gz
        tar -xvf $dependenciesDir/helm-v3.7.2-linux-amd64.tar.gz -C /usr/local/bin/
        echo -e "Helm installation completed\n"

    else
        echo -e "There was a problem initiating the control plane"
    fi

fi