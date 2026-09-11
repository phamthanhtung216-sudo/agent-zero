# Agent Zero Skill Lifecycle Policy

Đây là checklist hỗ trợ cho skill lifecycle; trigger, approval, evaluation và promotion gates bắt buộc phải nằm trong `AGENTS.md`. Có thể đọc cùng `CAPABILITY_POLICY.md` khi cần mẫu đánh giá chi tiết; hai file không tự cấp authority.

Lifecycle:

`OBSERVED -> PROPOSED -> DRAFT -> EVALUATED -> APPROVED -> ENABLED -> RETIRED`

- `OBSERVED`: có evidence về workflow lặp lại; chưa tạo skill.
- `PROPOSED`: nêu scope, trigger, non-trigger, lợi ích, rủi ro và owner.
- `DRAFT`: tạo dưới `.agent/skill-candidates/<skill-name>/`; không dùng `.agents/skills` vì host có thể tự discover. Skill do Agent Zero tạo dùng namespace `az-<project>-...`.
- `EVALUATED`: mỗi bảng positive trigger, negative trigger và workflow verification có ít nhất một row; case, expected behavior và evidence phải có nghĩa, mọi row đều `PASS`. Candidate SHA-256 phải khớp payload, được ghi trong registry/EVALS và xuất hiện trong evaluation artifact; `Evals SHA256` trong registry phải khớp raw bytes của `EVALS.md`. Artifact tồn tại trong project, không đi qua reparse point, có SHA-256 khớp nội dung thật và ghi evaluator cùng evaluator run khác creator run.
- `APPROVED`: user/owner chấp nhận activation.
- `ENABLED`: promote đúng payload candidate đã validate sang `.agents/skills/<skill-name>/`; giữ `EVALS.md` tại candidate evidence path ngoài active payload, rồi dùng phiên mới hoặc kiểm tra discovery.
- `RETIRED`: ngừng dùng bằng thay đổi đã được phê duyệt; giữ provenance/lý do trong registry/archive.

`SKILL.md` phải có frontmatter `name`, `description` và trigger boundaries rõ. Candidate có thể kèm scripts, references, assets và `EVALS.md`; toàn bộ payload phải reparse-free, nằm trong scan bound và không chứa project fact tạm thời, secret, credential hoặc personal path. Validator dò các pattern credential phổ biến nhưng không thay thế secret scanner chuyên dụng. Registry lifecycle phải khớp EVALS lifecycle; approver, approval reference, destination và rollback phải cross-bind, còn rollback phải trỏ đúng candidate directory của row đó. Validation pass không tự tạo approval.

`Evals SHA256` tạo chuỗi kiểm chứng `registry -> EVALS.md -> evaluation artifact`. Đây là dấu hiệu drift tương đối với registry/VCS, không phải chữ ký chống lại người có quyền sửa đồng thời cả registry. Khi nâng registry cũ, có thể tự thêm `UNKNOWN` cho row trước `EVALUATED`; row đã `EVALUATED|APPROVED|ENABLED` phải được review lại trước khi ghi hash, không tự đóng dấu nội dung hiện có.

Skill `SYSTEM|ADMIN|USER|PLUGIN` là external provider read-only; skill đã có trong repo trước Agent Zero là adoption inventory. Không copy, sửa, ép thêm `EVALS.md` hoặc nhận ownership của chúng. Resolver ưu tiên `REUSE|COMPOSE` khi đủ và chỉ `SPECIALIZE` khi còn gap ổn định; một skill chạy trong phase hiện tại, không tạo thêm review/repair loop hay reset parent budget.
