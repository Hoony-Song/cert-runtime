#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
사용법: grade-session.sh --session-id <id> --exam-type <type> --exam-set-id <id> [--grading-file <path>] [--question-bank-root <path>] [--session-root <dir>] [--output-file <path>] [--dry-run] [--verbose]

question-bank grading DSL 파일을 입력으로 받아 kubernetes/command 채점을 실행하고 결과 JSON을 출력한다.
USAGE
}

SESSION_ID=""
EXAM_TYPE="CKA"
EXAM_SET_ID=""
GRADING_FILE=""
SESSION_ROOT="${CKA_SESSION_ROOT:-/var/lib/cka/sessions}"
QUESTION_BANK_ROOT="${CKA_QUESTION_BANK_ROOT:-}"
OUTPUT_FILE=""
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type) EXAM_TYPE="${2:-}"; shift 2 ;;
    --exam-set-id) EXAM_SET_ID="${2:-}"; shift 2 ;;
    --grading-file) GRADING_FILE="${2:-}"; shift 2 ;;
    --question-bank-root) QUESTION_BANK_ROOT="${2:-}"; shift 2 ;;
    --session-root) SESSION_ROOT="${2:-}"; shift 2 ;;
    --output-file) OUTPUT_FILE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --help|-h) show_help; exit 0 ;;
    *) echo "알 수 없는 인자입니다: $1" >&2; show_help >&2; exit 2 ;;
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

resolve_grading_files() {
  python3 - "${QUESTION_BANK_ROOT}" "${EXAM_TYPE}" "${EXAM_SET_ID}" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
exam_type = sys.argv[2].lower()
exam_set_id = sys.argv[3]
exam_set_file = root / "exam-sets" / exam_type / f"{exam_set_id}.yaml"

with exam_set_file.open("r", encoding="utf-8") as handle:
    exam_set = yaml.safe_load(handle) or {}

questions = exam_set.get("questions") or []
if not questions:
    raise SystemExit("exam set에 questions가 없습니다.")

for entry in questions:
    question_dir = root / "questions" / exam_type / entry["id"] / entry["version"]
    question_file = question_dir / "question.yaml"

    with question_file.open("r", encoding="utf-8") as handle:
        question = yaml.safe_load(handle) or {}

    grading_file = question_dir / (question.get("grading") or {}).get("file", "")
    print(grading_file)
PY
}

require_value "--session-id" "${SESSION_ID}"
require_value "--exam-type" "${EXAM_TYPE}"
require_value "--exam-set-id" "${EXAM_SET_ID}"
require_safe_session_id "${SESSION_ID}"
require_absolute_path "--session-root" "${SESSION_ROOT}"

SESSION_DIR="${SESSION_ROOT}/${SESSION_ID}"
KUBECONFIG_FILE="${SESSION_DIR}/kubeconfig/config"
QUESTION_BANK_ROOT="$(resolve_question_bank_root)"
require_absolute_path "--question-bank-root" "${QUESTION_BANK_ROOT}"

if [[ -z "${GRADING_FILE}" && "${DRY_RUN}" == false ]]; then
  require_value "--exam-set-id" "${EXAM_SET_ID}"
  GRADING_FILES="$(resolve_grading_files)"
else
  GRADING_FILES="${GRADING_FILE}"
fi

if [[ -z "${OUTPUT_FILE}" ]]; then
  OUTPUT_FILE="${SESSION_DIR}/artifacts/grade-result.json"
fi

if [[ "${DRY_RUN}" == true ]]; then
  if [[ -z "${GRADING_FILE}" ]]; then
    GRADING_FILES="$(resolve_grading_files 2>/dev/null || true)"
  else
    GRADING_FILES="${GRADING_FILE}"
  fi
  printf '{"sessionId":"%s","examType":"%s","examSetId":"%s","gradingFiles":%s,"outputFile":"%s","dryRun":true}\n' \
    "${SESSION_ID}" "${EXAM_TYPE}" "${EXAM_SET_ID}" "$(printf '%s\n' "${GRADING_FILES}" | sed '/^$/d' | wc -l)" "${OUTPUT_FILE}"
  exit 0
fi

require_absolute_path "--output-file" "${OUTPUT_FILE}"

if [[ -z "${GRADING_FILES}" ]]; then
  echo "grading 파일 목록이 비어 있습니다." >&2
  exit 1
fi

while IFS= read -r grading_file; do
  [[ -z "${grading_file}" ]] && continue
  require_absolute_path "--grading-file" "${grading_file}"
  if [[ ! -f "${grading_file}" ]]; then
    echo "grading 파일이 없습니다: ${grading_file}" >&2
    exit 1
  fi
