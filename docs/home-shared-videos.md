# 首页「分享给我的视频」

首页推荐顶部会显示指定用户通过私信分享过来的视频。本文记录该功能的取数链路、两次真实缺陷及修复。

## 数据来源

指定用户 **StepGo**（uid `3546605619776050`）。

链路：`ImGrpc.sessionMain()` 取会话列表 → 找到该用户的单聊 → `syncFetchSessionMsgs()` 取消息 →
`SharedVideoParser` 解析 → `SharedVideoService.foldForWanted()` 过滤去重 →
`VideoHttp.videoIntro()` 补全标题与封面 → 首页横滑区渲染。

## 缺陷一：纯文本分享被整条丢弃

### 现象

解析结果为 **0 条**，首页完全不显示分享区。

### 排查

会话查找本身是成功的（`sessions=13 oneToOne=10 hasStepGo=true`），问题在解析。把该会话的真实消息导出后看到：

```
type=1 uid=3546605619776050 len=1393
{"content": "今天有 4 条值得看：\n\n1.《记忆插件装上之后，它什么都没记住》\nhttps://www.bilibili.com/video/BV1Cw4G6CEGX\n..."}
```

**该用户发的是 `EN_MSG_TYPE_TEXT`（纯文本）消息**，视频链接内嵌在正文里，而不是分享卡片类型。
解析器只接受 `SHARE`/`SHARE_V2`/`VIDEO_CARD`/`COMMON_SHARE_CARD`，因此 12 条消息一条都没匹配上。

### 修复

`shared_video_parser.dart`：

- 新增 `fromText()` 与 `_bvidInText`（`BV[0-9A-Za-z]{10}`），从正文提取 bvid
- `parsePage` 在卡片解析失败后回退到正文扫描，解开 `{"content": "..."}` 内层字符串
- **回退仅限 `EN_MSG_TYPE_TEXT`**

> 回退范围受限是必须的：测试曾抓到一个真实缺陷 —— 直播卡片被 `parse` 依规则拒绝后，
> 又被正文回退解析成了视频。限定类型后，已被卡片规则排除的直播/动态不会复活。

修复后解析数从 0 变为 **11**。

## 缺陷二：去重与过滤顺序颠倒

### 现象

指定用户分享的视频间歇性消失。

### 原因

`e8fc848f2` 引入 `senderId == stepGoUid` 过滤时，把它放在了**去重之后**。去重规则是"每个 bvid 保留最新副本"：

```
StepGo 分享 BV1x (ts=1000)
他人转发同一 BV1x (ts=2000)   ← 更新
        ↓ 去重先执行
保留 ts=2000 的他人副本
        ↓ 过滤后执行
senderId != stepGoUid → 丢弃
        ↓
结果：[]
```

只要有人转发过同一条视频且时间更晚，它就会从推荐中消失。

### 修复

过滤提前到去重之前，抽为 `foldForWanted()`，生产代码与测试共用同一实现。

## 缺陷三：标题显示为 URL

### 现象

卡片标题显示为 `https://www.bilibili.com/vid...`，封面空白。

### 原因

消息里链接独占一行，标题在**上一行**：

```
1《让 Agent 真正看懂整个视频》Sense Now 升级   ← 标题
https://www.bilibili.com/video/BV1tb4M6zEyD    ← 链接
```

初版取"包含 bvid 的那一行"作为标题，也就是链接自己那一行，于是标题成了裸 URL。
封面空白则是因为纯文本消息本身不带封面图。

### 修复

- 标题：优先取链接所在行的非 URL 文本；该行只有链接时，向上取最近的非空行；并剥掉 `1.` / `1、` / `1《` 这类列表编号
- 封面与标题补全：加载后对每条视频调用 `VideoHttp.videoIntro(bvid:)` 取真实 `title` 与 `pic`，
  查询失败则保留原值而不是丢弃条目
- `SharedVideo` 增加 `copyWith`，用于在查到结果后替换字段

实测补全结果（真机日志）：

```
share-detail bvid=BV1tb4M6zEyD title=让 Agent 真正看懂整个视频！... coverHost=i1.hdslb.com
share-detail bvid=BV1Cw4G6CEGX title=记忆插件装上之后，它什么都没记住 coverHost=i0.hdslb.com
```

11 条全部拿到真实标题与非空封面（`coverLen=76`，host 均为 `i*.hdslb.com`）。

## 会话扫描窗口

原实现只扫最新 10 个会话，指定用户的会话一旦掉出窗口就永远扫不到。
现改为最多 40 个，并**优先读取指定用户会话**，命中即 break —— 多数情况下比原来更快。

## 测试

| 文件 | 覆盖 |
| --- | --- |
| `test/utils/shared_video_text_share_test.dart` | 纯文本链接解析、无链接不产出、卡片仍正常、直播仍拒绝 |
| `test/utils/shared_video_filter_order_test.dart` | 先过滤再去重、他人转发不顶掉、非指定用户仍排除、排序 |
| `test/utils/shared_video_title_test.dart` | 标题取上一行、剥编号、链接不泄漏、封面由查询补全 |

全量 `flutter test`：**352 项通过**。
