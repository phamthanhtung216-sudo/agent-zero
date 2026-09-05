# Skill Lifecycle Registry

- Schema: `1`
- Candidate root: `.agent/skill-candidates`
- Active root: `.agents/skills`
- Last validated: `UNKNOWN`

Candidate không được đặt trong active root trước khi đạt `APPROVED`, vì host có thể tự discover skill hợp lệ tại đó.

## Status flow

`OBSERVED -> PROPOSED -> DRAFT -> EVALUATED -> APPROVED -> ENABLED -> RETIRED`

## Registry

| ID | Skill name | Status | Candidate path | Active path | Evidence/evals | Approved by | Rollback |
|---|---|---|---|---|---|---|---|

## Promotion checklist

- Workflow đã được user yêu cầu hoặc quan sát lặp lại ít nhất hai lần.
- `name` và `description` có trigger và boundary rõ.
- Positive và negative trigger evals đã pass.
- Ít nhất một workflow verification đã pass.
- Không chứa secret, credential hoặc temporary project state.
- Không trùng tên với repo skill đang nhìn thấy được.
- Owner đã phê duyệt activation.
- Có rollback path và cách xác minh discovery.
