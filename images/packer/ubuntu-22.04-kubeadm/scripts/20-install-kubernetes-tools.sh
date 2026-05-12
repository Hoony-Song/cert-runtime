#!/usr/bin/env bash
set -euo pipefail

KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.30.8-1.1}"
KUBERNETES_MINOR="${KUBERNETES_MINOR:-v1.30}"

export DEBIAN_FRONTEND=noninteractive

sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update
sudo apt-get install -y \
  "kubeadm=${KUBERNETES_VERSION}" \
  "kubectl=${KUBERNETES_VERSION}" \
  "kubelet=${KUBERNETES_VERSION}"

sudo apt-mark hold kubeadm kubectl kubelet
sudo systemctl enable kubelet

# CNI는 Golden Image 안에서 적용하지 않는다.
# kubeadm init 이후 클러스터 bootstrap 단계에서 CNI manifest를 적용해야 Node Ready가 된다.
