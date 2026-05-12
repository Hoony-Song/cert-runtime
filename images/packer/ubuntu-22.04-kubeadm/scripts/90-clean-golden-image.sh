#!/usr/bin/env bash
set -euo pipefail

# Golden Image에는 고정 SSH public key를 넣지 않는다.
# 세션별 VM 접속 key는 cloud-init user-data 렌더링 단계에서 주입한다.
sudo find /home /root -path '*/.ssh/authorized_keys' -type f -delete 2>/dev/null || true
sudo rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

sudo cloud-init clean --logs || true
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id

sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
