#!/usr/bin/env bash
set -euo pipefail

cloud-init --version

for unit in cloud-init cloud-config cloud-final; do
  if ! systemctl is-enabled "${unit}" >/dev/null; then
    echo "${unit} 서비스가 활성화되어 있지 않습니다." >&2
    exit 1
  fi
done

if find /home /root -path '*/.ssh/authorized_keys' -type f -size +0c 2>/dev/null | grep -q .; then
  echo "Golden Image에 고정 SSH authorized_keys가 남아 있습니다." >&2
  exit 1
fi
