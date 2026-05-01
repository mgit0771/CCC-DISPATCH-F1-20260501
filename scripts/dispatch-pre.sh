#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="dispatch-pre"
PROJECT=""; MANIFEST_FILE=""; TARGET_REPO=""; WORKER_NAME="w1"
CREATE_REPO=0; CODEX_API_KEY_FILE="/root/.openai-api-key"
SCRIPTS_DIR="/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts"
OVERLAY="/root/2026-opus-dispatcher-ma/scripts/pre-dispatch-overlay-v2.sh"
DRY_RUN=0; REPO_URL=""; SETUP_LOG=""; MANIFEST_TMP=""; STAGING_DIR=""; DISPATCH_LOG=""; DISPATCH_PID=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/dispatch-pre.sh --project PROJECT --manifest-file /abs/path/manifest.md --target-repo OWNER/REPO [--worker-name NAME] [--create-repo] [--codex-api-key-file FILE] [--scripts-dir DIR] [--overlay FILE] [--dry-run]
EOF
}

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
die() { local code="$1"; shift; printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit "$code"; }
need() { [ -n "${2:-}" ] || die 1 "Option '$1' requires a value."; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die 1 "Required command not found: $1"; }
is_root() { [ "$(id -u)" -eq 0 ]; }

need_secret_file() {
  local path="$1" label="$2" mode=""
  [ -f "$path" ] || die 1 "$label not found: $path"
  [ -r "$path" ] || die 1 "$label is not readable: $path"
  mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  if [[ "$mode" =~ ^[0-7]+$ ]] && [ "${#mode}" -ge 3 ]; then
    mode="${mode: -3}"
    [[ "${mode:1:1}" == "0" && "${mode:2:1}" == "0" ]] \
      || die 1 "$label must not be readable by group/other: $path (chmod 600 or 400)"
  fi
}

