#!/usr/bin/env bash
set -euo pipefail

CRICTL_VERSION="${CRICTL_VERSION:-v1.30.1}"
YQ_VERSION="${YQ_VERSION:-v4.44.6}"
ARCH="$(dpkg --print-architecture)"

case "${ARCH}" in
  amd64) TOOL_ARCH="amd64" ;;
  arm64) TOOL_ARCH="arm64" ;;
  *) echo "지원하지 않는 architecture입니다: ${ARCH}" >&2; exit 1 ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

curl -fsSL \
  "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${TOOL_ARCH}.tar.gz" \
  -o "${tmp_dir}/crictl.tar.gz"
sudo tar -C /usr/local/bin -xzf "${tmp_dir}/crictl.tar.gz" crictl

curl -fsSL \
  "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TOOL_ARCH}" \
  -o "${tmp_dir}/yq"
sudo install -m 0755 "${tmp_dir}/yq" /usr/local/bin/yq

sudo tee /etc/crictl.yaml >/dev/null <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

crictl --version
yq --version
jq --version
vim --version >/dev/null
