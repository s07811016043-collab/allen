# AI 情报晨报 · 智能体系统设计

> 目标：把《AI 情报晨报》的每日生成任务，从"一个大提示词 + 一次生成"重构为可调度、可观测、可回滚的多智能体流水线。
> 输入：每日 07:00 触发；输出：结构固定的七板块日报（Markdown / HTML 渲染图）。

---

## 1. 设计原则

1. **单一职责**：每个智能体只做一件事（采集、去重、撰写、审校……），提示词短而稳定，坏了可以单独替换。
2. **结构化数据契约**：智能体之间只传 JSON（带 Schema 校验），不传自由文本，保证下游可编排、可断点续跑。
3. **确定性编排、智能化执行**：流程控制（DAG、重试、并发、条件分支）由编排器代码决定；只有"理解与写作"交给 LLM。
4. **业务立场外置为记忆**：「家庭 AI / 语音入口 / 可信基础设施」的立场不写死在各处提示词里，而是存为立场档案（Stance Profile），由需要它的智能体统一引用，改一处全局生效。
5. **可降级**：任何一路信源失败（403 / 超时）不阻塞全局，缺口由搜索兜底智能体补齐，并在日报元数据行如实标注来源数。

---

## 2. 总体架构

```mermaid
flowchart TD
    CRON[定时触发器 07:00] --> ORCH[编排器 Orchestrator]

    subgraph 采集层（并行扇出）
        C1[信源采集A<br/>公众号/RSS]
        C2[信源采集B<br/>海外媒体/官方博客]
        C3[信源采集C<br/>聚合站/榜单]
        C4[搜索兜底 Agent<br/>按 watchlist 主题搜索]
    end

    ORCH --> C1 & C2 & C3 & C4
    C1 & C2 & C3 & C4 --> NORM[清洗归一 Agent]
    NORM --> DEDUP[事件聚类去重 Agent ★屏障]
    DEDUP --> RANK[打分排序 Agent]
    RANK --> FACT[交叉核对 Agent]

    subgraph 撰写层（按条目并行）
        W1[重点新闻撰写 Agent ×N]
        W2[补充新闻撰写 Agent]
        W3[精选精读 Agent ×3]
    end

    FACT --> W1 & W2 & W3
    W1 & W2 & W3 --> IMPACT[意义分析 Agent<br/>引用立场档案]
    IMPACT --> SUMM[一句总结 Agent]
    SUMM --> REVIEW[审校 Agent ★质量门]
    REVIEW -->|通过| RENDER[渲染发布 Agent]
    REVIEW -->|驳回≤2次| W1
    RENDER --> MEM[(记忆库写回)]
```

**关键屏障说明**：全流程默认流水线并行，只有两处必须等齐——
- **去重屏障**：事件聚类必须拿到全部采集结果才能判断"同一事件多篇报道"；
- **总结屏障**：「对我们的意义」和「今日一句总结」必须读到全部已写成的条目。

---

## 3. 智能体清单与职责

| # | 智能体 | 模型档位 | 输入 | 输出 | 工具 |
|---|--------|---------|------|------|------|
| 1 | 信源采集 ×3 | 小模型 | 信源清单分片 | `RawArticle[]` | HTTP 抓取、RSS 解析 |
| 2 | 搜索兜底 | 小模型 | watchlist 主题 + 已采集缺口 | `RawArticle[]` | Web 搜索 |
| 3 | 清洗归一 | 小模型 | `RawArticle[]` | `Article[]`（正文提取、时间归一、语言标注） | 无 |
| 4 | 事件聚类去重 | 中模型 | 全量 `Article[]` | `EventCluster[]`（每簇一主报道+若干旁证） | 向量检索 |
| 5 | 打分排序 | 中模型 | `EventCluster[]` + watchlist 权重 | `RankedEvent[]`（重点 5~9 / 补充 5~8 / 精选候选 / 弃用） | 无 |
| 6 | 交叉核对 | 中模型 | `RankedEvent[]` | 标注冲突字段（日期、数字），选多数信源值并留痕 | Web 搜索 |
| 7 | 重点新闻撰写 ×N | 大模型 | 单个 `RankedEvent`（含原文全文） | `StoryItem`（标题/摘要/金句/全文总结?/配图?/来源行） | 无 |
| 8 | 补充新闻撰写 | 小模型 | 补充档 `RankedEvent[]` | `BriefItem[]`（1~3 句 + 传闻标注） | 无 |
| 9 | 精选精读 ×3 | 大模型 | 单篇深度文章全文 | `DeepDive`（核心问题→方案→可借鉴，150~300 字） | 无 |
| 10 | 意义分析 | 大模型 | 全部 `StoryItem` + **立场档案** + 近 7 期意义板块 | `Impact[]`（2~3 个带加粗小标题的判断） | 记忆库读 |
| 11 | 一句总结 | 大模型 | 全部板块产出 | `OneLiner`（主线句→叙事串联→业务启示，100~200 字） | 无 |
| 12 | 审校 | 大模型 | 完整 `Digest` 草稿 | 通过 / 驳回清单（定位到条目和规则编号） | 无 |
| 13 | 渲染发布 | 代码为主 | 终稿 `Digest` | Markdown + HTML/长图，推送渠道 | 模板引擎 |

