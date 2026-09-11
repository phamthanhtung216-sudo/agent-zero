# Context Index

- Schema: `2`
- Retrieval mode: `DETERMINISTIC`
- Default hot byte limit: `65536`
- Retrieved detail byte limit: `16384`
- Max retrieved records: `8`
- Detail record byte limit: `4096`
- Retrieved registry byte limit: `8192`
- Max retrieved registry rows: `24`
- Changelog entry limit: `30`
- Archive root: `.agent/archive`
- Last validated: `UNKNOWN`

File này là control plane cho project memory. Nó mô tả phần context được đọc mặc định và budget dùng khi nạp detail records; không chứa lịch sử task hay nội dung lesson/decision đầy đủ.

## Load policy

| Source | Policy | Warning bytes | Hard bytes | Overflow action |
|---|---|---:|---:|---|
| `AGENTS.md` | `ALWAYS` | `26624` | `28672` | `Keep the complete stable operating contract; never append project context or learning` |
| `.agent/PROJECT.md` | `ALWAYS` | `13107` | `16384` | `Keep current contract; move historical detail to archive` |
| `.agent/STATE.md` | `ACTIVE_TASK` | `6553` | `8192` | `Replace stale checkpoint; never append task history` |
| `.agent/CONTEXT_INDEX.md` | `ALWAYS` | `6553` | `8192` | `Compact routing text without removing required fields` |
| `.agent/LESSONS.md` | `INDEX_ONLY` | `13107` | `16384` | `Move retired records to archive and keep active pointers` |
| `.agent/DECISIONS.md` | `INDEX_ONLY` | `13107` | `16384` | `Move superseded records to archive and keep active pointers` |
| `.agent/SKILLS.md` | `MATCH` | `13107` | `16384` | `Archive retired registry rows` |
| `.agent/CAPABILITIES.md` | `MATCH` | `13107` | `16384` | `Keep only project-relevant providers and reusable routing decisions` |
| `.agent/SUBAGENTS.md` | `MATCH` | `13107` | `16384` | `Archive retired managed-profile rows` |
| `.agent/CHANGELOG.md` | `AUDIT_ONLY` | `19661` | `24576` | `Rotate oldest complete entries to the archive root` |

`ALWAYS` và `ACTIVE_TASK` tạo default hot control plane. `INDEX_ONLY` chỉ được selector đọc để tạo summary; không đưa nguyên index vào prompt. `MATCH` chỉ được đọc khi task fingerprint khớp. `AUDIT_ONLY` chỉ dùng để truy vết, migration hoặc rollback. Evidence, logs, snapshots và generated artifacts là `EVIDENCE_ONLY` hoặc `NEVER_DEFAULT` dù không có row riêng.

## Retrieval contract

1. Đọc core, project contract, current state và file này; để selector đọc index lesson/decision và chỉ chọn registry rows khớp thay vì đưa toàn bộ index vào prompt.
2. Tạo task fingerprint từ goal, task type, paths/components, tools và error signatures đang có.
3. Chạy selector tại `scripts/select-context.ps1` trong source lab hoặc `.agent-zero/scripts/select-context.ps1` trong project đã cài.
4. Chỉ nạp detail records được selector trả về; exclusion thắng positive match. Mọi `CRITICAL` record khớp ít nhất một signal phải được preflight và giữ trước noncritical records; phần còn lại xếp theo match score, status, priority và ID.
5. Khi verification fail bất ngờ, bước vào `REPAIR`, user hỏi lịch sử, hoặc có conflict/rollback, chạy retrieval lại với signals mới và có thể tìm archive.
6. Không cắt giữa record và không vượt record/byte budget. Nếu selector hoặc index hỏng trong task rủi ro cao, dừng mutation và sửa/khôi phục memory trước.

## Indexed stores

| Kind | Hot index | Active detail root | Cold/archive root |
|---|---|---|---|
| Lessons | `.agent/LESSONS.md` | `.agent/lessons/` | `.agent/archive/lessons/` |
| Decisions | `.agent/DECISIONS.md` | `.agent/decisions/` | `.agent/archive/decisions/` |
| Capabilities | `.agent/CAPABILITIES.md` | Registry rows only | `SUPERSEDED` rows or changelog provenance |
| Skills | `.agent/SKILLS.md` | Managed candidate/active pointers | `RETIRED` rows |
| Persistent sub-agents | `.agent/SUBAGENTS.md` | Managed candidate/active pointers | `RETIRED` rows |
| Changelog | `.agent/CHANGELOG.md` | `.agent/CHANGELOG.md` | `.agent/archive/changelog/` |

Archive lookup dùng `.agent/archive/LESSONS_INDEX.md` và `.agent/archive/DECISIONS_INDEX.md`; selector chỉ đọc hai index này khi có `IncludeArchive` cùng lý do history, regression, repair, conflict, recalibration, rollback hoặc adoption audit.

## Selection checkpoint

`STATE.md` chỉ lưu query summary, selected record IDs và retrieved bytes của lần chọn gần nhất. Nội dung detail vẫn ở record nguồn và không được copy vào state.
