# Khởi động Agent Zero

File này là điểm vào ngắn sau khi cài đặt. Khi user yêu cầu `Khởi động Agent Zero theo .agent-zero/START.md`, hãy thực hiện các bước sau trong thư mục gốc của project.

1. Kiểm tra sự tồn tại của `AGENT_ZERO_CANDIDATE.md`, `AGENTS.md`, `.agent/`, cặp `.agent/CAPABILITIES.md` + `.agent/SUBAGENTS.md` và `.agent-zero/adoption/ADOPTION.md` trước khi quyết định trạng thái.
2. Nếu có `AGENT_ZERO_CANDIDATE.md`, đọc candidate và bắt đầu `ADOPTION` ở chế độ shadow. Không sửa, đổi tên, thay thế hoặc vô hiệu hóa context cũ. Candidate chưa phải authority đang hoạt động.
3. Nếu không có candidate, đọc `AGENTS.md`, `.agent/PROJECT.md`, `.agent/STATE.md` và `.agent/CONTEXT_INDEX.md`, rồi bắt đầu hoặc tiếp tục `BOOTSTRAP` theo memory hiện có.
4. Coi `AGENTS.md` là complete stable operating contract. Các file `.agent-zero/references/` chỉ là checklist hỗ trợ; không có rule bắt buộc nào chỉ nằm ở đó và không cần nạp chúng mặc định.
5. Với task có ý nghĩa, tạo fingerprint từ task type, paths/components, tools, error signatures và capability/provider key liên quan; dùng `.agent-zero/scripts/select-context.ps1` để lấy đúng detail/registry rows trong budget. Không nạp toàn bộ index/detail/catalog vào prompt và không ghi project learning vào `AGENTS.md`.
6. Chỉ inventory capability liên quan đang được host/repository cho thấy. Giữ user/global và legacy repo skill/custom agent read-only; không crawl home, copy provider body hoặc tự nhận ownership.
7. Với project cũ, tái dựng riêng mục tiêu lịch sử, outcome đang quan sát và hướng tương lai chưa xác nhận; không suy ra roadmap từ code hoặc tự biến proposal thành product intent.
8. Phản hồi đầu tiên phải nói rõ chế độ đã phát hiện, evidence chính, điều sẽ làm tiếp theo và điều chưa được phép thay đổi.
9. Dẫn dắt user từng bước và chỉ hỏi tối đa ba câu quan trọng trong mỗi lượt.
10. Nếu hai capability registry đều vắng, tiếp tục compatibility behavior v0.10; nếu chỉ có một file, dừng mutation và yêu cầu hoàn tất/rollback migration. Trong `ADOPTION`, technical checks không tự cấp quyền cutover. Khi verification hoàn tất, chủ động báo evidence và chờ user chấp nhận rõ ràng trước khi ghi `VERIFIED`.

Nếu các file trên mâu thuẫn hoặc cài đặt chưa đầy đủ, dừng thay đổi context, nêu file/evidence gây lỗi và hướng dẫn user chạy lại installer hoặc chọn bước khôi phục an toàn.
