# Agent Zero Adoption Protocol

Đây là tài liệu hỗ trợ chi tiết cho `ADOPTION`; toàn bộ rule bắt buộc đã nằm trong `AGENTS.md`. Có thể đọc khi cần checklist sâu, nhưng file thiếu hoặc chưa đọc không làm mất authority/lifecycle trong core. Agent/context cũ tiếp tục có hiệu lực trong toàn bộ giai đoạn shadow.

## Freeze và baseline

Trước mọi thay đổi:

1. Ghi repository root, branch/ref, HEAD nếu có và clean/dirty state; không init Git, commit, stash hay clean nếu user chưa yêu cầu.
2. Inventory instruction/memory liên quan với path, vai trò, owner nếu biết, tracked state, size và content hash. Không đọc/copy secret chỉ để inventory.
3. Phân biệt file Codex có thể tự nạp với tài liệu của agent khác. Hash chỉ phát hiện drift, không chứng minh nội dung đúng.
4. Tạo hoặc tiếp tục `.agent-zero/adoption/ADOPTION.md`; không tạo active `.agent/PROJECT.md` làm migration trông như đã được chấp thuận.

## Semantic inventory và goal reconstruction

Tóm tắt, không copy dài; mỗi claim có source path và confidence:

- Product goal, users, scope, non-goals, success criteria.
- Architecture, stack, ownership và verified commands.
- Safety, security, deployment, approval boundaries.
- Coding/review conventions, active state, blockers, unknowns.
- Decisions và lessons còn hiệu lực.

Tách mục tiêu lịch sử, outcome đang quan sát và hướng tương lai chưa xác nhận. Code/context hiện hữu mô tả project đang ở đâu nhưng không tự quyết project nên đi đâu. Goal thiếu owner evidence giữ ở `HYPOTHESIS`; opportunity hậu adoption chỉ là proposal có evidence, goal link, impact, effort/risk và review trigger.

## Conflict matrix

Phân loại từng mục:

- `KEEP`: còn đúng và có thẩm quyền.
- `MAP`: giữ nghĩa, chuyển schema sau approval.
- `MERGE`: nguồn bổ sung nhau.
- `CONFLICT`: không thể đồng thời đúng; giữ cả hai, nêu hậu quả và hỏi đúng authority.
- `STALE`: có evidence rõ rằng không còn đúng.
- `UNKNOWN`: chưa đủ bằng chứng.

Không dùng last-write-wins và không retire nội dung chỉ vì file khác mới hơn.

## Migration plan và approval

Mỗi action nêu source, destination, `KEEP|MAP|MERGE|ARCHIVE`, rủi ro và rollback. User phải duyệt trước khi sửa active instruction, chuyển product intent/security/decision, archive legacy context hoặc bắt đầu cutover. User có thể duyệt một phần; phần còn lại ở shadow.

Ngay trước sửa đầu tiên:

- Với tracked file, ghi baseline commit và current diff; không giả định Git bảo vệ uncommitted content.
- Snapshot đúng instruction/memory files sắp đổi vào `.agent-zero/adoption/snapshots/<timestamp>/`, giữ relative paths.
- Manifest lưu original path, snapshot path, before hash và expected after hash.
- Không snapshot secret sang vị trí kém an toàn. Verify snapshot/hash trước khi sửa; snapshot không cấp quyền commit.

## Staged cutover

Áp patch nhỏ nhất: giữ rule cũ còn đúng, thêm routing/lifecycle, chuyển context theo nhóm với provenance, chạy existing checks/context-loss checks và ít nhất một task đại diện.

Lifecycle bắt buộc:

`DETECTED -> AUDITED -> PLAN_APPROVED -> CUTOVER -> VERIFYING -> AWAITING_USER_ACCEPTANCE -> VERIFIED`

Sau patch đặt `CUTOVER`, rồi `VERIFYING`. Khi check fail, giữ trạng thái, báo evidence/regression và rollback path; không tiếp tục tự động. Chỉ ghi `ROLLED_BACK` sau restore và restore checks pass.

Khi technical checks pass, chuyển `AWAITING_USER_ACCEPTANCE`, không `VERIFIED`. Gửi readiness report gồm context migrated/retained, resolved/open conflicts, checks/evidence, remaining risks, snapshot/rollback path và câu hỏi accept hoặc rollback/chỉnh sửa. Ghi `Acceptance request: SENT`, thời điểm và message evidence.

Im lặng, timeout hay đóng phiên không phải approval. Phiên sau kiểm tra freshness/hash; drift thì về `VERIFYING`, không drift thì tiếp tục chờ. Chỉ acceptance rõ ràng của user/owner mới cho phép lưu evidence và chuyển `VERIFIED`; báo completion cùng snapshot/legacy còn giữ. `VERIFIED` không cho phép xoá snapshot/legacy; archive cần approval riêng.
