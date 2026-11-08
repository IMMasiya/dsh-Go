# C903：宠物与适配表市场的发布状态与读接口

本补丁在 dsh-go `c76c0db2d83573895f240307179e19802f674b1d` 上整合 C700，并修复完整发布语义批准、跨版本资源绑定和当前 App 契约。公开目录仍是 schema 1；内部 publication envelope 为版本 1；市场的维护者批准为 schema 2。这三个版本号代表不同协议。

本模块提供发布、目录读取与资源完整性校验。App 的浏览页、安装接线、模型 probe 和效果验收由主线完成。这里记录的是待部署代码合同；没有声明当前 go/dl 域名已配置、市场内容已经上架或实际模型已经验证。既有插件市场的 KV、静态目录与刷新逻辑不变。

## 1. 公开路径与目录权威来源

| 路径 | 响应 |
| --- | --- |
| `/market/pets.json` | 当前宠物 schema 1 目录 |
| `/market/adapters.json` | 当前适配表 schema 1 目录 |
| `/market/adapters/<moc>.json` | 当前模型指纹的目录条目，随后另取其不可变 JSON |
| `/market/pets/<id>/<version>/<sha>.zip` | 规范化宠物包 |
| 同一路径下的 `<sha>.png`、`<sha>.gif` | 各自有独立 SHA/size 的预览 |
| `/market/adapters/<moc>/<sha>.json` | 不可变 market-v1 适配表 |

**客户端目录权威来源是 Worker 路由**，部署目标为 go 的上述路径。dl 默认只用于内容寻址制品；若要继续让 dl 的两个目录路径可用，必须将这些路径的 origin 指向同一 Worker，由它投影同一 envelope。裸 R2 的 `market/pets.json`、`market/adapters.json` 不能继续充当目录。本实现不写第二份非事务性公开目录；不能让 App 在 Worker 失败时切换到旧裸桶目录。

索引里的 URL 为根相对路径，只能解析到应用配置的可信 Worker/制品域；不得让条目改成任意下载主机。源站来自管理员配置的 `MARKET_SOURCE_URL`（默认市场 Pages 根）。该根下是 `pets.json`、`pets/...` 等，Worker 去掉条目 URL 的 `/market/` 再拼接；`entry.source` 仅是来源署名，不被抓取。上游请求拒绝重定向。

GET、HEAD、OPTIONS 可用；其他方法 405。索引和单指纹查询支持 ETag/If-None-Match，下载沿用 Range、HEAD、条件读取和只读 CORS。内部 envelope 不由市场路由公开，也不被解析成另一个客户端协议。

## 2. 单个 CAS 发布点与永久资源绑定

每个分区只有一个权威 R2 对象：

- `market/_publication-v1/pets.json`
- `market/_publication-v1/adapters.json`

形状如下（适配表 binding 用 `moc`，没有 `preview`）：

```json
{
  "publication": 1,
  "kind": "pets",
  "catalogText": "<原样的公开 schema-1 JSON 文本>",
  "releases": [
    {
      "id": "owner-cat",
      "version": "1.0.0",
      "artifact": {"url": "/market/pets/owner-cat/1.0.0/<sha>.zip", "sha256": "<sha>", "size": 123},
      "preview": {
        "png": {"url": "/market/pets/owner-cat/1.0.0/<sha>.png", "sha256": "<sha>", "size": 123},
        "gif": {"url": "/market/pets/owner-cat/1.0.0/<sha>.gif", "sha256": "<sha>", "size": 123}
      }
    }
  ]
}
```

`(kind, id或moc, version)` 第一次成功提交的制品和预览 `url/sha256/size` 三元组永久保留。升级、撤回、当前目录不再列出该身份、回退和 isolate 重启都不删除旧 binding。A(1.0.0) → B(2.0.0) → 原 A，在原 A 仍满足当前数据 profile 时可以使用原资源；A → B → 同版不同资源 A′ 会失败 `version-rewritten`。历史记录无淘汰机制。

资源不可变不等于展示元数据永远不可变。author、license、source、minApp、title 等实际发布语义变化必须先获得市场新的 approval v2；若制品及预览三元组不变，Worker 可以在递增 generatedAt 下更新该版本的元数据，历史资源 binding 不变。Worker 不读取市场的私有审批政策；它信任管理员指定的已批准构建源站，并独立强制资源身份。

