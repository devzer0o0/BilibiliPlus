
# AI 推荐筛选与 S3 兼容备份

本文记录本次实现的产品行为、格式、安全边界和验证状态。它与代码同一分支；
“已实现”“已测试”“真实服务已验证”“真机已验证”是四个不同结论，文末逐项列出。

## 1. 结论摘要

| 项目 | 状态 |
| --- | --- |
| AI 推荐筛选完整闭环（设置、评分、排序、反馈、观看学习、多账号隔离、降级） | 已实现，单元/组件级测试通过 |
| S3 兼容备份（配置、连接测试、加密、上传回读、多版本、恢复预览、回滚） | 已实现，纯逻辑与假传输测试通过 |
| 全量静态检查 | dart analyze lib 无 error/warning（仅仓库既有 info） |
| 全量测试 | flutter test 513 项通过 |
| iOS 模拟器构建 | 见文末最新结果 |
| 真实模型服务 | 未验证（没有用户凭据） |
| 真实 S3 服务 | 连接测试已验证（MinIO，List/Put/Get/Delete 往返成功）；完整备份上传/恢复未真机验收 |
| iPhone Air / iOS 真机 | 未验证 |
| 安全存储在真机 Keychain 的读写 | 未验证（插件已接入并通过编译） |

## 2. AI 推荐筛选

### 2.1 接入位置

- 候选来源仍由 VideoHttp.rcmdVideoList / rcmdVideoListApp 获取。
- 现有广告、黑名单、标题正则、发布时间、时长、点赞率、关注豁免继续在 HTTP
  层先执行（RecommendFilter）。AI 只接收过滤后的候选，不能把已删除条目放回。
- RcmdController 负责刷新会话、分页、补量和页面状态；不解析模型协议、不做加密。
- AiRecommendationPipeline 负责缓存、预算、请求、降级与本地排序。
- HomeFeedPolicy 的“补足 6 条”只用于首页网格补量，不是推荐流总上限；AI 的
  严格精选会在一次刷新会话内按实际取数游标补充，最多沿用现有 3 页约束。
- 私信分享区仍走 SharedVideoService，不进入 AI 候选、不计入补量。

### 2.2 排序

权重集中在 RecommendationRanker：

- 语义相关性 0.40（模型 relevance 经 confidence 向 0.5 收缩）
- 本地画像/关键词 0.30
- 明确想看/少看 0.28
- 新鲜度 0.05
- B 站原顺序 0.06
- 作者偏好 0.04

缺失的评分不按 0 分处理：只对已知分量重新归一化。无关键词、无画像、无模型
时保留原顺序；探索位约占 20%，同一作者连续出现时做一次相邻降权；这些软约束
不突破硬过滤。

模式：

- 偏好排序（默认）：调整顺序；高置信度少看主题可折叠，状态栏可查看并恢复。
- 严格精选：只删除模型实际评分且低于阈值的内容；未评分内容保留。模型不可用
  时不伪装成严格精选，状态显示“当前使用本地规则”。

推荐原因由客户端模板生成，依据标题/简介/分类/时长等已有信息；不声称读取了
字幕、评论或画面。

### 2.3 请求与降级

- 独立 Dio，无 B 站拦截器，不携带 Cookie/CSRF/access key/设备头。
- 默认只接受 HTTPS；loopback 或显式允许的私有网络地址可使用 HTTP，公网 HTTP 始终拒绝。禁止重定向，防止 Authorization 转发。内网 HTTP 会用明文发送 API Key，只应在可信网络使用。
- 每批最多 20 个候选，每次刷新最多 2 批，每日默认 100 次；重试计入预算。
- 首屏等待预算默认 2000 ms，模型总超时 6 s。实测推理模型冷请求约 1.5 s；旧配置中的 800 ms 会钳制到 2000 ms，避免“响应已成功但先被标成不可用”。
- 刷新本身不发起模型请求：后台 worker 会提前拉取下一页并完成评分，刷新优先读取这份已准备好的结果；没有预取页时先用本地/缓存排序，并立即启动下一页预取。
- 预取使用完整模型超时（当前约 12 s/20 条），结果只存在内存中，App 重启后的第一次刷新会先走本地排序，随后后台重新预热。
- 迟到结果仍可只读缓存地应用到当前页；超时且无缓存时状态为“当前使用本地规则”，不再显示“AI 暂不可用”。
- 评分缓存键包含账号作用域、来源（app/web）、候选元数据 hash、profileVersion、
  关键词版本、provider 指纹、model、promptVersion/schemaVersion；TTL 24 小时。
