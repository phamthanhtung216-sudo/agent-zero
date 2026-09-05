# Agent Zero Execution, Review and Repair Protocol

Đây là checklist hỗ trợ cho task nhiều bước, `REVIEW` và `REPAIR`; vòng lặp và mọi invariant bắt buộc đã nằm trong `AGENTS.md`. Task đọc/trả lời đơn giản không cần nạp file này hoặc tạo run log hình thức.

## Chọn profile và luồng hữu hạn

- `TRIVIAL`: trả lời hoặc sửa nhỏ, mặc định không checkpoint, retrieval hoặc memory write; đi `UNDERSTAND -> DIRECT_REPORT -> COMPLETE`.
- `STANDARD`: define done, implement, verify và review một lần; chỉ review lần hai khi review đầu dẫn tới sửa.
- `HIGH_RISK`: thêm durable checkpoint, rollback path và checks tương xứng.
- `GOVERNANCE`: chỉ khi rule Agent Zero tạo friction đủ evidence; tối đa một meta-review và một proposal rồi dừng ở `AWAITING_USER_DECISION`.

Không quay từ report về understand, không review proposal trong cùng run và không mở run mới để né budget. Chỉ user input hoặc external evidence mới mở run tiếp.

## Gate và budget

1. `UNDERSTAND/DEFINE_DONE/PLAN`: xác định request, goal, done, risk/authority và context match.
2. `CHECKPOINT`: chỉ cho task nhiều bước/rủi ro, handoff, repair hoặc cần resume; ghi execution profile và counters schema 5.
3. `IMPLEMENT/VERIFY/REVIEW`: giữ scope và rollback; không claim PASS thiếu evidence; review mutation ít nhất một lần nhưng không gọi là independent review.
4. `REPAIR`: chỉ sửa lỗi có evidence; tổng tối đa hai lần trong run dù fingerprint đổi.
5. `LEARN/SYNC`: chỉ một durable memory transaction đã gộp; không có kiến thức/delta thì `NO_DURABLE_LEARNING`/`NO_MEMORY_DELTA`.
6. `REPORT`: nêu outcome, evidence, risk và terminal thật.

Ceiling mỗi run: repair 2, review 2, meta-review 1, proposal 1, durable memory transaction 1. Delegation, session hoặc context reload không reset count.

## Review gate

Review phải trả lời ít nhất:

- Kết quả có thực hiện đúng yêu cầu mới nhất và goal link không?
- Có thay đổi ngoài scope, phá authority gate hoặc ghi đè work của user không?
- Test/evidence có thực sự chứng minh claim không?
- Có regression, edge case, secret/privacy issue hoặc context conflict nào liên quan không?
- Core behavior, installer và copy-ready artifacts có đồng bộ nếu thay đổi là material không?

Một báo cáo từ sub-agent, validator hoặc chính agent là input cần kiểm tra, không tự động là fact hay independent approval.

## Repair và blocker

Chỉ sửa vấn đề có bằng chứng. Sau mỗi sửa, chạy lại check đã fail và integration check cần thiết. Khi tổng repair đạt hai mà verify vẫn fail, dừng thay vì đổi fingerprint hoặc session để tiếp tục; báo root cause, evidence, tác động và lựa chọn.

Checkpoint phải đủ để phiên mới tiếp tục mà không đoán phase, repair count hay verification state. Nếu task chưa hoàn thành, không đánh dấu `COMPLETE` vì hết thời gian hoặc token.

## Trải nghiệm user và Definition of done

Không thuật lại mọi phase. Chỉ cập nhật khi việc kéo dài, có kết quả hữu ích, vào repair, gặp blocker/risk hoặc cần quyết định; task ngắn trả outcome trực tiếp.

Agent Zero hoàn thành đúng khi user hiểu outcome; contract phân biệt fact/decision/assumption/unknown; task gắn goal hoặc ngoại lệ rõ; verification tương xứng risk; lesson chỉ lưu khi tái sử dụng được; memory không tăng vô hạn; product intent và authority của user không bị âm thầm thay đổi.
