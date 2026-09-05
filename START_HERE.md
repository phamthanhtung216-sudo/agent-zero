# Agent Zero Kit — Bắt đầu tại đây

`START_HERE.md` là hướng dẫn dành cho người sử dụng Agent Zero.

Kit này dùng được cho cả project mới và project đã có `AGENTS.md`, `CLAUDE.md` hoặc context cũ. Installer tự kiểm tra trước, giải thích kết quả và đề xuất chế độ an toàn; bạn chỉ cần xác nhận lựa chọn. Không copy đè bất kỳ file agent hiện hữu nào.

Project mới dùng complete stable core cùng bounded indexed context memory: mọi rule hành vi bắt buộc nằm trực tiếp trong `AGENTS.md`, còn project facts, lesson và decision detail tăng trưởng dưới `.agent/` và chỉ được nạp khi task fingerprint khớp. Supporting references là checklist tùy chọn; archive giữ lịch sử lossless nhưng không được nạp mặc định. Normal project learning không sửa core.

Phiên bản installer hiện tại dành cho Windows. Hãy dùng `INSTALL.cmd` để cửa sổ luôn được giữ lại nếu PowerShell bị chặn hoặc lỗi trước khi script bắt đầu.

## Bạn sẽ làm gì?

Chỉ có bốn bước:

1. Copy nguyên thư mục kit vào project.
2. Nhấp đúp `INSTALL.cmd`.
3. Mở một phiên AI mới tại project đó.
4. Gửi một câu khởi động ngắn được installer hiển thị.

## Bước 1 — Copy kit vào project

Giải nén file tải về, sau đó copy nguyên thư mục `agent-zero-kit` vào thư mục gốc của project:

```text
D:\Projects\my-project\
├── source-code...
└── agent-zero-kit\
    ├── INSTALL.cmd
    ├── install-agent-zero.ps1
    ├── START_HERE.md
    └── payload\
```

Phải giữ nguyên cả thư mục kit. Không lấy các file bên trong kit để copy đè trực tiếp vào project.

## Bước 2 — Chạy bằng PowerShell

Mở thư mục `agent-zero-kit`, sau đó:

1. Nhấp đúp vào `INSTALL.cmd`.
2. Nếu Windows hỏi xác nhận, kiểm tra đúng kit bạn vừa copy rồi cho phép chạy.
3. Installer hiển thị đường dẫn project, các dấu hiệu context tìm thấy và chế độ khuyến nghị.
4. Chọn `1` cho project mới hoặc `2` cho project cũ/đã có agent. Nhấn Enter hoặc nhập `Y` để dùng lựa chọn khuyến nghị.

`INSTALL.cmd` là launcher ngoài cùng: nó mở Windows PowerShell với execution policy chỉ nới lỏng cho process cài đặt này và giữ cửa sổ lại nếu PowerShell không khởi động được, script bị chặn hoặc có lỗi parser/runtime. Vì vậy thông báo lỗi không còn biến mất ngay. `install-agent-zero.ps1` vẫn là installer thật và vẫn có thể chạy trực tiếp từ terminal.

Installer mặc định coi thư mục cha của `agent-zero-kit` là project. Nó bỏ qua chính thư mục kit khi kiểm tra context.

Nếu muốn chạy bằng terminal hoặc chỉ định project khác, dùng:

```powershell
& "D:\Projects\my-project\agent-zero-kit\install-agent-zero.ps1" -TargetPath "D:\Projects\my-project"
```

Installer tự kiểm tra và đề xuất một trong hai kết quả:

- `NEW_PROJECT`: chưa tìm thấy agent/context cũ.
- `ADOPTION`: đã tìm thấy agent/context cần được bảo vệ; installer liệt kê các file hoặc thư mục làm evidence.

Bạn vẫn nhìn thấy cả hai lựa chọn. Nếu auto-detect là `NEW_PROJECT`, bạn có thể chủ động chọn `ADOPTION` để thận trọng hơn. Nếu đã phát hiện context cũ, installer không cho hạ xuống `NEW_PROJECT`; hãy dùng `ADOPTION` hoặc huỷ để tránh ghi đè nhầm.

Nếu chạy bằng terminal và muốn kiểm tra trước mà chưa tạo file nào, thêm `-WhatIf`:

```powershell
& "D:\Projects\my-project\agent-zero-kit\install-agent-zero.ps1" -TargetPath "D:\Projects\my-project" -WhatIf
```

Ngay sau khi bạn xác nhận, installer hiển thị bốn bước tiến độ: cài file, cấu hình mode, validation và chuẩn bị bước tiếp theo. Installer chỉ báo `CAI DAT THANH CONG` sau khi validation đã pass. Nếu có lỗi, installer rollback các file do chính lần cài đó tạo ra và giữ cửa sổ mở để bạn đọc thông báo; không tự copy hoặc đổi tên file để bỏ qua lỗi.

Sau khi cài thành công, bạn có thể xoá thư mục `agent-zero-kit` khỏi project. Các file Agent Zero đã cài sẽ không bị ảnh hưởng.

## Bước 3 — Mở một phiên AI mới

Mở Codex, Claude Code hoặc coding agent khác tại đúng thư mục gốc của project vừa cài.

