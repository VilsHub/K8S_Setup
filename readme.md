# K8Smgr - Kubernetes Cluster Manager

**K8Smgr** is a lightweight Bash-based CLI tool designed to simplify Kubernetes cluster management, including setup, initialization, node joining, and cluster maintenance. It provides a **user-friendly command-line interface** with colored menus, prompts, and status output for enhanced usability.

---

## Features

- Setup Kubernetes components on nodes
- Initialize Kubernetes clusters
- Join worker nodes to existing clusters
- Manage cluster operations via sub-modes:
  - Reset cluster
  - Initialize cluster
  - Upgrade cluster (remote agent installation, health checks, etc.)
- Clear, color-coded CLI output
- Interactive and prompt-based modes for ease of use
- Multi-platform support (Linux environments)

---

## Installation

Clone the repository and make the script executable:

```bash
git clone https://github.com/VilsHub/K8Smgr.git
cd K8Smgr
chmod +x k8smgr
```

---

## Help guide
![K8S Manager help menu](https://i.imgur.com/WFDt3oS.png)

---

## Usage

```bash
./k8smgr <mode> [sub-mode]
```

Or simply run without arguments to enter interactive prompt mode:

```bash
./k8smgr
```

### Argument Mode 
| Mode     | Description                                                 |
| -------- | ----------------------------------------------------------- |
| `setup`  | Install Kubernetes components only on the node              |
| `init`   | Install components and initialize a new Kubernetes cluster  |
| `join`   | Join a worker node to an existing Kubernetes cluster        |
| `manage` | Perform cluster management operations (requires a sub-mode) |

#### Sub-modes for **manage**

| Sub-mode      | Description                                                                                 |
| ------------- | ------------------------------------------------------------------------------------------- |
| `reset`       | Reset the cluster                                                                           |
| `initialize`  | Initialize the cluster                                                                      |
| `upgrade-ops` | Launch cluster upgrade mode: agent installation, health checks, and other operational tasks |

---

#### Examples

```bash
# Setup components only
./k8smgr setup

# Initialize a cluster
./k8smgr init

# Join a node to an existing cluster
./k8smgr join

# Manage cluster: reset
./k8smgr manage reset

# Manage cluster: initialize
./k8smgr manage initialize

# Manage cluster: upgrade operations
./k8smgr manage upgrade-ops
```

### Interactive Prompt Mode
If incorrect or missing arguments are supplied, the script automatically switches to interactive mode, guiding the user through available modes and sub-modes with color-coded menus and instructions.

![K8S Manager interactive mode](https://i.imgur.com/njYZVaF.png)

---

## Requirements
 - Linux environment
 - Bash 4.0+
 - Optional: terminal supporting ANSI color codes


--- 
## Contribution
Contributions are welcome! Please open issues for bugs or feature requests, or submit pull requests with improvements.