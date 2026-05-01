# Worker Session Manifest — w1 (ccc-dispatch-f1-20260501)

## Preamble (AE worker-manifest fragment)

Jesteś workerem w v2 pipeline. Operating rules: U1 read brief, U2 context trail, U5 tool-first verification, S3 exit on DoD, A5 structured response, A9 lineage commit prefix.

## 1. Objective

Napisz `scripts/dispatch-pre.sh` (~150-300 LOC bash), który **deterministically automates pre-dispatch phases (steps 0-3 + 5-6)** dla owner workflow. Cel: operator/owner daje manifest + project name + target repo, skrypt robi pre-flight + setup + overlay + manifest commit + dispatch — emituje session_id + PR-when-opened.

## 2. Context

Owner ma 11-krokowy canonical sequence. Dziś manualny. Cel F1: zautomatyzować kroki **0-3 + 5-6** w jeden idempotent skrypt.

Empiryczne baseline (Run 1+2 + R3, 4 dispatche zrobione manualnie):
- Wall time per single dispatch ~35 min, 3 manual interventions
- Wall time per parallel (3 workers) dispatch ~23 min, 1 manual
- Manual intervention list: B25 (CCC --resume CWD) [F2 territory], B26 (manifest abs path), B27 (PAT in manifest blocked by GitHub secret scan), B28 (pre-login codex redirect)

Tu w F1 zajmiesz B26 + B27 + B28 (zostawiasz B25 dla F2 review-merge).

## 3. Constraints

- Modify ONLY: `scripts/dispatch-pre.sh` (NEW), `tests/test-dispatch-pre.sh` (NEW), `README.md` (UPDATE z usage section)
- NIE dotykaj: niczego innego (manifests/, docs/, etc.)
- Commit prefix: `feat:` (phase = new feature)
- PR title: `feat: dispatch-pre.sh — F1 deterministic pre-dispatch orchestrator`
- Bash style: `set -euo pipefail`, idempotent, exit codes meaningful (0 success, 1-4 phase fails)
- NIE wpisuj literal PAT do skryptu — używaj env var `${GITHUB_TOKEN}` (B27 anti-pattern caught by GitHub secret scan)
- Test musi być smoke test na DRY-RUN mode (nie odpalaj real dispatchów z testu)

## 4. Expected outputs

### `scripts/dispatch-pre.sh`

