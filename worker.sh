#!/bin/bash

worker[0]="192.168.23.xx"
worker[1]="192.168.23.xx"

OS=$(cat /etc/os-release | grep -w ID |cut -d '=' -f2)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

CHECK_VAR() {
 var_names=("HOSTNAME" "OS" "IP" "SCRIPT_DIR" "CNI")
  for var_name in "${var_names[@]}"
  do
      [ -z "${!var_name}" ] && echo "$var_name is unset." && exit 1
  done
  return 0
}

KEY() {
  if [[ ! -f ~/.ssh/id_rsa && -f ~/.ssh/id_rsa.pub ]]; then
    ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa
    echo "rsa key is generated"
  fi
}

ALPINE() {
cat <<EOF | sudo tee /etc/modules
overlay
br_netfilter
EOF

sudo modprobe overlay

sudo modprobe br_netfilter

sudo apk update;sudo apk upgrade;sudo apk add sudo bash nano

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

sudo sed -i "326cnetwork_config_dir = \"/etc/cni/podman\"" /etc/containers/containers.conf

# install k8s
sudo apk add kubeadm kubelet --update-cache --repository http://dl-3.alpinelinux.org/alpine/edge/community/ --allow-untrusted

# install cri-o
sudo apk add cri-o --update-cache --repository http://dl-3.alpinelinux.org/alpine/edge/testing/ --allow-untrusted

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

echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf

sudo sysctl -p

cat <<EOF | sudo tee /etc/crio/crio.conf.apk-new
[crio.runtime]

# Overide defaults to not use systemd cgroups.
conmon_cgroup = "pod"
cgroup_manager = "cgroupfs"
EOF

sudo rc-update add kubelet default

}


case $OS in
  alpine)
    for c in ${worker[@]}
    do
      KEY
      ALPINE
    done
  ;;
esac
