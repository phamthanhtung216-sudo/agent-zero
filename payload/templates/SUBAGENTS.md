# Persistent Sub-agent Lifecycle Registry

- Schema: `2`
- Candidate root: `.agent/subagent-candidates`
- Active root: `.codex/agents`
- Managed namespace: `UNKNOWN`
- Reserved names: `default; worker; explorer`
- Last validated: `UNKNOWN`

Registry này chỉ quản lý persistent custom-agent profiles do Agent Zero tạo. Ephemeral sub-agent của một run không được ghi vào đây; custom agents có sẵn trong repo chỉ là provider `EXISTING_PROJECT` read-only trong capability inventory.

## Status flow

`OBSERVED -> PROPOSED -> DRAFT -> EVALUATED -> APPROVED -> ENABLED -> RETIRED`

## Registry

| ID | Provider ID | Capability key | Agent name | Status | Ownership | Candidate config | Active config | Evals | Evals SHA256 | Candidate SHA256 | Active SHA256 | Approved by | Approval reference | Rollback | Last verified |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

## Promotion checklist

- Role tái sử dụng đã được user yêu cầu hoặc workflow lặp có evidence.
- Tên có namespace riêng của project và không trùng `default`, `worker`, `explorer` hay provider đang nhìn thấy.
- Candidate TOML chỉ dùng host fields đã cho phép; không tự pin model, MCP, skill config hay quyền ghi rộng.
- Positive/negative delegation, workflow, authority, isolation và collision evals đã pass với case, expected behavior và evidence có nghĩa.
- Evaluator provenance độc lập phù hợp; từ `EVALUATED`, candidate hash phải khớp config và xuất hiện trong evaluation artifact, còn `Evals SHA256` phải khớp raw bytes của `EVALS.md`.
- User/owner đã explicit approval activation.
- Approval metadata, destination và rollback path được cross-bind với registry; có fresh-session discovery verification.
