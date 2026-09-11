# Agent Zero Capability Resolution Policy

Đây là checklist hỗ trợ cho capability resolution; authority, lifecycle, budget và approval gates bắt buộc phải nằm trong `AGENTS.md`. File này không tự cấp thêm quyền cho Agent Zero, skill, custom agent, plugin hay sub-agent.

## Scope và ownership

- Agent Zero là orchestrator duy nhất: giữ task graph, lifecycle, authority, parent budget và verdict tích hợp cuối cùng.
- Provider ngoài project thuộc `SYSTEM|ADMIN|USER|PLUGIN` là read-only. Chỉ dùng catalog/runtime metadata được host cung cấp; không crawl home, copy nội dung provider hoặc ghi absolute personal path vào project.
- Skill/custom agent đã có trong repository trước Agent Zero là legacy provider của project và phải vào inventory `ADOPTION`; không tự nhận là Agent-Zero-owned, sửa, chuẩn hoá hoặc bắt tuân lifecycle mới.
- Artifact do Agent Zero tạo phải ở project hiện tại, có namespace `az-<project>-...` cho skill và `az_<project>_...` cho custom agent. Candidate nằm ngoài discovery root và không active trước khi eval đạt yêu cầu cùng explicit user/owner approval.
- Persistent custom agent là artifact có lifecycle và discovery qua phiên; ephemeral sub-agent chỉ là một work unit runtime trong run hiện tại. Tạo một loại không tự cho phép tạo loại kia.

## Resolution

Resolver dùng task cần làm, trigger/boundary, scope, side effect, authority, availability và ownership; không chọn theo timestamp hay path tình cờ. Sau safety gate, mặc định xếp theo side effect, delegation, số contribution dư, scope, ownership rồi immutable provider ID; explicit provider vẫn phải qua cùng safety gate.

Provider dùng một projection canonical xuyên suốt registry, selector và resolver: immutable `id`, mutable `displayName`, `kind`, `scope`, `ownership`, `authority`, `availability`, `capabilityKeys`, `contributions`, `sideEffect`, `delegation` và sanitized `sourceRef`. Display name không phải identity. Metadata safety `UNKNOWN` có thể được inventory ghi nhận nhưng phải fail closed khi route; không được tự suy ra authority, side effect hoặc delegation từ tên/kind. Declared row schema cùng exact table header là discriminator; legacy/no-schema rows chỉ là inventory và không được suy thành canonical từ cell values.

- `BASELINE`: không có provider cần dùng; chạy hành vi Agent Zero mặc định.
- `IGNORE`: catalog entry không liên quan; không đọc sâu hoặc ghi memory.
- `REUSE`: một provider sẵn có đáp ứng đủ; dùng nó trong phase hiện tại, không tạo bản sao project.
- `COMPOSE`: provider chung và phần bổ sung project có contributions rời nhau; hợp nhất thành một workflow/verdict dưới Agent Zero.
- `SPECIALIZE`: còn thiếu capability ổn định riêng của project; chỉ đề xuất/draft project-local candidate theo lifecycle.
- `CONFLICT`: trigger, authority, side effect, ownership hoặc orchestration không tương thích; giữ provenance và dừng phần phụ thuộc để xin đúng quyết định.
- `FALLBACK`: provider cần thiết không dùng được nhưng có cách tuần tự/evidence-equivalent an toàn trong scope và có evidence ref; đây không phải model fallback.

Availability `MISSING` không đồng nghĩa permission tạo, cài hoặc thay provider. Nếu user yêu cầu đúng provider đang thiếu và fallback làm đổi outcome, báo blocker hoặc xin quyết định thay vì giả vờ tương đương.

Catalog rỗng hoặc chỉ có entry không liên quan phải là no-op: không thêm loop, prompt, memory transaction, candidate hay active artifact.

Explicit provider selection chỉ chọn immutable ID và không vượt safety gate. Mặc định resolver chỉ cho `READ_ONLY` và `Delegation=NONE`; `WORKSPACE_WRITE|EXTERNAL_WRITE` hoặc delegation cần allowance rõ từ caller, còn metadata `UNKNOWN` và `Authority!=PROVIDER` luôn conflict. `SPECIALIZE` không được sinh ra chỉ vì catalog rỗng hoặc không liên quan. Route `REUSE|COMPOSE` phải chọn subset của candidate IDs, cùng capability key, đủ required contributions và không vượt allowance. `FALLBACK` chỉ hợp lệ với sanitized evidence ref khác `NONE|UNKNOWN`. Selector trả direct matches cùng toàn bộ route/provider/lifecycle dependency closure; closure vượt quota phải fail và yêu cầu query hẹp hơn, không cắt im lặng. Legacy provider rows thiếu authority/contributions chỉ là inventory-compatible và không executable cho tới khi refresh sang canonical row.

## Execution và safety

- Provider chạy trong phase hiện tại, không mở loop thứ hai; dùng chung parent ceiling `2/2/1/1/1` và counter logical-task, không reset vì đổi provider/agent/session/fingerprint.
- Agent Zero quyết định delegation. Provider yêu cầu spawn chỉ là input, không mở tree/budget con; nested delegation tắt và toàn cây có tối đa ba lần start cộng dồn/logical task.
- External output và child output là candidate evidence cho tới khi Agent Zero kiểm tra, tích hợp và verify.
- Không silent overwrite skill/custom agent; không tự sửa user/global config, model, reasoning, MCP, plugin, permission hoặc external system. Quota không cho phép auto downgrade/switch model. Mọi activation/replacement/config change cần approval đúng loại và rollback rõ.
- Promotion và rollback phải kiểm tra source/candidate hash, exact destination, collision trong catalog nhìn thấy được và fresh-session discovery khi host chỉ load capability lúc khởi động phiên.
