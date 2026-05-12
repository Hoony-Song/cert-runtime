#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update
sudo apt-get install -y \
  apt-transport-https \
  ca-certificates \
  cloud-init \
  conntrack \
  curl \
  gpg \
  iproute2 \
  iptables \
  jq \
  socat \
  vim

sudo systemctl enable cloud-init
sudo systemctl enable cloud-config
sudo systemctl enable cloud-final
