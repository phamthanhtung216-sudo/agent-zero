# Agent Zero Sub-agent Policy

Đây là checklist hỗ trợ cho delegation; scope, authority, cap, ownership và integration gates bắt buộc đã nằm trong `AGENTS.md`. Có thể đọc khi cần mẫu work unit chi tiết.

## Khi nào phân công

- Chỉ phân công trong scope, budget và authority đã cấp; delegation không mở rộng quyền.
- Dùng cho workstream thực sự độc lập chạy song song hoặc kiểm tra chuyên biệt có giá trị.
- Không dùng cho task nhỏ/tuần tự, để né user decision, tạo vẻ review độc lập hoặc khi nhiều agent phải sửa cùng file.
- Tôn trọng yêu cầu dùng/không dùng của user. Nếu runtime thiếu tool hoặc child fail, tiếp tục tuần tự khi an toàn; không tuyên bố delegation nếu thiếu tool trace.

## Work unit contract

Mỗi sub-agent nhận mục tiêu, definition of done, path/action được phép, constraint và evidence/check phải trả. Chỉ gửi context cần thiết; không gửi secret hoặc dữ liệu nhạy cảm.

- Gán write ownership riêng; không để hai agent sửa cùng file.
- Tối đa ba sub-agent đồng thời trong cả cây hoặc runtime limit thấp hơn; descendant đều tính.
- Mặc định không nested delegation; ngoại lệ phải ghi scope/limit trong plan.
- Child kế thừa lifecycle và approval gate; không tự quyết product intent, tự duyệt output hay làm action Agent Zero chưa được phép.
- `ADOPTION`: child chỉ audit hoặc tạo sidecar được phép. `BOOTSTRAP`: assumption vẫn có nhãn. `RECALIBRATION`: conflict thuộc user phải trả về. `ACTIVE`: chỉ làm work unit được giao.
- Thiếu quyền, conflict hoặc ambiguity có thể đổi outcome thì dừng unit và trả blocker/evidence.

## Integration responsibility

Agent Zero chính đọc output/diff, xử lý conflict, chạy integration check và chịu trách nhiệm kết quả. Child output chỉ là candidate evidence, không tự thành fact, decision, lesson `VERIFIED` hoặc independent review.

Với task cần checkpoint, `STATE.md` ghi workstream, owner, status và evidence dự kiến. Agent Zero chính là writer mặc định cho `AGENTS.md` và project memory. Delegation không reset repair count/blocker fingerprint hay rút ngắn lesson/skill lifecycle.
