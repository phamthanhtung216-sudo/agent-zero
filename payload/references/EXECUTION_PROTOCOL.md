# Agent Zero Execution, Review and Repair Protocol

Đây là checklist hỗ trợ cho task nhiều bước, `REVIEW` và `REPAIR`; vòng lặp và mọi invariant bắt buộc đã nằm trong `AGENTS.md`. Task đọc/trả lời đơn giản không cần nạp file này hoặc tạo run log hình thức.

## Vòng lặp thực thi

1. `UNDERSTAND`: đọc yêu cầu, goal hiện hành, instruction và hot control plane; dùng selector lấy lesson/decision liên quan thay vì nạp toàn bộ memory.
2. `DEFINE_DONE`: xác định contribution và acceptance criteria kiểm tra được; hỏi user nếu thiếu lựa chọn có thể đổi đáng kể outcome.
3. `PLAN`: chọn bước nhỏ nhất hợp lý, nhận diện risk, authority gate và goal alignment.
4. `CHECKPOINT`: với task nhiều bước/rủi ro, ghi `Run ID`, goal link/alignment, definition of done, repair count, blocker fingerprint và changed paths dự kiến vào `STATE.md`.
5. `IMPLEMENT`: thay đổi trong scope, bảo toàn work không liên quan của user và giữ khả năng hoàn tác.
6. `VERIFY`: chạy test/lint/build/check tương xứng; lưu command, result, time và evidence path. Không tuyên bố PASS thiếu evidence.
7. `REVIEW`: đọc diff/output; kiểm tra milestone contribution, regression, edge case, scope/authority, context drift, bảo mật và dữ liệu nhạy cảm. Tự review không được gọi là independent review.
8. `REPAIR`: chỉ sửa lỗi có evidence, tăng `Repair attempt`, giữ cùng `Blocker fingerprint` cho cùng root problem rồi verify lại.
9. `LEARN`: đánh giá có kiến thức bền vững đáng ghi hay không; khi có, áp dụng transaction và learning boundary trong `AGENTS.md`, dùng file này hoặc `MEMORY_PROTOCOL.md` chỉ như checklist hỗ trợ.
10. `SYNC`: stage -> validate -> apply memory tối thiểu; không ghi chép vụn vặt.
11. `REPORT`: nêu outcome, checks/evidence, memory update, risk và việc còn lại; kết thúc checkpoint bằng `COMPLETE` hoặc `BLOCKED`.

## Review gate

Review phải trả lời ít nhất:

- Kết quả có thực hiện đúng yêu cầu mới nhất và goal link không?
- Có thay đổi ngoài scope, phá authority gate hoặc ghi đè work của user không?
- Test/evidence có thực sự chứng minh claim không?
- Có regression, edge case, secret/privacy issue hoặc context conflict nào liên quan không?
- Core behavior, installer và copy-ready artifacts có đồng bộ nếu thay đổi là material không?

Một báo cáo từ sub-agent, validator hoặc chính agent là input cần kiểm tra, không tự động là fact hay independent approval.

## Repair và blocker

Chỉ sửa vấn đề có bằng chứng. Sau mỗi sửa, chạy lại check đã fail và integration check cần thiết. Nếu cùng blocker fingerprint còn tồn tại sau hai chu kỳ sửa, dừng thay vì lặp vô hạn; báo root cause đã biết, evidence, tác động và lựa chọn tiếp theo. Delegation, session mới hoặc context reload không reset repair count.

Checkpoint phải đủ để phiên mới tiếp tục mà không đoán phase, repair count hay verification state. Nếu task chưa hoàn thành, không đánh dấu `COMPLETE` vì hết thời gian hoặc token.

## Trải nghiệm user và Definition of done

Ở mỗi phase, nói ngắn gọn agent đang ở state nào, đã biết/chưa biết gì, quyết định nào user cần đưa ra ngay và bước tiếp theo. Không biến onboarding thành bảng hỏi cứng và không chặn task hữu ích chỉ vì contract chưa hoàn hảo.

Agent Zero hoàn thành đúng khi user hiểu outcome; contract phân biệt fact/decision/assumption/unknown; task gắn goal hoặc ngoại lệ rõ; verification tương xứng risk; lesson chỉ lưu khi tái sử dụng được; memory không tăng vô hạn; product intent và authority của user không bị âm thầm thay đổi.
