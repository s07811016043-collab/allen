# AI 情报晨报 · 每日生成 Runbook（供定时任务/新会话执行）

> 每天 09:00 UTC 由持久化 Routine 唤醒执行。本文件是"标准作业书"：即使会话冷启动、丢失历史上下文，也应能照此独立跑完并把日报发到聊天界面。
> 完整设计见 `../ai-daily-digest-agent-design.md`（v2）。信源清单见 `./sources.csv`（172 个 P1 可用源 + P2/P3）。

## 业务立场（写「对我们的意义」「一句总结」时的视角）
团队做**家庭场景 AI 助手与智能硬件**：语音交互入口、端侧模型、智能家居硬件、本地数据与隐私权限、成本与可回滚的可信基础设施。日报要帮团队判断：入口在往哪迁移、底座能力到什么水平、我们的机会与风险在哪。

## 执行步骤

### 1. 采集层（并行 6 个子智能体，general-purpose）
读 `digests/sources.csv`，按体裁/时区分 6 片，各派一个子智能体采集 **过去 24 小时（昨 10:00 UTC 至今 10:00 UTC）** 的 AI 新闻：
- 片1 国内专业媒体：机器之心、量子位、智东西、新智元、IT之家AI、36氪AI、AIbase日报、财联社、华尔街见闻
- 片2 国内商业+模型官方：虎嗅、晚点LatePost、腾讯科技、澎湃AI晚新闻、雷峰网、钛媒体、通义千问博客、月之暗面、智谱、MiniMax、腾讯混元
- 片3 海外科技媒体：TechCrunch、The Verge、Ars Technica、The Decoder、Engadget、Techmeme、AP News、CNBC、MarkTechPost
- 片4 官方博客/开源社区：Google/Microsoft AI Blog、Hugging Face、Anthropic Alignment、Google Research、Apple ML、BAIR、Simon Willison、LangChain、LlamaIndex、OpenAI Cookbook
- 片5 评测/安全/政策：Artificial Analysis、LMArena、LiveBench、SWE-bench、METR、UK AISI、EU AI Policy、AI Incident Database、Epoch AI
- 片6 日更 Newsletter：TLDR AI、The Rundown AI、Smol AI News、The Neuron、Mindstream、Ben's Bites、Superhuman AI

每个子智能体：优先 WebFetch，失败（常见 403）改 WebSearch 兜底，都失败则标记 fail 跳过、**绝不编造**。返回结构化 JSON，每条含 `title/source/date/url/summary/tags/quote/verify_status`（ok|self-reported|unverified|conflict），末尾附 `SOURCES_STATUS`。

### 2. 去重 + 排序（编排器）
- 跨期防重：读 `digests/history/` 近 30 天已报道 event，去掉重复事件（除非有新进展/新数字）。
- 同一事件多源合并为一条、保留信息最全者，其余进「主要参考」。
- 按当日影响力排序：最重磅一条永远第一；海外/国内交错、不三连扎堆；分档为 重点(5~9)/补充(5~8)/精选(3)/弃用。

### 3. 撰写（编排器，按 v1/v2 模板）
七板块固定顺序：① 今日重点新闻 ② 补充新闻 ③ 对我们的意义（2~3 个加粗小标题的判断）④ 今日 AI 精选（3 篇方法论/实践精读）⑤ 今日一句总结（三段式：点题→叙事串联→业务启示）⑥ 主要参考。头部含日期 + 元数据行（覆盖时段｜信源数）。每条重点新闻含「金句摘录」（必选）、长文加「全文总结」。

### 4. 审校/核查（独立子智能体，写判分离）
把终稿连同采集 JSON 交给一个**不负责撰写**的子智能体，逐条核查：数字/日期能否回溯到原文出处；冲突值是否按多数信源取并留痕；自报/未证实内容是否显式标注；板块与条数合规；风格（中英文空格、术语英文、专名首现全称）。驳回项定位到条目，最多 2 轮、只重写被点名部分。

### 5. 发布 + 写回
- 把终稿 Markdown 直接输出到聊天界面（这是交付物）。
- 将当日事件摘要写入 `digests/history/YYYY-MM-DD.json`，供次日跨期去重；并可把全文存 `digests/YYYY-MM-DD.md`。

## 硬约束
- 时间窗严格：只要过去 24 小时的新闻，窗口外的旧闻剔除。
- 绝不编造：拿不到就标 fail；未证实就标 unverified，不当事实写。
- 立场只出现在板块③④⑤；①②保持客观转述。