发布顺序：

1. 有界读取并校验源目录。
2. 从 R2 读取、完整校验当前 envelope；不得使用内存缓存的历史发布。
3. 校验时间和撤回连续性，合并每个当前条目的历史资源 binding，并检查状态上限。
4. 验证/暂存该分区所有需要的新资源。adapter 即使已在 R2、仍是当前资源或目录字节完全相同，也必须重新读取完整有界 JSON，核真实 size/SHA 与现行 profile；匹配 HEAD checksum 不能替代语法验证。未完成时不提交目录或 binding。目录无变化时，adapter 重验后结束而不额外提交状态。
5. 对**同一个 envelope 对象**执行条件 PUT：已有对象使用读取时的 ETag/If-Match，首次使用 If-None-Match: *。
6. 成功响应后才更新当前 isolate 的公开目录缓存。HTTP 目录响应只投影 `catalogText`。

因此不存在“先写 ledger 再写目录”或“目录成功但 ledger 失败”的跨 key 窗口。条件失败返回 null 后报 `publication-conflict`，不能覆盖胜者。资源暂存失败或确定未提交的状态 PUT 失败，不产生新发布 binding；可能留下已核实但未列出的资源。

**调用方异常不一定证明 PUT 没有提交。** 已提交但确认丢失时，完整目录和 binding 已一起提交；重试必须重新读取。结果未知的早期 PUT 也可能在一次负读之后才尝试提交，但它仍携带原始条件，与同 key 的竞争写在提交时决胜。这里依赖 R2 对单 key 条件写的原子性，不声称跨 key 事务。[R2 一致性及条件写说明](https://developers.cloudflare.com/r2/reference/consistency/)；[Workers API 的 put/onlyIf 返回语义](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)。

宠物和适配表各有自己的发布点；它们与既有插件分区之间没有跨分区事务。Cron 等待已启动的分区任务结束，单个宠物分区失败不阻止尝试另一个。

| 资源 | 明确上限 |
| --- | ---: |
| 公开目录 | 2 MiB、1000 个当前条目、4000 条撤回 |
| 单个宠物 blockedVersions | 1000 |
| **内部完整 envelope** | **8 MiB UTF-8、10,000 条 lifetime bindings** |
| 规范化 ZIP | 50 MiB |
| 单份预览 | 4 MiB |
| adapter JSON | 256 KiB |
| 一次宠物 Cron 新资源传输 | 两分区合计 24 个资源、256 MiB |
| 单次上游请求 | 30 秒，须返回 200 |

达到 envelope 字节/条目上限会拒绝新状态，保留当前提交；不删除旧 binding 腾空间。修改上限需要受审的新版本；容量迁移仍须保留完整历史。ZIP/预览用 FixedLengthStream 和 R2 SHA-256 校验；adapter 有界缓冲后校验数据语法。详情见 `pet-market-io.ts`。

## 3. 故障、stale 与缓存寿命

| 实际状态 | 目录 | 制品/指纹查找 |
| --- | --- | --- |
| 源站失败，但 R2 已提交状态可读且有效 | 最后已提交目录，200，`X-Market-Stale: false`，无 Warning | 按当前已提交目录继续授权 |
| R2 读取失败、超限或状态校验失败；该 Env 有已验证缓存 | 200，`X-Market-Stale: true`，Warning 110，max-age=60 | 503 `catalog_unavailable` |
| 同样的 R2 故障，但 cold Env 无缓存 | 503 `catalog_unavailable` | 503 |
| 状态不存在，旧 bare key 也不存在，且初始化部署前置已满足 | 404 `not_published` | 404 |
| 状态不存在，但旧 bare key 存在或其检查失败 | 有已验证缓存的 warm Env 可 200/304 stale 展示；cold Env 为 503；禁止补造历史 | 503 |
| envelope 有效，但某个 adapter 缺失、读失败、size/SHA 不符或不符合现行 profile | 目录仍按 envelope 展示，stale=false | 该 adapter 的查找和文件请求为 503 artifact_unavailable |

条件 ETag 使用完整 quoted token 作弱比较；引号内的逗号和 `*` 是普通内容，只有整个字段恰为 `*` 才是通配。无效列表不会部分命中，If-None-Match 字段存在时也不退回 If-Modified-Since。adapter 的日期条件仅接受 IMF-fixdate、RFC850、asctime 三类合法 HTTP-date，校验实际日期/weekday，遵守两位年未来 50 年回退规则并支持 leap-second 的 60 秒；ISO 文本、裸年份、多值和无效日期被忽略。依据 [RFC 9110 §§5.6.7、8.8.3、13.1.2–13.1.3](https://www.rfc-editor.org/rfc/rfc9110.html#name-if-none-match)，日历语义见其引用的 [RFC 5322 §3.3](https://www.rfc-editor.org/rfc/rfc5322.html#section-3.3)。这不改变先验完整性/profile 失败必须 503 的顺序。

健康目录的 HTTP max-age=300 **只是 HTTP 缓存寿命，不是上游新鲜度 SLA**。本模块不根据上次源站抓取失败或 generatedAt 年龄自动打 stale 标志；读取路径也不向源站抓取。需监控 Cron 失败和 generatedAt 的部署方应单独设置告警；不能把 `stale=false` 解读成“最近 300 秒同步成功”。条件请求仍可能返回 304。

错误响应 no-store；503 带 Retry-After: 60。找不到当前条目/资源为 404 `not_found`；已撤回的宠物版本或已无当前条目的撤回模型指纹为 410 `withdrawn`；已列资源存储失败为 503 `artifact_unavailable`。未列出的旧 adapter 文件路径可能是 404，不承诺每个旧 URL 都能反查出撤回原因。

## 4. 旧状态迁移及启用顺序

旧 R1 的裸目录没有完整发布历史，不能自动把当前条目当作 lifetime ledger。代码遇到这种情况会拒绝发布 `history-migration-required`。cold 读请求为 503；warm Env 已有验证缓存时，目录可 200/304 stale 展示，而下载与指纹查找仍为 503，不向客户端泄露内部迁移错误。

部署前必须完成以下步骤，且**即使旧 bare key 当前不存在也不能省略第 1 步**：

1. 停止所有旧宠物 publisher、Cron、人工重放和回滚 writer，等待在途请求的结果得到确定结论。连接中断/超时/unknown outcome 不算已经失败；负 HEAD/GET 也不能证明此前 PUT 今后不会提交。
2. 留存旧目录、发布日志、成功构建证据、撤回记录和完整历史资源三元组。对每个曾成功发布的身份/版本，证明原始绑定；只有当前目录不足以证明此前所有版本。
3. 有完整可信历史时，由维护者离线构造 envelope：保留全部历史 bindings、当前目录和撤回；先核对条目/URL/SHA/size、当前目录与历史一致、状态格式和容量，再在 writer 停止期间以条件写安装。不能盲目覆盖已有状态。当前 adapter 还须通过现行 profile；不合格的旧版本应撤回并发布合格新版本，旧 binding 仍须保留。
4. 无法证明完整历史时，保持旧命名空间停止发布；如产品接受，明确建立新的 authority/namespace，并同步迁移客户端和既有不可变 URL。删除裸目录、清空 bindings 或只换内部 key 都不能让原身份“重新首次发布”。
5. 将公开目录入口切到 Worker；清除旧裸目录的 CDN 缓存，确认 App 不会回退到裸桶。若继续支持 dl 目录，其 origin 必须是此 Worker。
6. 最后部署/启用 `PET_MARKET_ENABLED=1`，验证合成目录、旧版本不可改写、故障降级和撤回。此仓库的示例配置含该开关；应用代码补丁不代表已经满足部署前置或执行了部署。

前述第 1 步是由 R2 负读与未知写入语义推导的**协议部署前置**。旧 bare key 与新 envelope 是不同对象，新 envelope 的 CAS 无法阻止旧 writer 迟到后向另一个 key 写入。[R2 负读与在途写入说明](https://developers.cloudflare.com/r2/reference/consistency/#negative-reads-and-in-flight-writes)。

不要给内部状态配置删除旧 bindings 的生命周期规则，不要在旧发布点与新发布点之间双写目录。维护者直接回滚/删除 R2 权威对象超出了正常 writer 的不可变性保证，必须依上述迁移流程处理。

## 5. 当前 App 数据边界

宠物构建使用与 C901 完全相同的 rules revision 3（SHA-256 `e14e27013d7a766293bdf385dcab966dea22afcb4f995b88d15ef07124922e04`）。底层 PetPack.parse 兼容与当前 App 导入门是两层：市场允许原稿的既有取整规范化，然后检查**输出**的 scale/cells ≤4096、canvas/frames 整数范围、深度 ≤60 和 Float32 几何。不得因为底层 parser 接受就宣布当前 App 可安装。

适配表继续使用 market-v1 数据 `adapter:1,moc:<sha>`。当前主线消费的 18 参数名、10 情绪名、12 动作名、5 触摸区是固定词表；支持一个或多个完整 target id、pose、xFrom/xTo；拒绝旧提案里的任意语义名和未实现 toggles。scale 非零且绝对值 ≤1000；offset、face、pose 的市场预算为 ±1000；zoom 0.3–3，y ±1，xFrom/xTo ±1.5。目标名称可为非 ASCII。此保守发布语法不建立另一套 C720 运行时 schema。

公开 index 只检查 envelope 的目录和历史结构，不逐条读 adapter；它可以展示一条资源暂不可用的记录。指纹查找和 adapter 文件 GET/HEAD/条件请求则先读取最多 256 KiB 的完整对象，核声明 size、实际字节数、SHA-256、UTF-8 JSON 与当前 profile；任何失败返回 503 artifact_unavailable，不能因条件命中返回 304。文件响应直接使用这份已验证的 bytes，支持单 Range、HEAD、ETag/If-Modified-Since 与 416；HEAD 忽略 Range。此门不使用裸目录、缓存目录或仅 HEAD 作为资源授权依据。

市场表与 C810/App 本地的当前适配状态有明确边界：下载后还须核 moc、用当前模型的 probe 验证每个 target/expression/motion，执行本地范围处理和效果验收。不能只取多 target 的第一个，不能把无 probe 的结构校验说成可直接安装或视觉效果已验证。本补丁不增加页面/stage 接线，不传送模型素材。notes 的市场文本上限为 4000 码点，主线本地检查器会缩短展示文本；不把市场文字长度当作 UI 展示保证。

## 6. 撤回与 C700 旧合同被替代的条款

撤回停止新安装授权，不抹掉公开 CDN、原始下载文件或已安装副本。需要物理清除时，应停止发布并确定在途结果，按确切 URL 删除资源和清 CDN；**保留 envelope 的历史绑定与撤回**，否则旧版本可改写的风险会回来。若只撤回最高版本，构建器可选择其他仍被批准且未撤回的原版本；其 binding 仍必须原样匹配。

| C700 / 旧 R1 表述 | C903 的替代规则 |
| --- | --- |
| dl 裸桶目录优先、go 后备 | Worker 目录为权威；dl 目录只有 Worker origin 才可用 |
| 每份裸索引独立 CAS | 每分区目录与 lifetime bindings 共用一个 envelope CAS |
| 仅比较相邻当前同版本资源 | 全历史 identity/version 资源 binding，升级/撤回/回退不丢失 |
| 批准只绑定规范化制品 SHA | 市场 approval v2 同时绑定有效元数据、owner/rights、制品及全部预览 |
| 源站失败必标 stale | stale 专指 R2 读/校验故障后的内存回退 |
| 300 秒意味着目录足够新 | 300 秒只是 HTTP TTL |
| §3 提案的任意 adapter 语义及 toggles | 采用当前 c76 已消费词表与字段；缓存/当前/相同目录及读取授权都重验 profile，App 继续 probe/效果验收 |
| 只有 parser/Android 几何检查 | 规范化输出同时通过当前 App 严格导入门 |

## 7. 复现与验证边界

从 dsh-go 根执行 `python3 app/tool/make_replay_viewer.py`；该生成器产生 Worker 所需的 viewer 静态输入。随后在 `services/share-worker` 执行：

```sh
npm ci --ignore-scripts
npm test -- --maxWorkers=1 --testTimeout=20000
npm run typecheck
```

完整 gate 包含既有 Worker 用例；单 worker 和显式 20 秒超时用于本地共享执行环境。R2/FixedLengthStream 单元替身模拟本文所用条件与校验合同；它们不替代真实 Cloudflare/R2/域名的部署验收。发布前需在有权限的测试环境验证原生 checksum、条件冲突、目录 origin、缓存及清除流程。C903 两仓代码、合成构建与测试是可复现证据，不是实机、真实模型或生产上线证明。
