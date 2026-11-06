# 伙伴小屋

> 2026-11-06。第一版的实现规格，以及之后的路线。调研和长期设计的底稿在 Drive `AI-workspace/dshgo-companion1/`（C1xx 调研、C2xx 设计、C3xx 后端约定）。

## 0. 结论

- **整页换模式，不是加挂件。** 从「切换主机」面板进入。这页是一个 Live2D 角色，上面叠字幕和输入条。现有的状态宠物（`pets.md`）不变，它仍然只表达 agent 在干什么。
- **活人感优先靠规则层，不靠模型。** 眨眼、视线、呼吸、闲置小动作、触摸反应、昼夜和问候都不花 token。模型只在用户开口时才调用。
- **Live2D 的东西不进 APK 和仓库。** Core 是 Live2D 的专有代码，框架和模型各有条款。它们打成素材包，用时才放进手机。App 里只有我们自己的舞台代码。
- **角色素材是数据，运行库是代码。** 运行库按写死的摘要校验，角色目录只收数据文件。所以以后用户自己导入角色时，别人的包不能在 WebView 里跑脚本。
- **两种对话方式，用户自己选（§6.3）。** 轻量：手机直接调模型，只聊天，不用启动引擎、不连主机。完整：当前主机上的一个普通会话，用 `dsh-go-companion-full` 预设，有主机的全部工具，开了手机操控时还有手机工具。

## 1. 第一版做了什么

| 能力 | 做法 | 位置 |
|---|---|---|
| 入口 | 「切换主机」面板里的「伙伴小屋」一行 | `app/lib/ui/remote/host_switcher.dart` |
| 页面 | 全屏 WebView 上面叠 Flutter（名牌、字幕、输入条），暗色玻璃 | `app/lib/ui/companion/` |
| 渲染 | 官方 Cubism Web Framework 5-r.5 + Core 6.0.1，自写模型类 | `app/assets/companion/stage.js` |
| 场景 | 水下：光束、远处的鲸、礁石、浮游微粒，随时段换色（清晨、白天、傍晚、夜晚） | `stage.css`、`scene.js` |
| 活着 | 分层逐帧计算：视线弹簧 → 闲置漂移 → 心情姿态 → 情绪表情 → 动作曲线 → 触摸 → 口型 → 表情 → 物理 → 尾巴 | `stage.js` |
| 触摸 | 点头、脸、身体、尾巴、腿各有反应；摸头闭眼脸红并飘心；连戳三下头晕；双指缩放；手指移动时视线跟随 | `stage.js`、`companion_page.dart` |
| 漫符 | 心、星、感叹号、问号、青筋、汗滴、思考点、Zzz | `scene.js` |
| 对话 | 文本和语音输入，流式字幕，标记驱动表情和动作，文本节奏带动口型 | `companion_page.dart`、`companion_reply.dart` |
| 问候 | 按时间和离开多久选一句，不责备 | `companionGreeting` |
| 素材 | 导入 zip，路径和类型检查，运行库摘要校验，可删除 | `app/lib/companion/companion_pack.dart` |
| 预设 | `dsh-go-companion-full`（完整模式，人设 + 标准预设的全部插件，Pro C410/C411）；只有人设的 `dsh-go-companion` 留着不用。桥接随引擎带上；旧主机退回「默认预设 + 人设放进第一条消息」 | `runtime/bridge/dsh-go-bridge/cordis.patch.yml` |
| 状态（第 1 期） | 主机上的心情、精力、亲近度：进门记一次到访，摸头记一次事件；心情好时带一点笑，精力影响动作幅度，越熟越常看着你。问候用主机记下的上次到访时间 | `runtime/bridge/dsh-go-bridge/lib/companion/`、`companion_api.dart` |
| 记忆（第 1 期） | 「她记得的事」：用户写下、修改、删除，只存在当前主机；页面如实写明她还不会自己想起 | `companion_memory_page.dart` |
| 生活细节 | 夜里更容易困、会打哈欠，清晨伸懒腰，心情好时哼歌冒音符，说到句末轻轻点头 | `stage.js` |
| 小房子（第 1 期） | 海底的一角：贝壳点心盘、泡泡球、海草软垫，点了各有一段表演，主机记下活动和剩余时间。见 §6.1 | `index.html`、`stage.js`、`companion_page.dart` |

