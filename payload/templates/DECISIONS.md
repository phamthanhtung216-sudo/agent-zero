# Decisions Index

- Schema: `2`
- Detail root: `.agent/decisions`
- Archive root: `.agent/archive/decisions`
- Last validated: `UNKNOWN`

File này chỉ là hot index. Nội dung quyết định đầy đủ nằm ở `Detail path`. Không giữ `SUPERSEDED` hoặc `REJECTED` trong hot index; chuyển record sang archive và ghi provenance.

## Status flow

`PROPOSED -> ACCEPTED -> SUPERSEDED`; proposal không được chọn có thể thành `REJECTED`.

## Decisions

| ID | Title | Status | Load | Priority | Components | Paths | Tools | Error signatures | Task types | Excludes | Detail path | Last reviewed | Detail SHA256 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

## Index rules

- `Load` là `MATCH` hoặc `GLOBAL`; chỉ decision `ACCEPTED` mới được dùng `GLOBAL`.
- Metadata nhiều giá trị dùng dấu chấm phẩy; dùng `NONE` khi không có signal.
- `Paths` và `Excludes` dùng glob tương đối từ project root.
- `Detail path` phải nằm dưới `.agent/decisions/`, có basename trùng ID và không vượt detail-record quota.
- `Detail SHA256` phải khớp nội dung record; hash chỉ phát hiện drift, không chứng minh nội dung đúng.
- `PROPOSED` chỉ được selector trả về khi caller yêu cầu rõ `IncludeProposed`.
