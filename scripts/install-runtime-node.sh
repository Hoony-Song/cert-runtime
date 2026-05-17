#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: install-runtime-node.sh --join-token <token> [options]

Options:
  --api-url <url>               Platform API URL. Default: https://api.sweetlabs.kr
  --manifest-url <url>          Runtime artifact manifest URL.
  --authorized-key <key>        SSH public key allowed for cka-runtime.
  --authorized-key-file <path>  File containing SSH public keys.
  --skip-packages               Skip apt package installation.
  --help                        Show this help.
USAGE
}

JOIN_TOKEN=""
API_URL="https://api.sweetlabs.kr"
MANIFEST_URL="https://artifacts.sweetlabs.kr/runtime/manifests/runtime-node-v20260517-runtime-node-v1.json"
AUTHORIZED_KEY=""
AUTHORIZED_KEY_FILE=""
SKIP_PACKAGES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --join-token)
      JOIN_TOKEN="${2:-}"
      shift 2
      ;;
    --api-url)
      API_URL="${2:-}"
      shift 2
      ;;
    --manifest-url)
      MANIFEST_URL="${2:-}"
      shift 2
      ;;
    --authorized-key)
      AUTHORIZED_KEY="${2:-}"
      shift 2
      ;;
    --authorized-key-file)
      AUTHORIZED_KEY_FILE="${2:-}"
      shift 2
      ;;
    --skip-packages)
      SKIP_PACKAGES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${JOIN_TOKEN}" ]]; then
  echo "--join-token is required" >&2
  exit 2
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "This installer must run as root. Use sudo." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d /tmp/cert-runtime-install.XXXXXX)"
MANIFEST_PATH="${WORK_DIR}/manifest.json"
MANIFEST_ENV="${WORK_DIR}/manifest.env"
CURRENT_STEP="start"
trap 'rm -rf "${WORK_DIR}"' EXIT

json_report_payload() {
  local status="$1"
  local step="$2"
  local message="$3"
  python3 - "$JOIN_TOKEN" "$status" "$step" "$message" <<'PY'
import json
import sys

print(json.dumps({
    "joinToken": sys.argv[1],
    "status": sys.argv[2],
    "step": sys.argv[3],
    "message": sys.argv[4],
}))
PY
}

api_post() {
  local endpoint="$1"
  local payload="$2"
  curl -fsS \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 10 \
    -H "Content-Type: application/json" \
    -X POST \
    -d "${payload}" \
    "${API_URL%/}${endpoint}" >/dev/null
}

report_status() {
  local status="$1"
  local step="$2"
  local message="$3"
  api_post "/runtime-node-joins/report" "$(json_report_payload "${status}" "${step}" "${message}")" || true
}

fail_report() {
  local exit_code=$?
  if [[ "${exit_code}" -ne 0 ]]; then
    report_status "FAILED" "${CURRENT_STEP}" "runtime node installer failed at ${CURRENT_STEP}"
  fi
  exit "${exit_code}"
}
trap fail_report ERR

claim_join() {
  local hostname_value="$1"
  local primary_ip="$2"
  local payload
  payload="$(python3 - "$JOIN_TOKEN" "$hostname_value" "$primary_ip" <<'PY'
import json
import sys

print(json.dumps({
    "joinToken": sys.argv[1],
    "hostname": sys.argv[2],
    "primaryIp": sys.argv[3],
}))
PY
)"
  api_post "/runtime-node-joins/claim" "${payload}"
}

download_file() {
  local url="$1"
  local output="$2"
  curl -fL \
    --retry 4 \
    --retry-delay 2 \
    --connect-timeout 15 \
    -o "${output}" \
    "${url}"
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  if [[ -z "${expected}" || "${expected}" == "None" || "${expected}" == "null" ]]; then
    return 0
  fi
  printf '%s  %s\n' "${expected}" "${file}" | sha256sum -c -
}

primary_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