> 模型档位原则：机械性任务（抓取、清洗、简讯）用小模型压成本；判断与写作（重点条目、意义、总结、审校）用大模型。全天成本大头在 7/9/10/11/12 五类。

---

## 4. 数据契约（核心 Schema）

```jsonc
// Article：清洗后的标准文章
{
  "id": "sha1(url)",
  "title": "...", "source": "Bloomberg | 微信公众号名",
  "lang": "zh|en", "published_at": "2026-07-27T02:00:00Z",
  "url": "...", "body": "...", "images": ["..."]
}

// EventCluster：同一事件的报道簇
{
  "event_id": "...", "primary": "article_id",   // 信息最全的一篇
  "supporting": ["article_id"],                  // 其余仅进主要参考
  "event_summary": "一句话事件描述"
}

// RankedEvent：打分后的事件
{
  "event_id": "...", "tier": "top|brief|deepdive|drop",
  "score": 0.87, "watchlist_tags": ["模型底座", "开源"],
  "conflicts": [{"field": "发布日期", "values": {"07-21": 1, "07-24": 3}, "chosen": "07-24"}]
}

// StoryItem：重点新闻成稿
{
  "headline": "月之暗面 Kimi K3 权重今日全量开放，1.4TB 成史上最大开源模型",
  "summary": "2~5 句，保留关键数字",
  "quote": "金句摘录（必选）",
  "full_summary": null,          // 长文才有
  "image": null,                 // 原文关键图（可选）
  "source_line": {"source": "IBTimes", "time": "2026-07-27", "url": "..."}
}

// Digest：终稿
{
  "date": "2026-07-27",
  "coverage": {"from": "...", "to": "...", "source_count": 22},
  "top_stories": ["StoryItem"], "briefs": ["BriefItem"],
  "impact": ["Impact"], "deep_dives": ["DeepDive"],
  "one_liner": "...", "references": ["url"]
}
```

---

## 5. 记忆库设计

| 记忆 | 内容 | 读方 | 写方 | 生命周期 |
|------|------|------|------|---------|
| 已报道事件库 | 近 30 天 event_id + 事件摘要向量 | 去重 Agent（跨期防重）、意义 Agent（"上期我们说过……"） | 发布后写回 | 30 天滚动 |
| 立场档案 | 业务方向、关注命题、禁区（一份可人工编辑的 YAML） | 意义 Agent、一句总结 Agent、打分 Agent（加权） | 仅人工 | 长期 |
| 模板版本 | 板块结构、标签规则、双语眉题开关 | 撰写层全部、审校、渲染 | 仅人工 | 长期 |
| 信源健康度 | 各信源近 7 天成功率/被 403 记录 | 编排器（决定是否跳过并触发兜底） | 采集层 | 7 天滚动 |

**状态与记忆分离**（引自精选文章的结论）：本节全部是"记忆"；每次运行的中间产物（各阶段 JSON）是"状态"，落到运行目录用于断点续跑与回滚，跑完即可归档，两者不混存。

---

## 6. 编排伪代码

