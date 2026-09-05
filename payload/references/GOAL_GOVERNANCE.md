# Agent Zero Goal Governance

Đây là tài liệu hỗ trợ cho goal governance; lifecycle, authority và stop gates bắt buộc đã nằm trực tiếp trong `AGENTS.md`. Dùng file này để xem checklist sâu khi tạo, đánh giá hoặc recalibrate goal.

## Bốn lớp mục tiêu

1. `Desired outcome`: north star cho primary user.
2. `Goal hypothesis`: hướng hiện tại có thể sai khi có evidence mới.
3. `Current phase`: milestone và success criteria đang ưu tiên.
4. `Task`: đóng góp cho goal hoặc ngoại lệ `MAINTENANCE|INCIDENT`.

Goal lifecycle: `HYPOTHESIS -> PROPOSED -> ACCEPTED -> SUPERSEDED`; proposal có thể thành `REJECTED`. Repository, test, runtime, feedback và yêu cầu lặp lại tạo evidence nhưng không tự cấp `ACCEPTED`. Chỉ user/owner được chấp nhận product intent. Khi supersede, giữ goal cũ và provenance.

## Task alignment

Mỗi task có ý nghĩa ghi trong `STATE.md`:

- `Goal link`
- `Alignment status`: `ALIGNED|AT_RISK|OFF_GOAL|NEEDS_USER_DECISION|NOT_ASSESSED`
- `Contribution`
- `Scope impact`
- `Decision required`

Không bắt đầu phần `OFF_GOAL|NEEDS_USER_DECISION`; có thể tiếp tục phần độc lập đã aligned. Task khẩn trong bootstrap dùng ngoại lệ rõ thay vì bịa goal.

## Opportunity backlog

Giữ tối đa năm mục active `NOW|NEXT|WATCH`, gộp mục trùng và không mở lại `REJECTED` nếu thiếu evidence mới. Mỗi proposal cần evidence, goal link, impact, effort/risk và review trigger.

- Fact/freshness đã kiểm chứng: agent tự cập nhật memory.
- Chi tiết nhỏ, reversible, trong scope: agent tự quyết theo authority hiện hành.
- Mở rộng chưa cần quyết định: ghi `NEXT|WATCH`, gom báo ở checkpoint.
- Đổi user/outcome/scope/success, kiến trúc lớn, chi phí hoặc production boundary: ghi `PROPOSED`, nêu diff/trade-off và xin xác nhận.

Khi hướng chưa rõ, đề xuất tối đa ba hypothesis hoặc thí nghiệm nhỏ cùng evidence cần thu và stop/review condition. Chỉ mời user rebaseline khi kết quả làm thay đổi quyết định tiếp theo.

## RECALIBRATION

Chuyển `RECALIBRATION` khi:

- User đổi mục tiêu, primary user, MVP hoặc constraint lớn.
- Evidence làm goal hypothesis không còn đáng tin hoặc opportunity được chấp nhận làm đổi contract.
- Kiến trúc thực tế khác đáng kể với `PROJECT.md`.
- Commands, paths hoặc assumptions trong memory không còn đúng.
- Hai nguồn có authority tương đương mâu thuẫn.

Quy trình:

1. Nêu thay đổi và evidence.
2. Xác định memory bị ảnh hưởng.
3. Xin xác nhận phần thuộc product intent hoặc authority của user.
4. Cập nhật tối thiểu và ghi `CHANGELOG.md` nếu có ý nghĩa lâu dài.
5. Chạy semantic memory validator và checks liên quan trước khi về `ACTIVE`.

Không âm thầm giải quyết conflict thuộc product intent và không suy ra roadmap tương lai từ code, context cũ hoặc technical outcome.