load_manifest_env() {
  python3 - "${MANIFEST_PATH}" <<'PY' > "${MANIFEST_ENV}"
import json
import shlex
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
bundle = manifest.get("runtimeBundle") or {}
golden = manifest.get("goldenImage") or {}
kind = manifest.get("kind") or {}
packages = manifest.get("requiredPackages") or []

def emit(name, value):
    if value is None:
        value = ""
    print(f"{name}={shlex.quote(str(value))}")

emit("RUNTIME_ROOT", manifest.get("runtimeRoot") or "/var/lib/cka")
emit("RUNTIME_USER", manifest.get("runtimeUser") or "cka-runtime")
emit("BUNDLE_URL", bundle.get("url") or "")
emit("BUNDLE_SHA256", bundle.get("sha256") or "")
emit("BUNDLE_EXTRACT_TO", bundle.get("extractTo") or manifest.get("runtimeRoot") or "/var/lib/cka")
emit("GOLDEN_URL", golden.get("url") or "")
emit("GOLDEN_SHA256", golden.get("sha256") or "")
emit("GOLDEN_COMPRESSION", golden.get("compression") or "")
emit("GOLDEN_INSTALL_PATH", golden.get("installPath") or "")
emit("KIND_URL", kind.get("url") or "https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64")
emit("KIND_SHA256", kind.get("sha256") or "")
print("REQUIRED_PACKAGES=(" + " ".join(shlex.quote(str(item)) for item in packages) + ")")
PY
  # shellcheck disable=SC1090
  source "${MANIFEST_ENV}"
}

install_packages() {
  if [[ "${SKIP_PACKAGES}" == true ]]; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get is required on the runtime node" >&2
    exit 1
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${REQUIRED_PACKAGES[@]}"
}

install_kind() {
  if command -v kind >/dev/null 2>&1; then
    return 0
  fi
  download_file "${KIND_URL}" /usr/local/bin/kind
  verify_sha256 /usr/local/bin/kind "${KIND_SHA256}"
  chmod 0755 /usr/local/bin/kind
}

setup_runtime_user() {
  local runtime_home="/home/${RUNTIME_USER}"
  if ! getent group "${RUNTIME_USER}" >/dev/null 2>&1; then
    groupadd --system "${RUNTIME_USER}"
  fi
  if ! id -u "${RUNTIME_USER}" >/dev/null 2>&1; then
    useradd --system --gid "${RUNTIME_USER}" --create-home --home-dir "${runtime_home}" --shell /bin/bash "${RUNTIME_USER}"
  fi
  for group_name in docker libvirt kvm; do
    if getent group "${group_name}" >/dev/null 2>&1; then
      usermod -aG "${group_name}" "${RUNTIME_USER}"
    fi
  done

  install -d -o "${RUNTIME_USER}" -g "${RUNTIME_USER}" -m 0700 "${runtime_home}/.ssh"
  touch "${runtime_home}/.ssh/authorized_keys"
  chmod 0600 "${runtime_home}/.ssh/authorized_keys"
  chown "${RUNTIME_USER}:${RUNTIME_USER}" "${runtime_home}/.ssh/authorized_keys"

  if [[ -n "${AUTHORIZED_KEY_FILE}" && -f "${AUTHORIZED_KEY_FILE}" ]]; then
    while IFS= read -r key_line; do
      [[ -z "${key_line}" ]] && continue
      grep -qxF "${key_line}" "${runtime_home}/.ssh/authorized_keys" || echo "${key_line}" >> "${runtime_home}/.ssh/authorized_keys"
    done < "${AUTHORIZED_KEY_FILE}"
  fi
  if [[ -n "${AUTHORIZED_KEY}" ]]; then
    grep -qxF "${AUTHORIZED_KEY}" "${runtime_home}/.ssh/authorized_keys" || echo "${AUTHORIZED_KEY}" >> "${runtime_home}/.ssh/authorized_keys"
  fi

  cat >/etc/sudoers.d/cka-runtime <<'SUDOERS'
cka-runtime ALL=(root) NOPASSWD: /usr/bin/docker, /usr/local/bin/kind, /usr/bin/virsh, /usr/bin/virt-install, /usr/bin/qemu-img, /usr/bin/cloud-localds, /usr/bin/systemctl
SUDOERS
  chmod 0440 /etc/sudoers.d/cka-runtime
}

configure_services() {
  sysctl -w fs.inotify.max_user_instances=1024 >/dev/null || true
  sysctl -w fs.inotify.max_user_watches=1048576 >/dev/null || true

  systemctl enable --now docker >/dev/null 2>&1 || true
  systemctl enable --now libvirtd >/dev/null 2>&1 || true

  if command -v virsh >/dev/null 2>&1; then
    virsh net-start default >/dev/null 2>&1 || true
    virsh net-autostart default >/dev/null 2>&1 || true
  fi
}

prepare_runtime_dirs() {
  install -d -o "${RUNTIME_USER}" -g kvm -m 2770 \
    "${RUNTIME_ROOT}" \
    "${RUNTIME_ROOT}/images" \
    "${RUNTIME_ROOT}/images/base" \
    "${RUNTIME_ROOT}/images/source" \
    "${RUNTIME_ROOT}/images/sessions" \
    "${RUNTIME_ROOT}/sessions" \
    "${RUNTIME_ROOT}/logs" \
    "${RUNTIME_ROOT}/tmp"
}