没有做：TTS（App 目前没有）、自动回忆、手机操控、房间装扮。见 §6。

**会话的权限**：伙伴会话建好后切到 `read-only`，也不受「自动批准命令」影响。Pro 的 C200 指出只挂人设的预设仍可能继承主机的全局工具，真实工具集合还在核实（Drive ADDENDUM-03）。

## 2. 结构

```
Flutter CompanionPage
  ├─ CompanionStage（WebViewController）── runJavaScript: stage.command({type, ...})
  │     ▲ JS channel DshCompanion: ready / error / touch / wake / mood / object / activity
  │     └─ http://127.0.0.1:<随机端口>/<随机令牌>/{app,pack}/...  CompanionServer
  ├─ 名牌、字幕、输入条（companion_chrome.dart）
  └─ chatProvider(sessionId) ── 普通会话 ── 当前主机上的 DSH
```

- **回环服务**：WebView 要 `fetch` 着色器和模型文件，`file://` 做不到。手机上任何 App 都能连回环端口，所以每条路径都以每次启动随机生成的令牌开头，没有令牌只有 404。页面关闭时服务也关闭。`app/` 只有固定的几个文件，`pack/` 只读且不出目录。
- **WebView 不拿权限**：`onPermissionRequest` 一律拒绝，页面只能导航到自己。麦克风留在 Flutter 一侧，用现有的 `VoiceInputController`。
- **CSP**：`script-src 'self' 'wasm-unsafe-eval'`，Core 的 WASM 需要后者。模型文字不进脚本，命令都是 JSON 编码的结构化消息。
- **一帧的顺序**（`StageModel.tick`）：恢复参数基线 → 保存 → `animate.before`（写视线、姿态、表情参数、动作、口型）→ 表情管理器 → 物理 → Pose → `animate.after`（尾巴）→ `model.update`。Framework 的 `getParameterIndex` 对不存在的参数会造一个虚拟索引，所以判断模型有没有某个参数要和 `getParameterCount` 比。

## 3. 素材包

```
pack.zip
├─ runtime/                      代码，摘要写死在 companionRuntimeDigest
│  ├─ live2dcubismcore.min.js    Live2D Proprietary Software License（RedistributableFiles.txt 列出的可再分发文件）
│  ├─ cubism-framework.js        Live2D Open Software License，由 build-pack.mjs 打包
│  ├─ shaders/*.frag|*.vert
│  └─ LICENSE-framework.md
└─ character/                    数据：.json .moc3 .png .jpg .jpeg .webp .wav .mp3 .txt .md
   ├─ character.json             可选，见下
   ├─ *.model3.json
   └─ ...
```

`tooling/companion/build-pack.mjs` 生成它并打印摘要。只含 `character/` 的包保留已装的运行库，这是以后「用户自己上传角色」的入口。

**Core 的版本**：Framework 5-r.5 要 Core 6.0.1，它来自 SDK 压缩包 `CubismSdkForWeb-5-r.5`。`cubism.live2d.com/sdk-web/cubismcore/` 上的 CDN 版本是 5.1.0，两者不兼容，`csmGetMocVersion` 会报错。

**`character.json`**（都可选，缺了用标准参数名和默认分区）：

| 键 | 含义 |
|---|---|
| `name`、`author`、`license`、`source` | 菜单底部如实显示 |
| `model` | 模型文件；缺省取第一个 `*.model3.json` |
| `framing` | `{zoom, y}` 默认取景 |
| `mark` | 漫符出现的位置，模型坐标 |
| `tail` | 尾巴的参数 ID，从根到尖 |
| `zones` | 触摸分区：`{id, from, to, xFrom?, xTo?}`，纵向是从头顶算的比例 |
| `emotions` | 情绪：`{expression, face: {参数: 值}, gaze: [x, y]}`，和默认表合并 |
| `actions` | 该模型专有的动作曲线，如 `wave` |

鲸鱼娘的配置在 `tooling/companion/whale-girl.character.json`。

## 4. 预设和人设

