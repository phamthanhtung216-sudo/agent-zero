# Cập nhật Agent Zero

`UPDATE.md` là hướng dẫn, **không phải file thực thi**. Nhấp đúp file này chỉ mở nội dung để đọc; nó không tự chạy lệnh và không tự tải gì từ GitHub.

## Nếu bạn có đủ kit hoặc bản cài v0.12.0 trở lên

Nhấp đúp `UPDATE.cmd`:

1. CMD tự kiểm tra bản stable mới nhất và hiển thị phiên bản, thay đổi, ảnh hưởng tới context và chế độ migration hiệu lực. Bước kiểm tra không cần AI.
2. Nếu chế độ là `CORE_ONLY` hoặc `LOSSLESS_SCRIPTED`, updater chỉ tiếp tục sau xác nhận, lấy khóa độc quyền, tạo snapshot, dựng staging, kiểm tra hash/validator rồi mới activate.
3. Nếu chế độ là `SEMANTIC_REVIEW`, updater không sửa context live. Nó tạo và copy một prompt để bạn dán vào **agent AI đang dùng**, bất kể nhà cung cấp nào.
4. `UNSUPPORTED`, manifest/hash sai, context đổi giữa lúc update hoặc validation fail đều làm updater dừng an toàn; bản cũ và snapshot được giữ lại.

Sau khi đã cài, nút update bền vững nằm tại `.agent-zero/UPDATE.cmd`; bạn có thể xoá thư mục kit đã tải.

Khi một transaction đã bắt đầu, updater tạo thêm `.agent-zero-update/RECOVER.cmd`. Nếu máy hoặc PowerShell dừng đúng lúc `.agent-zero` đang được thay thế và `UPDATE.cmd` tạm thời không còn, hãy nhấp đúp file recovery này. Nó dùng engine tương thích với journal đang mở để rollback snapshot, không cần AI.

`LOSSLESS_SCRIPTED` chạy migrator đã được publisher đóng gói trong một bản sao tạm độc lập. Updater chỉ nhận lại `.agent` sau khi exit code, boundary, reparse, validator và live-context rehash đều đạt. Đây là containment cho migrator đáng tin từ release chính thức, không phải sandbox hệ điều hành chống một script độc hại; nếu migration cần quyền hoặc diễn giải rộng hơn thì release phải dùng `SEMANTIC_REVIEW`.

## Nếu bản cũ chỉ được bổ sung mỗi file UPDATE.md

Markdown không thể tự biết hay tự `get` từ GitHub. Hãy copy nguyên prompt dưới đây và dán vào agent AI hiện đang mở tại root project:

```text
Hay ho tro toi cap nhat Agent Zero trong project hien tai tu nguon chinh thuc
https://github.com/phamthanhtung216-sudo/agent-zero/releases/latest.

Rang buoc bat buoc:
- Truoc het kiem tra xem `.agent-zero/UPDATE.cmd` hoac mot kit co `UPDATE.cmd` da ton tai hay chua; neu co, uu tien chay checker/updater do.
- Neu updater chua ton tai, tai dung release stable da publish, khong dung raw `main` va khong dung `git pull` de ghi vao ban da cai.
- Doi chieu repository, tag, `UPDATE_MANIFEST.json`, `SHA256SUMS.txt` va SHA-256 cua ZIP truoc khi giai nen hoac chay script.
- Khong sua truc tiep `.agent/`, `.agents/`, `.codex/`, goal, decision, lesson, skill, custom agent hoac context cua user.
- Dung mode nghiem ngat hon giua manifest va drift local: CORE_ONLY < LOSSLESS_SCRIPTED < SEMANTIC_REVIEW < UNSUPPORTED; khong tu ha mode.
- Moi thay doi phai di qua snapshot, staging, validation, rehash ngay truoc activation va rollback/recovery journal.
- Neu can hieu/nghi lai y nghia context, chi lam trong staging, trinh bay mapping va diem chua chac, roi hoi toi xac nhan ro truoc khi activate.
- Neu thieu network/tool, checksum, transition ho tro hoac co mau thuan, dung va huong dan toi buoc thu cong; khong doan va khong ghi de de co hoan tat.

Hay bao truoc: phien ban hien tai, phien ban moi, noi dung thay doi, mode khai bao, mode hieu luc, context nao duoc giu nguyen va duong rollback. Sau khi update thanh cong, nhac toi mo chat/session moi de nap core moi.
```

AI có thể hỗ trợ thao tác, nhưng không thể tự bảo đảm tương đương ngữ nghĩa. Snapshot context cũ phải được giữ; nếu migration làm thay đổi ý nghĩa, quyền chấp nhận cuối cùng thuộc về user.