- 缓存是派生数据，不进入备份。
- 刷新、改关键词、切账号、关闭 AI、清画像、页面销毁都会推进 generation；旧响应
  不写回页面。账号切换后缓存键不同，不混用画像。
- PlaybackSession 的两种后端都经 PlPlayerController.applySnapshot 汇入同一个
  addSnapshotListener；WatchIntervalAccumulator 过滤暂停、缓冲、seek、倍速和
  重复区间，写库最多每 2 分钟一次，并在暂停/完成/切视频时落盘。

### 2.4 隐私

- 首次启用不自动读取历史；导入需显式点击，最近 30 天、最多 200 条、只看 archive。
- 默认不把历史发送给模型；导入只在本地按明确关键词/已有主题做匹配。
- 历史账号与推荐账号不一致时拒绝导入，避免画像混用。
- 暂停学习、匿名/无痕、初学者默认关闭都会阻止学习写入。
- 删除画像后旧任务不会重新写回：学习写入只发生在显式反馈或本地播放结束，
  且每次读取当前账号作用域。
- 只保存内容偏好；不推断身份、健康、政治立场等敏感属性。
- API Key 只进平台安全存储，不进入 Hive、归档、日志或 Git。

## 3. S3 兼容备份

### 3.1 配置

字段：服务名称、Endpoint、Bucket、Region、Prefix、Access Key ID、Secret Access Key、
可选 Session Token、path-style / virtual-hosted、超时、自动备份间隔与保留数量。

示例（均需自行验证）：

| 服务 | Endpoint | Region | 寻址 |
| --- | --- | --- | --- |
| AWS S3 | https://s3.<实际区域>.amazonaws.com | 实际区域 | virtual-hosted |
| Cloudflare R2 | https://<account>.r2.cloudflarestorage.com | auto | path-style |
| MinIO | 自建 HTTPS；私有网络 HTTP 需显式允许 | 服务端配置（常见 us-east-1） | path-style |