`cordis.patch.yml` 里 `--- shared rows ---` 以下的行，`rtbuild.py` 也会放进本机运行时的 overlay，所以本机和 `dsh plugin add dsh-go-bridge` 的远程主机都有这个预设。人设用 `prefix` + `complete: true` + `includeRuntimeContext: false`，只留人设，再带上压缩组。人设写了不声称是真人、不写色情内容、不发展恋爱情节、遇到自伤信号要放下角色认真回应。

**没有预设的主机**（旧运行时、没更新桥接的远程主机）：`CompanionSessions` 查不到预设就退回默认预设，人设放进第一条消息。这时她有工具，请求审批时页面上出现「有件事要你确认」，点了进普通对话。批准只能是真实点按，她说的话和语音都不算。

**会话隔离**：`companionSessionFilterProvider` 让她的会话不进抽屉，她的回复不发「做完了」提醒。需要用户处理的提醒照常走。

**旁白**：每条消息前加 `〔11月6日 周五 21:14，对方刚才摸了摸你的头〕`，告诉她时间和刚才的触摸。人设说明了这不是对方说的话。

## 5. 设计约定

- 气质按 `polish-guide.md`：玻璃表面、边距 12、顶栏 44、输入条里的圆键同心。这一页的水下场景、缓慢光束和轻微视差是例外，它就是这一页的内容，而且都是合成层变换，开销很小。系统关闭动画时全部停掉。
- 触摸反应立刻发生，不等网络。
- 低内存手机（不足 6 GB）纹理降到 2048。画布最多 2 倍像素。闲置 30 帧，有事 60 帧，睡着 12 帧。App 进后台时暂停。

## 6. 路线图

### 6.1 小房子第 1 期

依据 Pro 的 C204。不另做房间页：她本来就住在水下场景里，所以把场景的下半部分变成她的一角，三件东西摆在她身边。

| 物件 | 位置 | 点了以后（表演时长） | 主机上的活动 |
|---|---|---|---|
| 贝壳点心盘 | 她前面，左下 | 先看你（熟了才有），再看盘子，一块点心沿弧线飘到嘴边，她往盘子那边探身，吃到时点头、开心、摆尾（3.2 秒） | `snack`，45 秒 |
| 泡泡球 | 她前面，右侧 | 球飞到她脸旁边（不挡脸），她视线跟着球、开心、轻轻一跳，球弹回去；很熟时把球递还给你（3.6 秒） | `play`，90 秒 |
| 海草软垫 | 她身后，右下 | 她往软垫那边靠、身体微沉、犯困，软垫被压扁（1.2 秒） | `rest`，15 分钟 |

- **表演归页面，活动归主机。** 表演只在本机跑，不等网络；活动和结束时间由主机的快照决定（`vitals.activity`、`activityUntil`），剩余时间按快照里主机自己的 `asOf` 算，不用手机时钟。没有主机或主机不支持时，页面按同样的时长自己记一份。
- **一次只演一段。** 表演中再点物件，只回一个按压动画，事件照常记。
- **点按顺序**：前面的点心盘、泡泡球 → 她 → 她身后的软垫。所以软垫露出来的部分才算点中，点她身上永远是摸她。休息时整个模型往右偏，触摸的坐标换算会扣掉这个偏移。
- **名牌**写她在做什么（在吃点心 / 在玩泡泡 / 在软垫上歇着），活动结束时舞台通知页面换回来。她说话、在想、在听的时候这些优先。
- **旁白**带上刚才的事（「对方刚才给你吃了一块点心」），下一条消息里她能接上。
- **配色**跟着四个时段换，物件用场景的颜色变量，不是贴图。

### 6.3 轻量和完整两种模式

owner 的决定：「轻量的模式就只做对话，甚至连 dsh 内核都不用起；完整版就把 dsh 内核以及各种完整的工具调用、手机操控能力接上。」菜单里的「对话方式」切换，没选过时，连着主机用完整，没连就用轻量。

