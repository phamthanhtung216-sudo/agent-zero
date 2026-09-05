# Agent Memory Changelog

- Schema: `1`
- Active entry limit: `30`
- Archive root: `.agent/archive/changelog`

Chỉ ghi thay đổi có ý nghĩa đối với project context, decision hoặc learning policy. Không ghi các chỉnh sửa câu chữ nhỏ.

Khi vượt giới hạn, chuyển các entry hoàn chỉnh cũ nhất sang archive theo tháng hoặc release; không truncate entry và không xóa provenance.

## Entry template

### YYYY-MM-DD — Tóm tắt thay đổi

- Trigger/task: `UNKNOWN`
- Files changed: `UNKNOWN`
- Why: `UNKNOWN`
- Evidence or user decision: `UNKNOWN`
- Validation: `NOT_RUN | PASS | FAIL` — `UNKNOWN`
- Follow-up: `NONE`
