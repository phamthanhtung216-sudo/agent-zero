# Agent Zero

Agent Zero là bộ quy tắc và công cụ cài đặt giúp coding agent làm việc có kiểm chứng, giữ context dự án có kiểm soát và không âm thầm thay đổi ý định của người dùng.

Đây là bộ instruction/installer dành cho coding agent; cần một coding agent có sẵn để sử dụng.

Phiên bản hiện tại: **v0.8.1**

Nền tảng cài đặt: **Windows (PowerShell)**

## Điểm chính

- Khảo sát repository trước khi hỏi người dùng.
- Phân biệt fact, quyết định của người dùng, giả định và điều chưa biết.
- Bảo vệ project đã có agent/context bằng quy trình adoption dạng shadow-first.
- Giữ project memory có giới hạn, có index và chỉ nạp context phù hợp với task.
- Review, verify và repair dựa trên evidence; không báo thành công khi chưa kiểm tra.
- Không tự đổi product goal, scope, architecture lớn hoặc quyền quyết định của người dùng.
- Hỗ trợ Codex qua `AGENTS.md` và có adapter tối thiểu cho Claude Code.

## Cài nhanh

Mở PowerShell ngay tại thư mục gốc của project cần cài Agent Zero rồi chạy:

```powershell
git clone https://github.com/phamthanhtung216-sudo/agent-zero.git agent-zero-kit
```

Sau đó mở thư mục `agent-zero-kit` và nhấp đúp:

```text
INSTALL.cmd
```

Installer sẽ:

1. Xác định thư mục project ở ngay bên ngoài `agent-zero-kit`.
2. Kiểm tra project mới hay đã có agent/context.
3. Đề xuất chế độ `NEW_PROJECT` hoặc `ADOPTION` và chờ bạn xác nhận.
4. Cài đặt, validate và rollback phần vừa tạo nếu có lỗi.
5. Hiển thị câu lệnh ngắn để khởi động Agent Zero trong một phiên AI mới.

Bạn nên đọc [START_HERE.md](START_HERE.md) trước lần cài đầu tiên. Có thể kiểm tra mà chưa ghi file bằng lệnh:

```powershell
& ".\agent-zero-kit\install-agent-zero.ps1" -TargetPath "." -WhatIf
```

## Hai chế độ an toàn

### Project mới

Agent Zero cài `AGENTS.md`, adapter `CLAUDE.md`, project memory và các validator cần thiết. Sau đó agent khảo sát project và hướng dẫn bạn hoàn thiện mục tiêu, phạm vi cùng tiêu chí thành công.

### Project đã có agent hoặc context

Agent Zero không ghi đè context hiện hữu. Nó cài một candidate riêng, lập inventory và migration plan, rồi chờ bạn phê duyệt trước khi cutover. Technical checks không tự thay thế sự chấp nhận của người dùng.

## Nội dung repository này

Đây là **bản phân phối công khai**, không phải source/lab phát triển. Repository chỉ chứa kit đã build và tài liệu cần để cài đặt:

```text
agent-zero/
├── README.md
├── START_HERE.md
├── INSTALL.cmd
├── install-agent-zero.ps1
├── AGENT_ZERO_CANDIDATE.md
└── payload/
```

Project memory nội bộ, test history, công cụ phát triển và cấu hình máy cá nhân không được đưa vào repository này.

## Cập nhật

Repository public chỉ được cập nhật khi có bản phát hành đã review. Mỗi phiên bản ổn định có Git tag tương ứng, ví dụ `v0.8.1`. [Releases](https://github.com/phamthanhtung216-sudo/agent-zero/releases) cung cấp ZIP chứa nguyên thư mục `agent-zero-kit`; có thể tải ZIP mà không cài Git.

Khi Agent Zero đã được cài trong project, `git pull` vào thư mục kit chỉ cập nhật bản tải về. Phiên bản hiện tại chưa có quy trình nâng cấp tại chỗ tự động; cần review các file đã cài và bảo toàn project memory trước khi migration. Không chạy lại installer để ghi đè một bản đã cài.

## Khởi động và giới hạn

Sau khi cài, mở phiên coding agent mới tại project và gửi:

```text
Khởi động Agent Zero theo .agent-zero/START.md
```

“Học” nghĩa là cập nhật context có kiểm chứng trong repository; không thay đổi trọng số mô hình. Bộ instruction định hướng hành vi nhưng không thay thế sandbox hoặc quyền của công cụ. Các kiểm tra tự động xác nhận cấu trúc và các nhánh installer; một số kịch bản hành vi tự nhiên còn cần đánh giá thêm.

## Yêu cầu

- Windows 10/11.
- Windows PowerShell 5.1 hoặc PowerShell 7.
- Một coding agent có khả năng đọc instruction trong repository.

## An toàn

- Không lưu API key, token, credential hoặc dữ liệu cá nhân trong project memory.
- Không tự deploy production hoặc thay đổi external system khi chưa được cho phép.
- Không ghi đè instruction cũ trong chế độ adoption.
- Luôn review nội dung script trước khi chạy code tải từ Internet.

## Phản hồi

Nếu gặp lỗi, hãy tạo GitHub Issue kèm phiên bản Agent Zero, phiên bản PowerShell, bước tái hiện và thông báo lỗi đã được loại bỏ dữ liệu nhạy cảm.

## License

Chủ dự án chưa chọn license. Repository công khai chưa cấp một giấy phép open-source như MIT; nếu muốn sử dụng lại, sửa đổi hoặc phân phối ngoài những quyền sẵn có, hãy trao đổi với chủ dự án trước. Xem [giải thích của GitHub về repository chưa có license](https://choosealicense.com/no-permission/).
