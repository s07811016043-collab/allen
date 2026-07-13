/**
 * 输入解析：从用户粘贴的内容中提取「加密视频地址」与「decode_key」。
 *
 * 支持三种来源：
 *  1. 微信视频号接口返回的完整 JSON（含 object_desc.media[].url / decode_key）。
 *  2. 直接给出的视频直链 URL + 数字 decode_key。
 *  3. 抓包工具复制出的、包含 url 与 decode_key 字段的任意 JSON 片段。
 */
'use strict';

/** 递归在对象中查找第一个匹配的字段值 */
function deepFind(obj, predicate, path = []) {
  if (obj == null) return undefined;
  if (Array.isArray(obj)) {
    for (let i = 0; i < obj.length; i++) {
      const r = deepFind(obj[i], predicate, path.concat(i));
      if (r !== undefined) return r;
    }
    return undefined;
  }
  if (typeof obj === 'object') {
    for (const k of Object.keys(obj)) {
      if (predicate(k, obj[k])) return obj[k];
    }
    for (const k of Object.keys(obj)) {
      const r = deepFind(obj[k], predicate, path.concat(k));
      if (r !== undefined) return r;
    }
  }
  return undefined;
}

/** 从 media 节点拼出可下载的完整 URL（url + url_token） */
function buildUrl(media) {
  if (!media || typeof media !== 'object') return undefined;
  let url = media.url || media.fileUrl || media.videoUrl;
  if (!url) return undefined;
  const token = media.url_token || media.urlToken;
  if (token && !url.includes(token)) {
    url += (url.includes('?') ? '' : '') + token;
  }
  return url;
}

/**
 * 解析任意 JSON 文本，尽力提取 { url, decodeKey, title }。
 * @param {string} text
 * @returns {{url?:string, decodeKey?:string, title?:string}}
 */
function parseJsonText(text) {
  let data;
  try {
    data = JSON.parse(text);
  } catch (_) {
    return {};
  }
  const out = {};

  // 优先走官方结构 data.object_desc.media[0]
  const media = deepFind(data, (k, v) => k === 'media' && Array.isArray(v) && v.length);
  if (Array.isArray(media) && media[0]) {
    const u = buildUrl(media[0]);
    if (u) out.url = u;
    if (media[0].decode_key) out.decodeKey = String(media[0].decode_key);
  }

  if (!out.url) {
    const u = deepFind(data, (k, v) => (k === 'url' || k === 'fileUrl' || k === 'videoUrl') &&
      typeof v === 'string' && /^https?:\/\//.test(v) && /\.(mp4|f0|finder|video)/i.test(v));
    if (u) out.url = u;
  }
  if (!out.url) {
    // 退而求其次：任意 http url
    const u = deepFind(data, (k, v) => k === 'url' && typeof v === 'string' && /^https?:\/\//.test(v));
    if (u) out.url = u;
  }
  if (!out.decodeKey) {
    const key = deepFind(data, (k, v) => (k === 'decode_key' || k === 'decodeKey') &&
      (typeof v === 'number' || typeof v === 'string'));
    if (key !== undefined) out.decodeKey = String(key);
  }
  const title = deepFind(data, (k, v) => (k === 'title' || k === 'desc' || k === 'description') &&
    typeof v === 'string' && v.trim());
  if (title) out.title = String(title).trim();

  return out;
}

/**
 * 通用入口：接受一段自由文本（可能是 JSON、也可能是纯 URL），
 * 结合可选的显式 decodeKey，返回归一化结果。
 * @param {{ text?: string, url?: string, decodeKey?: string, title?: string }} input
 * @returns {{url?:string, decodeKey?:string, title?:string}}
 */
function parseInput(input = {}) {
  const out = { url: undefined, decodeKey: undefined, title: undefined };

  const text = (input.text || '').trim();
  if (text) {
    if (text.startsWith('{') || text.startsWith('[')) {
      Object.assign(out, parseJsonText(text));
    } else {
      const m = text.match(/https?:\/\/[^\s"']+/);
      if (m) out.url = m[0];
      const km = text.match(/decode_?key["'\s:=]+(\d{5,})/i);
      if (km) out.decodeKey = km[1];
    }
  }

  // 显式字段优先级最高
  if (input.url && input.url.trim()) out.url = input.url.trim();
  if (input.decodeKey && String(input.decodeKey).trim()) {
    out.decodeKey = String(input.decodeKey).trim();
  }
  if (input.title && input.title.trim()) out.title = input.title.trim();

  // 归一化 decodeKey：去掉非数字
  if (out.decodeKey) {
    const digits = String(out.decodeKey).replace(/[^\d]/g, '');
    out.decodeKey = digits || undefined;
  }
  return out;
}

module.exports = { parseInput, parseJsonText };