```javascript
// 编排器逻辑（框架无关，可落地为 LangGraph / Claude Agent SDK / 自研 DAG）
const raw = await parallel([srcA, srcB, srcC].map(s => () => collect(s)))
const gaps = watchlistGaps(raw)                     // 哪些主题一条都没采到
if (gaps.length) raw.push(await searchFallback(gaps))

const articles = await pipeline(raw.flat(), normalize)
const clusters = await dedupe(articles)             // ★屏障：需要全量
const ranked   = await rank(clusters, stanceProfile.weights)
const checked  = await pipeline(ranked, crossCheck) // 冲突字段核对可并行

// 撰写层：每条独立并行，互不等待
const [tops, briefs, dives] = await Promise.all([
  pipeline(checked.filter(e => e.tier === 'top'),   writeStory),
  writeBriefs(checked.filter(e => e.tier === 'brief')),
  pipeline(pickDeepDives(checked, 3),               writeDeepDive),
])

const impact  = await writeImpact(tops, stanceProfile, memory.recentImpacts)
const oneLiner = await writeOneLiner({tops, impact})

let digest = assemble({tops, briefs, impact, dives, oneLiner})
for (let i = 0; i < 2; i++) {                       // 审校门：最多驳回重写 2 轮
  const verdict = await review(digest, templateRules)
  if (verdict.pass) break
  digest = await applyFixes(digest, verdict.issues) // 只重写被点名的条目
}
await render(digest); await publish(digest)
await memory.writeBack(digest)                      // 事件库写回，防跨期重复
```

---

## 7. 审校 Agent 的规则清单（质量门）

审校不做"泛泛的润色建议"，只按可判定规则输出驳回项，每项定位到板块+条目：

1. 七板块齐全、顺序正确，条数在区间内（重点 5~9、补充 5~8、精选 =3）。
2. 每条重点新闻含金句摘录；全文总结仅出现在长文条目。
3. 数字保真：成稿中的参数量/价格/日期必须能在对应 `Article.body` 中找到出处。
4. 冲突字段已按核对 Agent 的多数值书写，且不确定处有「据传/信源有出入」标注。
5. 排序规则：第 1 条为当日最高分事件；海外/国内无三连扎堆。
6. 「意义」有 2~3 个加粗小标题且立场明确（禁止纯复述）；「一句总结」为三段式叙事。
7. 风格：中英文与数字间空格、术语保留英文、专有名词首现给全称。

---

## 8. 调度、降级与可观测性

- **调度**：每日 07:00 触发；周一自动把覆盖时段扩到 72 小时（周末合并），元数据行如实标注。
- **降级路径**：信源 403/超时 → 信源健康度记账 → 搜索兜底补齐该主题 → 仍缺则该主题当期留空，不编造。采集总量 < 阈值（如 10 篇）时降级为"精简版日报"（重点 3~5 条、无精选），并在头部标注。
- **可观测**：每次运行留存各阶段 JSON 与各智能体 token 消耗；关键指标——采集成功率、去重压缩比、审校驳回率、端到端时长与成本——按期归档，驳回率连续走高即提示某个撰写提示词漂移。
- **回归评估**：保留历史各期人工终版作为金标准，模板或提示词改版后用近 7 期的原始采集数据重放流水线，对比板块结构与条目选择的一致性。

---

## 9. 与单提示词方案的对照

| 维度 | 单提示词一次生成 | 本设计 |
|------|----------------|--------|
| 信源覆盖 | 受单上下文限制，长文只能截断 | 采集/精读按条目分片，全文进入撰写上下文 |
| 跨期防重 | 无记忆，同一事件可能连报两天 | 已报道事件库 + 去重 Agent |
| 事实冲突 | 模型静默择一 | 核对 Agent 显式记录冲突与取值依据 |
| 失败恢复 | 整体重跑 | 阶段状态落盘，断点续跑，只重写被驳回条目 |
| 立场演进 | 改提示词需全文回归 | 立场档案单点修改，全局生效 |
| 成本 | 一次大模型长生成 | 小模型跑量、大模型写作，可按档位控成本 |

---

## 10. 落地路线

1. **P0（1 周）**：编排器 + 采集/清洗/去重/撰写四段最小闭环，人工当审校，产出 Markdown。
2. **P1（1 周）**：接入审校 Agent、记忆库（事件库+立场档案）、搜索兜底与降级逻辑。
3. **P2（1 周）**：HTML/长图渲染、推送渠道、指标看板与重放回归。
