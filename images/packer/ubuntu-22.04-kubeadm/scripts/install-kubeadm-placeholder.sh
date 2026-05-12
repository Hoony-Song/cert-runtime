#!/usr/bin/env bash
set -euo pipefail

KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.30.8-1.1}"
KUBERNETES_MINOR="${KUBERNETES_MINOR:-v1.30}"

export DEBIAN_FRONTEND=noninteractive

sudo swapoff -a || true
sudo sed -i.bak '/[[:space:]]swap[[:space:]]/ s/^/# /' /etc/fstab

sudo tee /etc/modules-load.d/cka-kubernetes.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/99-cka-kubernetes.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

sudo apt-get update
sudo apt-get install -y \
  apt-transport-https \
  ca-certificates \
  containerd \
  curl \
  gpg \
  jq \
  vim

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable containerd

sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update
sudo apt-get install -y \
  "kubelet=${KUBERNETES_VERSION}" \
  "kubeadm=${KUBERNETES_VERSION}" \
  "kubectl=${KUBERNETES_VERSION}"

sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet

# Golden Image에는 고정 SSH public key를 넣지 않는다.
# 세션별 VM 접속 key는 cloud-init user-data 렌더링 단계에서 주입한다.
sudo rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
sudo cloud-init clean --logs || true
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
