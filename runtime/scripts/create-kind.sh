#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'USAGE'
Usage: create-kind.sh --session-id <id> [--exam-type <type>] [--exam-set-id <id>] [--dry-run] [--verbose]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id|--exam-type|--exam-set-id) shift 2 ;;
    --dry-run|--verbose) shift ;;
    --help|-h) show_help; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; show_help >&2; exit 2 ;;
  esac
done
