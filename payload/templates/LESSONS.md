# Lessons Index

- Schema: `2`
- Purpose: `PROJECT_LEARNING_MEMORY`
- Detail root: `.agent/lessons`
- Archive root: `.agent/archive/lessons`
- Last validated: `UNKNOWN`

File này là điểm vào riêng cho kiến thức Agent Zero học được từ project và chỉ là hot index. Nội dung đầy đủ của mỗi lesson nằm ở `Detail path`. Không đưa `RETIRED` vào hot index; chuyển record đó sang archive và giữ provenance trong changelog. Normal project learning không được append hoặc promote vào `AGENTS.md`.

## Status flow

`CANDIDATE -> VERIFIED -> ENFORCED -> RETIRED`

## Lessons

| ID | Title | Status | Load | Priority | Components | Paths | Tools | Error signatures | Task types | Excludes | Detail path | Last verified | Detail SHA256 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

## Index rules

- `Load` là `MATCH` hoặc `GLOBAL`; chỉ lesson `ENFORCED` mới được dùng `GLOBAL`.
- Metadata nhiều giá trị dùng dấu chấm phẩy; dùng `NONE` khi không có signal.
- `Paths` và `Excludes` dùng glob tương đối từ project root.
- `Detail path` phải nằm dưới `.agent/lessons/`, có basename trùng ID và không vượt detail-record quota.
- `Detail SHA256` phải khớp nội dung record; hash chỉ phát hiện drift, không chứng minh nội dung đúng.
- `CANDIDATE` chỉ được selector trả về khi caller yêu cầu rõ `IncludeCandidates`.
- Lesson `ENFORCED` phải trỏ tới project policy, test/guard hoặc approved skill; nó vẫn không tự sửa Agent Zero core.
