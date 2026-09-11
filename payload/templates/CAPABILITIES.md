# Capability Registry

- Schema: `1`
- Provider row schema: `2`
- Route row schema: `2`
- Inventory scope: `RELEVANT_ONLY`
- Resolution mode: `ON_DEMAND`
- Catalog state: `UNOBSERVED`
- Catalog fingerprint: `NONE`
- Last observed: `UNKNOWN`
- Last validated: `UNKNOWN`

Registry này chỉ lưu metadata capability liên quan đến project và routing decision có thể tái sử dụng. Không copy nội dung provider external, không crawl user home và không lưu absolute personal path.

## Provider contract

- `Provider ID` là định danh bất biến dùng cho routing; `Display name` chỉ là nhãn có thể đổi và không được dùng thay ID.
- `Provider row schema` và `Route row schema` quyết định cách đọc toàn bảng; không suy đoán legacy/canonical từ giá trị một cell. Header hoặc row hỏng phải fail thay vì bị coi như catalog rỗng.
- Canonical provider fields là `id`, `displayName`, `kind`, `scope`, `ownership`, `authority`, `availability`, `capabilityKeys`, `contributions`, `sideEffect`, `delegation`, `sourceRef`, `observedSha256`, `lastSeen`.
- `Capability keys` và `Contributions` là mapping có evidence, không được suy ra chỉ từ display name.
- Metadata safety `UNKNOWN` chỉ được giữ cho inventory; provider đó không được `REUSE|COMPOSE` tới khi metadata được xác minh.
- `Source ref` của provider external dùng logical pointer như `USER:<name>` hoặc `SYSTEM:<name>`; repo provider dùng project-relative path.
- Catalog `PARTIAL` hoặc provider `MISSING` không tự cấp quyền tạo replacement.

## Providers

| Provider ID | Capability keys | Kind | Display name | Scope | Ownership | Authority | Availability | Contributions | Side effect | Delegation | Source ref | Observed SHA256 | Last seen |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|

## Resolution contract

`BASELINE | IGNORE | REUSE | COMPOSE | SPECIALIZE | CONFLICT | FALLBACK`

Mọi provider chạy trong phase và budget của parent run. `REUSE` ưu tiên provider an toàn, ít side effect/delegation, ít contribution dư và scope/ownership hẹp hơn trước khi dùng immutable ID làm tie-break. `COMPOSE` chỉ dùng provider có contributions rời nhau và tạo một workflow/verdict tích hợp; không tạo lifecycle hoặc review loop lồng. `FALLBACK` cần evidence chứng minh outcome tương đương; `NONE|UNKNOWN` không phải evidence. `Use case` và `Review trigger` của mỗi route phải cụ thể.

## Resolutions

| Route ID | Capability key | Use case | Candidate providers | Decision | Selected providers | Required contributions | Max side effect | Delegation allowance | Authority | Fallback evidence | Evidence | Parent-run accounting | Review trigger | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
