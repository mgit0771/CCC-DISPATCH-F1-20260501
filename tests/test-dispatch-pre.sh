#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; SCRIPT="$ROOT/scripts/dispatch-pre.sh"; TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
printf '# dummy\n' >"$TMPDIR/dummy.md"
OUT="$(bash "$SCRIPT" --dry-run --project test-dryrun --manifest-file "$TMPDIR/dummy.md" --target-repo mgit0771/dummy 2>&1)"; [[ "$OUT" == *"Phase 0 (pre-flight):"* && "$OUT" == *"Phase 1 (target repo):"* ]]
set +e; bash "$SCRIPT" --dry-run --manifest-file "$TMPDIR/dummy.md" --target-repo mgit0771/dummy >"$TMPDIR/missing.out" 2>&1; STATUS=$?; set -e; [ "$STATUS" -eq 1 ] && grep -q -- "--project is required" "$TMPDIR/missing.out"
printf 'secret=%s\n' "ghp_$(printf '%025d' 0)" >"$TMPDIR/secret.md"
set +e; bash "$SCRIPT" --dry-run --project test-dryrun --manifest-file "$TMPDIR/secret.md" --target-repo mgit0771/dummy >"$TMPDIR/secret.out" 2>&1; STATUS=$?; set -e; [ "$STATUS" -eq 3 ] && grep -q "B27 detection" "$TMPDIR/secret.out"
