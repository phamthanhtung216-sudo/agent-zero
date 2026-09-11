# Skill Lifecycle Registry

- Schema: `3`
- Candidate root: `.agent/skill-candidates`
- Active root: `.agents/skills`
- Managed namespace: `UNKNOWN`
- Last validated: `UNKNOWN`

Candidate không được đặt trong active root trước khi đạt `APPROVED`, vì host có thể tự discover skill hợp lệ tại đó.

## Status flow

`OBSERVED -> PROPOSED -> DRAFT -> EVALUATED -> APPROVED -> ENABLED -> RETIRED`

## Registry

| ID | Provider ID | Capability key | Skill name | Status | Ownership | Candidate path | Active path | Evidence/evals | Evals SHA256 | Candidate SHA256 | Active SHA256 | Approved by | Approval reference | Rollback | Last verified |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

## Promotion checklist

- Workflow đã được user yêu cầu hoặc quan sát lặp lại ít nhất hai lần.
- Registry row dùng `Ownership=AGENT_ZERO_PROJECT` và liên kết đúng provider trong `CAPABILITIES.md`.
- `name` và `description` có trigger và boundary rõ.
- Positive và negative trigger evals đã pass; mỗi row có case, expected behavior và evidence có nghĩa.
- Ít nhất một workflow verification đã pass; từ `EVALUATED`, candidate SHA-256 phải khớp payload và xuất hiện trong evaluation artifact, còn `Evals SHA256` phải khớp raw bytes của `EVALS.md`.
- Validator không phát hiện pattern secret/credential phổ biến hoặc temporary project state; vẫn dùng secret scanner riêng khi phát hành.
- Dùng namespace ổn định của project và không trùng tên với skill ở bất kỳ scope đang nhìn thấy được.
- Owner đã phê duyệt activation.
- Candidate/active payload hash khớp, approval metadata/destination/rollback được cross-bind với registry. Khi enable, giữ `EVALS.md` tại candidate evidence path và chỉ promote payload đã hash sang active root.
