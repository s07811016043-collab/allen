/* 搜索与文案生成效果度量台 —— 全部计算在浏览器本地完成，无任何网络请求
   指标口径对齐：ranx / trec_eval（搜索）、DeepEval G-Eval / rouge-score / Distinct-n（生成） */
(function () {
  "use strict";

  /* ================= 列名别名（中英） ================= */
  const ALIASES = {
    query_id: ["queryid", "qid", "查询id", "查询编号", "查询号"],
    doc_id: ["docid", "documentid", "文档id", "结果id", "歌曲id", "影片id", "条目id", "itemid", "did"],
    relevance: ["rel", "label", "相关性", "相关度", "标注", "相关等级"],
    rank: ["排名", "排序", "名次", "位置"],
    score: ["分数", "得分", "相似度"],
    system: ["run_name", "runid", "系统", "版本", "系统版本", "模型版本"],
    query_text: ["querytext", "query", "查询", "查询词", "查询文本"],
    category: ["type", "类别", "分类", "类型", "文案类别"],
    case_id: ["caseid", "样本id", "编号", "样本编号"],
    prompt: ["任务", "任务要求", "指令", "要求"],
    generated: ["generation", "output", "生成文案", "生成结果", "生成文本", "生成"],
    reference: ["ref", "参考", "参考文案", "参考文本", "标准答案"],
  };
  const normKey = (h) => String(h).toLowerCase().replace(/[\s_\-（）()·]/g, "");
  const ALIAS_MAP = (() => {
    const m = {};
    for (const [canon, list] of Object.entries(ALIASES)) {
      m[normKey(canon)] = canon;
      list.forEach((a) => (m[normKey(a)] = canon));
    }
    m[normKey("id")] = "case_id";
    m[normKey("rank")] = "rank";
    m[normKey("score")] = "score";
    m[normKey("system")] = "system";
    return m;
  })();
  function canonicalize(records) {
    return records.map((r) => {
      const o = {};
      for (const [k, v] of Object.entries(r)) {
        const canon = ALIAS_MAP[normKey(k)] || String(k).trim();
        if (!(canon in o) || o[canon] === "") o[canon] = typeof v === "string" ? v.trim() : v;
      }
      return o;
    });
  }

  /* ================= 表格类型识别 ================= */
  // 文案表中 relevance/score 是合法评分维度，不列入排除集
  const GEN_META = new Set(["case_id", "category", "prompt", "generated", "reference",
    "query_id", "doc_id", "rank", "system", "query_text"]);
  function numericDims(records) {
    if (!records.length) return [];
    return Object.keys(records[0]).filter((h) => !GEN_META.has(h) &&
      records.every((r) => r[h] === "" || r[h] == null || !isNaN(parseFloat(r[h]))) &&
      records.some((r) => r[h] !== "" && r[h] != null));
  }
  function classify(records) {
    if (!records.length) return "empty";
    const H = new Set(Object.keys(records[0]));
    const hasRel = H.has("relevance"), hasRank = H.has("rank") || H.has("score");
    if (H.has("generated")) return "gen";
    if (H.has("query_id") && H.has("doc_id") && hasRel && hasRank) return "combined";
    if (H.has("query_id") && H.has("doc_id") && hasRel) return "qrels";
    if (H.has("query_id") && H.has("doc_id") && hasRank) return "run";
    if (H.has("query_id") && !H.has("doc_id") && (H.has("query_text") || H.has("category"))) return "queries";
    if (H.has("prompt") && numericDims(records).length) return "gen";
    return "unknown";
  }

  /* ================= 文件读取（CSV / Excel） ================= */
  function parseCSV(text) {
    text = String(text).replace(/^﻿/, "");
    const rows = [];
    let row = [], field = "", inQ = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (inQ) {
        if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else inQ = false; }
        else field += c;
      } else if (c === '"') inQ = true;
      else if (c === ",") { row.push(field); field = ""; }
      else if (c === "\n") { row.push(field); rows.push(row); row = []; field = ""; }
      else if (c !== "\r") field += c;
    }
    if (field !== "" || row.length) { row.push(field); rows.push(row); }
    if (!rows.length) return [];
    const header = rows.shift().map((h) => String(h).trim());
    return rows.filter((r) => r.some((x) => String(x).trim() !== ""))
      .map((r) => { const o = {}; header.forEach((h, i) => (o[h] = (r[i] ?? "").toString())); return o; });
  }
  function readFileTables(file) {
    // 返回 Promise<[{name, records}]>；xlsx 每个工作表一张，csv 一张
    return new Promise((resolve) => {
      const reader = new FileReader();
      const isExcel = /\.(xlsx|xls)$/i.test(file.name);
      reader.onload = () => {
        try {
          if (isExcel) {
            const wb = XLSX.read(reader.result, { type: "array" });
            const tables = [];
            for (const name of wb.SheetNames) {
              if (/说明|readme|指引/i.test(name)) continue;
              const rows = XLSX.utils.sheet_to_json(wb.Sheets[name], { header: 1, raw: false, defval: "" });
              const hIdx = rows.findIndex((r) => r.filter((c) => String(c).trim() !== "").length >= 2);
              if (hIdx < 0) continue;
              const header = rows[hIdx].map((h) => String(h).trim());
              const records = rows.slice(hIdx + 1)
                .filter((r) => r.some((c) => String(c).trim() !== ""))
                .map((r) => { const o = {}; header.forEach((h, i) => h && (o[h] = (r[i] ?? "").toString().trim())); return o; });
              if (records.length) tables.push({ name: `${file.name} / ${name}`, records });
            }
            resolve(tables);
          } else {
            resolve([{ name: file.name, records: parseCSV(reader.result) }]);
          }
        } catch (e) { resolve([{ name: file.name, records: [], error: String(e) }]); }
      };
      if (isExcel) reader.readAsArrayBuffer(file);
      else reader.readAsText(file, "utf-8");
    });
  }

  /* ================= 搜索指标（口径：ranx / trec_eval） ================= */
  function evalSearch(qrelsRecs, runRecs, queriesRecs, K) {
    const qrels = new Map();
    for (const r of qrelsRecs) {
      const qid = r.query_id, doc = r.doc_id, rel = parseFloat(r.relevance);
      if (!qid || !doc || isNaN(rel)) continue;
      if (!qrels.has(qid)) qrels.set(qid, new Map());
      qrels.get(qid).set(doc, rel);
    }
    if (!qrels.size) throw "标注集 qrels 为空或缺少 query_id / doc_id / relevance";
    const qinfo = new Map();
    for (const r of queriesRecs || []) {
      if (r.query_id) qinfo.set(r.query_id, { text: r.query_text || "", category: r.category || "" });
    }
    const runs = new Map();
    for (const r of runRecs) {
      const sys = r.system || "被测系统", qid = r.query_id, doc = r.doc_id;
      if (!qid || !doc) continue;
      if (!runs.has(sys)) runs.set(sys, new Map());
      const m = runs.get(sys);
      if (!m.has(qid)) m.set(qid, []);
      m.get(qid).push({ doc, rank: parseFloat(r.rank), score: parseFloat(r.score) });
    }
    if (!runs.size) throw "检索结果 run 为空或缺少 query_id / doc_id";

    const systems = [...runs.keys()];
    const perQuery = [];
    for (const sys of systems) {
      for (const [qid, rels] of qrels) {
        let list = (runs.get(sys).get(qid) || []).slice();
        if (list.some((x) => !isNaN(x.rank))) list.sort((a, b) => a.rank - b.rank);
        else if (list.some((x) => !isNaN(x.score))) list.sort((a, b) => b.score - a.score);
        const relTotal = [...rels.values()].filter((v) => v > 0).length;
        const top = list.slice(0, K);
        const gains = top.map((x) => rels.get(x.doc) || 0);
        const relInK = gains.filter((g) => g > 0).length;
        const firstIdx = gains.findIndex((g) => g > 0);
        let dcg = 0, idcg = 0, ap = 0, seen = 0;
        gains.forEach((g, i) => {
          dcg += g / Math.log2(i + 2);
          if (g > 0) { seen++; ap += seen / (i + 1); }
        });
        [...rels.values()].sort((a, b) => b - a).slice(0, K).forEach((g, i) => (idcg += g / Math.log2(i + 2)));
        const P = K ? relInK / K : 0;
        const R = relTotal ? relInK / relTotal : 0;
        const relInR = list.slice(0, relTotal).filter((x) => (rels.get(x.doc) || 0) > 0).length;
        perQuery.push({
          system: sys, qid,
          queryText: (qinfo.get(qid) || {}).text || qid,
          category: (qinfo.get(qid) || {}).category || "",
          hit: firstIdx >= 0, firstRank: firstIdx >= 0 ? firstIdx + 1 : 0,
          rr: firstIdx >= 0 ? 1 / (firstIdx + 1) : 0,
          map: relTotal ? ap / Math.min(relTotal, K) : 0,
          recall: R, precision: P,
          f1: P + R ? (2 * P * R) / (P + R) : 0,
          ndcg: idcg ? dcg / idcg : 0,
          rprec: relTotal ? relInR / relTotal : 0,
        });
      }
    }
    const summary = {};
    for (const sys of systems) {
      const rows = perQuery.filter((r) => r.system === sys);
      const mean = (k) => rows.reduce((s, r) => s + (k === "hit" ? (r.hit ? 1 : 0) : (k === "mrr" ? r.rr : r[k])), 0) / rows.length;
      summary[sys] = { hit: mean("hit"), mrr: mean("mrr"), map: mean("map"), recall: mean("recall"),
        precision: mean("precision"), f1: mean("f1"), ndcg: mean("ndcg"), rprec: mean("rprec") };
    }
    return {
      k: K, systems, summary, perQuery,
      hasCategory: perQuery.some((r) => r.category),
      queryCount: qrels.size,
      badcases: perQuery.slice().sort((a, b) => a.ndcg - b.ndcg).slice(0, 20),
    };
  }

  /* ================= 文本重合/多样性指标 ================= */
  function ngrams(chars, n) {
    const out = [];
    for (let i = 0; i + n <= chars.length; i++) out.push(chars.slice(i, i + n).join(""));
    return out;
  }
  function rougeN(cand, ref, n) {
    const a = ngrams([...String(cand)].slice(0, 1500), n);
    const b = ngrams([...String(ref)].slice(0, 1500), n);
    if (!a.length || !b.length) return null;
    const cnt = new Map();
    b.forEach((g) => cnt.set(g, (cnt.get(g) || 0) + 1));
    let overlap = 0;
    a.forEach((g) => { const c = cnt.get(g) || 0; if (c > 0) { overlap++; cnt.set(g, c - 1); } });
    const p = overlap / a.length, r = overlap / b.length;
    return p + r ? (2 * p * r) / (p + r) : 0;
  }
  function rougeL(cand, ref) {
    const a = [...String(cand)].slice(0, 1500), b = [...String(ref)].slice(0, 1500);
    if (!a.length || !b.length) return null;
    let prev = new Array(b.length + 1).fill(0);
    for (let i = 1; i <= a.length; i++) {
      const cur = [0];
      for (let j = 1; j <= b.length; j++)
        cur[j] = a[i - 1] === b[j - 1] ? prev[j - 1] + 1 : Math.max(prev[j], cur[j - 1]);
      prev = cur;
    }
    const lcs = prev[b.length], p = lcs / a.length, r = lcs / b.length;
    return p + r ? (2 * p * r) / (p + r) : 0;
  }
  function distinctN(texts, n) {
    let total = 0; const uniq = new Set();
    for (const t of texts) {
      const grams = ngrams([...String(t)], n);
      total += grams.length;
      grams.forEach((g) => uniq.add(g));
    }
    return total ? uniq.size / total : 0;
  }

  /* ================= 文案生成指标 ================= */
  function evalGen(recs, threshold) {
    if (!recs.length) throw "评测数据为空";
    const dims = numericDims(recs);
    if (!dims.length) throw "未识别到评分维度列";
    const cases = recs.map((r, i) => {
      const scores = {};
      dims.forEach((d) => (scores[d] = parseFloat(r[d]) || 0));
      const mean = dims.reduce((s, d) => s + scores[d], 0) / dims.length;
      const gen = r.generated || "", ref = r.reference || "";
      return {
        id: r.case_id || "c" + (i + 1), category: r.category || "",
        text: gen, scores, mean,
        pass: dims.every((d) => scores[d] >= threshold),
        r1: ref && gen ? rougeN(gen, ref, 1) : null,
        r2: ref && gen ? rougeN(gen, ref, 2) : null,
        rl: ref && gen ? rougeL(gen, ref) : null,
      };
    });
    const dimMeans = {};
    dims.forEach((d) => (dimMeans[d] = cases.reduce((s, c) => s + c.scores[d], 0) / cases.length));
    const weakestDim = dims.reduce((a, b) => (dimMeans[a] <= dimMeans[b] ? a : b));
    const avg = (key) => {
      const xs = cases.filter((c) => c[key] !== null);
      return xs.length ? xs.reduce((s, c) => s + c[key], 0) / xs.length : null;
    };
    const texts = cases.map((c) => c.text).filter(Boolean);
    return {
      count: cases.length, dims, cases, dimMeans, weakestDim,
      weakestScore: dimMeans[weakestDim],
      overallMean: cases.reduce((s, c) => s + c.mean, 0) / cases.length,
      passRate: cases.filter((c) => c.pass).length / cases.length,
      rouge1: avg("r1"), rouge2: avg("r2"), rougeL: avg("rl"),
      distinct1: distinctN(texts, 1), distinct2: distinctN(texts, 2),
      avgLen: texts.length ? texts.reduce((s, t) => s + [...t].length, 0) / texts.length : 0,
      hasCategory: cases.some((c) => c.category),
      badcases: cases.slice().sort((a, b) => a.mean - b.mean).slice(0, 10),
    };
  }

  /* ================= 工具 ================= */
  const cssVar = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
  function downloadCSV(name, lines) {
    const blob = new Blob(["﻿" + lines.join("\n")], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = name;
    a.click();
    URL.revokeObjectURL(a.href);
  }
  function histogram(values, min, max, bins) {
    const width = (max - min) / bins;
    const counts = new Array(bins).fill(0);
    for (const v of values) counts[Math.min(bins - 1, Math.max(0, Math.floor((v - min) / width)))]++;
    const labels = counts.map((_, i) => (min + i * width).toFixed(1) + "–" + (min + (i + 1) * width).toFixed(1));
    return { counts, labels };
  }

  /* ================= 框架清单 ================= */
  const FW_SEARCH = [
    { name: "ranx", lang: "Python", repo: "github.com/AmenRa/ranx",
      desc: "信息检索评估『瑞士军刀』：Qrels + Run 两个对象即可计算 Hit/MRR/MAP/NDCG 等 30+ 指标，自带多系统对比、统计显著性检验与报告导出。",
      why: "API 最简、指标最全，几十到几千条评测集的团队场景最顺手；本页搜索指标口径与其一致，可交叉验证。" },
    { name: "pytrec_eval", lang: "Python", repo: "github.com/cvangysel/pytrec_eval",
      desc: "TREC 官方评估工具 trec_eval 的 Python 绑定，信息检索学术界的标准评分实现。",
      why: "作为『仲裁』实现校验其他工具的数字；写论文/对外报告时引用其口径最权威。" },
    { name: "ir_measures", lang: "Python", repo: "github.com/terrierteam/ir_measures",
      desc: "统一的 IR 指标接口层：一套指标表达式（如 nDCG@10）适配多个计算后端。",
      why: "指标命名规范统一，适合写进 CI 脚本，团队内避免『同名不同算法』的口径争议。" },
    { name: "BEIR", lang: "Python", repo: "github.com/beir-cellar/beir",
      desc: "零样本检索评测基准：18 个公开数据集 + 统一评测流程，检索模型横向比较的事实标准。",
      why: "选 embedding 模型时先在公开基准初筛，再上自建业务评测集精测，两步走降低选型风险。" },
    { name: "FlagEmbedding / C-MTEB", lang: "Python", repo: "github.com/FlagOpen/FlagEmbedding",
      desc: "BGE 系列模型官方仓库，附带中文向量模型基准 C-MTEB（含检索、语义相似度任务）。",
      why: "中文语义检索模型选型的事实基准；NAS 选 0.6B 级轻量模型时用它横比中文检索效果。" },
    { name: "Quepid", lang: "Web 应用", repo: "github.com/o19s/quepid",
      desc: "搜索相关性调优平台：管理查询集与人工相关性标注，改排序配置实时看指标变化。",
      why: "解决『标注怎么组织』的痛点——产品/运营在 Web 界面协作标注 qrels，不用手搓表格。" },
  ];
  const FW_GEN = [
    { name: "DeepEval", lang: "Python", repo: "github.com/confident-ai/deepeval",
      desc: "pytest 风格的 LLM 输出评估框架：内置 G-Eval、幻觉、摘要、答案相关性等 14+ 指标，评审模型可自由替换。",
      why: "G-Eval（LLM 评审）实现最成熟，可接本地/国产模型做评审；本页维度评分与通过率即采用其口径。" },
    { name: "Ragas", lang: "Python", repo: "github.com/explodinggradients/ragas",
      desc: "面向 RAG 与生成任务的评估库：faithfulness（忠实度）、answer relevancy、context precision 等指标。",
      why: "影视/音乐文案基于元数据生成，faithfulness 直接度量『是否忠于元数据、有无编造』——对准确性维度最对口。" },
    { name: "promptfoo", lang: "Node.js", repo: "github.com/promptfoo/promptfoo",
      desc: "提示词评估与 A/B 回归工具：YAML 声明用例与断言，自带 Web UI 逐格对比不同提示词/模型的输出。",
      why: "零代码上手、自带界面，产品同学也能跑；提示词版本回归（改了模板会不会变差）体验最好。" },
    { name: "OpenCompass", lang: "Python", repo: "github.com/open-compass/opencompass",
      desc: "大模型综合评测体系（上海 AI Lab）：覆盖中文能力、推理、安全等百余基准。",
      why: "选『底座模型』阶段用它看中文综合能力；任务级文案评估仍配 DeepEval/promptfoo，两层分工。" },
    { name: "EvalScope", lang: "Python", repo: "github.com/modelscope/evalscope",
      desc: "魔搭社区模型评估框架：支持自定义数据集、LLM 评审，附带推理性能压测工具。",
      why: "与国内模型生态（Qwen 系）衔接最顺；其压测能力可复用于 NAS 端侧推理延迟/内存评估。" },
    { name: "Arize Phoenix", lang: "Python + Web", repo: "github.com/Arize-ai/phoenix",
      desc: "开源 LLM 可观测与评估平台：采集调用 trace，在 UI 中跑 LLM 评审并可视化质量趋势。",
      why: "上线后持续监控生成质量的选项——离线评估用 DeepEval，线上回流监控用 Phoenix。" },
  ];

  const METRIC_ROWS = [
    { key: "hit", label: (k) => `Hit@${k} 命中率`, src: "ranx: hit_rate", pct: true },
    { key: "mrr", label: (k) => `MRR@${k}`, src: "trec_eval: recip_rank", pct: false },
    { key: "map", label: (k) => `MAP@${k}`, src: "trec_eval: map", pct: false },
    { key: "recall", label: (k) => `Recall@${k}`, src: "ranx: recall", pct: true },
    { key: "precision", label: (k) => `Precision@${k}`, src: "trec_eval: P", pct: true },
    { key: "f1", label: (k) => `F1@${k}`, src: "ranx: f1", pct: false },
    { key: "ndcg", label: (k) => `NDCG@${k}`, src: "trec_eval: ndcg", pct: false },
    { key: "rprec", label: () => "R-Precision", src: "trec_eval: r_prec", pct: false },
  ];

  /* ================= Vue 应用 ================= */
  const { createApp } = Vue;
  createApp({
    data() {
      return {
        theme: matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light",
        tab: "guide",
        tabs: [
          { id: "guide", name: "度量说明" },
          { id: "search", name: "搜索效果度量" },
          { id: "gen", name: "文案生成度量" },
          { id: "steps", name: "操作步骤" },
          { id: "fw", name: "开源框架选型" },
        ],
        topK: 5,
        passThreshold: 4,
        dragging: "",
        raw: { qrels: [], run: [], queries: [], gen: [] },
        searchIngest: { touched: false, qrels: 0, run: 0, queries: 0 },
        genIngest: { touched: false, rows: 0, dims: "", ref: false },
        searchGuide: [], genGuide: [],
        searchResult: null, genResult: null,
        searchError: "", genError: "",
        fwSearch: FW_SEARCH, fwGen: FW_GEN,
        metricRows: METRIC_ROWS,
        _charts: null,
      };
    },
    computed: {
      canRunSearch() { return this.searchIngest.qrels > 0 && this.searchIngest.run > 0; },
    },
    mounted() {
      this._charts = {};
      document.documentElement.dataset.theme = this.theme;
      addEventListener("resize", () => Object.values(this._charts).forEach((c) => c && c.resize()));
    },
    methods: {
      fix(v, n) { return v == null ? "—" : Number(v).toFixed(n == null ? 3 : n); },
      pct(v) { return v == null ? "—" : (v * 100).toFixed(1) + "%"; },
      toggleTheme() {
        this.theme = this.theme === "dark" ? "light" : "dark";
        document.documentElement.dataset.theme = this.theme;
        this.$nextTick(() => { this.renderSearchCharts(); this.renderGenCharts(); });
      },
      switchTab(id) {
        this.tab = id;
        this.$nextTick(() => Object.values(this._charts).forEach((c) => c && c.resize()));
      },

      /* ---------- 上传入口 ---------- */
      onPick(ev, target) { this.ingest([...ev.target.files], target); ev.target.value = ""; },
      onDrop(ev, target) { this.dragging = ""; this.ingest([...ev.dataTransfer.files], target); },
      async ingest(files, target) {
        const tables = (await Promise.all(files.map(readFileTables))).flat();
        const unknown = [];
        if (target === "search") {
          this.raw.qrels = []; this.raw.run = []; this.raw.queries = [];
          for (const t of tables) {
            const recs = canonicalize(t.records);
            const kind = classify(recs);
            if (kind === "qrels") this.raw.qrels.push(...recs);
            else if (kind === "run") this.raw.run.push(...recs);
            else if (kind === "queries") this.raw.queries.push(...recs);
            else if (kind === "combined") {
              this.raw.run.push(...recs);
              this.raw.qrels.push(...recs.filter((r) => r.relevance !== "" && !isNaN(parseFloat(r.relevance))));
            } else if (kind === "gen") unknown.push(`「${t.name}」看起来是文案评测数据，请切换到"文案生成度量"页上传。`);
            else unknown.push(`「${t.name}」未能识别（表头：${Object.keys(t.records[0] || {}).join("、") || "空"}）——请对照模板调整列名。`);
          }
          this.searchIngest = { touched: true, qrels: this.raw.qrels.length, run: this.raw.run.length, queries: this.raw.queries.length };
          const g = [...unknown];
          if (!this.raw.qrels.length) g.push("未识别到<b>标注集（qrels）</b>：需要三列 <b>query_id、doc_id、relevance</b>（支持别名：查询ID / 文档ID / 相关性；relevance 取 0–3）。可下载模板中的「qrels标注集」表填写。");
          if (!this.raw.run.length) g.push("未识别到<b>检索结果（run）</b>：需要列 <b>query_id、doc_id</b>，外加 <b>rank</b>（排名）或 <b>score</b>（分数）；多版本对比再加 <b>system</b>（版本名）列。");
          if (this.raw.qrels.length && this.raw.run.length && !this.raw.queries.length)
            g.push("提示：再提供「queries查询清单」（query_id、query_text、category）可解锁<b>按类别对比</b>图，用于定位短板类别（可选）。");
          this.searchGuide = g;
          this.searchResult = null;
        } else {
          this.raw.gen = [];
          for (const t of tables) {
            const recs = canonicalize(t.records);
            const kind = classify(recs);
            if (kind === "gen") this.raw.gen.push(...recs);
            else if (kind === "qrels" || kind === "run" || kind === "combined") unknown.push(`「${t.name}」看起来是搜索评测数据，请切换到"搜索效果度量"页上传。`);
            else unknown.push(`「${t.name}」未能识别（表头：${Object.keys(t.records[0] || {}).join("、") || "空"}）。`);
          }
          const dims = numericDims(this.raw.gen);
          const hasRef = this.raw.gen.some((r) => r.reference);
          this.genIngest = { touched: true, rows: this.raw.gen.length, dims: dims.join(" / "), ref: hasRef };
          const g = [...unknown];
          if (!this.raw.gen.length) g.push("未识别到<b>生成文案列</b>：请将生成文本所在列命名为 <b>generated</b>（支持别名：生成文案 / 生成结果 / 生成文本）。");
          else if (!dims.length) g.push("未识别到<b>评分维度列</b>：需要至少一列 1–5 的数值评分（如 relevance / fluency / 相关性 / 流畅性），列名即维度名。可用「操作步骤」页的 LLM 评审提示词批量打分后填入。");
          if (this.raw.gen.length && !hasRef) g.push("提示：补充 <b>reference</b>（参考文案）列可解锁 ROUGE-1/2/L 重合度指标（摘要类文案建议提供，可选）。");
          this.genGuide = g;
          this.genResult = null;
        }
      },

      /* ---------- 示例数据 ---------- */
      loadSearchSample() {
        this.raw.qrels = canonicalize(parseCSV(SAMPLES.qrels));
        this.raw.run = canonicalize(parseCSV(SAMPLES.run));
        this.raw.queries = canonicalize(parseCSV(SAMPLES.queries));
        this.searchIngest = { touched: true, qrels: this.raw.qrels.length, run: this.raw.run.length, queries: this.raw.queries.length };
        this.searchGuide = [];
        this.runSearchEval();
      },
      loadGenSample() {
        this.raw.gen = canonicalize(parseCSV(SAMPLES.gen));
        const dims = numericDims(this.raw.gen);
        this.genIngest = { touched: true, rows: this.raw.gen.length, dims: dims.join(" / "), ref: true };
        this.genGuide = [];
        this.runGenEval();
      },

      runSearchEval() {
        this.searchError = "";
        try {
          this.searchResult = evalSearch(this.raw.qrels, this.raw.run, this.raw.queries, this.topK);
          this.$nextTick(() => this.renderSearchCharts());
        } catch (e) { this.searchResult = null; this.searchError = String(e); }
      },
      runGenEval() {
        this.genError = "";
        try {
          this.genResult = evalGen(this.raw.gen, this.passThreshold);
          this.$nextTick(() => this.renderGenCharts());
        } catch (e) { this.genResult = null; this.genError = String(e); }
      },

      /* ---------- 图表 ---------- */
      chartBase() {
        return {
          textStyle: { fontFamily: "-apple-system, BlinkMacSystemFont, 'PingFang SC', 'Microsoft YaHei', system-ui, sans-serif" },
          grid: { left: 8, right: 16, top: 34, bottom: 8, containLabel: true },
          tooltip: {
            trigger: "axis", axisPointer: { type: "shadow" },
            backgroundColor: cssVar("--surface-1"), borderColor: cssVar("--baseline"),
            textStyle: { color: cssVar("--text-primary"), fontSize: 12 },
          },
        };
      },
      axisPair(cats, yMax, yFmt) {
        return {
          xAxis: {
            type: "category", data: cats,
            axisLine: { lineStyle: { color: cssVar("--baseline") } },
            axisTick: { show: false },
            axisLabel: { color: cssVar("--text-muted"), fontSize: 11, interval: 0 },
          },
          yAxis: {
            type: "value", max: yMax,
            axisLabel: { color: cssVar("--text-muted"), fontSize: 11, formatter: yFmt },
            splitLine: { lineStyle: { color: cssVar("--grid"), width: 1 } },
          },
        };
      },
      barSeries(name, data, colorVar, withLabel) {
        return {
          name, type: "bar", data,
          barMaxWidth: 26, barGap: "25%", barCategoryGap: "35%",
          itemStyle: { color: cssVar(colorVar), borderRadius: [4, 4, 0, 0] },
          label: withLabel ? {
            show: true, position: "top", fontSize: 10,
            color: cssVar("--text-secondary"),
            formatter: (p) => (typeof p.value === "number" ? (p.value <= 1 ? p.value.toFixed(2) : p.value) : p.value),
          } : { show: false },
        };
      },
      draw(refName, option) {
        const el = this.$refs[refName];
        if (!el) return;
        if (this._charts[refName]) this._charts[refName].dispose();
        const c = echarts.init(el);
        c.setOption(option);
        this._charts[refName] = c;
      },
      renderSearchCharts() {
        const R = this.searchResult;
        if (!R) return;
        const colors = ["--series-1", "--series-2", "--series-3", "--series-4", "--series-5", "--series-6"];
        const multi = R.systems.length > 1;
        const metrics = ["hit", "mrr", "map", "recall", "f1", "ndcg"];
        const names = [`Hit@${R.k}`, `MRR@${R.k}`, `MAP@${R.k}`, `Recall@${R.k}`, `F1@${R.k}`, `NDCG@${R.k}`];
        this.draw("chartSummary", Object.assign(this.chartBase(), this.axisPair(names, 1), {
          legend: multi ? { top: 0, textStyle: { color: cssVar("--text-secondary"), fontSize: 12 }, itemWidth: 14 } : { show: false },
          series: R.systems.map((sys, i) =>
            this.barSeries(sys, metrics.map((m) => +R.summary[sys][m].toFixed(3)), colors[i % 6], true)),
        }));
        this.draw("chartDist", Object.assign(this.chartBase(), (() => {
          const seriesList = R.systems.map((sys, i) => {
            const vals = R.perQuery.filter((r) => r.system === sys).map((r) => r.ndcg);
            return { sys, h: histogram(vals, 0, 1.0001, 10), i };
          });
          const ax = this.axisPair(seriesList[0].h.labels, null, null);
          ax.yAxis.minInterval = 1;
          return Object.assign(ax, {
            legend: multi ? { top: 0, textStyle: { color: cssVar("--text-secondary"), fontSize: 12 }, itemWidth: 14 } : { show: false },
            series: seriesList.map((s) => this.barSeries(s.sys, s.h.counts, colors[s.i % 6], false)),
          });
        })()));
        if (R.hasCategory) {
          const cats = [...new Set(R.perQuery.map((r) => r.category || "未分类"))];
          this.draw("chartCat", Object.assign(this.chartBase(), this.axisPair(cats, 1, (v) => (v * 100).toFixed(0) + "%"), {
            legend: multi ? { top: 0, textStyle: { color: cssVar("--text-secondary"), fontSize: 12 }, itemWidth: 14 } : { show: false },
            series: R.systems.map((sys, i) => this.barSeries(sys, cats.map((cat) => {
              const rows = R.perQuery.filter((r) => r.system === sys && (r.category || "未分类") === cat);
              return rows.length ? +(rows.filter((r) => r.hit).length / rows.length).toFixed(3) : 0;
            }), colors[i % 6], true)),
          }));
        }
      },
      renderGenCharts() {
        const G = this.genResult;
        if (!G) return;
        const colors = ["--series-1", "--series-2", "--series-3", "--series-4", "--series-5", "--series-6"];
        this.draw("gchartDims", Object.assign(this.chartBase(), this.axisPair(G.dims, 5), {
          legend: { show: false },
          series: [Object.assign(this.barSeries("均分", G.dims.map((d) => +G.dimMeans[d].toFixed(2)), "--series-1", true), {
            markLine: {
              silent: true, symbol: "none",
              lineStyle: { color: cssVar("--critical"), type: "dashed", width: 1 },
              label: { formatter: "通过线 " + this.passThreshold, position: "insideEndTop", color: cssVar("--text-muted"), fontSize: 10 },
              data: [{ yAxis: this.passThreshold }],
            },
          })],
        }));
        const h = histogram(G.cases.map((c) => c.mean), 1, 5.0001, 8);
        const ax = this.axisPair(h.labels, null, null);
        ax.yAxis.minInterval = 1;
        this.draw("gchartDist", Object.assign(this.chartBase(), ax, {
          legend: { show: false },
          series: [this.barSeries("样本数", h.counts, "--series-1", false)],
        }));
        if (G.hasCategory) {
          const cats = [...new Set(G.cases.map((c) => c.category || "未分类"))];
          this.draw("gchartCat", Object.assign(this.chartBase(), this.axisPair(cats, 5), {
            legend: { top: 0, textStyle: { color: cssVar("--text-secondary"), fontSize: 12 }, itemWidth: 14 },
            series: G.dims.map((d, i) => this.barSeries(d, cats.map((cat) => {
              const rows = G.cases.filter((c) => (c.category || "未分类") === cat);
              return +(rows.reduce((s, c) => s + c.scores[d], 0) / rows.length).toFixed(2);
            }), colors[i % 6], false)),
          }));
        }
      },

      /* ---------- 导出 ---------- */
      exportSearchCSV() {
        const R = this.searchResult;
        const lines = ["system,query_id,query_text,category,hit,first_rank,rr,map,recall,precision,f1,ndcg,r_prec"];
        for (const r of R.perQuery)
          lines.push([r.system, r.qid, '"' + r.queryText.replace(/"/g, '""') + '"', r.category,
            r.hit ? 1 : 0, r.firstRank, r.rr.toFixed(4), r.map.toFixed(4), r.recall.toFixed(4),
            r.precision.toFixed(4), r.f1.toFixed(4), r.ndcg.toFixed(4), r.rprec.toFixed(4)].join(","));
        downloadCSV(`search_eval_K${R.k}.csv`, lines);
      },
      exportGenCSV() {
        const G = this.genResult;
        const lines = ["case_id,category," + G.dims.join(",") + ",mean,pass,rouge_1,rouge_2,rouge_l"];
        for (const c of G.cases)
          lines.push([c.id, c.category, ...G.dims.map((d) => c.scores[d]), c.mean.toFixed(2), c.pass ? 1 : 0,
            c.r1 == null ? "" : c.r1.toFixed(4), c.r2 == null ? "" : c.r2.toFixed(4), c.rl == null ? "" : c.rl.toFixed(4)].join(","));
        downloadCSV("gen_eval.csv", lines);
      },
    },
  }).mount("#app");
})();
