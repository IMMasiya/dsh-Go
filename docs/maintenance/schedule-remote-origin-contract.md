# 定时任务 Remote 来源约定（W17 追加 2）

当前保持无会话载体的 Remote 创建、修改拒绝。`actorSessionId === undefined` 仅表示调用方法未提供助手会话，不能证明请求由人点击界面发出。此文不授权放宽确认，不修改官方界面。

## 官方调用合同

核对对象为官方 npm `0.2.2-rc.1`。

| 入口 | 官方源位置 | 进入服务的身份 |
| --- | --- | --- |
| 页面保存新任务 | `dsh-client-ui-schedule/lib/client.js:15836,19377` | `ctx.remote.schedule.create(request)`，没有 actor |
| 页面修改 | 同文件 `15841,19320` | `ctx.remote.schedule.edit(request)`，含 expectedUpdatedAt，没有 actor |
| 页面立即执行 | 同文件 `19328` | `ctx.remote.schedule.run({id})`；不走 create/edit 确认 |
| Remote 创建 | `dsh-schedule/lib/index.js:2216` | `this.create(request, undefined, signal)` |
| Remote 修改 | 同文件 `2387` | `this.edit(request, undefined, signal)` |
| 助手工具创建／修改 | `dsh-tool-schedule/lib/index.js:548,686` | 由 exec.agent 取得真实 agent.session.id；子代理在 runForCaller 拒绝 |

RemoteActor／ToolActor 在这里是描述来源的用语，当前官方接口没有对应的可信身份类型。HTTP Cookie、可构造参数、Origin、User-Agent、是否有 actor 都不能单独证明人的明确点击。新的可信机制必须来自助手无法访问或代答的用户侧通道；本补丁不自行发明浏览器标头例外。

## 当前授权不变量

创建／修改先确认完整任务，后进入串行提交；批准等待不持有写队列。拒绝、取消、超时、服务停止、不支持确认的客户端都不保存。提交时继续检查删除准入、目标、未来时间及修改版本冲突。批准仅覆盖一次完整变更，不缓存授权。

有 session 目标的 Remote 操作继续经该会话真实 user-question 通道确认；没有 actor 且目标为 new/new_once 时立即拒绝，不等待无处显示的确认。已有 new/new_once 任务仍可能由带 actor 的助手工具提出修改并请求确认。不能因目标记录含 reserved sessionId 就把尚未创建的 Agent 当作确认载体。

## 真实验证及边界

`DSH_PREFIX=<main-prefix> node runtime/tests/schedule-remote-origin-live.mjs` 启动真实 `dsh web`，临时 HOME、真实 HTTP/Cookie/mux；没有外部账号或模型调用。两个暂停的 new/new_once 任务为离线合成既存 profile，真实 Host 读取。页面相同 RPC 的两类创建和两类修改均拒绝，catalog 深比较不变。session 目标的拒绝／明确批准通过真实 user-question 与 `$events/result`，分别不保存／保存一次。

此验证未执行浏览器点击，未把离线种子声称为助手创建成功。助手 service/tool 实现的 49 项回归通过，其中超时采用可控定时器，取消／拒绝验证不落库；该层是内存接缝测试，不是模型端到端证明。助手绕过工具到 Remote 的可达性须结合并行源核对及对抗报告决定，不能以本验证代替来源隔离证明。