Args (pozycyjne lub flags — wybierz jedno spójne):
- `--project PROJECT_SLUG` (e.g. `ccc-roll-N-YYYYMMDD`) — REQUIRED
- `--manifest-file PATH` — REQUIRED, absolute path do manifestu (B26)
- `--target-repo OWNER/REPO_UPPER` — REQUIRED, e.g. `mgit0771/CCC-ROLL-N-YYYYMMDD`
- `--worker-name NAME` — default `w1`
- `--create-repo` — opcjonalny, gh API create jeśli repo nie istnieje
- `--codex-api-key-file PATH` — default `/root/.openai-api-key`
- `--scripts-dir PATH` — default `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts` (PR #7 checkout)
- `--overlay PATH` — default `/root/2026-opus-dispatcher-ma/scripts/pre-dispatch-overlay-v2.sh`
- `--dry-run` — opcjonalny, validate args + show planned actions, no side effects

Phases:

**Phase 0 — pre-flight aggregate (fail-fast):**
- claudeuser `expiresAt > now + 1h` check (Python via subprocess albo bash arithmetic)
- `/root/.openai-api-key` exists + readable (mode 600 OK, group/other r/w → ERROR per B27 spirit)
- overlay script exists + executable
- canonical scripts dir contains `dispatch-worker.sh` z `--backend headless` support (grep)
- systemd `claude-cmd-api.service` active
- emit summary z `Status: OK/FAIL` per check

**Phase 1 — target repo (jeśli `--create-repo`):**
- gh API POST `/user/repos` z `auto_init=true`
- jeśli już istnieje → continue (idempotent)
- emit `repo_url` na stdout

**Phase 2 — setup (async nohup):**
- `nohup bash -c "GITHUB_TOKEN=... setup-repo.sh + setup-user.sh"` w background
- poll co 5-10s przez max 5 min za `User ready: ccuser-${PROJECT}` w log
- timeout → exit 2 z helpful message

**Phase 3 — overlay-v2:**
- run `${OVERLAY} ${PROJECT}` synchronous
- verify final line zawiera `done — ${PROJECT} ready for dispatch`
- jeśli nie → exit 2

**Phase 5 — manifest secret scan + transfer:**
- `grep -E '(ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9-]{20,}|ANTHROPIC_API_KEY=[A-Za-z0-9-]{20,})' ${MANIFEST_FILE}` — fail if any match (B27 prevention)
- copy manifest do `/tmp/${PROJECT}-${WORKER_NAME}-manifest.md` (abs path B26)
- echo `manifest_abs_path=...` na stdout

**Phase 6 — manifest commit + dispatch:**
- clone target repo do `/tmp/${PROJECT}-staging` (rm -rf jeśli istnieje, idempotent)
- `git checkout -b worker/${PROJECT}-${WORKER_NAME}`
- `mkdir -p manifests && cp /tmp/${PROJECT}-${WORKER_NAME}-manifest.md manifests/worker-${WORKER_NAME}.md`
- commit z `git -c user.email=mg@fractals-ai.com -c user.name=mgit0771`
- `git push -u origin worker/${PROJECT}-${WORKER_NAME}` — jeśli push rejected z `secrets`:
  - **NIE** retry naively — emit ERROR z `B27 detection: PAT/secret leaked into manifest history. Check ${MANIFEST_FILE} content + redact + re-run.` exit 3
- `git config --global --add safe.directory /root/2026-loop/repo-${PROJECT}` (B22/S7-Q fix)
- `nohup bash -c "cd /root/2026-loop/repo-${PROJECT} && bash ${SCRIPTS_DIR}/dispatch-worker.sh --project ${PROJECT} --worker-name ${WORKER_NAME} --manifest-file /tmp/${PROJECT}-${WORKER_NAME}-manifest.md --user ccuser-${PROJECT} --backend headless --codex-api-key-file ${CODEX_KEY}" > /tmp/${PROJECT}-dispatch.log 2>&1 &`
- emit dispatch PID + log path

**Phase 7 (just verify start, NIE polling):**
- sleep 5 + grep `thread started` w log
- jeśli brak → ERROR exit 4
- jeśli OK → emit `thread_id=...` na stdout
- exit 0

Output format na stdout — jeden block per phase:
```
[dispatch-pre] PROJECT=...
[dispatch-pre] Phase 0 (pre-flight): OK (claude=Xh, overlay=ok, services=active)
[dispatch-pre] Phase 1 (target repo): created OR exists, url=...
[dispatch-pre] Phase 2 (setup): user ready: ccuser-...
[dispatch-pre] Phase 3 (overlay): applied
[dispatch-pre] Phase 5 (manifest): secret-scan PASS, abs_path=/tmp/...
[dispatch-pre] Phase 6 (commit + dispatch): branch worker/..., dispatch PID=N, log=/tmp/...
[dispatch-pre] Phase 7 (verify): thread_id=019de..., codex live
[dispatch-pre] DONE — pass to F2 (review-merge) when worker DONE
```

### `tests/test-dispatch-pre.sh`

Smoke test:
- run `dispatch-pre.sh --dry-run --project test-dryrun --manifest-file /tmp/dummy.md --target-repo mgit0771/dummy` z mock manifestem
- verify output zawiera oczekiwane Phase 0/1 strings
- verify exit 0
- run z bad args (missing --project) — verify exit 1 + helpful error
- run z manifest containing fake PAT pattern (np. `g h p _` bez spacji + 25 alnum) — verify exit 3 z B27 error. **DO NOT** paste literal valid-shaped PAT string here, GitHub secret scanner will block push.
- 5-10 LOC

### `README.md` (UPDATE)

Add usage section ~20 linii:
```markdown
## dispatch-pre.sh — F1 orchestrator (steps 0-6)

Bundles pre-flight + setup + overlay + manifest commit + dispatch into single command.

### Usage
[example invocation]

### After dispatch-pre.sh
- Worker pracuje headless. Poll PID `pgrep -f 'codex exec.*${PROJECT}'`.
- Po PID gone → check `/root/codex-headless/${PROJECT}/${WORKER_NAME}/final-*.txt`.
- Wtedy F2 (`dispatch-review-merge.sh`) — coming next.
```

## 5. Definition of Done

- [ ] `scripts/dispatch-pre.sh` utworzony, ~150-300 LOC, `bash -n` clean, shellcheck clean (jeśli dostępny)
- [ ] 7 phases (0-7) zaimplementowane jak wyżej
- [ ] Wszystkie B22/B26/B27/B28 fixes wbudowane
- [ ] `tests/test-dispatch-pre.sh` 3 test cases (dry-run OK, bad args, secret scan trigger), exit 0 jeśli wszystkie pass
- [ ] `README.md` z usage section
- [ ] Commit message: `feat: dispatch-pre.sh — F1 deterministic pre-dispatch orchestrator`
- [ ] `git push origin worker/ccc-dispatch-f1-20260501-w1` OK
- [ ] PR otwarty
- [ ] **Manifest update z Status: DONE.** (ALE: jeśli scope conflict z constraint "modify ONLY scripts/", emit Final report w final.txt jak w2 z R3 — explicit acknowledge)

## 6. Materials

- Repo: `/root/2026-loop/repo-ccc-dispatch-f1-20260501/.letta/worktrees/worker-ccc-dispatch-f1-20260501-w1/`
- Source-of-truth dla 11-krokowego sequence: `git clone .../2026-loop-final /tmp/source && cd /tmp/source && git checkout ccc-dispatcher && cat ccc-dispatcher-handoff/runs/00-quick-start-cheatsheet.md ccc-dispatcher-handoff/03-BLOCKERS.md`
- opus-ma overlay-v2 reference: `/root/2026-opus-dispatcher-ma/scripts/pre-dispatch-overlay-v2.sh` (czytaj jako example bash style)
- PR #7 dispatch-worker.sh (canonical reference): `/root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts/dispatch-worker.sh`
- PAT: `GITHUB_TOKEN env var (already set, do not paste literal — B27)`
- Codex API key: `/root/.openai-api-key` (referenced jako path, never read content)

## 7. Open questions

- Args jako positional czy flags? **FLAGS** (długoterminowo łatwiej rozszerzać)
- Bash 3.x compat? **NIE wymagany** — VPS ma bash 5+, focus on readability nie portability
- Logging level? **default = info, --verbose = debug, --quiet = errors only** (opcjonalnie, jeśli czas pozwala)

---

## Final report (worker fills AFTER push, BEFORE exit)

**Status:** [DONE/BLOCKED]
**Commit SHA:** [worker fills]
**PR URL:** [worker fills]
**Lines:** [worker fills, scripts + tests + README delta]
**Decision:** [krótko co napisałeś, jakie design choices]
**Next:** Owner deleguje CCC review (Turn 1) + merge (Turn 2 same session).
**Blocked:** [none / opis]
