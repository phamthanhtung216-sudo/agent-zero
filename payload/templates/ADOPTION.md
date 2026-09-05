# Agent Zero Adoption Report

- Status: `DETECTED`
- Candidate file: `AGENT_ZERO_CANDIDATE.md`
- Started: `UNKNOWN`
- Migration approved by: `NONE`

Status flow:

`DETECTED -> AUDITED -> PLAN_APPROVED -> CUTOVER -> VERIFYING -> AWAITING_USER_ACCEPTANCE -> VERIFIED`

Rollback path:

`CUTOVER | VERIFYING | AWAITING_USER_ACCEPTANCE -> ROLLED_BACK`

Không sửa instruction/memory hiện hữu khi status chưa đạt `PLAN_APPROVED`.

Không chuyển sang `VERIFIED` chỉ vì check đã pass. Phải chuyển sang `AWAITING_USER_ACCEPTANCE`, chủ động báo evidence cho user và chờ xác nhận rõ ràng. Im lặng hoặc đóng phiên không phải là approval.

## Repository baseline

- Repository root: `UNKNOWN`
- Version control: `NONE_OR_UNKNOWN`
- Branch/ref: `UNKNOWN`
- HEAD/baseline: `UNKNOWN`
- Working tree: `UNKNOWN`
- Baseline captured at: `UNKNOWN`

## Existing context inventory

| Path | Expected role | Owner/authority | Loaded by Codex? | Tracked? | Size/hash | Notes |
|---|---|---|---|---|---|---|
| `UNKNOWN` | `UNKNOWN` | `UNKNOWN` | `UNKNOWN` | `UNKNOWN` | `UNKNOWN` | `UNKNOWN` |

## Semantic inventory

| Context item | Current value | Source path/section | Confidence | Proposed treatment |
|---|---|---|---|---|
| `UNKNOWN` | `UNKNOWN` | `UNKNOWN` | `UNKNOWN` | `KEEP|MAP|MERGE|CONFLICT|STALE|UNKNOWN` |

## Goal reconstruction

Context đầy đủ mô tả project đang ở đâu nhưng không tự quyết định project nên đi đâu. Tách mục tiêu lịch sử, outcome quan sát được và hướng tương lai chưa xác nhận; không suy ra roadmap từ code.

- Historical goal: `UNKNOWN`
- Historical goal source/owner: `UNKNOWN`
- Current observed outcome: `UNKNOWN`
- Current direction confidence: `UNKNOWN`
- Future direction: `UNKNOWN_OR_HYPOTHESIS`
- Confirmation needed from: `USER_OR_OWNER`

## Post-adoption opportunity candidates

Các mục này chỉ là proposal shadow, không phải migration approval hay product intent đã chấp nhận.

| ID | Proposal | Evidence | Goal link | Expected impact | Effort/risk | Review trigger | Status |
|---|---|---|---|---|---|---|---|

## Conflicts requiring authority

| ID | Source A | Source B | Why they conflict | Consequence | Required owner | Status |
|---|---|---|---|---|---|---|
| `C-001` | `UNKNOWN` | `UNKNOWN` | `UNKNOWN` | `UNKNOWN` | `USER_OR_OWNER` | `OPEN` |

## Proposed migration

| ID | Action | Source | Destination | Risk | Rollback | Approval |
|---|---|---|---|---|---|---|
| `M-001` | `KEEP|MAP|MERGE|ARCHIVE` | `UNKNOWN` | `UNKNOWN` | `UNKNOWN` | `UNKNOWN` | `PENDING` |

## Snapshot and rollback manifest

Chỉ điền ngay trước cutover đã được duyệt.

| Original path | Snapshot path | Before hash | Expected after hash | Restore check |
|---|---|---|---|---|
| `UNKNOWN` | `UNKNOWN` | `UNKNOWN` | `UNKNOWN` | `UNKNOWN` |

## Verification plan

- Existing checks to preserve: `UNKNOWN`
- Representative pre/post task: `UNKNOWN`
- Context-loss checks: `UNKNOWN`
- Acceptance owner: `UNKNOWN`

## Verification and final acceptance

- Technical verification: `NOT_RUN`
- Verification evidence: `NONE`
- Acceptance request: `NOT_SENT`
- Acceptance requested at: `NONE`
- Acceptance request evidence: `NONE`
- Final acceptance: `PENDING`
- Accepted by: `NONE`
- Accepted at: `NONE`
- Acceptance evidence: `NONE`
- Rollback result: `NOT_RUN`
- Rollback evidence: `NONE`

Khi technical verification pass, điền readiness report rồi chuyển status sang `AWAITING_USER_ACCEPTANCE`. Chỉ chuyển sang `VERIFIED` sau khi user/owner chấp nhận rõ ràng.

### Readiness report

- Migration summary: `UNKNOWN`
- Checks summary: `UNKNOWN`
- Remaining risks: `UNKNOWN`
- Rollback reference: `UNKNOWN`
- Decision requested: `UNKNOWN`

Nếu mở phiên mới khi status là `AWAITING_USER_ACCEPTANCE`, kiểm tra lại freshness của evidence/hash trước khi báo lại. Nếu có drift, chuyển về `VERIFYING`; nếu rollback được thực hiện, chỉ ghi `ROLLED_BACK` sau khi restore checks pass và có rollback evidence.

## Adoption log

Mỗi lần đổi status phải append đúng một transition liền kề. Dòng cuối phải kết thúc ở status hiện tại.

| From | To | At | Evidence |
|---|---|---|---|
| `NONE` | `DETECTED` | `UNKNOWN` | `Installer created shadow adoption report` |