Hãy dùng một phiên mới để agent nạp các instruction vừa được tạo. Với CLI, kiểm tra terminal hiện đang đứng tại project cần làm việc. Project mới có cả `AGENTS.md` cho Codex và `CLAUDE.md` nhập nội dung từ `AGENTS.md` cho Claude Code. Agent khác vẫn có thể cần prompt bên dưới để đọc đúng file.

## Bước 4 — Gửi câu khởi động ngắn

Installer lưu hướng dẫn đầy đủ tại `.agent-zero/START.md` và hiển thị một câu duy nhất để gửi cho agent:

```text
Khởi động Agent Zero theo .agent-zero/START.md
```

Đây là câu chung cho cả project mới và project cũ. Màn hình thành công cho phép nhấn `C` để copy câu này hoặc `O` để mở `.agent-zero/NEXT_STEPS.md`. Phần kích hoạt và các quy tắc an toàn nằm trong core cùng `START.md`, nên người dùng không phải copy một prompt dài.

## Sau khi gửi prompt

### Nếu là project mới

Agent Zero sẽ:

1. Kiểm tra cấu trúc project, tài liệu, source code, config và test hiện có.
2. Nói rõ điều đã xác minh, điều đang suy luận và điều còn thiếu.
3. Hỏi bạn một số câu ngắn về mục tiêu, người dùng, MVP và tiêu chí thành công.
4. Hoàn thiện dần các file trong `.agent/`.
5. Giữ mục tiêu chưa chắc chắn ở dạng hypothesis, liên kết task với goal hiện tại và xin xác nhận trước khi đổi product intent.
6. Chuyển sang `ACTIVE` khi context tối thiểu đã đủ và bắt đầu thực hiện task.

Project mới cũng nhận `.agent/SKILLS.md`. Skill chưa được duyệt phải được soạn dưới `.agent/skill-candidates/`; không đặt draft trực tiếp trong `.agents/skills`.

Nếu host có công cụ sub-agent, Agent Zero có thể điều phối tối đa ba workstream độc lập theo policy trong `AGENTS.md`. Agent chính vẫn giữ authority, quyền ghi instruction/memory và trách nhiệm tích hợp, kiểm chứng kết quả.

Bạn chỉ cần trả lời các câu hỏi quan trọng và xác nhận những quyết định thuộc về sản phẩm.

### Nếu project đã có agent/context cũ

Agent Zero sẽ hoạt động ở chế độ shadow:

1. Giữ nguyên agent và context cũ.
2. Lập danh sách các instruction, memory và decision hiện hữu.
3. Chỉ ra nội dung nên giữ, hợp nhất, cần xác minh hoặc đang mâu thuẫn.
4. Tái dựng riêng mục tiêu lịch sử, outcome đang quan sát và hướng tương lai chưa xác nhận; không suy ra roadmap từ code.
5. Ghi cơ hội cải tiến dưới dạng proposal có evidence, impact, effort/risk và review trigger.
6. Tạo migration plan để bạn review.
7. Chờ bạn phê duyệt trước khi sửa instruction đang hoạt động hoặc cutover sang Agent Zero.
8. Sau cutover, chạy verification rồi chủ động gửi readiness report cho bạn.
9. Giữ trạng thái `AWAITING_USER_ACCEPTANCE` cho tới khi bạn chấp nhận rõ ràng hoặc yêu cầu rollback/chỉnh sửa.

Bạn chỉ cần giải quyết các mâu thuẫn quan trọng, phê duyệt từng phần migration và trả lời readiness report. Test pass không tự động biến cutover thành `VERIFIED`; im lặng hoặc đóng phiên cũng không phải là chấp nhận. Sau khi bạn chấp nhận, Agent Zero sẽ ghi `VERIFIED` và chủ động báo cutover hoàn tất, nên bạn không cần tự mở report để kiểm tra. Nếu mở phiên mới khi đang chờ, Agent Zero phải kiểm tra evidence còn mới rồi báo lại. Agent Zero không thể gửi thông báo nền khi IDE/CLI đã đóng, trừ khi runtime có automation riêng được bạn cho phép.

## Installer không làm những gì?

Installer không:

- Mở hoặc điều khiển Codex/Claude thay bạn.
- Commit, stash hoặc thay đổi lịch sử Git.
- Xoá hay ghi đè agent/context cũ.
- Tự động migration hoặc cutover khi chưa được bạn phê duyệt.
- Tự ghi `VERIFIED` chỉ vì verification đã pass hoặc vì user chưa phản hồi.
- Tự động promote skill candidate thành active skill chỉ vì validation đã pass.
- Suy ra roadmap tương lai từ code cũ hoặc tự chuyển proposal thành product intent đã chấp nhận.

Ở project mới, installer tạo một `CLAUDE.md` tối thiểu chỉ để Claude Code nhập `AGENTS.md`. Nếu đã có bất kỳ Claude/Codex/Cursor context nào, installer chuyển sang `ADOPTION` thay vì tạo adapter này.

## Khi installer dừng để bảo vệ project

Installer sẽ từ chối ghi file nếu phát hiện nguy cơ ghi đè, payload không đầy đủ, hoặc Agent Zero đã được cài trước đó. Khi gặp trường hợp này, giữ nguyên project và đọc thông báo lỗi trước khi tiếp tục.