install_runtime_bundle() {
  if [[ -z "${BUNDLE_URL}" ]]; then
    echo "runtimeBundle.url is missing from manifest" >&2
    exit 1
  fi
  local bundle_path="${WORK_DIR}/runtime-bundle.tar.gz"
  download_file "${BUNDLE_URL}" "${bundle_path}"
  verify_sha256 "${bundle_path}" "${BUNDLE_SHA256}"
  mkdir -p "${BUNDLE_EXTRACT_TO}"
  tar -xzf "${bundle_path}" -C "${BUNDLE_EXTRACT_TO}"
  chown -R "${RUNTIME_USER}:kvm" "${RUNTIME_ROOT}" || true
}

install_golden_image() {
  if [[ -z "${GOLDEN_URL}" ]]; then
    return 0
  fi
  if [[ -z "${GOLDEN_INSTALL_PATH}" ]]; then
    GOLDEN_INSTALL_PATH="${RUNTIME_ROOT}/images/base/cka-ubuntu-22.04-kubeadm-1.30-v1/cka-ubuntu-22.04-kubeadm-1.30-v1.qcow2"
  fi
  local image_download="${WORK_DIR}/$(basename "${GOLDEN_URL}")"
  download_file "${GOLDEN_URL}" "${image_download}"
  verify_sha256 "${image_download}" "${GOLDEN_SHA256}"
  mkdir -p "$(dirname "${GOLDEN_INSTALL_PATH}")"
  if [[ "${GOLDEN_COMPRESSION}" == "zstd" || "${image_download}" == *.zst ]]; then
    zstd -d -f "${image_download}" -o "${GOLDEN_INSTALL_PATH}"
  else
    cp "${image_download}" "${GOLDEN_INSTALL_PATH}"
  fi
  chown "${RUNTIME_USER}:kvm" "${GOLDEN_INSTALL_PATH}" || true
  chmod 0660 "${GOLDEN_INSTALL_PATH}"
}

complete_join() {
  local total_mib
  local available_mib
  local disk_free_mib
  total_mib="$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)"
  available_mib="$(awk '/MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)"
  disk_free_mib="$(df -Pm "${RUNTIME_ROOT}" | awk 'NR == 2 {print $4}')"

  local payload
  payload="$(python3 - "$JOIN_TOKEN" "$(hostname -s)" "$(primary_ip)" "${total_mib}" "${available_mib}" "${disk_free_mib}" <<'PY'
import json
import sys

print(json.dumps({
    "joinToken": sys.argv[1],
    "hostname": sys.argv[2],
    "primaryIp": sys.argv[3],
    "totalMemoryMiB": int(sys.argv[4]),
    "availableMemoryMiB": int(sys.argv[5]),
    "diskFreeMiB": int(sys.argv[6]),
    "message": "runtime node installer completed",
}))
PY
)"
  api_post "/runtime-node-joins/complete" "${payload}"
}

HOSTNAME_VALUE="$(hostname -s)"
PRIMARY_IP="$(primary_ip)"

CURRENT_STEP="claim"
claim_join "${HOSTNAME_VALUE}" "${PRIMARY_IP}"

CURRENT_STEP="manifest"
report_status "INSTALLING" "${CURRENT_STEP}" "downloading runtime manifest"
download_file "${MANIFEST_URL}" "${MANIFEST_PATH}"
load_manifest_env

CURRENT_STEP="packages"
report_status "INSTALLING" "${CURRENT_STEP}" "installing runtime packages"
install_packages

CURRENT_STEP="kind"
report_status "INSTALLING" "${CURRENT_STEP}" "installing kind"
install_kind

CURRENT_STEP="runtime-user"
report_status "INSTALLING" "${CURRENT_STEP}" "creating runtime user"
setup_runtime_user

CURRENT_STEP="services"
report_status "INSTALLING" "${CURRENT_STEP}" "configuring docker and libvirt"
configure_services

CURRENT_STEP="runtime-dirs"
report_status "INSTALLING" "${CURRENT_STEP}" "preparing runtime directories"
prepare_runtime_dirs

CURRENT_STEP="runtime-bundle"
report_status "INSTALLING" "${CURRENT_STEP}" "installing runtime bundle"
install_runtime_bundle

CURRENT_STEP="golden-image"
report_status "INSTALLING" "${CURRENT_STEP}" "installing golden image"
install_golden_image

CURRENT_STEP="complete"
report_status "INSTALLING" "${CURRENT_STEP}" "registering runtime node"
complete_join

echo "Runtime node join completed."
