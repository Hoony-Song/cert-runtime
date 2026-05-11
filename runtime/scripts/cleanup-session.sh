#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
Usage: cleanup-session.sh --session-id <id> [--exam-type <type>] [--exam-set-id <id>] [--dry-run] [--verbose]

Deletes per-session resources. This skeleton only validates CLI parsing.
USAGE
}

SESSION_ID=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --exam-type|--exam-set-id) shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) shift ;;
    --help|-h) show_help; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; show_help >&2; exit 2 ;;
  esac
done

if [[ "$DRY_RUN" == true ]]; then
  printf '{"sessionId":"%s","dryRun":true,"cleanup":"ok"}\n' "$SESSION_ID"
fi
