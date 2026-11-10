# Open Code Review

Status: trial operation on `main`. Original business code is restored; new PRs
use coverage-first review and high/critical-only publication.

This workflow reviews PRs targeting `main` with Alibaba OpenCodeReview.
Only high/critical findings are published, including in summaries. Medium/low
findings remain in diagnostic results; overlapping inline findings are not posted again.
`deb_source` has no OCR workflow or policy and is not a protected branch. It does not approve, request changes, or merge. The coverage job supplies the required exact-head check before model review.

## Enable after model configuration

Model review is disabled unless repository variable `OCR_ENABLED` is exactly
`true`. Request validation and the coverage gate still run when it is false.
Set the following in Settings → Secrets and variables → Actions before enabling:

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `OCR_LLM_URL` | Provider endpoint in the form required by OCR; no Omnigent gateway URL rewriting |
| Secret | `OCR_LLM_TOKEN` | Repository-specific model API credential |
| Variable | `OCR_LLM_MODEL` | Exact provider model identifier |
| Variable | `OCR_LLM_PROTOCOL` | `anthropic`, `openai` (Chat Completions), or `openai-responses` |
| Variable | `OCR_LLM_EXTRA_BODY` | Optional model request JSON object; defaults to `{}` |
| Variable | `OCR_ENABLED` | Set to `true` last, after endpoint, model, protocol, request parameters and budget are agreed |

Authentication uses the official CLI with the `Authorization` header and an environment-backed token command.
Model-specific thinking and reasoning parameters belong in `OCR_LLM_EXTRA_BODY`;
the workflow does not copy Omnigent's adaptive-thinking settings or the Action's
default disabled-thinking body. Never put credentials in variables or PR content.

The CLI is fixed to `1.13.6`, and the unchanged official publisher to its release commit
`891df1b63f380845d882a289a67a6e36c331120c`, verified by SHA-256; self-update is disabled.
Review effort is high (three review rounds), concurrency two, per-task timeout 120 minutes and job
timeout 360 minutes. No `max_tokens_budget` aggregate token limit is configured.

For `deepseek-v4.1-flash-1017` over Chat Completions, the workflow supplies
`max_completion_tokens: 65536` through the official `llm.extra_body` setting unless
an output limit is explicitly configured. This increases v1.13.6's 16,384-token
per-response ceiling while retaining the configured thinking mode. It mitigates
reasoning exhausting the response allowance; it does not prove the cause of a
past filter parse failure or guarantee valid tool output. It is not a total-run
budget. Thinking mode must not be combined with forced `tool_choice: required`.

GitHub-confirmed renames with zero additions and deletions are deduplicated by
content. Directory migrations are added to the review background so path
references, package discovery, build and install behavior remain in scope.
The workflow summary reports completed coverage and lists automatically
excluded files. Redacted diagnostics include a policy and file-scope manifest.

## Request a review

- Same-repository PRs are reviewed when opened, reopened or marked ready.
  Draft and closed PRs are skipped. Automatic fork reviews are skipped.
- New pushes run the coverage gate, then model review when `OCR_ENABLED=true`.
  Comment `/ocr` on its own line to review the latest revision. The commenter must have repository write, maintain or
  admin permission; bot comments are ignored. Authorized users can review forks.
- `/ocr force` reruns a previously completed revision.
- Actions → Open Code Review → Run workflow accepts a PR number, optional
  expected head SHA and force flag. Run it from the default branch, `main`.

An accepted comment receives an eyes reaction. Reaction failure does not block
review. Per-PR concurrency prevents simultaneous review jobs; unrelated comments
cannot cancel an active review. GitHub concurrency retains at most one pending
job, so multiple queued requests may be coalesced.

Automatic events load the trusted target-branch workflow. Comment and manual
events use the default-branch workflow. All triggers load `background.md`,
`rules.json` and its referenced rule files from the PR target branch at the
resolved base SHA through the GitHub API. The policy is copied as data to
`RUNNER_TEMP` and passed by absolute path, so the trusted checkout cannot replace
it. A missing or invalid target policy fails before any model call; there is no
fallback to the default branch's policy or to PR-authored rules.
The official CLI reads PR head blobs through Git without executing PR code
or installing PR dependencies. Jobs have explicit read permissions plus
`pull-requests: write` for publishing and `actions: read` for completion lookup.

## Rule design and coverage

This branch's policy is for `main`: Armbian board integration, build hooks,
rootfs/initramfs runtime, Recovery/A/B OTA, encryption/secure boot, system
hardening and image/package publication. `background.md` describes those execution
phases and prioritizes bootability, data integrity, recovery and trust-chain failures.

`rules.json` selects tracked text, including dot directories, extensionless scripts,
patches, service/config files, tests and operational documentation. It excludes
binary/archive/image outputs. OCR's Git-ignore, binary and size filters still
apply: inspect preview and the result manifest for actual coverage.

