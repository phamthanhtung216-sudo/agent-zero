# Agent Zero

**Giúp AI hiểu dự án, học từ việc đã làm và tiếp tục công việc có căn cứ.**

Bạn đang dùng AI để làm website, ứng dụng hay công cụ nội bộ? Agent Zero bổ sung **bộ nhớ dự án và một quy trình làm việc** cho trợ lý AI: tìm hiểu trước khi sửa, ghi nhớ quyết định, kiểm tra kết quả và rút kinh nghiệm từ những vấn đề đã được xác minh.

Mục tiêu là giúp bạn bớt phải giải thích lại từ đầu, dễ biết AI đang làm gì và giữ quyền quyết định khi dự án phát triển.

Agent Zero là bộ hướng dẫn, file bộ nhớ và công cụ kiểm tra chạy cùng một **coding agent** — tức trợ lý AI có thể đọc, sửa file và chạy lệnh trong dự án. Bạn vẫn cần một công cụ như Codex hoặc Claude Code để thực hiện công việc.

**Bản hiện tại: v0.11.1 · Bộ cài Windows · Hướng dẫn bằng tiếng Việt**

[Cài bằng Git](#cài-đặt) · [Tải bộ cài ZIP](https://github.com/phamthanhtung216-sudo/agent-zero/releases/latest) · [Hướng dẫn chi tiết](START_HERE.md) · [Báo lỗi / góp ý](https://github.com/phamthanhtung216-sudo/agent-zero/issues)

## Cập nhật v0.11.1

Phiên bản này tập trung giảm việc tiêu quota ngoài dự kiến khi Agent Zero audit hoặc sửa một project lớn:

- Audit và phần sửa tiếp theo giữ nguyên một task; lệnh `continue` hoặc mở lại phiên không tạo ngân sách mới. Toàn task chỉ được start tối đa ba sub-agent.
- Khi mức dùng Codex đạt 80%, Agent Zero cảnh báo trước khi nhận việc lớn. Từ 90%, agent phải tóm tắt việc đang làm, ghi đúng bước tiếp theo rồi dừng phần tốn quota cho tới khi mức dùng được xác nhận đã xuống dưới 90%.
- Full matrix thường chỉ chạy một lần ở cuối. Lượt thứ hai chỉ được phép nếu lượt đầu thất bại, đã có đúng một lần sửa tập trung và focused check đã PASS.
- Agent Zero không tự đổi model hoặc reasoning để né quota. Installer hỗ trợ nâng cấp bản cài nguyên gốc từ v0.10.0 lên v0.11.1 với snapshot và giữ nguyên bộ nhớ, skill cùng custom agent của project.

Các gate trên giúp giới hạn vòng lặp và giữ điểm tiếp tục rõ ràng; chúng không làm quota Codex tự reset và cũng không bảo đảm mọi workload sẽ dùng cùng một lượng quota.

## Agent Zero giúp bạn làm gì?

| Bạn cần | Cơ chế của Agent Zero |
|---|---|
| Bắt đầu khi mới có một ý tưởng | Đọc dự án hiện có, hỏi những điểm quan trọng rồi cùng bạn làm rõ mục tiêu và bước đầu tiên. |
| AI nhớ những điều hai bên đã thống nhất | Lưu mục tiêu, quyết định và việc đang làm vào các file trong dự án để phiên sau có thể đọc lại. |
| AI rút kinh nghiệm từ lỗi cũ | Ghi bài học có bằng chứng và tìm lại bài học liên quan trước công việc tương tự. |
| AI nhận ra chính quy trình của nó đang cản việc | Review rule của Agent Zero, chủ động đưa proposal có bằng chứng và chờ bạn duyệt trước khi đổi core. |
| AI không biến mọi câu hỏi thành quy trình dài | Chọn profile theo độ phức tạp, giới hạn số vòng review/repair và dừng ở terminal state rõ ràng. |
| AI không âm thầm đốt quota khi audit lớn | Giữ audit+sửa trong một logical task, đếm tối đa ba lần start sub-agent, cảnh báo ở 80%; từ 90% lưu hiện trạng/next action rồi chờ quota giảm, không có bypass hoặc tự đổi model. |
| Hiểu biết của AI theo kịp dự án | Cập nhật trạng thái và thông tin kỹ thuật khi có bằng chứng mới; chỉ ra mâu thuẫn cần bạn quyết định. |
| Dự án lớn dần mà context vẫn có tổ chức | Chia bộ nhớ theo tầng, dùng mục lục và chỉ lấy những chi tiết phù hợp với công việc. |
| Biết một việc đã thực sự xong chưa | Đặt tiêu chí hoàn thành, chạy kiểm tra và báo kết quả, lỗi hoặc phần còn thiếu. |
| Thêm khả năng mới cho agent | Đề xuất quy trình tái sử dụng thành **skill** — một bộ hướng dẫn chuyên cho một loại việc — rồi đánh giá trước khi xin bạn kích hoạt. |
| Dùng cùng skill hoặc agent bạn đã cài | Giữ capability user/global và capability có sẵn trong project ở chế độ read-only; ưu tiên reuse/compose, chỉ tạo bản chuyên biệt có namespace riêng khi thật sự cần và được duyệt. |

Các cơ chế này kết hợp hướng dẫn cho AI với script kiểm tra. Khả năng thực hiện còn phụ thuộc vào coding agent, mô hình và quyền công cụ bạn đang dùng.

## 1. Tự học: biến kinh nghiệm đã kiểm chứng thành bộ nhớ

Hãy hình dung Agent Zero có một **sổ tay kinh nghiệm riêng cho dự án**.

Sau một công việc, agent xem có điều gì đáng giữ lại để lần sau làm tốt hơn: một nguyên nhân lỗi đã tìm được, một điều kiện dễ bỏ sót, hoặc một cách kiểm tra phù hợp. Bài học cần ghi rõ **áp dụng khi nào, vì sao và bằng chứng ở đâu**.

Một bài học đi qua các mức:

1. **Mới quan sát:** có dấu hiệu đáng chú ý, nhưng còn cần xác minh.
2. **Đã kiểm chứng:** nguyên nhân được xác nhận bằng tái hiện lỗi, kiểm tra hoặc bằng chứng phù hợp.
3. **Được đưa vào quy trình:** với bài học cần trở thành quy tắc bắt buộc, agent xin bạn đồng ý; có thể bổ sung bài kiểm tra hoặc cơ chế chặn lỗi.
4. **Không còn phù hợp:** khi dự án thay đổi, giữ lại lịch sử và ngừng áp dụng bài học cũ.

Một ghi chú mới chưa được coi là sự thật. Trong công việc thông thường, agent tra những bài học đã đủ điều kiện và có liên quan đến task hiện tại.

**Ví dụ minh họa:** bạn làm website đặt lịch. Agent phát hiện lịch bị lệch ngày, tái hiện lỗi và xác nhận nguyên nhân nằm ở cách xử lý múi giờ. Nó có thể lưu bài học cho phần ngày/giờ. Khi làm chức năng nhắc lịch sau đó, bài học này có thể được chọn lại để nhắc kiểm tra đúng chỗ.

**“Tự học” ở đây là tích lũy kiến thức trong các file dự án.** Nó không huấn luyện lại hay thay đổi trọng số của mô hình AI.

## 2. Tự cập nhật: giữ hiểu biết của agent theo kịp dự án

Dự án thay đổi mỗi ngày. Agent Zero có quy trình cập nhật những điều nó biết, gồm:

- Công việc đã xong, việc còn dở và bước tiếp theo.
- Lệnh kiểm tra thực sự chạy được và kết quả đã quan sát.
- Thông tin kỹ thuật đã được xác minh từ code, cấu hình hoặc quá trình chạy.
- Bài học và quyết định nào còn phù hợp, thông tin nào đã cũ hoặc mâu thuẫn.

Agent phân biệt **điều đã xác minh**, **quyết định của bạn**, **giả định** và **điều chưa biết**. Khi phát hiện thông tin cũ không còn đúng, nó phải đối chiếu lại trước khi cập nhật.

Ví dụ: tài liệu ghi một lệnh chạy test, nhưng lệnh đó không còn khớp cấu hình hiện tại. Agent kiểm tra lại, xác nhận lệnh phù hợp và cập nhật hướng dẫn để phiên sau có cơ sở dùng đúng.

**Có ba loại “update” cần phân biệt:**

| Loại cập nhật | Agent Zero xử lý thế nào? |
|---|---|
| Bộ nhớ và trạng thái dự án | Có thể tự cập nhật trong phạm vi được giao, dựa trên bằng chứng và qua kiểm tra bộ nhớ. |
| Quy trình, skill hoặc quy tắc bắt buộc | Có thể đề xuất, soạn bản nháp và đánh giá; cần bạn phê duyệt trước khi kích hoạt hoặc áp dụng bắt buộc. |
| Bộ quy tắc lõi hoặc phiên bản Agent Zero mới | Agent phải chủ động đề xuất khi chính rule gây cản trở; việc sửa core vẫn cần bạn duyệt, có bản sao để khôi phục và kiểm tra tương ứng. v0.11 có đường nâng cấp explicit từ v0.10, không tự chạy nền. |

Việc cập nhật diễn ra khi agent đang thực hiện công việc. Bộ kit không có dịch vụ tự chạy nền khi bạn đã đóng công cụ AI.

## 3. Context theo tầng: bàn làm việc và tủ hồ sơ

**Context** là những thông tin AI đang được cung cấp để hiểu và làm việc. Trong một phiên làm việc, lượng thông tin đó có giới hạn.

Bạn có thể hình dung bộ nhớ của Agent Zero như **bàn làm việc có tài liệu cần dùng ngay, bên cạnh là tủ hồ sơ để tra cứu**:

| Tầng | Ví như | Chứa gì? | Khi nào dùng? |
|---|---|---|---|
| **1. Quy tắc lõi** | Nội quy làm việc | Quyền hạn, cách kiểm tra, cách học, cách xin quyết định và bảo vệ dữ liệu. | Là phần nền tảng phải được đọc khi làm việc. |
| **2. Dự án hiện tại** | Hồ sơ đang mở trên bàn | Mục tiêu, phạm vi, ràng buộc, việc đang làm và cách tìm bộ nhớ liên quan. | Đọc khi bắt đầu hoặc tiếp tục task. |
| **3. Kiến thức liên quan** | Ngăn hồ sơ có mục lục | Nội dung chi tiết của các bài học và quyết định đã lưu. | Chọn theo loại việc, phần dự án, công cụ hoặc dấu hiệu lỗi. |
| **4. Lịch sử lưu trữ** | Kho hồ sơ cũ | Bản ghi đã chuyển sang lưu trữ và lịch sử thay đổi. | Tra khi cần hiểu quá khứ, xử lý mâu thuẫn hoặc khôi phục. |

Hai tầng đầu là phần thông tin thường trực, còn gọi là **hot context**. Phần chi tiết được tra có chọn lọc; lịch sử lưu trữ là **cold context**, không được nạp mặc định.

**Ví dụ:** khi sửa màn hình đặt lịch, agent tìm quyết định về luồng đặt lịch và bài học về ngày/giờ. Những hồ sơ về một phần khác của dự án chỉ được lấy khi có liên quan.

Cơ chế chọn còn có điều kiện loại trừ và giới hạn dung lượng. Khi cần tìm lại do lỗi bất ngờ hoặc mâu thuẫn, agent phải nêu lý do mở rộng tra cứu.

Điểm quan trọng: **kiến thức dự án được phép tăng lên, nhưng lượng đem vào mỗi task được giới hạn**. Bộ quy tắc lõi được giữ ổn định; bài học mới đi vào kho bộ nhớ riêng.

<details>
<summary>Muốn biết các tầng nằm ở file nào?</summary>

Đây là cấu trúc trong project **sau khi cài**, không phải cấu trúc thư mục tải về:

| Nhóm thông tin | Vị trí |
|---|---|
| Quy tắc lõi | `AGENTS.md` |
| Mục tiêu và thông tin hiện hành | `.agent/PROJECT.md` |
| Task và điểm tiếp tục | `.agent/STATE.md` |
| Quy tắc tra cứu, giới hạn dung lượng | `.agent/CONTEXT_INDEX.md` |
| Mục lục bài học và quyết định | `.agent/LESSONS.md`, `.agent/DECISIONS.md` |
| Capability/routing liên quan | `.agent/CAPABILITIES.md` |
| Skill và custom agent do Agent Zero quản lý | `.agent/SKILLS.md`, `.agent/SUBAGENTS.md` |
| Bản nháp theo project | `.agent/skill-candidates/`, `.agent/subagent-candidates/` |
| Asset active để host discover | `.agents/skills/`, `.codex/agents/` |
| Nội dung chi tiết | `.agent/lessons/`, `.agent/decisions/` |
| Lịch sử lưu trữ | `.agent/archive/` |

Mặc định của kit: phần thường trực tối đa **64 KiB**, phần chi tiết được chọn tối đa **16 KiB** và **8 bản ghi** cho mỗi lần chọn context. Đây là giới hạn cho bộ nhớ do Agent Zero quản lý, không phải giới hạn toàn bộ cửa sổ chat của mô hình.

Các bản ghi chi tiết có mã kiểm tra SHA-256 để phát hiện nội dung bị thay đổi. Mã này kiểm tra tính toàn vẹn; bằng chứng và xác nhận của đúng người vẫn quyết định nội dung có đáng tin hay không.

Bạn có thể đọc [bộ quy tắc lõi](AGENT_ZERO_CANDIDATE.md) và [mẫu quản lý context](payload/templates/CONTEXT_INDEX.md) ngay trong repo này.

</details>

## 4. Một yêu cầu được xử lý như thế nào?

Giả sử bạn nói:

> “Tôi muốn thêm tính năng nhắc khách trước buổi hẹn.”

Đây là ví dụ minh họa cách Agent Zero được thiết kế để làm việc:

1. **Hiểu yêu cầu trong dự án.** Đọc mục tiêu, phần đang làm và tài liệu liên quan. Kiểm tra dự án trước khi hỏi những gì có thể tự tìm.
2. **Làm rõ điều ảnh hưởng đến kết quả.** Nếu cần chọn kênh nhắc lịch hoặc dùng dịch vụ có phí, agent trình bày lựa chọn để bạn quyết định.
3. **Thống nhất thế nào là xong.** Chẳng hạn nhắc đúng thời điểm, không gửi trùng và có cách kiểm tra kết quả.
4. **Làm theo bước nhỏ.** Ghi điểm tiếp tục cho việc nhiều bước để phiên sau biết đang ở đâu.
5. **Kiểm tra, tự review và sửa lỗi có bằng chứng.** Agent review cả kết quả lẫn việc quy trình Agent Zero có gây cản trở hay không. Nếu cùng một lỗi vẫn còn sau hai chu kỳ sửa, agent phải dừng và báo phương án tiếp theo.
6. **Báo kết quả và lưu điều đáng nhớ.** Nêu đã làm gì, kiểm tra ra sao, còn thiếu gì; cập nhật trạng thái và bài học có giá trị.

Bạn không cần tự quản lý từng file bộ nhớ. Vai trò chính của bạn là mô tả điều muốn đạt được, phản hồi và đưa ra những quyết định quan trọng.

## 5. Chủ động cải tiến, với quyền quyết định thuộc về bạn

Agent Zero phải tự review governance khi rule gây blocking/repair lặp, user phải sửa hành vi, overhead không tăng chất lượng, behavioral regression hoặc giả định về năng lực model/runtime đã cũ. Khi có bằng chứng đáng kể, agent chủ động tạo proposal — không chờ bạn hỏi. Đề xuất nêu rule bị ảnh hưởng, evidence, tác động, thay đổi nhỏ nhất, rủi ro, cách kiểm tra và rollback. Proposal không phải approval và không cho agent tự ý sửa core.

Một quy trình nhiều bước lặp lại có thể được đề xuất thành **skill**. Skill được soạn ở nơi dành cho bản nháp, kiểm tra lúc nào nên dùng và lúc nào không nên dùng, rồi mới xin bạn kích hoạt.

Nếu user hoặc project đã có skill/custom agent tương tự, Agent Zero không ghi đè và không gộp hai nội dung cùng tên. Nó phân loại khả năng theo use case: dùng lại một provider đủ (`REUSE`), ghép các phần bổ sung không chồng lấn (`COMPOSE`), hoặc đề xuất một bản project-specific có namespace riêng (`SPECIALIZE`). Semantic/authority conflict được giữ nguyên để đúng owner quyết định. Theo core contract và validator, provider phải dùng parent-run accounting; khả năng load và thực thi provider thật vẫn phụ thuộc host/runtime.

Nếu công cụ AI đang dùng hỗ trợ agent phụ, Agent Zero cũng có thể chia các việc độc lập cho chúng. Agent chính vẫn phải đọc kết quả, tích hợp và kiểm tra; số lượng và khả năng chạy song song phụ thuộc công cụ đó.

Agent có thể tự xử lý những chi tiết nhỏ, có thể hoàn tác, trong phạm vi đã được giao. Những thay đổi như mục tiêu sản phẩm, phạm vi lớn, kiến trúc nền tảng, dịch vụ trả phí hoặc đưa thay đổi lên hệ thống thật cần đúng quyền phê duyệt.

## Bắt đầu với dự án mới hoặc dự án đang làm

**Nếu bạn mới có ý tưởng:** agent bắt đầu bằng tìm hiểu dự án, người dùng và điều bạn muốn đạt được. Nó giúp hoàn thiện dần mục tiêu và phạm vi, hỏi tối đa ba câu quan trọng mỗi lượt. Nếu đã có một task cụ thể, agent vẫn có thể làm phần an toàn trong khi làm rõ các điểm còn thiếu.

**Nếu dự án đã có agent hoặc bộ nhớ cũ:** installer chọn luồng **adoption** — tiếp nhận có kiểm soát. Agent Zero được đặt ở dạng bản đề xuất riêng, khảo sát phần cũ và lập kế hoạch chuyển đổi. Việc thay đổi phần đang dùng cần bạn duyệt. Sau khi chuyển đổi và kiểm tra, agent còn phải báo kết quả để bạn chấp nhận rõ ràng.

## Cài đặt

Bạn cần Windows 10/11, Windows PowerShell 5.1 hoặc PowerShell 7, Git nếu chọn cách 1, và một coding agent có quyền làm việc với file dự án.

### Cách 1 — Kéo toàn bộ repo bằng một lệnh Git

Mở PowerShell **ngay tại thư mục gốc của project** rồi chạy:

```powershell
git clone https://github.com/phamthanhtung216-sudo/agent-zero.git agent-zero-kit
```

Lệnh này tải toàn bộ bản public vào thư mục `agent-zero-kit`. Lần đầu phải dùng `git clone`; `git pull` chỉ hoạt động sau khi thư mục Git đã tồn tại.

Mở thư mục `agent-zero-kit`, nhấp đúp **`INSTALL.cmd`**, đọc đường dẫn project và xác nhận chế độ installer đề xuất.

Khi muốn kéo bản public mới nhất về **thư mục kit đã clone**, đứng tại thư mục gốc project và chạy:

```powershell
git -C .\agent-zero-kit pull --ff-only
```

Lệnh này chỉ cập nhật bộ kit đã tải. Nếu project đang dùng v0.10.0, xem mục “Muốn cập nhật lên bản Agent Zero mới thì sao?” bên dưới để chạy upgrade có snapshot.

### Cách 2 — Tải file ZIP

1. Mở [trang Releases](https://github.com/phamthanhtung216-sudo/agent-zero/releases/latest), tải file **`agent-zero-kit-v0.11.1.zip`** trong phần **Assets**.
2. Giải nén và copy **nguyên thư mục `agent-zero-kit`** vào thư mục gốc của project.
3. Mở thư mục kit, nhấp đúp **`INSTALL.cmd`**, đọc đường dẫn project và xác nhận chế độ installer đề xuất.

### Sau khi installer hoàn tất

1. Mở **phiên coding agent mới** tại thư mục project.
2. Gửi câu khởi động:

```text
Khởi động Agent Zero theo .agent-zero/START.md
```

Sau đó mô tả điều bạn muốn làm, ví dụ:

> “Tôi muốn làm website đặt lịch cho một studio nhỏ. Hãy kiểm tra dự án và giúp tôi xác định bước đầu tiên.”

Xem [START_HERE.md](START_HERE.md) nếu cần hướng dẫn từng bước hoặc giải thích các lựa chọn của installer.

<details>
<summary>Muốn kiểm tra trước khi cài?</summary>

Kiểm tra mà chưa ghi file vào project:

```powershell
& ".\agent-zero-kit\install-agent-zero.ps1" -TargetPath "." -WhatIf
```

</details>

## Một vài điều cần biết

**Mở phiên chat mới, agent có nhớ hết không?**

Agent có thể đọc lại những gì đã được lưu trong file dự án. Cuộc hội thoại chưa được lưu, file bị mất hoặc dữ liệu nằm ngoài dự án không tự trở thành bộ nhớ. Để tiếp tục, mở agent tại đúng project và dùng câu khởi động ở trên.

**Cài Agent Zero có bảo đảm AI luôn làm đúng không?**

Bộ hướng dẫn giúp tổ chức cách làm việc; script kiểm tra xác nhận các điều kiện mà chúng được viết để kiểm tra. Kết quả vẫn phụ thuộc mô hình, công cụ và bằng chứng thực tế. Tự review cũng không thay thế một người hoặc bên khác review độc lập.

**Bộ nhớ có tự đồng bộ lên GitHub không?**

Kit lưu bộ nhớ trong project local. Việc backup hoặc đồng bộ là quy trình riêng. Không lưu mật khẩu, API key, token hay dữ liệu nhạy cảm trong bộ nhớ; xem lại các file trước khi chia sẻ dự án. Dữ liệu cung cấp cho coding agent còn phụ thuộc thiết lập và dịch vụ AI bạn dùng.

**Muốn cập nhật lên bản Agent Zero mới thì sao?**

Theo dõi [Releases](https://github.com/phamthanhtung216-sudo/agent-zero/releases). Nếu đã tải bằng Git, chạy `git -C .\agent-zero-kit pull --ff-only` để kéo bản public mới về thư mục kit. Với bản v0.10.0 đã cài, chạy explicit:

```powershell
& ".\agent-zero-kit\install-agent-zero.ps1" -TargetPath "." -UpgradeExisting
```

Installer chỉ hỗ trợ `0.10.0 -> 0.11.1`, snapshot trước và giữ nguyên project memory, user skill cùng custom agent. STATE schema 5 cũ chỉ được đọc ở compatibility mode và được migrate có kiểm chứng tại checkpoint sau; không có silent activation hay counter reset.

## Tài liệu và góp ý

Repo này chứa kit phát hành và tài liệu công khai. Bộ nhớ của dự án bạn sẽ được tạo trong chính project sau khi cài.

- [Hướng dẫn cài đặt và khởi động](START_HERE.md)
- [Bộ quy tắc hoạt động đầy đủ](AGENT_ZERO_CANDIDATE.md)
- [Các kịch bản đánh giá](payload/TESTING.md)
- [Báo lỗi hoặc đề xuất cải tiến](https://github.com/phamthanhtung216-sudo/agent-zero/issues)

Khi báo lỗi, gửi phiên bản Agent Zero, phiên bản PowerShell, bước tái hiện và thông báo lỗi đã loại bỏ dữ liệu nhạy cảm. Một số kịch bản hành vi tự nhiên vẫn cần đánh giá thêm; tài liệu quy trình không đồng nghĩa tất cả hành vi đã được chứng minh trên mọi mô hình.

## License

Chủ dự án chưa chọn license. Repository công khai chưa cấp một giấy phép open-source như MIT; nếu muốn sử dụng lại, sửa đổi hoặc phân phối ngoài những quyền sẵn có, hãy trao đổi với chủ dự án trước. Xem [giải thích của GitHub về repository chưa có license](https://choosealicense.com/no-permission/).
