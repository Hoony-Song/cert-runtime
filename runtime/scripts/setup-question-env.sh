#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
Usage: setup-question-env.sh --session-id <id> --exam-type <type> --exam-set-id <id> [--dry-run] [--verbose]
USAGE
}

SESSION_ID=""
EXAM_TYPE="CKA"
EXAM_SET_ID=""
SESSION_ROOT="${CKA_SESSION_ROOT:-/var/lib/cka/sessions}"
QUESTION_BANK_ROOT="${CKA_QUESTION_BANK_ROOT:-}"
CRI_DOCKERD_DEB="${CKA_CRI_DOCKERD_DEB:-/var/lib/cka/assets/cri-dockerd_0.3.6.3-0.ubuntu-jammy_amd64.deb}"
HELM_VERSION="${CKA_HELM_VERSION:-v3.14.4}"
HELM_ARCH="${CKA_HELM_ARCH:-amd64}"
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --exam-set-id) EXAM_SET_ID="${2:-}"; shift 2 ;;
    --session-root) SESSION_ROOT="${2:-}"; shift 2 ;;
    --question-bank-root) QUESTION_BANK_ROOT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --help|-h) show_help; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; show_help >&2; exit 2 ;;
  esac
done

require_value() {
  local name="$1"
  local value="$2"

  if [[ -z "${value}" ]]; then
    echo "필수 인자가 비어 있습니다: ${name}" >&2
    exit 2
  fi
}

