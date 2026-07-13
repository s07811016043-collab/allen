/* 本地网页服务（零依赖，仅用 Node 内置模块）。
 *
 * 运行：npm run web  ——  浏览器打开 http://127.0.0.1:8799
 * 后端负责跨域抓取加密视频、流式解密，前端与桌面版共用同一套界面。
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { parseInput } = require('../main/parser.js');
const { downloadAndDecrypt, sanitizeFilename } = require('../main/downloader.js');

const PORT = process.env.PORT || 8799;
const HOST = process.env.HOST || '127.0.0.1';
const RENDERER = path.join(__dirname, '..', 'renderer');
const SHARED = path.join(__dirname, '..', 'shared');
const DOWNLOAD_DIR = process.env.WVD_DOWNLOAD_DIR || path.join(os.homedir(), 'Downloads', 'wechat-video');
fs.mkdirSync(DOWNLOAD_DIR, { recursive: true });

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.mp4': 'video/mp4',
};

/** jobId -> { subscribers:Set<res>, events:[], done:bool, filePath, fileName } */
const jobs = new Map();

function emit(job, evt) {
  job.events.push(evt);
  const data = 'data: ' + JSON.stringify(evt) + '\n\n';
  for (const res of job.subscribers) res.write(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let b = '';
    req.on('data', (c) => { b += c; if (b.length > 5e6) req.destroy(); });
    req.on('end', () => resolve(b));
    req.on('error', reject);
  });
}
function sendJson(res, obj, code = 200) {
  const s = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(s);
}

function serveStatic(req, res) {
  let urlPath = decodeURIComponent(req.url.split('?')[0]);
  if (urlPath === '/' || urlPath === '') urlPath = '/index.html';

  let filePath;
  if (urlPath.startsWith('/shared/')) filePath = path.join(SHARED, urlPath.slice('/shared/'.length));
  else filePath = path.join(RENDERER, urlPath);

  // 防目录穿越
  const rootOk = filePath.startsWith(RENDERER) || filePath.startsWith(SHARED);
  if (!rootOk) { res.writeHead(403); res.end('forbidden'); return; }

  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end('not found'); return; }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream' });
    res.end(data);
  });
}

const server = http.createServer(async (req, res) => {
  const url = req.url.split('?')[0];

  // 允许捕获助手（运行在 channels.weixin.qq.com）跨域推送任务
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  try {
    if (url === '/api/ping') return sendJson(res, { ok: true, mode: 'web' });

    if (url === '/api/settings') return sendJson(res, { outputDir: DOWNLOAD_DIR });

    if (url === '/api/parse' && req.method === 'POST') {
      const body = await readBody(req);
      let payload = {};
      try { payload = JSON.parse(body); } catch (_) {}
      return sendJson(res, parseInput(payload));
    }

    if (url === '/api/download' && req.method === 'POST') {
      const body = await readBody(req);
      let payload = {};
      try { payload = JSON.parse(body); } catch (_) {}
      const parsed = parseInput(payload);
      if (!parsed.url) return sendJson(res, { error: '缺少视频直链 URL' }, 400);

      const jobId = crypto.randomBytes(8).toString('hex');
      const fileName = sanitizeFilename(parsed.title || 'wechat_video') + '.mp4';
      const filePath = path.join(DOWNLOAD_DIR, jobId + '_' + fileName);
      const job = { subscribers: new Set(), events: [], done: false, filePath, fileName };
      jobs.set(jobId, job);

      sendJson(res, { jobId });

      downloadAndDecrypt({
        url: parsed.url,
        decodeKey: parsed.decodeKey,
        outputPath: filePath,
        onProgress: (p) => emit(job, { type: 'progress', ...p }),
      }).then((r) => {
        job.done = true;
        emit(job, { type: 'done', validMp4: r.validMp4 });
      }).catch((err) => {
        job.done = true;
        emit(job, { type: 'error', message: err.message });
      });
      return;
    }

    if (url.startsWith('/api/progress/')) {
      const jobId = url.slice('/api/progress/'.length);
      const job = jobs.get(jobId);
      if (!job) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
      });
      // 补发已有事件
      for (const evt of job.events) res.write('data: ' + JSON.stringify(evt) + '\n\n');
      job.subscribers.add(res);
      req.on('close', () => job.subscribers.delete(res));
      return;
    }

    if (url.startsWith('/api/file/')) {
      const jobId = url.slice('/api/file/'.length);
      const job = jobs.get(jobId);
      if (!job || !fs.existsSync(job.filePath)) { res.writeHead(404); res.end('not found'); return; }
      res.writeHead(200, {
        'Content-Type': 'video/mp4',
        'Content-Disposition': 'attachment; filename="' + encodeURIComponent(job.fileName) + '"',
        'Content-Length': fs.statSync(job.filePath).size,
      });
      fs.createReadStream(job.filePath).pipe(res);
      return;
    }

    return serveStatic(req, res);
  } catch (err) {
    sendJson(res, { error: err.message }, 500);
  }
});

server.listen(PORT, HOST, () => {
  console.log('┌───────────────────────────────────────────────┐');
  console.log('│  微信视频号下载器 · 本地网页服务已启动          │');
  console.log('└───────────────────────────────────────────────┘');
  console.log('  地址:     http://' + HOST + ':' + PORT);
  console.log('  下载目录: ' + DOWNLOAD_DIR);
  console.log('  按 Ctrl+C 停止服务');
});

module.exports = { server };
