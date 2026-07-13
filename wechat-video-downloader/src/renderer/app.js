/* 渲染层逻辑 —— 同一份代码适配三种运行环境：
 *   1. Electron 桌面版：使用 window.desktopAPI（preload 注入的 IPC 桥）
 *   2. 本地网页服务（npm run web）：使用 REST + SSE
 *   3. 纯静态网页（在线 Artifact）：仅「本地解密」可用
 */
(function () {
  'use strict';

  const hasDesktop = !!window.desktopAPI;
  let mode = hasDesktop ? 'desktop' : 'web';

  const $ = (id) => document.getElementById(id);
  const el = (tag, cls, txt) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (txt != null) e.textContent = txt;
    return e;
  };

  /* ---------- 主题切换 ---------- */
  const root = document.documentElement;
  $('theme-btn').addEventListener('click', () => {
    const next = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    $('theme-btn').textContent = next === 'dark' ? '🌙' : '☀️';
    try { localStorage.setItem('theme', next); } catch (_) {}
  });
  try {
    const saved = localStorage.getItem('theme');
    if (saved) { root.setAttribute('data-theme', saved); $('theme-btn').textContent = saved === 'dark' ? '🌙' : '☀️'; }
  } catch (_) {}

  /* ---------- 标签页 ---------- */
  document.querySelectorAll('nav.tabs button').forEach((btn) => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('nav.tabs button').forEach((b) => b.classList.remove('active'));
      document.querySelectorAll('.panel').forEach((p) => p.classList.remove('active'));
      btn.classList.add('active');
      $('panel-' + btn.dataset.tab).classList.add('active');
    });
  });

  /* ---------- 环境探测 ---------- */
  async function detectEnv() {
    if (hasDesktop) {
      mode = 'desktop';
      $('env-badge').textContent = '桌面版';
      $('env-badge').classList.add('ok');
      return;
    }
    // 尝试探测本地服务是否存在
    try {
      const r = await fetch('/api/ping', { method: 'GET' });
      if (r.ok) {
        mode = 'web';
        $('env-badge').textContent = '本地网页服务';
        $('env-badge').classList.add('ok');
        return;
      }
    } catch (_) {}
    mode = 'static';
    $('env-badge').textContent = '纯网页模式';
    $('env-badge').classList.add('warn');
    $('web-warn').classList.remove('hidden');
    ['smart-go', 'smart-parse', 'choose-dir'].forEach((id) => { $(id).disabled = true; });
  }

  /* ---------- 保存目录（桌面 / 本地服务） ---------- */
  let outputDir = '';
  async function refreshDir() {
    if (mode === 'desktop') {
      const s = await window.desktopAPI.getSettings();
      outputDir = s.outputDir || '';
    } else if (mode === 'web') {
      try { const r = await fetch('/api/settings'); const s = await r.json(); outputDir = s.outputDir || ''; } catch (_) {}
    }
    $('dir-label').textContent = outputDir ? '保存到：' + outputDir : '';
  }
  $('choose-dir').addEventListener('click', async () => {
    if (mode === 'desktop') {
      const dir = await window.desktopAPI.chooseDir();
      if (dir) { outputDir = dir; $('dir-label').textContent = '保存到：' + dir; }
    } else {
      alert('本地网页服务将保存到服务器端的下载目录（启动时会打印路径）。');
    }
  });

  /* ---------- 识别 url / key ---------- */
  async function doParse() {
    const payload = {
      text: $('smart-text').value,
      url: $('smart-url').value,
      decodeKey: $('smart-key').value,
      title: $('smart-title').value,
    };
    let parsed;
    if (mode === 'desktop') parsed = await window.desktopAPI.parse(payload);
    else {
      const r = await fetch('/api/parse', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
      parsed = await r.json();
    }
    if (parsed.url) $('smart-url').value = parsed.url;
    if (parsed.decodeKey) $('smart-key').value = parsed.decodeKey;
    if (parsed.title && !$('smart-title').value) $('smart-title').value = parsed.title;
    return parsed;
  }
  $('smart-parse').addEventListener('click', async () => {
    try {
      const p = await doParse();
      if (!p.url && !p.decodeKey) alert('未能识别出 url 或 decode_key，请检查输入。');
    } catch (e) { alert('识别失败：' + e.message); }
  });

  /* ---------- 任务列表 ---------- */
  const jobsEl = $('jobs');
  function addJobRow(id, name) {
    const li = el('li', 'job'); li.id = 'job-' + id;
    const head = el('div', 'job-head');
    head.appendChild(el('div', 'job-name', name));
    const meta = el('div', 'job-meta', '准备中…'); meta.dataset.role = 'meta';
    head.appendChild(meta);
    li.appendChild(head);
    const bar = el('div', 'bar'); const i = el('i'); bar.appendChild(i); li.appendChild(bar);
    const acts = el('div', 'job-actions'); acts.dataset.role = 'acts'; li.appendChild(acts);
    jobsEl.prepend(li);
    return li;
  }
  function setJob(id, { percent, meta, done, error, fileUrl, filePath }) {
    const li = $('job-' + id); if (!li) return;
    if (percent != null) li.querySelector('.bar > i').style.width = percent + '%';
    const metaEl = li.querySelector('[data-role=meta]');
    if (meta != null) metaEl.textContent = meta;
    if (error) { metaEl.innerHTML = '<span class="tag err">失败</span> ' + error; }
    if (done) {
      metaEl.innerHTML = '<span class="tag ok">完成</span>';
      const acts = li.querySelector('[data-role=acts]'); acts.innerHTML = '';
      if (fileUrl) { const a = el('a', null, '下载视频'); a.href = fileUrl; a.download = ''; acts.appendChild(a); }
      if (filePath && mode === 'desktop') {
        const b = el('button', null, '在文件夹中显示');
        b.addEventListener('click', () => window.desktopAPI.reveal(filePath));
        acts.appendChild(b);
      }
    }
  }

  let jobSeq = 0;
  async function startDownload() {
    const parsed = await doParse();
    if (!parsed.url) { alert('缺少视频直链 URL。'); return; }
    if (!parsed.decodeKey) {
      if (!confirm('未提供 decode_key，将只下载不解密（视频可能只能播放前几秒）。是否继续？')) return;
    }
    const id = ++jobSeq;
    const name = (parsed.title || 'wechat_video') + '.mp4';
    addJobRow(id, name);

    if (mode === 'desktop') {
      window.desktopAPI.startDownload(
        { url: parsed.url, decodeKey: parsed.decodeKey, title: parsed.title, outputDir },
        (evt) => {
          if (evt.type === 'progress') setJob(id, { percent: evt.percent, meta: fmtBytes(evt.received) + (evt.total ? ' / ' + fmtBytes(evt.total) : '') });
          else if (evt.type === 'done') setJob(id, { done: true, filePath: evt.outputPath });
          else if (evt.type === 'error') setJob(id, { error: evt.message });
        }
      );
    } else if (mode === 'web') {
      try {
        const r = await fetch('/api/download', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ url: parsed.url, decodeKey: parsed.decodeKey, title: parsed.title }) });
        const { jobId, error } = await r.json();
        if (error) { setJob(id, { error }); return; }
        const es = new EventSource('/api/progress/' + jobId);
        es.onmessage = (m) => {
          const evt = JSON.parse(m.data);
          if (evt.type === 'progress') setJob(id, { percent: evt.percent, meta: fmtBytes(evt.received) + (evt.total ? ' / ' + fmtBytes(evt.total) : '') });
          else if (evt.type === 'done') { setJob(id, { done: true, fileUrl: '/api/file/' + jobId }); es.close(); }
          else if (evt.type === 'error') { setJob(id, { error: evt.message }); es.close(); }
        };
        es.onerror = () => { es.close(); };
      } catch (e) { setJob(id, { error: e.message }); }
    }
  }
  $('smart-go').addEventListener('click', () => startDownload().catch((e) => alert('下载失败：' + e.message)));

  /* ---------- 本地解密（三种环境通用，纯浏览器端） ---------- */
  const dz = $('dropzone');
  const fileInput = $('local-file');
  let localFile = null;
  dz.addEventListener('click', () => fileInput.click());
  dz.addEventListener('dragover', (e) => { e.preventDefault(); dz.classList.add('drag'); });
  dz.addEventListener('dragleave', () => dz.classList.remove('drag'));
  dz.addEventListener('drop', (e) => {
    e.preventDefault(); dz.classList.remove('drag');
    if (e.dataTransfer.files[0]) selectLocal(e.dataTransfer.files[0]);
  });
  fileInput.addEventListener('change', () => { if (fileInput.files[0]) selectLocal(fileInput.files[0]); });
  function selectLocal(f) {
    localFile = f;
    $('local-file-name').textContent = f.name + '  (' + fmtBytes(f.size) + ')';
    $('local-go').disabled = false;
  }
  $('local-go').addEventListener('click', async () => {
    if (!localFile) return;
    const key = $('local-key').value.replace(/[^\d]/g, '');
    if (!key) { alert('请输入 decode_key（纯数字）。'); return; }
    $('local-status').textContent = '解密中…';
    try {
      const buf = new Uint8Array(await localFile.arrayBuffer());
      window.WxDecrypt.decryptInPlace(buf, key);
      const valid = window.WxDecrypt.isValidMp4(buf);
      const outName = localFile.name.replace(/\.(mp4|f0|bin|dat)$/i, '') + '_decrypted.mp4';
      triggerDownload(buf, outName);
      $('local-status').innerHTML = valid
        ? '<span class="tag ok">成功</span> 已识别到 MP4 签名，文件已开始下载。'
        : '<span class="tag warn">已保存</span> 未检测到 MP4 签名，decode_key 可能不匹配。';
    } catch (e) {
      $('local-status').innerHTML = '<span class="tag err">失败</span> ' + e.message;
    }
  });

  /* ---------- 工具函数 ---------- */
  function fmtBytes(n) {
    if (!n) return '0 B';
    const u = ['B', 'KB', 'MB', 'GB']; let i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return n.toFixed(i ? 1 : 0) + ' ' + u[i];
  }
  function triggerDownload(uint8, name) {
    const blob = new Blob([uint8], { type: 'video/mp4' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = name;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 4000);
  }

  detectEnv().then(refreshDir);
})();
