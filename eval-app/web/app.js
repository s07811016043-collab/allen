/* 搜索与文案生成效果度量台 —— 全部计算在浏览器本地完成，无任何网络请求 */
(function () {
  "use strict";

  /* ---------- CSV 解析（支持引号、逗号、BOM、CRLF） ---------- */
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
    if (!rows.length) return { header: [], records: [] };
    const header = rows.shift().map((h) => h.trim().toLowerCase());
    const records = rows
      .filter((r) => r.some((x) => x.trim() !== ""))
      .map((r) => { const o = {}; header.forEach((h, i) => (o[h] = (r[i] || "").trim())); return o; });
    return { header, records };
  }

  /* ---------- 搜索指标 ---------- */
  function evalSearch(qrelsRecs, runRecs, queriesRecs, K) {
    const qrels = new Map(); // qid -> Map(doc -> rel)
    for (const r of qrelsRecs) {
      const qid = r.query_id || r.qid, doc = r.doc_id || r.docid;
      const rel = parseFloat(r.relevance ?? r.rel ?? r.label);
      if (!qid || !doc || isNaN(rel)) continue;
      if (!qrels.has(qid)) qrels.set(qid, new Map());
      qrels.get(qid).set(doc, rel);
    }
    if (!qrels.size) throw "标注集 qrels 为空或缺少 query_id / doc_id / relevance 列";

    const qinfo = new Map();
    for (const r of queriesRecs || []) {
      const qid = r.query_id || r.qid;
      if (qid) qinfo.set(qid, { text: r.query_text || r.query || "", category: r.category || r.type || "" });
    }

    const runs = new Map(); // system -> qid -> [{doc, rank, score}]
    for (const r of runRecs) {
      const sys = r.system || r.run || "被测系统";
      const qid = r.query_id || r.qid, doc = r.doc_id || r.docid;
      if (!qid || !doc) continue;
      if (!runs.has(sys)) runs.set(sys, new Map());
      const m = runs.get(sys);
      if (!m.has(qid)) m.set(qid, []);
      m.get(qid).push({ doc, rank: parseFloat(r.rank), score: parseFloat(r.score) });
    }
    if (!runs.size) throw "检索结果 run 为空或缺少 query_id / doc_id 列";

    const systems = [...runs.keys()];
    const perQuery = [];
    for (const sys of systems) {
      for (const [qid, rels] of qrels) {
        let list = (runs.get(sys).get(qid) || []).slice();
        if (list.some((x) => !isNaN(x.rank))) list.sort((a, b) => a.rank - b.rank);
        else if (list.some((x) => !isNaN(x.score))) list.sort((a, b) => b.score - a.score);
        const top = list.slice(0, K);
        const gains = top.map((x) => rels.get(x.doc) || 0);
        const relTotal = [...rels.values()].filter((v) => v > 0).length;
        const relInK = gains.filter((g) => g > 0).length;
        const firstIdx = gains.findIndex((g) => g > 0);
        let dcg = 0, idcg = 0;
        gains.forEach((g, i) => (dcg += g / Math.log2(i + 2)));
        [...rels.values()].sort((a, b) => b - a).slice(0, K).forEach((g, i) => (idcg += g / Math.log2(i + 2)));
        perQuery.push({
          system: sys, qid,
          queryText: (qinfo.get(qid) || {}).text || qid,
          category: (qinfo.get(qid) || {}).category || "",
          hit: firstIdx >= 0, firstRank: firstIdx >= 0 ? firstIdx + 1 : 0,
          rr: firstIdx >= 0 ? 1 / (firstIdx + 1) : 0,
          recall: relTotal ? relInK / relTotal : 0,
          precision: K ? relInK / K : 0,
          ndcg: idcg ? dcg / idcg : 0,
        });
      }
    }
    const summary = {};
    for (const sys of systems) {
      const rows = perQuery.filter((r) => r.system === sys);
      const mean = (k) => rows.reduce((s, r) => s + (k === "hit" ? (r.hit ? 1 : 0) : r[k]), 0) / rows.length;
      summary[sys] = { hit: mean("hit"), mrr: mean("rr"), recall: mean("recall"), precision: mean("precision"), ndcg: mean("ndcg") };
    }
    const hasCategory = perQuery.some((r) => r.category);
    return {
      k: K, systems, summary, perQuery, hasCategory,
      queryCount: qrels.size,
      badcases: perQuery.slice().sort((a, b) => a.ndcg - b.ndcg).slice(0, 20),
    };
  }

  /* ---------- ROUGE-L（字符级） ---------- */
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

  /* ---------- 文案生成指标 ---------- */
  function evalGen(recs, threshold) {
    if (!recs.length) throw "生成结果文件为空";
    const META = new Set(["case_id", "id", "category", "type", "prompt", "generated", "generation", "output", "reference", "ref"]);
    const header = Object.keys(recs[0]);
    const dims = header.filter((h) => !META.has(h) && recs.every((r) => r[h] === "" || !isNaN(parseFloat(r[h]))));
    if (!dims.length) throw "未识别到评分维度列（除 case_id/category/prompt/generated/reference 外的数值列）";
    const cases = recs.map((r, i) => {
      const scores = {};
      dims.forEach((d) => (scores[d] = parseFloat(r[d]) || 0));
      const mean = dims.reduce((s, d) => s + scores[d], 0) / dims.length;
      const gen = r.generated || r.generation || r.output || "";
      const ref = r.reference || r.ref || "";
      return {
        id: r.case_id || r.id || "c" + (i + 1), category: r.category || r.type || "",
        text: gen, scores, mean,
        pass: dims.every((d) => scores[d] >= threshold),
        rouge: ref && gen ? rougeL(gen, ref) : null,
      };
    });
    const dimMeans = {};
    dims.forEach((d) => (dimMeans[d] = cases.reduce((s, c) => s + c.scores[d], 0) / cases.length));
    const weakestDim = dims.reduce((a, b) => (dimMeans[a] <= dimMeans[b] ? a : b));
    const rl = cases.filter((c) => c.rouge !== null);
    return {
      count: cases.length, dims, cases, dimMeans, weakestDim,
      weakestScore: dimMeans[weakestDim],
      overallMean: cases.reduce((s, c) => s + c.mean, 0) / cases.length,
      passRate: cases.filter((c) => c.pass).length / cases.length,
      rougeL: rl.length ? rl.reduce((s, c) => s + c.rouge, 0) / rl.length : null,
      hasCategory: cases.some((c) => c.category),
      badcases: cases.slice().sort((a, b) => a.mean - b.mean).slice(0, 10),
    };
  }

  /* ---------- 工具 ---------- */
  function cssVar(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  }
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

  /* ---------- 框架清单 ---------- */
  const FW_SEARCH = [
    { name: "ranx", lang: "Python", repo: "github.com/AmenRa/ranx",
      desc: "信息检索评估『瑞士军刀』：Qrels + Run 两个对象即可计算 Hit/MRR/MAP/NDCG 等 30+ 指标，自带多系统对比、统计显著性检验与报告导出。",
      why: "API 最简、指标最全，几十到几千条评测集的团队场景最顺手；本页指标口径与其一致，可交叉验证。" },
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
      why: "G-Eval（LLM 评审）实现最成熟，可接本地/国产模型做评审；单元测试式写法天然进 CI，适合作为文案质量门禁。" },
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

  /* ---------- Vue 应用 ---------- */
  const { createApp } = Vue;
  createApp({
    data() {
      return {
        theme: matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light",
        tab: "guide",
        tabs: [
          { id: "guide", name: "📖 度量说明" },
          { id: "search", name: "🔍 搜索效果度量" },
          { id: "gen", name: "✍️ 文案生成度量" },
          { id: "steps", name: "🧭 操作步骤" },
          { id: "fw", name: "🧰 开源框架选型" },
        ],
        topK: 5,
        passThreshold: 4,
        files: { qrels: 0, run: 0, queries: 0, gen: 0 },
        raw: { qrels: [], run: [], queries: [], gen: [] },
        searchResult: null, genResult: null,
        searchError: "", genError: "",
        fwSearch: FW_SEARCH, fwGen: FW_GEN,
        _charts: null,
      };
    },
    computed: {
      canRunSearch() { return this.files.qrels > 0 && this.files.run > 0; },
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
      onFile(ev, key) {
        const f = ev.target.files[0];
        if (!f) return;
        const reader = new FileReader();
        reader.onload = () => {
          const { records } = parseCSV(reader.result);
          this.raw[key] = records;
          this.files[key] = records.length;
        };
        reader.readAsText(f, "utf-8");
      },
      loadSearchSample() {
        this.raw.qrels = parseCSV(SAMPLES.qrels).records;
        this.raw.run = parseCSV(SAMPLES.run).records;
        this.raw.queries = parseCSV(SAMPLES.queries).records;
        this.files.qrels = this.raw.qrels.length;
        this.files.run = this.raw.run.length;
        this.files.queries = this.raw.queries.length;
        this.runSearchEval();
      },
      loadGenSample() {
        this.raw.gen = parseCSV(SAMPLES.gen).records;
        this.files.gen = this.raw.gen.length;
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
          textStyle: { fontFamily: "system-ui, -apple-system, 'Segoe UI', 'PingFang SC', 'Microsoft YaHei', sans-serif" },
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
        const metrics = ["hit", "mrr", "recall", "precision", "ndcg"];
        const metricNames = [`Hit@${R.k}`, `MRR@${R.k}`, `Recall@${R.k}`, `Precision@${R.k}`, `NDCG@${R.k}`];

        this.draw("chartSummary", Object.assign(this.chartBase(), this.axisPair(metricNames, 1), {
          legend: multi ? { top: 0, textStyle: { color: cssVar("--text-secondary"), fontSize: 12 }, itemWidth: 14 } : { show: false },
          series: R.systems.map((sys, i) =>
            this.barSeries(sys, metrics.map((m) => +R.summary[sys][m].toFixed(3)), colors[i % 6], true)),
        }));

        const bins = 10;
        this.draw("chartDist", Object.assign(this.chartBase(), (() => {
          const seriesList = R.systems.map((sys, i) => {
            const vals = R.perQuery.filter((r) => r.system === sys).map((r) => r.ndcg);
            return { sys, h: histogram(vals, 0, 1.0001, bins), i };
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
        const distAx = this.axisPair(h.labels, null, null);
        distAx.yAxis.minInterval = 1;
        this.draw("gchartDist", Object.assign(this.chartBase(), distAx, {
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
        const lines = ["system,query_id,query_text,category,hit,first_rank,rr,recall,precision,ndcg"];
        for (const r of R.perQuery)
          lines.push([r.system, r.qid, '"' + r.queryText.replace(/"/g, '""') + '"', r.category,
            r.hit ? 1 : 0, r.firstRank, r.rr.toFixed(4), r.recall.toFixed(4), r.precision.toFixed(4), r.ndcg.toFixed(4)].join(","));
        downloadCSV(`search_eval_K${R.k}.csv`, lines);
      },
      exportGenCSV() {
        const G = this.genResult;
        const lines = ["case_id,category," + G.dims.join(",") + ",mean,pass,rouge_l"];
        for (const c of G.cases)
          lines.push([c.id, c.category, ...G.dims.map((d) => c.scores[d]), c.mean.toFixed(2),
            c.pass ? 1 : 0, c.rouge == null ? "" : c.rouge.toFixed(4)].join(","));
        downloadCSV("gen_eval.csv", lines);
      },
    },
  }).mount("#app");
})();
