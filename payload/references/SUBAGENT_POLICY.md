# Agent Zero Sub-agent Policy

Đây là checklist hỗ trợ cho delegation; scope, authority, cap, ownership và integration gates bắt buộc phải nằm trong `AGENTS.md`. Có thể đọc cùng `CAPABILITY_POLICY.md`; file này không tự cấp authority.

## Khi nào phân công

- Chỉ phân công trong scope, budget và authority đã cấp; delegation không mở rộng quyền.
- Dùng cho workstream thực sự độc lập chạy song song hoặc kiểm tra chuyên biệt có giá trị.
- Không dùng cho task nhỏ/tuần tự, để né user decision, tạo vẻ review độc lập hoặc khi nhiều agent phải sửa cùng file.
- Tôn trọng yêu cầu dùng/không dùng của user. Nếu runtime thiếu tool hoặc child fail, tiếp tục tuần tự khi an toàn; không tuyên bố delegation nếu thiếu tool trace.
- Agent Zero là orchestrator duy nhất. Skill hay provider yêu cầu spawn chỉ cung cấp input; không tự sở hữu task graph, budget hoặc verdict.

## Work unit contract

Mỗi sub-agent nhận mục tiêu, definition of done, path/action được phép, constraint và evidence/check phải trả. Chỉ gửi context cần thiết; không gửi secret hoặc dữ liệu nhạy cảm.

- Gán write ownership riêng; không để hai agent sửa cùng file.
- Tối đa ba lần start cộng dồn trong toàn cây của một `Logical task ID` hoặc runtime limit thấp hơn; không phải ba agent đồng thời. Descendant, start đã complete/fail đều tính. `continue/resume`, compaction, session/reload, provider hoặc fingerprint đổi không reset.
- Không nested delegation; child và persistent custom agent không được spawn descendant.
- Child kế thừa lifecycle và approval gate; không tự quyết product intent, tự duyệt output hay làm action Agent Zero chưa được phép.
- `ADOPTION`: child chỉ audit hoặc tạo sidecar được phép. `BOOTSTRAP`: assumption vẫn có nhãn. `RECALIBRATION`: conflict thuộc user phải trả về. `ACTIVE`: chỉ làm work unit được giao.
- Thiếu quyền, conflict hoặc ambiguity có thể đổi outcome thì dừng unit và trả blocker/evidence.

## Integration responsibility

Agent Zero chính đọc output/diff, xử lý conflict, chạy integration check và chịu trách nhiệm kết quả. Child output chỉ là candidate evidence, không tự thành fact, decision, lesson `VERIFIED` hoặc independent review.

Với task cần checkpoint, `STATE.md` ghi logical task, số start/limit, workstream, status và evidence. Agent Zero chính là writer mặc định cho `AGENTS.md` và project memory. Delegation không reset counter/blocker hay rút ngắn lifecycle.

## Persistent custom agent

Persistent custom agent khác ephemeral delegation: nó là capability project-local có candidate/eval/explicit approval trước discovery, namespace `az_<project>_...` và fresh-session verification khi cần. External/user agent read-only; repo-existing agent là adoption inventory. Không silent overwrite hay sửa config/model/MCP. `FALLBACK` khi runtime `MISSING` chỉ là thực thi tuần tự evidence-equivalent, không phải quyền cài provider hay đổi model/reasoning.

Agent Zero-managed `SUBAGENT.toml` dùng schema v1 canonical, fail-closed: chỉ bare key đã cho phép, string hai dấu nháy cho field một dòng và một block `developer_instructions` ba dấu nháy; mọi key, table, dotted/quoted key hoặc value shape không hiểu đều bị từ chối. `sandbox_mode` nếu có chỉ là `read-only`; không cho MCP hoặc `skills.config` trong candidate mặc định.

`EVALUATED|APPROVED` chỉ hợp lệ khi mọi row trong positive, negative, workflow, authority/isolation và collision/compatibility đều `PASS` với case, expected behavior và evidence có nghĩa. Candidate SHA-256 phải khớp config, được ghi trong registry/EVALS và xuất hiện trong artifact; `Evals SHA256` trong registry phải khớp raw bytes của `EVALS.md`. Artifact phải tồn tại trong project, không qua reparse point, có SHA-256 đúng và liên kết evaluator/evaluator run khác creator run. Registry lifecycle, approver, approval reference và rollback phải cross-bind với EVALS; rollback phải trỏ đúng candidate config của row đó. Chuỗi metadata tự khai không thay thế artifact đã kiểm chứng; detector pattern credential không thay thế secret scanner chuyên dụng.

`Evals SHA256` tạo chuỗi kiểm chứng `registry -> EVALS.md -> evaluation artifact`. Đây là dấu hiệu drift tương đối với registry/VCS, không phải chữ ký chống lại người có quyền sửa đồng thời cả registry. Khi nâng registry cũ, chỉ row trước `EVALUATED` được thêm `UNKNOWN` cơ học; row lifecycle cao hơn phải được review lại trước khi ghi hash.
