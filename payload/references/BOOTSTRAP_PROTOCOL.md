# Agent Zero Bootstrap Protocol

Đây là checklist hỗ trợ cho `BOOTSTRAP`; `AGENTS.md` là contract có thẩm quyền và tự đủ. Có thể đọc file này khi cần template chi tiết. Một task cụ thể vẫn có thể được thực hiện với context tối thiểu nếu an toàn; không ép user hoàn tất onboarding dài trước khi nhận giá trị.

## Reconnaissance

Trước khi hỏi user, kiểm tra theo mức liên quan:

- Cấu trúc thư mục, repository root và trạng thái version control nếu có.
- README, manifest, dependency files, config, entry points, tests, CI/CD và tài liệu hiện hữu.
- Stack có thể suy ra, build/test/lint commands và constraints có bằng chứng.
- Agent instructions, memory, decision log hoặc conventions đã tồn tại; nếu có thì dừng bootstrap mới và chuyển `ADOPTION`, không ghi đè.

Tóm tắt discovery theo bốn nhóm: `Đã xác minh`, `Suy luận cần xác nhận`, `Chưa biết nhưng quan trọng`, `Mâu thuẫn/rủi ro phát hiện được`. Không biến code hay tài liệu không có owner evidence thành product intent.

## Phỏng vấn thích ứng

Chỉ hỏi câu có thể thay đổi quyết định tiếp theo, tối đa ba câu mỗi lượt. Ưu tiên:

1. Project giải quyết vấn đề gì, cho ai, outcome mong muốn là gì?
2. MVP/in-scope, non-goals và success criteria là gì?
3. Constraints về stack, nền tảng, deadline, ngân sách, bảo mật hoặc pháp lý là gì?
4. Agent được tự quyết đến đâu và việc nào luôn cần user xác nhận?
5. Build, test, review và release flow mong muốn là gì?

Không hỏi lại điều repository hoặc user đã cung cấp. Sau mỗi lượt, cập nhật summary provisional và chỉ tiếp tục khi khoảng trống còn ảnh hưởng công việc.

## Khởi tạo project memory

Khi không có adoption đang mở, tạo `.agent/` bằng template cài ở `.agent-zero/templates/` hoặc source lab `templates/agent-zero/`:

- `PROJECT.md`: contract, scope, architecture, commands, constraints và evidence.
- `STATE.md`: task hiện tại, goal alignment, checkpoint, blockers, unknowns và next action.
- `CONTEXT_INDEX.md`: budget, load policy và routing contract.
- `DECISIONS.md` và `LESSONS.md`: hot indexes; body nằm trong `decisions/` và `lessons/`.
- `SKILLS.md`: skill lifecycle registry.
- `CHANGELOG.md`: chỉ các thay đổi memory có ý nghĩa lâu dài.
- Archive indexes và detail roots theo template; không đưa history vào active index.

Draft được phép tự tạo nhưng mọi nội dung chưa được xác nhận phải là `ASSUMED` hoặc `UNKNOWN`. Commands chưa chạy là `UNVERIFIED`.

## Gate chuyển ACTIVE

Chỉ chuyển `PROJECT.md` sang `ACTIVE` khi đủ:

- Purpose và primary user/outcome.
- In-scope và non-goals hoặc ranh giới MVP đủ tránh đi sai hướng.
- Success criteria của phase hiện tại.
- Constraints và decision authority quan trọng.
- Commands đã biết cùng trạng thái verification đúng.

Thiếu gate thì giữ `BOOTSTRAP`; vẫn thực hiện task độc lập an toàn và tiếp tục làm rõ contract theo mức cần thiết.
