# Agent Zero Skill Lifecycle Policy

Đây là checklist hỗ trợ cho skill lifecycle; trigger, approval, evaluation và promotion gates bắt buộc đã nằm trong `AGENTS.md`. Có thể đọc khi cần mẫu đánh giá chi tiết.

Lifecycle:

`OBSERVED -> PROPOSED -> DRAFT -> EVALUATED -> APPROVED -> ENABLED -> RETIRED`

- `OBSERVED`: có evidence về workflow lặp lại; chưa tạo skill.
- `PROPOSED`: nêu scope, trigger, non-trigger, lợi ích, rủi ro và owner.
- `DRAFT`: tạo dưới `.agent/skill-candidates/<skill-name>/`; không dùng `.agents/skills` vì host có thể tự discover.
- `EVALUATED`: positive triggers, negative triggers và ít nhất một workflow verification đã pass với provenance phù hợp.
- `APPROVED`: user/owner chấp nhận activation.
- `ENABLED`: promote đúng candidate đã validate sang `.agents/skills/<skill-name>/SKILL.md`, rồi dùng phiên mới hoặc kiểm tra discovery.
- `RETIRED`: ngừng dùng bằng thay đổi đã được phê duyệt; giữ provenance/lý do trong registry/archive.

`SKILL.md` phải có frontmatter `name`, `description` và trigger boundaries rõ. Candidate có thể kèm scripts, references, assets và `EVALS.md`; không chứa project fact tạm thời, secret hoặc credential. Trước promotion, kiểm tra trùng name trong các skill roots nhìn thấy được và ghi rollback path. Validation pass không tự tạo approval.