最小权限（只覆盖指定前缀）：

    s3:ListBucket            arn:aws:s3:::BUCKET            (条件 s3:prefix)
    s3:GetObject             arn:aws:s3:::BUCKET/PREFIX/*
    s3:PutObject             arn:aws:s3:::BUCKET/PREFIX/*
    s3:DeleteObject          arn:aws:s3:::BUCKET/PREFIX/*

未使用 CreateBucket、ListAllMyBuckets、生命周期或版本控制修改。没有删除权限时
备份/恢复仍可用，自动清理被禁用并在连接测试中说明。

### 3.2 内容分类

默认：通用设置、界面与主题、播放与弹幕偏好、推荐过滤规则、本地黑名单、
AI 明确偏好。

单独选择且默认关闭：AI 推测画像与反馈、搜索历史、本地历史评论、本地播放进度、
自定义字体。

从不备份：B 站账号/Cookie/CSRF/access key/refresh token、AI API Key、
S3 Access/Secret/Session、WebDAV 密码、恢复密钥、私信、缓存/日志/下载媒体/临时文件。

新增未知设置默认不进入备份；必须加入 BackupRegistry 的显式白名单。
凭据字段还有第二道 isExcludedSettingKey 检查。

### 3.3 对象与归档

对象键：

    <prefix>/v1/<backupSetId>/<deviceId>/<UTC时间>-<snapshotId>.ppbackup

backupSetId、deviceId、snapshotId 均为随机标识，不含 B 站 UID、昵称或关键词。
不可变对象；上传使用 If-None-Match: *，412/409 时先回读比对，不覆盖不同内容。
没有可变的 latest.json。

外层 .ppbackup：

    magic PPBK (4)
    header length (4, big-endian)
    header JSON (v, alg, keyId, nonce)
    ciphertext
    GCM tag (16)

header 是 AAD；先验证认证标签，再解析归档。每次加密新 nonce；同一上传任务重试
复用已生成的完整密文字节。

内层 ZIP：

    manifest.json
    data.json
    font.bin (可选)

manifest 包含 formatVersion、各分类 schemaVersion、App 名称/版本/构建、平台、
创建时间、snapshotId、deviceId、backupSetId、分类列表、文件字节数与 SHA-256、
contentHash、warnings、profileScope。data.json 按分类保存规范化 JSON（Map 键排序）。

恢复顺序：文件大小/外层格式 → 加密版本 → 解密认证 → 归档条目白名单/路径/重复 →
解压总量与单文件上限 → 文件 SHA-256 → data/manifest 分类一致 → JSON 类型 →
分类 schema 版本 → 平台兼容性。当前限制：压缩 32 MiB、展开 64 MiB、data 16 MiB、
字体 32 MiB、200 个条目、JSON 深度 32、全局压缩比 300:1。

### 3.4 密钥与恢复码

- 256 位随机恢复密钥，默认存平台安全存储。
- 恢复码：PPB1- + Base32(密钥 32 字节 + SHA-256 前 2 字节校验)，带版本号；
  新设备输入恢复码即可解密对应 keyId 的快照。
- S3 Secret Key 不兼作备份密钥；密钥不进入 Hive、归档、日志、崩溃报告或 S3。
- 安全存储不可用时保存会失败，不退化为明文。

### 3.5 恢复与回滚

- 下载/解密/校验阶段不写任何现有设置。
- RestorePlanner 生成分类变更、跳过项、是否需要重启；支持黑名单/搜索历史
  合并去重或替换；空分类不删除现有数据；其他账号画像跳过；跨平台设备相关设置跳过。
- 恢复 AI 明确偏好时强制 enabled=false，恢复后需要用户重新确认模型地址和发送授权；
  恢复不自动打开外部请求或自动备份。
- 应用前写入 Hive 备份箱中的恢复日志；写入失败时按日志回滚旧值。启动早期
  BackupService.recoverPendingRestore() 处理未完成的恢复，再初始化控制器。
- 恢复后刷新 RecommendFilter 静态镜像；播放/界面设置提示重启。
- 恢复前创建的回滚快照就是日志中的旧值，不复制整个 Hive。

### 3.6 自动备份

默认关闭。触发：启动、回到前台、网络恢复、相关设置变更后 30 秒防抖。
同时满足：已启用、连接/密钥可用、内容指纹变化、达到最小间隔（默认 6 小时）、
网络符合偏好、没有恢复或另一任务。首次启用后的首次成功后记录基线；失败不更新
“最近成功备份”。仅当用户开启保留策略时清理本设备、当前备份集、自动创建的
旧快照；手动快照不自动删除。iOS 后台不承诺固定时间执行。

## 4. 主要改动文件

AI：

- lib/models/ai_recommend/：设置、候选特征、评分 DTO、画像、卡片动作
- lib/utils/ai_recommend/：画像服务/仓库、排序器、provider、缓存、用量、
  流水线、观看区间、观看服务、历史导入、生产服务
- lib/utils/security/secret_store.dart
- lib/pages/rcmd/controller.dart、view.dart、widgets/ai_status_bar.dart
- lib/pages/setting/ai_recommend.dart、ai_profile.dart
- lib/common/widgets/video_popup_menu.dart、video_card/video_card_v.dart
- lib/plugin/pl_player/controller.dart、lib/pages/video/controller.dart

备份：

- lib/models/backup/：配置、manifest/归档、快照记录
- lib/utils/backup/：注册表、编解码、加密、密钥、快照构建、S3 客户端、
  恢复规划/协调、Hive writer、历史仓库、调度、服务
- lib/pages/backup/s3_backup_page.dart、lib/pages/setting/view.dart

其它：lib/main.dart（启动恢复与自动备份）、lib/utils/storage*.dart
（新增 AI/备份 box 与设置键）、pubspec.yaml/lock。

## 5. 锁定依赖与许可证

| 包 | 版本 | 许可证 | 用途 |
| --- | --- | --- | --- |
| flutter_secure_storage | 11.2.0 | BSD-3-Clause | API/S3/恢复密钥 |
| cryptography | 2.9.0 | Apache-2.0 | AES-256-GCM |
| aws_signature_v4 | 0.6.13 | Apache-2.0 | SigV4 签名 |
| aws_common | 0.7.16 | Apache-2.0 | AWS HTTP 请求/凭据 |
| xml | 6.6.1 | MIT | ListObjectsV2 XML |

iOS 部署目标为 15.0，满足上述插件的声明要求；真实 Keychain 行为仍需真机验证。

## 6. 验证记录

运行命令（Flutter 3.47.9 / Dart 3.13.7）：

    dart analyze lib
    flutter test
    flutter build ios --simulator --debug

结果（截至本次提交）：

- dart analyze lib：无 error/warning；info 均为仓库既有或风格提示。
- flutter test：513 项通过，包含新增 AI 60 项、备份 44 项左右。
- flutter build ios --simulator --debug：通过，产物 build/ios/iphonesimulator/Runner.app
  （Xcode build 156.9 秒；Flutter 3.47.9）。
- AI 测试覆盖：两种来源归一化/去重、DTO 严格校验、画像反馈/撤销/衰减/保留、
  seek/暂停/缓冲/倍速/重复区间、预算/缓存/超时/账号隔离/generation、排序模式。
- 备份测试覆盖：加密往返/错钥/篡改/截断/恢复码、归档路径穿越/重复/超大/
  篡改/版本、注册表排除、构建指纹、规划差异/跳过/合并、恢复回滚与崩溃恢复、
  S3 签名 header/条件上传/分页/错误映射/回读校验。
- 已验证：真实模型请求、真实 S3 连接测试/对象往返、iPhone Air 上的安装与启动。
- 未做：完整 S3 备份上传到真实服务、从真实 S3 恢复的端到端真机验收、真机安全存储与 UI 手感。

## 7. 使用说明

### AI

1. 设置 → 推荐流设置 → AI 推荐筛选。
2. 填写想看/少看（每行一个短语）和可选兴趣描述；选择模式。
3. 高级设置填写 OpenAI-compatible 服务地址（通常以 /v1 结尾）、模型名称、
   API Key；保存并测试连接。
4. 开启“使用观看记录学习兴趣”后才会从本机播放/反馈学习；导入近期历史需再次点击。
5. 首页顶部 AI 状态条可查看状态、折叠数、调整兴趣、立即刷新。
6. 卡片菜单：为什么推荐 / 多看一些 / 少看一些 / 撤销最近反馈。反馈只影响本地画像，
   不调用 B 站“不感兴趣”或拉黑接口。

### S3

1. 设置 → S3 兼容备份，填写 Endpoint/Bucket/Region/Prefix 和凭据。私有网络 HTTP 端点首次保存/测试时会要求显式允许；公网 HTTP 仍拒绝。
2. 保存并测试连接；确认读/写/删除结果。
3. 选择备份内容；生成并保存恢复码。
4. 立即备份；刷新快照；查看大小/时间/设备。
5. 恢复：选择快照 → 预览变更与跳过项 → 勾选分类 → 应用；中途失败会回滚，
   成功后可重启使播放/界面设置完全生效。
6. 新设备：填入同样的 S3 配置和恢复码，刷新快照即可发现已有备份集。

## 8. 回退

- 功能开关关闭即恢复原推荐行为；AI 关闭不产生新请求/学习。
- 备份是独立新链路，旧本地 ZIP 与 WebDAV 入口保持原样，不被改写。
- 代码回退：普通 git revert <本任务提交>；不涉及数据迁移或历史重写。
- 恢复失败时以恢复日志中的旧值为准回滚；若回滚不完整，日志状态为
  rollbackIncomplete，启动时不会静默忽略。

## 9. 已知限制

- 真实模型与 S3 连接测试已用局域网服务验证；完整备份/恢复链路仍需在真机走一遍，不因连接成功而声称已验收。
- 本地播放学习只接入 UGC 视频；PGC 标题上下文未接入。
- 恢复字体后仍需重启才能保证所有文本使用新字体；回滚日志不保存旧字体字节。
- 自动备份是前台机会式调度，iOS 不保证固定时间后台执行。
- 图片/媒体/日志/缓存不进入备份；B 站云端历史、关注、收藏不会被恢复修改。
