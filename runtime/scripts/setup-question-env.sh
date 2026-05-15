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

require_value "--session-id" "${SESSION_ID}"
require_value "--exam-type" "${EXAM_TYPE}"
require_value "--exam-set-id" "${EXAM_SET_ID}"
require_safe_session_id "${SESSION_ID}"
require_absolute_path "--session-root" "${SESSION_ROOT}"

QUESTION_BANK_ROOT="$(resolve_question_bank_root)"
require_absolute_path "--question-bank-root" "${QUESTION_BANK_ROOT}"

EXAM_DIR="$(printf '%s' "${EXAM_TYPE}" | tr '[:upper:]' '[:lower:]')"
EXAM_SET_FILE="${QUESTION_BANK_ROOT}/exam-sets/${EXAM_DIR}/${EXAM_SET_ID}.yaml"
KUBECONFIG_FILE="${SESSION_ROOT}/${SESSION_ID}/kubeconfig/config"

read_question_metadata() {
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

entry = questions[0]
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
    raise SystemExit("setup.files가 비어 있습니다.")

print(f"question_id={question_id}")
print(f"version={version}")
print(f"target_cluster={target_cluster}")
print(f"question_dir={question_dir}")
for setup_file in files:
    path = question_dir / setup_file
    print(f"setup_file={path}")
PY
}

if [[ "${DRY_RUN}" == true ]]; then
  METADATA="$(read_question_metadata)"
  TARGET_CLUSTER="$(printf '%s\n' "${METADATA}" | awk -F= '$1 == "target_cluster" { print $2; exit }')"
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","questionBankRoot":"%s","examSetFile":"%s","targetCluster":"%s","kubeconfig":"%s","dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "${QUESTION_BANK_ROOT}" "${EXAM_SET_FILE}" "${TARGET_CLUSTER}" "${KUBECONFIG_FILE}"
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 명령을 찾을 수 없습니다." >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl 명령을 찾을 수 없습니다." >&2
  exit 1
fi

if [[ ! -f "${EXAM_SET_FILE}" ]]; then
  echo "exam set 파일이 없습니다: ${EXAM_SET_FILE}" >&2
  exit 1
fi

if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  echo "kubeconfig 파일이 없습니다: ${KUBECONFIG_FILE}" >&2
  exit 1
fi

METADATA="$(read_question_metadata)"
QUESTION_ID="$(printf '%s\n' "${METADATA}" | awk -F= '$1 == "question_id" { print $2; exit }')"
TARGET_CLUSTER="$(printf '%s\n' "${METADATA}" | awk -F= '$1 == "target_cluster" { print $2; exit }')"
mapfile -t SETUP_FILES < <(printf '%s\n' "${METADATA}" | awk -F= '$1 == "setup_file" { print $2 }')

if [[ "${#SETUP_FILES[@]}" -eq 0 ]]; then
  echo "적용할 setup manifest가 없습니다." >&2
  exit 1
fi

for setup_file in "${SETUP_FILES[@]}"; do
  if [[ ! -f "${setup_file}" ]]; then
    echo "setup manifest가 없습니다: ${setup_file}" >&2
    exit 1
  fi
  kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${TARGET_CLUSTER}" apply -f "${setup_file}"
done

if [[ "${VERBOSE}" == true ]]; then
  printf '{"sessionId":"%s","examSetId":"%s","questionId":"%s","targetCluster":"%s","appliedSetupFiles":%s}\n' \
    "${SESSION_ID}" "${EXAM_SET_ID}" "${QUESTION_ID}" "${TARGET_CLUSTER}" "${#SETUP_FILES[@]}"
fi
