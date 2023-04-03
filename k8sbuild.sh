#!/bin/bash

# Debug mode
set -x
# set -o pipefail

OS=$(cat /etc/os-release | grep -w ID |cut -d '=' -f2)
IP=$(ifconfig eth0| grep inet | tr -s \ - | cut -d ":" -f2 | cut -d ' ' -f1 )
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
CNI="flannel"

CHECK_VAR() {
 var_names=("OS" "IP" "SCRIPT_DIR" "CNI")
  for var_name in "${var_names[@]}"
  do
      [ -z "${!var_name}" ] && echo "$var_name is unset." && exit 1
  done
  return 0
}

ALPINE() {
sudo apk update;sudo apk upgrade;sudo apk add sudo

# close ipv6
cat <<EOF | sudo tee /etc/sysctl.conf
net.ipv6.conf.all.disable_ipv6 = 1
EOF

# install podman
sudo apk add podman

sudo rc-update add cgroups

sudo rc-service cgroups start

sudo mkdir -p /etc/cni/podman

sudo mv /etc/cni/net.d/cni.lock /etc/cni/podman/

sudo sed -i "326cnetwork_config_dir = "/etc/cni/podman"" /etc/containers/containers.conf

# install cri-o
sudo apk add cri-o cri-tools --update-cache --repository http://dl-3.alpinelinux.org/alpine/edge/testing/ --allow-untrusted

sudo rc-service crio start

sudo rc-update add crio default

cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///var/run/crio/crio.sock
image-endpoint: unix:///var/run/crio/crio.sock
timeout: 2
EOF

cat <<EOF | sudo tee /etc/crio/crio.conf
[crio.runtime]
# Overide defaults to not use systemd cgroups.
conmon_cgroup = "pod"
cgroup_manager = "cgroupfs"
default_runtime = "crun"

default_capabilities = [
  "CHOWN",
  "DAC_OVERRIDE",
  "FSETID",
  "FOWNER",
  "SETGID",
  "SETUID",
  "SETPCAP",
  "NET_BIND_SERVICE",
  "AUDIT_WRITE",
  "SYS_CHROOT",
  "KILL"
]

[crio.runtime.runtimes.crun]
runtime_path = "/usr/bin/crun"
runtime_type = "oci"
runtime_root = ""

[crio.network]
network_dir = "/etc/cni/net.d/"
plugin_dir = "/opt/cni/bin"
EOF

# close swap
sudo swapoff -a

sudo sed -i '/swap/s/^/#/' /etc/fstab

cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

sudo modprobe br_netfilter

echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf

sudo sysctl -p

cat <<EOF | sudo tee /etc/crio/crio.conf.apk-new
[crio.runtime]

# Overide defaults to not use systemd cgroups.
conmon_cgroup = "pod"
cgroup_manager = "cgroupfs"
EOF

# install k8s
sudo apk add kubeadm kubelet kubectl --update-cache --repository http://dl-3.alpinelinux.org/alpine/edge/testing/ --allow-untrusted

sudo rc-update add kubelet default
}

INIT_K8S() {
  cat "${SCRIPT_DIR}"/init-config.yaml | envsubst > "${SCRIPT_DIR}"/init-tmp-config.yaml && mv "${SCRIPT_DIR}"/init-tmp-config.yaml "${SCRIPT_DIR}"/init-config.yaml
  sudo kubeadm init --upload-certs --config="${SCRIPT_DIR}"/init-config.yaml
  if [ "$?" == "0" ]; then
    echo "Starting control-plane ok"
    sleep 6
  else
    echo "Your Kubernetes control-plane has initialized failed!" && exit 1
  fi
}

INSTALL_CNI() {
  if [ "$CNI" == "calico" ]; then
    kubectl create -f "${SCRIPT_DIR}"/cni/calico.yaml
    [ "$?" != "0" ] && echo "Setup CNI Error" && exit 1
  fi
  if [ "$CNI" == "flannel" ]; then
    kubectl apply -f "${SCRIPT_DIR}"/cni/kube-flannel.yml
    [ "$?" != "0" ] && echo "Setup CNI Error" && exit 1
  fi
}

SET_K8S_ADMIN() {
  if ! (mkdir -p "$HOME"/.kube; sudo cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config; sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config); then
    echo "$(hostname) Set bigred as admin failed!" && exit 1
  fi
}

UNTAINT() {
  if ! cat "${script_dir}"/init-config.yaml | grep 'taints: \[\]' &> /dev/null; then
    kubectl taint node "$HOSTNAME" node-role.kubernetes.io/control-plane:NoSchedule- &> /dev/null
    if [ "$?" != "0" ]; then
      echo "node/"$HOSTNAME" untainted failed" && exit 1
    fi
  fi
}

if [ "$OS" == "alpine" ]; then
  CHECK_VAR
  ALPINE
  INIT_K8S
  INSTALL_CNI
  SET_K8S_ADMIN
  UNTAINT
fi
