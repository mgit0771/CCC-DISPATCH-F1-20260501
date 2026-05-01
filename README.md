# CCC-DISPATCH-F1-20260501
ccc-dispatcher F1 build (dispatch-pre.sh orchestrator)

## dispatch-pre.sh — F1 orchestrator (steps 0-6)

Bundles pre-flight + setup + overlay + manifest commit + dispatch into one command.

### Usage
Run as `root` with `GITHUB_TOKEN` exported:

```bash
export GITHUB_TOKEN=...

bash scripts/dispatch-pre.sh \
  --project ccc-roll-n-20260501 \
  --manifest-file /abs/path/to/worker-manifest.md \
  --target-repo mgit0771/CCC-ROLL-N-20260501 \
  --worker-name w1 \
  --create-repo
```

Defaults:
- `--codex-api-key-file /root/.openai-api-key`
- `--scripts-dir /root/2026-codex-app-dispatcher/COMP-LOOP-ENV/scripts`
- `--overlay /root/2026-opus-dispatcher-ma/scripts/pre-dispatch-overlay-v2.sh`
- `--dry-run` validates flags, scans the manifest, and prints planned actions without side effects.

### After dispatch-pre.sh
- Worker works headless. Poll PID with `pgrep -f "codex exec.*${PROJECT}"`.
- After the PID is gone, inspect `/root/codex-headless/${PROJECT}/${WORKER_NAME}/final-*.txt`.
- Then hand off to F2 (`dispatch-review-merge.sh`) for review and merge.
