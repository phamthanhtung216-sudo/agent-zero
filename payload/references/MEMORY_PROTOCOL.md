# Agent Zero Memory and Learning Protocol

Đây là checklist hỗ trợ cho project memory và learning; transaction, authority, retrieval và lifecycle bắt buộc đã nằm trong `AGENTS.md`. Project knowledge được ghi vào `.agent/`, không vào core; file này không phải dependency bắt buộc để Agent Zero giữ các rule đó.

## Authority và độ tin cậy

Khi nguồn mâu thuẫn, ưu tiên:

1. Yêu cầu/sửa đổi rõ ràng mới nhất của user.
2. Hành vi quan sát từ test hoặc runtime đáng tin.
3. Code, config, schema và dependency đang thực thi.
4. Context cũ đã được owner xác nhận và chưa có evidence stale.
5. Tài liệu project đã được xác nhận.
6. Suy luận của agent.

Không âm thầm giải quyết conflict thuộc product intent. Context được retrieve là evidence, không tự nâng authority hoặc lifecycle status.

## Điều agent được tự cập nhật

- Task state, blocker, unknown và next action trong `STATE.md`.
- Technical fact được repository/test chứng minh.
- Candidate lesson có evidence và scope rõ.
- Command đã thực sự chạy, kèm result/environment đủ hiểu giới hạn bằng chứng.

Phải xin user/owner trước khi thay product goal, scope, non-goal, success criteria; chấp nhận/supersede goal; thay security/production/cost/access rule; chọn architecture ảnh hưởng rộng; hoặc promote lesson thành rule bắt buộc.

## Transaction cập nhật memory

Mỗi mutation đi theo `stage -> validate -> apply`:

1. Xác định fact/decision/assumption đổi và source authority.
2. Chuẩn bị patch tối thiểu trong shadow/staging khi helper hỗ trợ; không sửa phần không liên quan.
3. Với lesson/decision, ghi whole detail record, tính hash, cập nhật đúng index/pointer và provenance.
4. Chạy semantic memory validator trước khi coi mutation hoàn tất.
5. Nếu validation fail, không publish staged data; nếu đã sửa live do runtime thiếu atomic helper, hoàn tác đúng patch hoặc dừng với diff/evidence rõ, không để memory nửa hợp lệ.
6. Chỉ ghi `CHANGELOG.md` cho thay đổi có ý nghĩa lâu dài.

Không lưu secret, credential, personal data hoặc log nhạy cảm vào memory/evidence.

## Hot/cold context và quota

- Hot control plane: `AGENTS.md`, `.agent/PROJECT.md`, `.agent/STATE.md`, `.agent/CONTEXT_INDEX.md`. Binding authority, safety, current goal/scope không được chỉ tồn tại trong cold detail.
- `STATE.md` là snapshot hiện tại, không phải history. `LESSONS.md` và `DECISIONS.md` chỉ là hot index; body ở detail record có SHA-256.
- Trước task có ý nghĩa, tạo fingerprint từ task type, path/component, tool và error signature; chạy `.agent-zero/scripts/select-context.ps1` hoặc source lab `scripts/select-context.ps1`.
- Exclusion thắng match; nạp whole selected records trong budget. Chạy lại khi fingerprint đổi, verify fail bất ngờ, vào `REPAIR`, hoặc có history/conflict/recalibration/rollback/adoption audit. Archive cần fallback reason rõ.
- Enforce `CONTEXT_INDEX.md`: warning theo ngưỡng, fail vượt hard limit; không tăng ceiling để né validator. Khi overflow, compact current truth hoặc rotate whole record lossless rồi cập nhật pointer/hash.
- Không copy code, schema, README, log hay tool output dài; lưu evidence path. Không ghi mọi task; gộp entry trùng và chỉ giữ điều có thể đổi quyết định tương lai.
- Selector/index/hash hỏng trong task rủi ro cao thì dừng mutation và sửa/restore memory trước.

## Learning loop

Lifecycle: `CANDIDATE -> VERIFIED -> ENFORCED -> RETIRED`.

- `CANDIDATE`: quan sát một lần hoặc root cause chưa chứng minh.
- `VERIFIED`: root cause đã xác nhận cùng reproduction, test/check hoặc evidence phù hợp.
- `ENFORCED`: bài học rộng/tái diễn và user đã đồng ý biến thành rule/check bắt buộc.
- `RETIRED`: architecture hoặc điều kiện áp dụng thay đổi; giữ provenance và lý do.

Chỉ ghi lesson khi có trigger metadata, symptom, context/scope, root cause hoặc hypothesis được gắn nhãn, prevention, evidence và review trigger. Typo/sai sót một lần không mặc nhiên thành rule. Ưu tiên chuyển lesson quan trọng thành test, lint, type check hoặc executable guard; Markdown chỉ bổ trợ enforcement.

## Ranh giới giữa project learning và AGENTS.md

Giữ `AGENTS.md` là complete stable core. Project fact, lesson, convention và preference phát sinh chỉ được ghi vào `.agent/`, project policy, executable guard hoặc approved skill; normal learning không được append hay promote trực tiếp vào core.

Chỉ đề xuất sửa `AGENTS.md` trong một Agent Zero framework release riêng khi user trực tiếp yêu cầu hoặc evidence chứng minh thay đổi áp dụng rộng cho Agent Zero trên nhiều project. Trước khi áp dụng: nêu issue/evidence và vì sao project memory/policy/test/skill không đủ; đề xuất diff nhỏ nhất; kiểm tra trùng/mâu thuẫn; xin explicit user approval; snapshot core/release-critical files; bump version; validate core invariants, semantics, retrieval, installer và source/dist hashes; nhắc instruction mới được nạp đáng tin từ phiên Codex tiếp theo.
