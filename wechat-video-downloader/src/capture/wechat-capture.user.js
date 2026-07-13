// ==UserScript==
// @name         微信视频号捕获助手
// @namespace    https://github.com/allen/wechat-video-downloader
// @version      1.0.0
// @description  在视频号网页端自动捕获视频直链与 decode_key，一键发送到本地下载器
// @match        https://channels.weixin.qq.com/*
// @match        https://finder.video.qq.com/*
// @run-at       document-start
// @grant        none
// ==/UserScript==

/*
 * 用法：
 *   1. 安装 Tampermonkey / 篡改猴 浏览器扩展，添加本脚本。
 *   2. 用 npm run web 启动本地下载器（默认 http://127.0.0.1:8799）。
 *   3. 打开 https://channels.weixin.qq.com/ 并播放目标视频。
 *   4. 页面右下角会弹出捕获到的视频，点「发送到下载器」即可自动下载并解密。
 *
 * 原理：劫持页面的 fetch / XMLHttpRequest，扫描返回 JSON 中的
 *      object_desc.media[].url 与 decode_key，无需安装任何证书。
 */
(function () {
  'use strict';
  const DOWNLOADER = 'http://127.0.0.1:8799';
  const seen = new Set();

  function extract(obj) {
    // 深度优先找 media 数组
    const results = [];
    (function walk(o) {
      if (!o || typeof o !== 'object') return;
      if (Array.isArray(o.media)) {
        for (const m of o.media) {
          if (m && m.url && m.decode_key != null) {
            let url = m.url;
            if (m.url_token && !url.includes(m.url_token)) url += m.url_token;
            results.push({ url, decodeKey: String(m.decode_key), title: (o.description || o.title || '').trim() });
          }
        }
      }
      for (const k in o) { try { walk(o[k]); } catch (_) {} }
    })(obj);
    return results;
  }

  function handleText(text) {
    if (!text || text.length < 20 || text.indexOf('decode_key') === -1) return;
    let data; try { data = JSON.parse(text); } catch (_) { return; }
    for (const item of extract(data)) {
      const id = item.decodeKey + '|' + item.url.slice(0, 60);
      if (seen.has(id)) continue;
      seen.add(id);
      showCard(item);
    }
  }

  /* ---- 劫持 fetch ---- */
  const origFetch = window.fetch;
  window.fetch = async function (...args) {
    const res = await origFetch.apply(this, args);
    try { res.clone().text().then(handleText).catch(() => {}); } catch (_) {}
    return res;
  };

  /* ---- 劫持 XHR ---- */
  const origOpen = XMLHttpRequest.prototype.open;
  const origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (...a) { this.__wvd = true; return origOpen.apply(this, a); };
  XMLHttpRequest.prototype.send = function (...a) {
    if (this.__wvd) this.addEventListener('load', function () {
      try { if (typeof this.responseText === 'string') handleText(this.responseText); } catch (_) {}
    });
    return origSend.apply(this, a);
  };

  /* ---- 悬浮卡片 UI ---- */
  function showCard(item) {
    const box = document.createElement('div');
    box.style.cssText = 'position:fixed;right:18px;bottom:18px;z-index:999999;width:300px;background:#171a21;color:#e6e8ec;border:1px solid #07c160;border-radius:12px;padding:14px;font-family:system-ui,-apple-system,sans-serif;font-size:13px;box-shadow:0 8px 30px rgba(0,0,0,.4)';
    box.innerHTML =
      '<div style="font-weight:600;margin-bottom:6px">🎬 捕获到视频</div>' +
      '<div style="color:#9aa1ac;word-break:break-all;margin-bottom:4px">' + (item.title || '(无标题)') + '</div>' +
      '<div style="color:#9aa1ac;margin-bottom:10px">decode_key: <code style="color:#07c160">' + item.decodeKey + '</code></div>';
    const send = document.createElement('button');
    send.textContent = '发送到下载器';
    send.style.cssText = 'background:#07c160;color:#fff;border:none;border-radius:8px;padding:8px 12px;cursor:pointer;margin-right:8px';
    send.onclick = () => {
      fetch(DOWNLOADER + '/api/download', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(item) })
        .then(() => { send.textContent = '✅ 已发送'; send.disabled = true; })
        .catch(() => { send.textContent = '❌ 下载器未启动'; });
    };
    const copy = document.createElement('button');
    copy.textContent = '复制信息';
    copy.style.cssText = 'background:#1f232c;color:#e6e8ec;border:1px solid #2a2f3a;border-radius:8px;padding:8px 12px;cursor:pointer';
    copy.onclick = () => navigator.clipboard.writeText(JSON.stringify(item, null, 2)).then(() => copy.textContent = '已复制');
    const close = document.createElement('span');
    close.textContent = '✕';
    close.style.cssText = 'position:absolute;top:10px;right:12px;cursor:pointer;color:#9aa1ac';
    close.onclick = () => box.remove();
    box.appendChild(send); box.appendChild(copy); box.appendChild(close);
    document.body.appendChild(box);
    setTimeout(() => box.remove(), 60000);
  }

  console.log('[微信视频号捕获助手] 已启动，播放视频后将自动捕获。');
})();