require_safe_session_id() {
  local value="$1"

  if [[ ! "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
    echo "session_id는 영문자, 숫자, 점, 밑줄, 하이픈만 사용할 수 있고 1~63자여야 합니다." >&2
    exit 2
  fi
}

require_absolute_path() {
  local name="$1"
  local value="$2"

  if [[ "${value}" != /* ]]; then
    echo "${name}에는 절대 경로를 사용해야 합니다: ${value}" >&2
    exit 2
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "필수 명령을 찾을 수 없습니다: ${command_name}" >&2
    exit 1
  fi
}

resolve_question_bank_root() {
  local script_dir
  local repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/../.." && pwd)"

  if [[ -n "${QUESTION_BANK_ROOT}" ]]; then
    printf '%s\n' "${QUESTION_BANK_ROOT}"
  elif [[ -d "${repo_root}/../cert-question-bank" ]]; then
    (cd "${repo_root}/../cert-question-bank" && pwd)
  elif [[ -d "/var/lib/cka/question-bank" ]]; then
    printf '%s\n' "/var/lib/cka/question-bank"
  else
    printf '%s\n' "${repo_root}/../cert-question-bank"
  fi
}

read_exam_metadata() {
  python3 - "${QUESTION_BANK_ROOT}" "${EXAM_DIR}" "${EXAM_SET_FILE}" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
exam_dir = sys.argv[2]
exam_set_file = Path(sys.argv[3])

with exam_set_file.open("r", encoding="utf-8") as handle:
    exam_set = yaml.safe_load(handle) or {}

questions = exam_set.get("questions") or []
if not questions:
    raise SystemExit("exam set에 questions가 없습니다.")

for entry in questions:
    question_id = entry["id"]
    version = entry["version"]
    question_dir = root / "questions" / exam_dir / question_id / version
    question_file = question_dir / "question.yaml"

    with question_file.open("r", encoding="utf-8") as handle:
        question = yaml.safe_load(handle) or {}

    target_cluster = question.get("targetCluster")
    setup = question.get("setup") or {}
    files = setup.get("files") or []
    if target_cluster not in {"cka-vm", "cka-kind"}:
        raise SystemExit(f"지원하지 않는 targetCluster입니다: {target_cluster}")
    if not files:
        raise SystemExit(f"{question_id}/{version} setup.files가 비어 있습니다.")

    print(f"question={question_id}|{version}|{target_cluster}|{question_dir}")
    for setup_file in files:
        path = question_dir / setup_file
        print(f"setup_file={question_id}|{target_cluster}|{path}")
PY
}

vm_ip() {
  local node="$1"
  awk -v node="${node}" '
    $1 == node {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^ansible_host=/) {
          split($i, parts, "=")
          print parts[2]
          exit
        }
      }
    }
  ' "${INVENTORY_FILE}"
}

remote_ssh() {
  local node="$1"
  shift
  local ip
  ip="$(vm_ip "${node}")"
  if [[ -z "${ip}" ]]; then
    echo "inventory에서 VM IP를 찾지 못했습니다: ${node}" >&2
    exit 1
  fi
  ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=${KNOWN_HOSTS}" \
    "ubuntu@${ip}" "$@"
}

remote_bash() {
  local node="$1"
  local script="$2"
  local quoted_script
  printf -v quoted_script '%q' "${script}"
  remote_ssh "${node}" "bash -c ${quoted_script}"
}

copy_to_vm() {
  local source="$1"
  local node="$2"
  local target="$3"
  local ip
  ip="$(vm_ip "${node}")"
  if [[ -z "${ip}" ]]; then
    echo "inventory에서 VM IP를 찾지 못했습니다: ${node}" >&2
    exit 1
  fi
  scp -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=${KNOWN_HOSTS}" \
    "${source}" "ubuntu@${ip}:${target}" >/dev/null
}

has_question() {
  local wanted="$1"
  printf '%s\n' "${QUESTION_IDS[@]}" | grep -Fxq "${wanted}"
}

install_helm_on_kind_vm() {
  remote_bash cka0002 "
    set -euo pipefail
    if ! command -v helm >/dev/null 2>&1; then
      tmpdir=\$(mktemp -d)
      curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-${HELM_ARCH}.tar.gz -o \"\$tmpdir/helm.tgz\"
      tar -C \"\$tmpdir\" -xzf \"\$tmpdir/helm.tgz\"
      sudo install -m 0755 \"\$tmpdir/linux-${HELM_ARCH}/helm\" /usr/local/bin/helm
      rm -rf \"\$tmpdir\"
    fi
    helm version --short >/dev/null
    curl -fsSL https://kubernetes-sigs.github.io/metrics-server/index.yaml >/dev/null
  "
}

install_local_path_provisioner() {
  kubectl --kubeconfig "${KUBECONFIG_FILE}" --context cka-vm \
    apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
  kubectl --kubeconfig "${KUBECONFIG_FILE}" --context cka-vm \
    -n local-path-storage rollout status deployment/local-path-provisioner --timeout=180s
  kubectl --kubeconfig "${KUBECONFIG_FILE}" --context cka-vm \
    get storageclass local-path >/dev/null
}

install_gateway_api() {
  kubectl --kubeconfig "${KUBECONFIG_FILE}" --context cka-vm \
    apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
  kubectl --kubeconfig "${KUBECONFIG_FILE}" --context cka-vm \
    wait --for=condition=Established \
      crd/gatewayclasses.gateway.networking.k8s.io \
      crd/gateways.gateway.networking.k8s.io \
      crd/httproutes.gateway.networking.k8s.io \
      --timeout=180s
  kubectl --kubeconfig "${KUBECONFIG_FILE}" --context cka-vm apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx
spec:
  controllerName: cert-platform.io/static-gateway
YAML
}

prepare_cri_dockerd_package() {
  if [[ ! -f "${CRI_DOCKERD_DEB}" ]]; then
    echo "Q017 선행 파일이 없습니다: ${CRI_DOCKERD_DEB}" >&2
    exit 1
  fi
  remote_bash cka0003 "mkdir -p /home/ubuntu/docker"
  copy_to_vm "${CRI_DOCKERD_DEB}" cka0003 "/home/ubuntu/docker/cri-dockerd_0.3.6.3-0.ubuntu-jammy_amd64.deb"
  remote_bash cka0003 "test -f /home/ubuntu/docker/cri-dockerd_0.3.6.3-0.ubuntu-jammy_amd64.deb"
}

verify_node_access() {
  kubectl --kubeconfig "${KUBECONFIG_FILE}" --context cka-vm wait --for=condition=Ready nodes --all --timeout=180s
  kubectl --kubeconfig "${KUBECONFIG_FILE}" --context cka-kind wait --for=condition=Ready nodes --all --timeout=180s
  remote_bash cka0001 "command -v kubectl >/dev/null && sudo -n test -d /etc/kubernetes/manifests"
  remote_bash cka0002 "command -v kubectl >/dev/null"
  remote_bash cka0003 "sudo -n test -d /var/lib/kubelet && sudo -n true"
}

run_prerequisites() {
  verify_node_access

  if has_question cka-q008; then
    install_helm_on_kind_vm
  fi
  if has_question cka-q009; then
    install_local_path_provisioner
  fi
  if has_question cka-q010; then
    install_gateway_api
  fi
  if has_question cka-q014; then
    curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml >/dev/null
  fi
  if has_question cka-q017; then
    prepare_cri_dockerd_package
  fi
}

wait_for_setup_deployments() {
  local question_id="$1"
  local target_cluster="$2"
  local deployments

  deployments="$(kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${target_cluster}" \
    get deployments -A -l "cert-platform.io/question-id=${question_id}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}')"

  if [[ -z "${deployments}" ]]; then
    return 0
  fi

  while IFS='|' read -r namespace name; do
    [[ -z "${namespace}" || -z "${name}" ]] && continue
    kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${target_cluster}" \
      -n "${namespace}" rollout status "deployment/${name}" --timeout=180s
  done <<<"${deployments}"
}

require_value "--session-id" "${SESSION_ID}"
require_value "--exam-type" "${EXAM_TYPE}"
require_value "--exam-set-id" "${EXAM_SET_ID}"
require_safe_session_id "${SESSION_ID}"
require_absolute_path "--session-root" "${SESSION_ROOT}"

QUESTION_BANK_ROOT="$(resolve_question_bank_root)"
require_absolute_path "--question-bank-root" "${QUESTION_BANK_ROOT}"

EXAM_DIR="$(printf '%s' "${EXAM_TYPE}" | tr '[:upper:]' '[:lower:]')"
EXAM_SET_FILE="${QUESTION_BANK_ROOT}/exam-sets/${EXAM_DIR}/${EXAM_SET_ID}.yaml"
SESSION_DIR="${SESSION_ROOT}/${SESSION_ID}"
KUBECONFIG_FILE="${SESSION_DIR}/kubeconfig/config"
INVENTORY_FILE="${SESSION_DIR}/inventory.ini"
SSH_KEY="${SESSION_DIR}/ssh/session_vm"
KNOWN_HOSTS="${SESSION_DIR}/ssh/known_hosts"

require_command python3

if [[ ! -f "${EXAM_SET_FILE}" ]]; then
  echo "exam set 파일이 없습니다: ${EXAM_SET_FILE}" >&2
  exit 1
fi

METADATA="$(read_exam_metadata)"
mapfile -t QUESTION_ROWS < <(printf '%s\n' "${METADATA}" | awk -F= '$1 == "question" { print $2 }')
mapfile -t SETUP_ROWS < <(printf '%s\n' "${METADATA}" | awk -F= '$1 == "setup_file" { print $2 }')
mapfile -t QUESTION_IDS < <(printf '%s\n' "${QUESTION_ROWS[@]}" | awk -F'|' '{ print $1 }')

if [[ "${DRY_RUN}" == true ]]; then
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","questionBankRoot":"%s","examSetFile":"%s","questions":%s,"setupFiles":%s,"dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "${QUESTION_BANK_ROOT}" "${EXAM_SET_FILE}" "${#QUESTION_ROWS[@]}" "${#SETUP_ROWS[@]}"
  exit 0
fi

require_command kubectl
require_command ssh
require_command scp
require_command curl

if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  echo "kubeconfig 파일이 없습니다: ${KUBECONFIG_FILE}" >&2
  exit 1
fi

if [[ ! -f "${INVENTORY_FILE}" ]]; then
  echo "inventory 파일이 없습니다: ${INVENTORY_FILE}" >&2
  exit 1
fi

if [[ ! -f "${SSH_KEY}" ]]; then
  echo "세션 SSH key가 없습니다: ${SSH_KEY}" >&2
  exit 1
fi

run_prerequisites

for setup_row in "${SETUP_ROWS[@]}"; do
  IFS='|' read -r question_id target_cluster setup_file <<<"${setup_row}"
  if [[ ! -f "${setup_file}" ]]; then
    echo "setup manifest가 없습니다: ${setup_file}" >&2
    exit 1
  fi
  kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${target_cluster}" apply -f "${setup_file}"
done

for question_row in "${QUESTION_ROWS[@]}"; do
  IFS='|' read -r question_id _version target_cluster _question_dir <<<"${question_row}"
  wait_for_setup_deployments "${question_id}" "${target_cluster}"
done

if [[ "${VERBOSE}" == true ]]; then
  printf '{"sessionId":"%s","examSetId":"%s","questions":%s,"appliedSetupFiles":%s,"status":"READY"}\n' \
    "${SESSION_ID}" "${EXAM_SET_ID}" "${#QUESTION_ROWS[@]}" "${#SETUP_ROWS[@]}"
fi