validate_args() {
  [ -n "$PROJECT" ] || die 1 "--project is required."
  [ -n "$MANIFEST_FILE" ] || die 1 "--manifest-file is required."
  [ -n "$TARGET_REPO" ] || die 1 "--target-repo is required."
  [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die 1 "--project must match ^[a-z0-9][a-z0-9-]*$"
  [[ "$WORKER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 1 "--worker-name contains unsupported characters."
  [[ "$TARGET_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 1 "--target-repo must be OWNER/REPO."
  [[ "$MANIFEST_FILE" = /* ]] || die 1 "--manifest-file must be an absolute path (B26)."
  [ -f "$MANIFEST_FILE" ] || die 1 "Manifest file not found: $MANIFEST_FILE"
  [ -r "$MANIFEST_FILE" ] || die 1 "Manifest file is not readable: $MANIFEST_FILE"
  if [ "$DRY_RUN" -eq 0 ]; then
    is_root || die 1 "Run as root for live dispatch, or add --dry-run."
    [ -n "${GITHUB_TOKEN:-}" ] || die 1 "GITHUB_TOKEN is required for setup, push, and optional repo creation."
  fi
}

claude_hours() {
  python3 -c 'import json,sys,time; data=json.load(open(sys.argv[1], "r", encoding="utf-8")); exp=float(data["claudeAiOauth"]["expiresAt"]); exp=exp/1000.0 if exp > 10**12 else exp; rem=exp-time.time(); print(f"{rem/3600:.1f}"); raise SystemExit(0 if rem > 3600 else 1)' \
    /home/claudeuser/.claude/.credentials.json
}

latest_headless_log() {
  local dir="/root/codex-headless/${PROJECT}/${WORKER_NAME}"
  [ -d "$dir" ] || return 1
  find "$dir" -maxdepth 1 -type f -name 'run-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-
}

need_gh_auth() {
  need_cmd gh; need_cmd git
  gh auth status --hostname github.com >/dev/null 2>&1 && return 0
  printf '%s\n' "$GITHUB_TOKEN" | gh auth login --hostname github.com --with-token >/dev/null 2>&1 \
    || die 1 "gh auth login failed for github.com"
  gh auth setup-git --hostname github.com >/dev/null 2>&1 || die 1 "gh auth setup-git failed for github.com"
}

phase0() {
  local hours=""
  if [ "$DRY_RUN" -eq 1 ] && ! is_root; then
    log "Phase 0 (pre-flight): OK (dry-run, privileged checks skipped)"
    return 0
  fi
  need_cmd python3; need_cmd grep; need_cmd stat; need_cmd systemctl
  hours="$(claude_hours)" || die 1 "claudeuser credentials are unreadable or expire within 1h."
  need_secret_file "$CODEX_API_KEY_FILE" "Codex API key file"
  [ -x "$OVERLAY" ] || die 1 "Overlay is missing or not executable: $OVERLAY"
  for file_name in setup-repo.sh setup-user.sh dispatch-worker.sh; do
    [ -f "$SCRIPTS_DIR/$file_name" ] || die 1 "Missing $file_name under $SCRIPTS_DIR"
  done
  grep -Eq -- '--backend.*headless|headless.*--backend' "$SCRIPTS_DIR/dispatch-worker.sh" \
    || die 1 "dispatch-worker.sh does not advertise --backend headless support."
  systemctl is-active --quiet claude-cmd-api.service || die 1 "claude-cmd-api.service is not active."
  log "Phase 0 (pre-flight): OK (claude=${hours}h, overlay=ok, services=active)"
}

phase1() {
  REPO_URL="https://github.com/${TARGET_REPO}"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Phase 1 (target repo): DRY-RUN $([ "$CREATE_REPO" -eq 1 ] && printf 'create' || printf 'exists'), url=${REPO_URL}"
    return 0
  fi
  need_gh_auth
  if REPO_URL="$(gh repo view "$TARGET_REPO" --json url --jq .url 2>/dev/null)"; then
    log "Phase 1 (target repo): exists, url=${REPO_URL}"
    return 0
  fi
  [ "$CREATE_REPO" -eq 1 ] || die 1 "Target repo does not exist and --create-repo was not set: $TARGET_REPO"
  local owner="${TARGET_REPO%%/*}" name="${TARGET_REPO#*/}" login="" output="" status=0
  login="$(gh api user --jq .login 2>/dev/null || true)"
  [ -n "$login" ] || die 1 "Unable to resolve the authenticated GitHub user."
  [ "$owner" = "$login" ] || die 1 "--create-repo uses POST /user/repos and requires OWNER=$login: $TARGET_REPO"
  set +e
  output="$(gh api --method POST /user/repos -f name="$name" -F auto_init=true -F private=true --jq .html_url 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    if REPO_URL="$(gh repo view "$TARGET_REPO" --json url --jq .url 2>/dev/null)"; then
      log "Phase 1 (target repo): exists, url=${REPO_URL}"
      return 0
    fi
    die 1 "Failed to create ${TARGET_REPO}: ${output}"
  fi
  REPO_URL="$output"
  log "Phase 1 (target repo): created, url=${REPO_URL}"
}

phase2() {
  local setup_cmd="" setup_pid="" deadline=0
  SETUP_LOG="/tmp/${PROJECT}-${WORKER_NAME}-setup.log"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Phase 2 (setup): DRY-RUN, log=${SETUP_LOG}"
    return 0
  fi
  printf -v setup_cmd 'bash %q --project %q --repo %q && bash %q --project %q --codex-api-key-file %q' \
    "${SCRIPTS_DIR}/setup-repo.sh" "$PROJECT" "$TARGET_REPO" "${SCRIPTS_DIR}/setup-user.sh" "$PROJECT" "$CODEX_API_KEY_FILE"
  : > "$SETUP_LOG"
  GITHUB_TOKEN="$GITHUB_TOKEN" nohup bash -c "$setup_cmd" >"$SETUP_LOG" 2>&1 &
  setup_pid=$!; deadline=$((SECONDS + 300))
  while [ "$SECONDS" -lt "$deadline" ]; do
    grep -Fq "User ready: ccuser-${PROJECT}" "$SETUP_LOG" && { log "Phase 2 (setup): user ready: ccuser-${PROJECT}"; return 0; }
    kill -0 "$setup_pid" 2>/dev/null || die 2 "Setup failed before 'User ready: ccuser-${PROJECT}'. Check ${SETUP_LOG}."
    sleep 5
  done
  die 2 "Setup timed out after 300s waiting for 'User ready: ccuser-${PROJECT}' in ${SETUP_LOG}."
}

phase3() {
  local output="" final_line=""
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Phase 3 (overlay): DRY-RUN, would run ${OVERLAY} ${PROJECT}"
    return 0
  fi
  output="$("$OVERLAY" "$PROJECT" 2>&1)" || die 2 "Overlay failed for ${PROJECT}."
  final_line="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$final_line" == *"done — ${PROJECT} ready for dispatch" ]] \
    || die 2 "Overlay output did not end with the expected ready marker."
  log "Phase 3 (overlay): applied"
}

phase5() {
  MANIFEST_TMP="/tmp/${PROJECT}-${WORKER_NAME}-manifest.md"
  grep -Eq '(ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9-]{20,}|ANTHROPIC_API_KEY=[A-Za-z0-9-]{20,})' "$MANIFEST_FILE" \
    && die 3 "B27 detection: PAT/secret leaked into manifest history. Check ${MANIFEST_FILE} content + redact + re-run."
  [ "$DRY_RUN" -eq 0 ] && install -m 600 "$MANIFEST_FILE" "$MANIFEST_TMP"
  log "Phase 5 (manifest): secret-scan PASS, abs_path=${MANIFEST_TMP}"
}

phase6() {
  local branch="worker/${PROJECT}-${WORKER_NAME}" repo_path="/root/2026-loop/repo-${PROJECT}" pr_url="" push_output="" push_status=0 dispatch_cmd=""
  STAGING_DIR="/tmp/${PROJECT}-staging"; DISPATCH_LOG="/tmp/${PROJECT}-dispatch.log"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Phase 6 (commit + dispatch): DRY-RUN, branch ${branch}, log=${DISPATCH_LOG}"
    return 0
  fi
  need_gh_auth
  rm -rf -- "$STAGING_DIR"
  git clone "https://github.com/${TARGET_REPO}.git" "$STAGING_DIR" >/dev/null 2>&1 \
    || die 2 "Failed to clone ${TARGET_REPO} into ${STAGING_DIR}."
  if git -C "$STAGING_DIR" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    git -C "$STAGING_DIR" fetch origin "$branch" >/dev/null 2>&1 || die 2 "Failed to fetch existing branch ${branch}."
    git -C "$STAGING_DIR" checkout -B "$branch" FETCH_HEAD >/dev/null 2>&1 || die 2 "Failed to checkout existing branch ${branch}."
  else
    git -C "$STAGING_DIR" checkout -b "$branch" >/dev/null 2>&1 || die 2 "Failed to create branch ${branch}."
  fi
  mkdir -p "$STAGING_DIR/manifests"
  cp "$MANIFEST_TMP" "$STAGING_DIR/manifests/worker-${WORKER_NAME}.md"
  git -C "$STAGING_DIR" add "manifests/worker-${WORKER_NAME}.md"
  if ! git -C "$STAGING_DIR" diff --cached --quiet; then
    git -C "$STAGING_DIR" -c user.email=mg@fractals-ai.com -c user.name=mgit0771 commit -m "chore: add worker-${WORKER_NAME} manifest for ${PROJECT}" >/dev/null 2>&1 \
      || die 2 "Failed to commit manifest branch ${branch}."
  fi
  set +e
  push_output="$(git -C "$STAGING_DIR" push -u origin "$branch" 2>&1)"
  push_status=$?
  set -e
  if [ "$push_status" -ne 0 ]; then
    grep -qiE 'GH009|GH013|secret|push protection|repository rule violation' <<<"$push_output" \
      && die 3 "B27 detection: PAT/secret leaked into manifest history. Check ${MANIFEST_FILE} content + redact + re-run."
    die 2 "Push failed for ${branch}. Check ${STAGING_DIR}."
  fi
  git config --global --add safe.directory "$repo_path" >/dev/null 2>&1 || true
  printf -v dispatch_cmd 'cd %q && bash %q --project %q --worker-name %q --manifest-file %q --user %q --backend headless --codex-api-key-file %q' \
    "$repo_path" "${SCRIPTS_DIR}/dispatch-worker.sh" "$PROJECT" "$WORKER_NAME" "$MANIFEST_TMP" "ccuser-${PROJECT}" "$CODEX_API_KEY_FILE"
  : > "$DISPATCH_LOG"
  nohup bash -c "$dispatch_cmd" >"$DISPATCH_LOG" 2>&1 &
  DISPATCH_PID=$!
  pr_url="$(gh pr list --repo "$TARGET_REPO" --head "$branch" --json url --jq '.[0].url' 2>/dev/null || true)"
  log "Phase 6 (commit + dispatch): branch ${branch}, dispatch PID=${DISPATCH_PID}, log=${DISPATCH_LOG}${pr_url:+, pr=${pr_url}}"
}

phase7() {
  local headless_log="" thread_id=""
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Phase 7 (verify): DRY-RUN, would inspect /root/codex-headless/${PROJECT}/${WORKER_NAME}/run-*.log"
    return 0
  fi
  sleep 5
  headless_log="$(latest_headless_log || true)"
  [ -n "$headless_log" ] || die 4 "Dispatch log exists but no headless run log was created under /root/codex-headless/${PROJECT}/${WORKER_NAME}."
  grep -Fq 'thread started:' "$headless_log" || die 4 "Dispatch started but no 'thread started' marker was found in ${headless_log}."
  thread_id="$(sed -n 's/^thread started: //p' "$headless_log" | tail -n 1)"
  [ -n "$thread_id" ] || die 4 "Found 'thread started' but could not parse thread_id from ${headless_log}."
  log "Phase 7 (verify): thread_id=${thread_id}, codex live"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project|--manifest-file|--target-repo|--worker-name|--codex-api-key-file|--scripts-dir|--overlay)
      need "$1" "${2:-}"
      case "$1" in
        --project) PROJECT="$2" ;;
        --manifest-file) MANIFEST_FILE="$2" ;;
        --target-repo) TARGET_REPO="$2" ;;
        --worker-name) WORKER_NAME="$2" ;;
        --codex-api-key-file) CODEX_API_KEY_FILE="$2" ;;
        --scripts-dir) SCRIPTS_DIR="$2" ;;
        --overlay) OVERLAY="$2" ;;
      esac
      shift 2
      ;;
    --create-repo) CREATE_REPO=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die 1 "Unknown argument: $1" ;;
  esac
done

validate_args
log "PROJECT=${PROJECT}"
phase0
phase1
phase2
phase3
phase5
phase6
phase7
log "DONE — pass to F2 (review-merge) when worker DONE"