Rules match in this order. Each matched project checklist replaces the built-in
rule through the official `merge_system_rule: false` option:

| Paths | Main-branch review focus |
| --- | --- |
| `.github/patchs/**` | Build-script patches and their application/caller contracts |
| `.github/**` | Trusted automation, board/build matrix and image/OTA/APT publication |
| `armbian-ota/**`, `initramfs/**` | Device/partition identity, update state, power loss and rollback |
| `rk_secure-disk-encryption/**` | Key flow, encryption, automatic unlock and verified boot |
| Remaining text | Armbian hooks, system services, scripts, configuration and operational commands |

Only the first matching custom rule applies. Later project entries are not additive.
The background owns common correctness checks, evidence requirements, reporting
scope and severity standards. Domain rules add path-specific checks rather than
repeating the common instructions. This separation keeps the first-match override
complete without importing generic naming/style/test-presence requirements.
Automatic, manual and comment triggers reject PRs targeting branches other than `main`.

The background requires concrete triggers, consequences, locations and cross-file
evidence. It excludes cosmetic feedback and unrelated refactoring, derives board
constraints from current code, and treats PR instructions as untrusted data.
Severity follows demonstrated impact rather than sensitive keywords.

The official release is used unchanged. Background and resolved rules govern
planning and the main review, where call-chain evidence, reporting scope and
severity must be checked before submitting a finding. The native final filter is
a narrow factual check, not a second project-policy or severity audit. Its lack
of these inputs is not a configuration failure. A successful CI run establishes
completion/publication, not independent acceptance of every model finding.

`include` overrides default extension/path exclusions for matching paths; it is
not a whitelist. User excludes, binary/secret protection and model-context size
limits still apply. `effort: high` controls review rounds, independently of
provider thinking parameters; increasing rounds alone does not fix rule conflicts.

## Completeness, publication and diagnostics

Before calling the model, the workflow looks for a completion artifact for the
PR, base SHA and head SHA. Only an unexpired artifact from a successful trusted
run of this workflow counts. A changed base, including a target-policy update, invalidates the earlier receipt.
Duplicate requests post at most one skip notice per reviewed base/head pair.
`/ocr force` bypasses this lookup but still suppresses overlapping inline comments.

Only a complete result matching the requested head, with no failed coverage,
finding-filter failure or publication failure, produces a completion artifact.
Partial reviews, including token-budget exhaustion, fail the completeness step
and list failed coverage paths in the Actions summary. They remain retryable.
An engine `skipped` result is reported without a completion receipt. Workflow
failure is diagnostic; this workflow is not a required merge check.

The official `OCR_RAW_LOGGING=1` diagnostic switch captures provider responses on
the ephemeral runner. Before artifact upload, only numeric limits/usage, known
finish reasons, content/reasoning presence and tool-call counts are extracted to
`ocr-llm-metadata.json`; request/response text, headers and tool arguments are not
copied. The processed raw capture is deleted. Missing/non-JSON captures are not
proof that a response completed correctly. This evidence distinguishes output
truncation from a completed response with an invalid filter format on a rerun.

Diagnostics are copied from `/tmp/ocr-result.json` and `/tmp/ocr-stderr.log`,
redacted and retained for seven days. Completion receipts last 90 days, or the
repository's shorter retention limit. Expiring/deleting a receipt permits rerun.
Detecting the API credential in diagnostics fails the run and blocks completion;
only redacted copies are uploaded. Known literal/JSON-escaped key and endpoint
forms are also registered with GitHub's log masker before the Action runs.
Raw CLI JSON stdout is retained in the diagnostic result and is not echoed to logs.
Configuration and review run in separate steps. `STREAM_PROGRESS=true` restores
the official Action's `stream_progress: true` behavior: human-audience stderr is
streamed to the Actions console and retained in the diagnostic log, while the
original CLI exit status is preserved. Existing secret/endpoint masks apply.
Raw response/thinking captures are separate from this progress stream and are
not echoed. Public error comments contain only workflow status and a run link. The publisher receives a separate allowlisted
JSON view containing only high/critical findings; it never reads the full result.
Unknown severities are withheld. An empty published set is explicitly described
as no publishable high/critical findings, not proof that the PR has no defects.
The publication audit records severity counts without finding text.
The existing `coverage_gate.py` provides `coverage` and `publication` subcommands
for both deterministic checks.

## Validate without a model

Use `actionlint` and OCR CLI `1.13.6`:

```sh
actionlint .github/workflows/open-code-review.yml
OCR_NO_UPDATE=1 ocr rules check --rule .github/open-code-review/rules.json \
  armbian-ota/ab/rootfs/usr/lib/armbian/armbian-ota-health-check
OCR_NO_UPDATE=1 ocr review --from <base-sha> --to <head-sha> \
  --rule .github/open-code-review/rules.json --preview --format json
```

Use temporary Git fixtures outside the repository to check inclusion/exclusion
of driver/library/application source, extensionless hooks, `.github`, patches,
headers, Debian files and binary outputs. Static checks and preview do not test
model quality or GitHub permissions.