done <<<"${GRADING_FILES}"

if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  echo "세션 kubeconfig 파일이 없습니다: ${KUBECONFIG_FILE}" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 명령을 찾을 수 없습니다." >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT_FILE}")"

export CKA_SESSION_ID="${SESSION_ID}"
export CKA_EXAM_TYPE="${EXAM_TYPE}"
export CKA_EXAM_SET_ID="${EXAM_SET_ID}"
export CKA_SESSION_DIR="${SESSION_DIR}"
export CKA_GRADING_FILES="${GRADING_FILES}"
export CKA_KUBECONFIG_FILE="${KUBECONFIG_FILE}"
export CKA_OUTPUT_FILE="${OUTPUT_FILE}"
export CKA_VERBOSE="${VERBOSE}"

python3 <<'PY'
import json
import os
import shlex
import subprocess
import sys
from datetime import datetime, timezone

try:
    import yaml
except Exception as exc:
    print(f"PyYAML을 불러오지 못했습니다: {exc}", file=sys.stderr)
    sys.exit(1)


def now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def load_grading(path):
    with open(path, "r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
    spec = data.get("spec", data.get("grading", data))
    checks = spec.get("checks", [])
    if not isinstance(checks, list):
        raise ValueError("grading checks는 list여야 합니다.")
    question_id = (data.get("metadata") or {}).get("questionId", "unknown")
    target_cluster = spec.get("targetCluster", "cka-kind")
    namespace = spec.get("namespace")
    max_score = int(spec.get("maxScore", sum(int(check.get("points", check.get("score", 0))) for check in checks)))
    return question_id, target_cluster, namespace, max_score, checks


def run_command(args, timeout=30):
    completed = subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=False)
    return completed.returncode, completed.stdout, completed.stderr


def load_session_state():
    state_file = os.path.join(os.environ["CKA_SESSION_DIR"], "state.json")
    with open(state_file, "r", encoding="utf-8") as handle:
        return json.load(handle)


def vm_ip(node_name):
    state = load_session_state()
    for vm in state.get("vms", []):
        if vm.get("name") == node_name:
            ip = vm.get("ip")
            if ip:
                return ip
    raise ValueError(f"세션 state에서 VM IP를 찾을 수 없습니다: {node_name}")


def remote_file_content(check):
    node = check.get("node", "cka0001")
    file_spec = check.get("file") or {}
    path = file_spec.get("path")
    if not isinstance(path, str) or not path.startswith("/"):
        raise ValueError("remote-file-line-set check에는 file.path 절대 경로가 필요합니다.")

    ssh_key = os.path.join(os.environ["CKA_SESSION_DIR"], "ssh", "session_vm")
    known_hosts = os.path.join(os.environ["CKA_SESSION_DIR"], "ssh", "known_hosts")
    args = [
        "ssh",
        "-i",
        ssh_key,
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
        f"ubuntu@{vm_ip(node)}",
        "cat",
        "--",
        path,
    ]
    return run_command(args, timeout=int(check.get("timeoutSeconds", 30)))


def remote_command(check):
    node = check.get("node", "cka0001")
    command = check.get("command")
    if not isinstance(command, str) or not command.strip():
        raise ValueError("remote-command check에는 command 문자열이 필요합니다.")

    ssh_key = os.path.join(os.environ["CKA_SESSION_DIR"], "ssh", "session_vm")
    known_hosts = os.path.join(os.environ["CKA_SESSION_DIR"], "ssh", "known_hosts")
    args = [
        "ssh",
        "-i",
        ssh_key,
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
        f"ubuntu@{vm_ip(node)}",
        f"bash -c {shlex.quote(command)}",
    ]
    return run_command(args, timeout=int(check.get("timeoutSeconds", 30)))


def kubectl_get(check, context, default_namespace):
    obj = check.get("object") or check.get("resource") or {}
    namespace = check.get("namespace") or default_namespace
    kind = obj.get("kind") or check.get("kind")
    name = obj.get("name")

    if not kind:
        raise ValueError("check에는 object.kind가 필요합니다.")
    if not name:
        raise ValueError("check에는 object.name이 필요합니다.")

    args = [
        "kubectl",
        "--kubeconfig",
        os.environ["CKA_KUBECONFIG_FILE"],
        "--context",
        context,
    ]
    if namespace:
        args.extend(["-n", namespace])
    args.extend(["get", kind, name, "-o", "json"])

    return run_command(args, timeout=int(check.get("timeoutSeconds", 30)))


