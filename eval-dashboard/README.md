# 搜索与文案生成效果度量台

面向 AI NAS 影视/音乐搜索与文案生成场景的**纯本地离线评估网页**：上传标注集与系统输出，在浏览器内完成指标计算与可视化，**不发起任何网络请求**（与产品"数据不出域"原则一致）。

## 快速开始

```bash
# 方式一：直接双击打开（零依赖）
eval-dashboard/index.html

# 方式二：起个静态服务（推荐，避免个别浏览器对 file:// 的限制）
cd eval-dashboard && python3 -m http.server 8080
# 打开 http://localhost:8080
```

进入页面后先点各页签里的 **"加载示例数据"**，30 秒了解完整流程。

## 页面结构

| 页签 | 内容 |
|---|---|
| 📖 度量说明 | 每个指标测什么、怎么算、什么场景用（Hit@K / MRR / Recall / Precision / NDCG；维度均分 / 通过率 / ROUGE-L） |
| 🔍 搜索效果度量 | 上传 qrels + run（+可选 queries）→ 指标磁贴、多系统对比图、NDCG 分布、按类别对比、badcase 清单、明细导出 |
| ✍️ 文案生成度量 | 上传 gen_results → 维度均分、通过率、总分分布、按文案类别对比、badcase 清单、明细导出 |
| 🧭 操作步骤 | 需要提供什么数据、文件格式、LLM 评审提示词模板、与命令行框架配合的方式 |
| 🧰 开源框架选型 | 搜索/生成两类评估框架推荐及选择理由；本页技术栈选择理由 |

## 需要提供的文件

**搜索效果度量**（列名不分大小写）：

| 文件 | 必需 | 列 |
|---|---|---|
| qrels.csv | ✓ | `query_id, doc_id, relevance`（0=不相关 … 3=非常相关；未标注默认不相关） |
| run.csv | ✓ | `system, query_id, doc_id, rank`（或 `score`；`system` 列可放多个版本做对比） |
| queries.csv | 可选 | `query_id, query_text, category` → 启用按类别对比图 |

**文案生成度量**：

| 文件 | 必需 | 列 |
|---|---|---|
| gen_results.csv | ✓ | `case_id, category, prompt, generated, reference(可选)` + 任意数量的数值评分列（列名即维度名，1–5 分） |

示例文件见 [`samples/`](samples/)。

## 技术栈与选择理由

- **Vue 3**（全局构建版，`<script>` 直引）：主流框架的可维护性，零构建、零 Node 依赖，克隆即用，契合 NAS 团队离线/轻部署约束。
- **Apache ECharts**：国内可视化事实标准，中文文档完善，支持主题重绘（亮/暗切换）。
- **纯静态 + 浏览器本地计算**：评测数据可能含内部信息，全部解析与计算留在本机。
- **指标自实现（约 100 行）**：Hit/MRR/Recall/Precision/NDCG 与字符级 ROUGE-L 均为标准公式，可用 `ranx` 交叉验证：

```python
from ranx import Qrels, Run, evaluate
# 与本页 K=5 的口径一致
evaluate(qrels, run, ["hit_rate@5", "mrr@5", "recall@5", "precision@5", "ndcg@5"])
```

## 目录

```
eval-dashboard/
├── index.html      # 页面结构（5 个页签）
├── app.js          # 指标计算 + ECharts 图表 + Vue 应用
├── styles.css      # 亮/暗双主题（调色板经无障碍校验）
├── samples.js      # 内嵌示例数据（file:// 打开时"加载示例"可用）
├── samples/        # 示例 CSV（同时是文件格式参考）
└── vendor/         # vue.global.prod.js / echarts.min.js（离线内置）
```
