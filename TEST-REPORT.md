# TEST-REPORT

Living per-iteration test report, maintained per the Testing Discipline iron
rule (main repo AGENTS.md, 2026-09-06).

Layer definitions: L1 static (bash -n, shellcheck, gitleaks, no-Chinese scan),
L2 config validation, L3 runtime smoke in a disposable environment, L4
host-level lifecycle.

---

## 2026-09-06T20:25:45Z — commit ea93839 (Round 2 Day 11 backfill: CI pipeline, shellcheck + printf fixes)

**Layers executed: L1, L2. L3/L4 not run.**

| Check | Result |
|---|---|
| L1 bash -n sweep (scripts + mb) | PASS |
| L1 shellcheck -S warning gate | PASS (0 findings; 8 fixed in iter/ai-ci-validate) |
| L1 gitleaks history scan (allowlist: historical virtual-key docs example, commit 3f205a26) | PASS (exit 0) |
| L1 no-Chinese content scan (CI job, run 34046306486) | PASS |
| L2 compose config: 10 compose units under compose/ (excluding *-config.yaml app configs) | PASS (10 valid, 0 failed) |

Defects found during this development cycle (fixed pre-push, verified):

- mb_detail printed with 4 printf conversions but 3 arguments, silently
  dropping the reset color from every detail line - real format-string bug,
  fixed (iter/ai-ci-validate).
- Dead MB_DEPLOY_DIR removed; MB_MODELS_DIR retained after repo-wide grep
  found lib/model.sh consuming it.
- CI compose glob initially matched application configs (litellm-config.yaml)
  as compose units; restricted to *.yml compose units with the app-config
  exclusion (ea93839).

Known issues (open): baseline security properties (unauthenticated access
rejected, backends unreachable from outside, resource limits effective) are
unverified - Round 3 iter/ai-backend-isolation owns them.

Untested (honest boundaries):

- L3 runtime smoke: no inference stack was booted this cycle; compose files
  are config-valid only. CPU-profile smoke of Ollama + Open WebUI is the next
  runtime evidence step (images are multi-GB pulls; data dirs on /Volumes/D).
- L4 host-level: GPU pass-through, auth enforcement at the gateway, and
  model-provenance checks not run - blocked on an NVIDIA host and disposable
  environment.