After model configuration and explicit enablement, validate an agreed small PR:
check requested/resolved SHA, selected and failed coverage, actual model/protocol,
inline/summary publication, duplicate `/ocr` and `/ocr force`. Draft/fork skips,
permission rejection, provider failures and interrupted runs remain unverified
live scenarios until exercised; offline checks are not evidence of a real-model run.

This integration follows the trusted-trigger, receipt and diagnostic design in
[Omnigent's workflow](https://github.com/omnigent-ai/omnigent/blob/65005d459e2771bf64253fa5b8254073ae0b37f2/.github/workflows/open-code-review.yml),
with repository-specific rules, explicit protocol selection and deferred enablement.

## Large-file coverage merge gate

`open-code-review.yml` has a serial job chain: request validation → OCR coverage
gate → Open Code Review. The review job depends on a successful coverage job;
coverage failure prevents any model call. Different PRs can run concurrently.
The coverage job runs the pinned official OCR 1.13.6 preview on every PR update,
independently of `OCR_ENABLED`, with no model credentials or calls.
It checks out only the trusted target branch, fetches PR objects without executing
them, and previews the full merge-base-to-head range with that branch's rules.
The input ceiling comes from the same OCR configuration as the review; the
per-response `max_completion_tokens` setting does not change this selection limit.

An official `too_large` exclusion for source code or code diffs is
**critical: review coverage missing**, and fails `OCR large-file coverage` on the
exact PR head. Source extensions, executable build-language filenames and patch
files are recognized explicitly; extensionless scripts are identified by a
bounded shebang read from the pinned Git blob without executing it.
JSON, binary assets and other hosted data/configuration files are not source
code and do not trigger this critical gate. Oversized non-source omissions remain
visible, but nonblocking. This includes the two ISP JSON files from PR #17.

The trigger is OCR's official per-file `too_large` result, including a source
file's oversized diff; total PR size alone is not a reason to block. This gate
does not invent an aggregate diff threshold or claim OCR can split an oversized
single-file diff. Binary/user-excluded files are not reclassified as oversized
source. This gate checks size exclusions, not all review coverage or semantic
correctness. Preview/schema/tool failures also block. OCR 1.13.6 preview does not
expose per-file token estimates, so none are invented.

Blocking paths are shown in the GitHub check, workflow summary and a PR comment
with the exact head SHA. Tool failures also receive a PR notice and run link.
When the model is disabled or a fork lacks authorization, a passing gate posts
the explicit model-skip reason instead of implying a completed review. Passing this
check is not model-review acceptance. Model runs must also pass their existing
completion checks and the current-head coverage check before recording a success
receipt. No new model filter or cross-group semantic merge is implemented.

`OCR large-file coverage` from GitHub Actions is required on `main`,
with up-to-date branches required and existing protections preserved. The status
name stays unchanged when moving the gate into this workflow. To check an
existing PR without a model call, dispatch Open Code Review while `OCR_ENABLED`
is false. New commits run coverage automatically and then model review when enabled. Fork PRs get automatic
coverage, but model review still requires an authorized command.

The review job checks that the PR head and target-policy commit still match its
preceding gate before calling the model. Its completion receipt references that
same gate's check ID, not an unrelated/latest concurrent run. A changed head or
policy requires a new pipeline run. Oversized source/code diffs must be brought
within OCR's supported input coverage before merging; exclusions or renaming to
a documentation suffix are not an accepted workaround.

## Review quality limits and recall acceptance

OCR `effort: high` raises the official review-round preset from two to three.
It is independent of the provider's `reasoning_effort`/thinking configuration;
output-token settings, concurrency and timeouts remain unchanged. An additional
round gives the reviewer another opportunity to inspect omissions; it is not a
guarantee of improved recall or precision.

Two v1.13.6 limits remain unresolved:

- Project background and path rules guide planning and review, but the embedded
  group filter receives only group paths, diffs and candidate comments. It does
  not receive project constraints. Existing pre-submission evidence checks are
  mitigation, not a repair of the filter's context boundary.
- The Action's enabled incremental deduplication suppresses overlapping comments
  on the same path/line ranges. It does not merge a shared root cause reported
  against different files/groups. No extra model-based merge stage is added.

Compare high effort against the existing medium runs on the same business heads
of PR #16 and #17 using result artifacts, not newly posted comment counts (the
publisher may suppress overlaps). Freeze the model, extra_body, rules and input
heads; record any policy/base changes separately. Count each confirmed root cause
once, and evaluate known false positives, severity inflation and cross-file
duplicates as well as recall. Unverified candidates are excluded from the known
bug denominator. Check completion and filtering errors before interpreting an
absence as a missed defect. A single comparison measures that run only, not
long-term stability. Real-model acceptance must run through GitHub PR workflows;
static checks do not establish review-quality improvement.