| | 轻量 | 完整 |
|---|---|---|
| 大脑 | 手机直接调 DeepSeek 官方 Messages 接口：`https://api.deepseek.com/anthropic/v1/messages`，`x-api-key` + `anthropic-version: 2023-06-01`，模型 `deepseek-flash`，`thinking: disabled`，流式。和引擎的 `@deepseek-ai/dsh-llm-deepseek` 同一个接口 | 当前主机上的 DSH 会话，`dsh-go-companion` 预设 |
| 要什么 | App 里存的 DeepSeek API Key（设置里填的那个，安全存储）。只用 DeepSeek 账号登录、没有 Key 时不能用 | 一台连着的主机 |
| 人设 | `companionPersonaCore` 做 system，和预设里的同一份 | 预设里的人设 |
| 对话记录 | 这台手机上的 `<伙伴目录>/light-chat.json`，存最近 80 行，每次带最近 24 行（同一方连续的行合并，开头是用户）。移除素材包不删它，「重新认识」删它 | 主机上的会话，菜单能打开 |
| 状态和记忆 | 这台手机上的 `<伙伴目录>/light-state.json`：`CompanionLocalStore`（packages/dsh_client，Pro C434/C436）跑和主机桥接同一套规则（C303），storeId、revision、冲突错误都一样，有和桥接 store 对拍的夹具。页面经 `CompanionKeeper` 两边通用 | 主机上的状态和「她记得的事」 |
| 工具 | 没有 | 主机的全部工具（0.2.2-rc.1 是 31 个），开了手机操控再加 13 个手机工具。权限用主机的默认设置，不受「自动批准命令」影响；要批准时页面出现「有件事要你确认」，点了到普通对话里处理。小屋里直接审批按 Pro C420/C422 做。以前那个只有人设、只读的会话不再复用，留在主机上，下次说话时开新的 |

- **出错时**：没有 Key、Key 被拒（401/403）、太忙（429 或 `overloaded_error`）各有一句；一个字都没回就失败的话，这句话放回输入框，记录里也不留。停止时她已经说出的部分留下。
- **两种模式共用一套回复处理**（`_onReply`）：标记只执行一次、字幕、口型、说完后的心情，都和完整模式一样。
- **切换**时丢掉正在路上的回复，不再打招呼，只换掉对话的去处。

### 6.2 后续

Pro 的长期设计（C2xx）到了之后再细化这张表。

| 阶段 | 内容 | 依赖 |
|---|---|---|
| 1.1 | TTS 和真实口型，打断 | 方案见 C205、C309：Android 系统 TTS，首次静音，试听后开启 |
| 1.1 | 轻量模式：手机直连模型，只聊天（§6.3） | ☑️ 对话；本地状态和记忆待 Pro 移植 |
| 4 | 完整模式带全部工具和手机操控，小屋里直接审批 | Pro companion2 线 2 的预设和合同 |
| 1.2 | 素材包在线下载（已留 `companionPackSource`） | 素材授权确认后发布 |
| 2 | 内在状态：心情、精力、亲近度，规则层推进，不因缺席惩罚 | ☑️ 后端（Pro C303，本机 34 项测试通过）和 App 接线；待真机 |
| 2 | 持久记忆：用户确认后写入，可查可删；换主机不伪装连续 | ☑️ 存取和页面；自动回忆要先核实引擎作用域（C200 §7） |
| 3 | 小房子：三件物件和活动状态（点心、玩耍、休息） | ☑️ 第 1 期（§6.1）；待真机 |
| 3 | 小房子第 2 期：房间装扮、更多物件、按时段的作息 | 第 1 期上真机后 |
| 3 | 主动开口：默认关，有每日预算，便宜信号触发 | 状态层 |
| 4 | 用户上传角色 | Live2D 的 Expandable Application 条款 |

## 7. 待确认

- **素材授权。** 群友包里的说明写着模型商用需授权、本包不含授权；owner 说模型是开源的。公开发布素材包前要有来源和条款，`character.json` 的 `author`、`license`、`source` 现在是空的。
- **Live2D 条款。** 个人和年销售额低于 1000 万日元的小企业通常不用签发布授权，但用户可加载任意模型的应用属于 Expandable Application，要过审，官方写明完全免费的应用原则上不批。第 4 阶段前要问 Live2D。
- **《人工智能拟人化互动服务管理暂行办法》**（2026-07-15 施行）对开源、自带 key 的客户端要求到哪一步，需要懂的人确认。