def json_path_value(data, path):
    if not path.startswith("$."):
        raise ValueError(f"지원하지 않는 JSON path입니다: {path}")
    current = data
    parts = []
    buffer = []
    escaped = False
    for char in path[2:]:
        if escaped:
            buffer.append(char)
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == ".":
            parts.append("".join(buffer))
            buffer = []
            continue
        buffer.append(char)
    parts.append("".join(buffer))

    for raw_part in parts:
        part = raw_part
        while "[" in part:
            key, rest = part.split("[", 1)
            if key:
                current = current[key]
            index_text, part = rest.split("]", 1)
            current = current[int(index_text)]
            if part.startswith("."):
                part = part[1:]
        if part:
            current = current[part]
    return current


def values_equal(actual, expected):
    return actual == expected or str(actual) == str(expected)


def normalize_lines(text):
    return [line.strip() for line in text.splitlines() if line.strip()]


def evaluate_check(check, context, namespace):
    check_type = check.get("type", "kubernetes-object-exists")

    if check_type == "remote-file-line-set":
        rc, stdout, stderr = remote_file_content(check)
        if rc != 0:
            return False, rc, stderr.strip()
        file_spec = check.get("file") or {}
        expected = file_spec.get("lines") or []
        if not isinstance(expected, list):
            raise ValueError("remote-file-line-set check의 file.lines는 list여야 합니다.")
        actual_lines = normalize_lines(stdout)
        expected_lines = [str(line).strip() for line in expected if str(line).strip()]
        exact = bool(file_spec.get("exact", True))
        if exact:
            passed = sorted(actual_lines) == sorted(expected_lines)
        else:
            passed = set(expected_lines).issubset(set(actual_lines))
        detail = f"actual={sorted(actual_lines)!r}, expected={sorted(expected_lines)!r}"
        return passed, rc, detail

    if check_type == "remote-command":
        rc, stdout, stderr = remote_command(check)
        if rc != 0:
            return False, rc, (stderr or stdout).strip()
        return True, rc, (stdout or "").strip()

    rc, stdout, stderr = kubectl_get(check, context, namespace)

    if check_type == "kubernetes-object-absent":
        return rc != 0, rc, stderr.strip() if stderr.strip() else stdout.strip()

    if check_type == "kubernetes-object-exists":
        return rc == 0, rc, stdout.strip() if stdout.strip() else stderr.strip()

    if rc != 0:
        return False, rc, stderr.strip()

    if check_type == "jsonpath-equals":
        data = json.loads(stdout)
        actual = json_path_value(data, check["path"])
        expected = check.get("equals")
        return values_equal(actual, expected), rc, f"{check['path']}={actual!r}"

    raise ValueError(f"지원하지 않는 grading type입니다: {check_type}")


def grade_one(grading_file):
    question_id, target_cluster, namespace, max_score, checks = load_grading(grading_file)
    check_results = []
    earned = 0

    for index, check in enumerate(checks, start=1):
        name = check.get("id") or check.get("name") or f"check-{index}"
        check_type = check.get("type", "kubernetes-object-exists")
        score = int(check.get("points", check.get("score", 1)))
        try:
            passed, rc, detail = evaluate_check(check, target_cluster, namespace)
            if passed:
                earned += score
            check_results.append({
                "name": name,
                "type": check_type,
                "maxScore": score,
                "score": score if passed else 0,
                "passed": passed,
                "exitCode": rc,
                "detail": detail[:1000],
            })
        except Exception as exc:
            check_results.append({
                "name": name,
                "type": check_type,
                "maxScore": score,
                "score": 0,
                "passed": False,
                "exitCode": 1,
                "detail": str(exc),
            })

    total = sum(item["maxScore"] for item in check_results) or max_score
    question_status = "PASSED" if earned == total else "FAILED"
    return {
        "questionId": question_id,
        "status": question_status,
        "score": earned,
        "maxScore": total,
        "message": f"{sum(1 for item in check_results if item['passed'])}/{len(check_results)} checks passed",
        "checks": check_results,
    }


def main():
    grading_files = [line.strip() for line in os.environ["CKA_GRADING_FILES"].splitlines() if line.strip()]
    results = [grade_one(path) for path in grading_files]
    total_score = sum(item["score"] for item in results)
    max_score = sum(item["maxScore"] for item in results)
    output = {
        "sessionId": os.environ["CKA_SESSION_ID"],
        "examType": os.environ["CKA_EXAM_TYPE"],
        "examSetId": os.environ["CKA_EXAM_SET_ID"],
        "status": "FINISHED",
        "gradedAt": now(),
        "totalScore": total_score,
        "maxScore": max_score,
        "results": results,
    }

    with open(os.environ["CKA_OUTPUT_FILE"], "w", encoding="utf-8") as handle:
        json.dump(output, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(json.dumps(output, ensure_ascii=False))


main()
PY
