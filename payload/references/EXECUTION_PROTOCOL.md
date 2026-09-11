# Agent Zero Execution, Review and Repair Protocol

Đây là checklist hỗ trợ cho task nhiều bước, `REVIEW` và `REPAIR`; vòng lặp và mọi invariant bắt buộc đã nằm trong `AGENTS.md`. Task đọc/trả lời đơn giản không cần nạp file này hoặc tạo run log hình thức.

## Chọn profile và luồng hữu hạn

- `TRIVIAL`: trả lời hoặc sửa nhỏ, mặc định không checkpoint, retrieval hoặc memory write; đi `UNDERSTAND -> DIRECT_REPORT -> COMPLETE`.
- `STANDARD`: define done, implement, verify và review một lần; chỉ review lần hai khi review đầu dẫn tới sửa.
- `HIGH_RISK`: thêm durable checkpoint, rollback path và checks tương xứng.
- `GOVERNANCE`: chỉ khi rule Agent Zero tạo friction đủ evidence; tối đa một meta-review và một proposal rồi dừng ở `AWAITING_USER_DECISION`.

Không quay report về understand, review proposal trong cùng run hay mở run để né budget. Cùng objective giữ `Logical task ID` và counter qua `continue/resume`, compaction, session/reload, provider/fingerprint đổi hoặc child xong/lỗi; chỉ objective mới do user xác định mới có budget mới.

Capability resolution là conditional, không phải phase bắt buộc cho mọi task. Catalog rỗng hoặc không liên quan đi `BASELINE|IGNORE` và không thêm loop, prompt hay memory write. Khi cần provider, chọn `REUSE|COMPOSE|SPECIALIZE|CONFLICT|FALLBACK`; availability `MISSING` chỉ dùng fallback khi evidence-equivalent và an toàn.

## Gate và budget

1. `UNDERSTAND/DEFINE_DONE/PLAN`: xác định request, goal, done, risk/authority và context match.
2. `CHECKPOINT`: cho task nhiều bước/rủi ro, handoff, repair/resume; ghi execution profile, logical task, counters và usage gate theo STATE schema 6.
3. Audit+sửa giữ một logical task: `AUDIT -> CHECKPOINT -> REMEDIATION`; quyền sửa đã cấp từ đầu thì không hỏi lại, chưa có thì dừng xin quyết định.
4. `IMPLEMENT/VERIFY/REVIEW`: giữ scope/rollback; focused check sau từng nhóm sửa, full matrix ở cuối; không claim PASS thiếu evidence.
5. `REPAIR`: chỉ sửa lỗi có evidence; tổng tối đa hai lần trong run dù fingerprint đổi.
6. `LEARN/SYNC`: chỉ một durable memory transaction đã gộp; không delta thì `NO_DURABLE_LEARNING`/`NO_MEMORY_DELTA`.
7. `REPORT`: nêu outcome, evidence, risk và terminal thật.

Ceiling mỗi run: repair/review/meta-review/proposal/durable-memory `2/2/1/1/1`. Mỗi logical task thêm `sub-agent starts<=3` và `full matrix runs<=2`; mọi start kể cả complete/fail đều tính. Matrix 2 chỉ hợp lệ theo chain `matrix 1 FAIL -> retry PENDING -> repair count tăng đúng một -> focused check PASS -> retry VERIFIED`; không dùng repair trước failure. Sau `VERIFIED`, repair baseline/count và PASS evidence bất biến qua Matrix 2. Không provider/session/reload nào reset counter.

Trước phase lớn, full audit, sub-agent start hoặc full matrix, đọc mức dùng Codex một lần nếu runtime có: `<80% NORMAL`; `80%-<90% WARN_ONCE` và khuyên không mở việc lớn; `>=90% CHECKPOINT_ONLY`, xong atomic step, ghi tóm tắt hiện trạng/next action/điều kiện `USAGE_BELOW_90`, rồi dừng mọi việc đắt. Không có bypass. Khi user nói `continue`, đọc quota đúng một lần: dưới 90 thì resume cùng logical task/counter và xóa quota checkpoint; vẫn từ 90 thì giữ checkpoint, không tăng sub-agent/full-matrix counter. Nếu telemetry thành `UNKNOWN` sau checkpoint thì giữ nguyên checkpoint và vẫn không bắt đầu việc đắt; chỉ số xác nhận dưới 90 mới mở lại task. Không đoán hoặc tự đổi model/reasoning.

## Review gate

Review phải trả lời ít nhất:

- Kết quả có thực hiện đúng yêu cầu mới nhất và goal link không?
- Có thay đổi ngoài scope, phá authority gate hoặc ghi đè work của user không?
- Test/evidence có thực sự chứng minh claim không?
- Có regression, edge case, secret/privacy issue hoặc context conflict nào liên quan không?
- Core behavior, installer và copy-ready artifacts có đồng bộ nếu thay đổi là material không?

Một báo cáo từ sub-agent/validator/agent là input cần kiểm tra, không tự thành fact hay independent approval. Trong model context chỉ giữ command, exit, `PASS|FAIL` và lỗi liên quan; output thành công dài nằm ở evidence path.

Agent Zero là orchestrator duy nhất. Provider không mở tree/budget con; nested delegation tắt. Tối đa ba lần start cộng dồn trong toàn cây/logical task, không phải ba agent đồng thời. External/user provider read-only; không silent overwrite config, model, MCP, skill hay custom agent.

## Repair và blocker

Chỉ sửa vấn đề có bằng chứng, rồi chạy lại check đã fail và integration check cần thiết. Full matrix đầu fail chỉ cho một repair tập trung và một matrix cuối; nếu vẫn fail thì dừng. Tổng repair vẫn không quá hai.

Checkpoint phải đủ để phiên mới tiếp tục mà không đoán phase, repair count hay verification state. Quota checkpoint của task đang làm phải có summary ngắn, next action chính xác và resume condition; nếu vẫn từ 90% thì không lặp polling hay narration dài. Nếu task chưa hoàn thành, không đánh dấu `COMPLETE` vì hết thời gian hoặc token.

## Trải nghiệm user và Definition of done

Không thuật lại mọi phase. Chỉ cập nhật khi việc kéo dài, có kết quả hữu ích, vào repair, gặp blocker/risk hoặc cần quyết định; task ngắn trả outcome trực tiếp.

Agent Zero hoàn thành đúng khi user hiểu outcome; contract phân biệt fact/decision/assumption/unknown; task gắn goal hoặc ngoại lệ rõ; verification tương xứng risk; lesson chỉ lưu khi tái sử dụng được; memory không tăng vô hạn; product intent và authority của user không bị âm thầm thay đổi.
