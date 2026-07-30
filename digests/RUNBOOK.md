# AI 情报晨报 · 每日生成 Runbook（供定时任务/新会话执行）

> 每天北京时间 09:00（UTC 01:00）由持久化 Routine 唤醒执行。本文件是"标准作业书"：即使会话冷启动、丢失历史上下文，也应能照此独立跑完并把日报发到聊天界面。
> 完整设计见 `../ai-daily-digest-agent-design.md`（v2）。信源清单见 `./sources.csv`。
> **v3（2026-07-30 起）**：扩到 8 个采集分片，新增「X/社区热议」与「AI+游戏」两个专门分片；日报新增两个板块；提高信息量目标。

## 业务立场（写「对我们的意义」「一句总结」时的视角）
团队做**家庭场景 AI 助手与智能硬件**：语音交互入口、端侧模型、智能家居硬件、本地数据与隐私权限、成本与可回滚的可信基础设施。日报要帮团队判断：入口在往哪迁移、底座能力到什么水平、我们的机会与风险在哪。**同时用户要求"全面"：宁可多采、分板块承载，也不要漏掉大 V 观点、科技媒体热稿与 AI+游戏动态。**

## 执行步骤

### 1. 采集层（并行 8 个子智能体，general-purpose）
读 `digests/sources.csv`，按体裁/时区/垂类分 8 片，各派一个子智能体采集 **过去 24 小时** 的 AI 新闻（窗口由编排器按当次运行时刻给定，通常"昨 01:00 UTC 至今 01:00 UTC"）：

- **片1 国内科技媒体（深挖）**：机器之心、量子位、智东西、新智元、IT之家AI、36氪AI、AIbase日报、雷峰网、钛媒体、虎嗅。→ 这些站点常 403，务必用 WebSearch 深挖：按「站点名 + 今日/日期」「站点名 + 关键词」多轮检索，宁可多采 5~10 条也别只回 1~2 条。
- **片2 国内商业+模型官方**：财联社、华尔街见闻、晚点LatePost、腾讯科技、澎湃AI晚新闻；模型厂官方：通义千问/Qwen、月之暗面/Kimi、智谱/GLM、MiniMax、腾讯混元、字节豆包/Seed、DeepSeek、阶跃星辰、面壁智能。
- **片3 海外科技媒体**：TechCrunch、The Verge、Ars Technica、The Decoder、Engadget、Techmeme、AP News、CNBC、VentureBeat、MarkTechPost、Wired、The Information。
- **片4 官方博客/开源社区**：OpenAI、Anthropic、Google/DeepMind、Microsoft、Meta AI、Hugging Face（blog+trending papers/models）、Apple ML、Mistral、xAI、LangChain、LlamaIndex、Simon Willison。
- **片5 评测/安全/政策**：Artificial Analysis、LMArena、LiveBench、SWE-bench、Terminal-Bench、METR、UK AISI、EU AI Policy、AI Incident Database、Epoch AI。
- **片6 X/Twitter 大 V + 社区热议**：英文大 V：@sama、@karpathy、@swyx、@simonw、@AndrewYNg、@_akhaliq、@rowancheung、@drjimfan、@ylecun、@emollick、@amir、@nearcyan；中文大 V：宝玉（@dotey）、归藏（@op7418）、@karminski3、量子位/机器之心的 KOL 帖；社区：Reddit r/LocalLLaMA、r/MachineLearning、r/singularity、Hacker News AI 头条。抓「被广泛转发/讨论的观点、爆料、实测、争议」，注明是观点还是事实、标 verify_status。
- **片7 AI + 游戏**：AI 游戏生成与世界模型（Genie/World Labs/Decart/Runway 游戏向）、游戏内 AI NPC 与生成式内容、游戏大厂 AI（腾讯游戏/网易/米哈游/育碧/EA/Roblox/Unity/Epic/NVIDIA ACE）、AI 陪玩/AI 主播、AI 生成 3D 资产与关卡、相关融资与产品发布、玩家社区争议。
- **片8 日更 Newsletter**：TLDR AI、The Rundown AI、Smol AI News（news.smol.ai，403 时读其 GitHub 仓库原文）、The Neuron、Ben's Bites、Superhuman AI、Mindstream。捕捉底层一手事件 + 链接。

每个子智能体：优先 WebFetch，失败（常见 403）改 WebSearch **多轮深挖**兜底，都失败则标记 fail 跳过、**绝不编造**。返回结构化 JSON，每条含 `title/source/date/url/summary/tags/quote/verify_status`（ok|self-reported|unverified|conflict）+ `is_new_progress_on_known_event`，末尾附 `SOURCES_STATUS`。

### 2. 去重 + 排序（编排器）
- 跨期防重：读 `digests/history/` 近 30 天已报道 event，去掉重复事件（除非有新进展/新数字）。
- 同一事件多源合并为一条、保留信息最全者，其余进「主要参考」。
- 按当日影响力排序：最重磅一条永远第一；海外/国内交错、不三连扎堆；分档为 重点(6~10)/补充(8~15)/游戏(2~6)/社区(3~6)/精选(3~5)/弃用。**目标是"全面"，补充板块可长，不要为求短而丢信息。**

### 3. 撰写（编排器）
八板块固定顺序：
① 今日重点新闻（每条含「金句摘录」，长文加「全文总结」）
② 补充新闻（可按 国内 / 海外 / 开源&工具 分组，长度不设上限）
③ **AI + 游戏**（该垂类当日动态；无则写"本日无重大进展"并列 1~2 条边角）
④ **社区热议（X 大 V / Reddit / HN）**（观点与爆料，注明观点/事实、标注未证实）
⑤ 对我们的意义（2~3 个加粗判断，家庭AI/语音入口/端侧/可信基础设施视角）
⑥ 今日 AI 精选（3~5 篇方法论/实践精读）
⑦ 今日一句总结（三段式：点题→叙事串联→业务启示）
⑧ 主要参考
头部含日期 + 元数据行（覆盖时段｜采集分片数｜去重后事件数）。

### 4. 审校/核查（独立子智能体，写判分离）
把终稿连同采集 JSON 交给一个**不负责撰写**的子智能体，逐条核查：数字/日期能否回溯到原文出处；冲突值是否按多数信源取并留痕；自报/未证实内容（尤其 X 大 V 观点、爆料）是否显式标注；板块与条数合规；风格（中英文空格、术语英文首现全称、引号统一「」）。驳回项定位到条目，最多 2 轮、只重写被点名部分。

### 5. 发布 + 写回
- 把终稿 Markdown 直接输出到聊天界面（这是交付物）。
- 将当日事件摘要写入 `digests/history/YYYY-MM-DD.json`，供次日跨期去重；全文存 `digests/YYYY-MM-DD.md`；提交推送到分支 `claude/ai-daily-digest-0717-l22piz`。

## 硬约束
- 时间窗严格：只要过去 24 小时的新闻，窗口外的旧闻剔除（历史事件的"新进展/新数字"可入，但要标明）。
- 绝不编造：拿不到就标 fail；未证实/大 V 观点就标 unverified/self-reported，不当事实写。
- 立场只出现在板块⑤⑥⑦；①②③④保持客观转述（社区板块可转述观点，但须标"观点"）。
- **全面优先**：用户明确要求信息量，补充/游戏/社区板块宁全勿缺，但仍守"不编造、可回溯"。
