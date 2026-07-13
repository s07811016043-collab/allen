/**
 * 下载 + 流式解密。
 *
 * 微信视频号只加密文件前 131072 字节，因此下载时无需把整段视频读进内存：
 * 先缓冲前 128KB、用 decode_key 生成的密钥流做 XOR，写出后其余字节直接透传。
 * 支持进度回调、取消。可在 Electron 主进程或独立 Node 服务中复用。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { KEYSTREAM_SIZE, generateKeystream, isValidMp4 } = require('../shared/decrypt.js');

const DEFAULT_HEADERS = {
  'User-Agent':
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
    'Chrome/124.0.0.0 Safari/537.36',
  Referer: 'https://channels.weixin.qq.com/',
};

function sanitizeFilename(name) {
  return (name || 'wechat_video')
    .replace(/[\\/:*?"<>|\n\r\t]/g, '_')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 80) || 'wechat_video';
}

/**
 * 下载并解密一个视频号视频。
 * @param {object} opts
 * @param {string} opts.url            加密视频直链
 * @param {string|number} opts.decodeKey  解密 key（可缺省 => 仅下载不解密）
 * @param {string} opts.outputPath     输出文件完整路径
 * @param {(p:{received:number,total:number,percent:number})=>void} [opts.onProgress]
 * @param {AbortSignal} [opts.signal]
 * @returns {Promise<{outputPath:string, size:number, decrypted:boolean, validMp4:boolean}>}
 */
async function downloadAndDecrypt(opts) {
  const { url, decodeKey, outputPath, onProgress, signal } = opts;
  if (!url) throw new Error('缺少视频地址 url');

  fs.mkdirSync(path.dirname(outputPath), { recursive: true });

  const res = await fetch(url, { headers: DEFAULT_HEADERS, signal });
  if (!res.ok) throw new Error(`下载失败：HTTP ${res.status} ${res.statusText}`);
  const total = Number(res.headers.get('content-length')) || 0;

  const keystream = decodeKey ? generateKeystream(decodeKey, KEYSTREAM_SIZE) : null;

  const fh = await fs.promises.open(outputPath, 'w');
  let received = 0;
  let headBytesDone = 0; // 已解密的头部字节数
  let firstChunkForCheck = null;

  try {
    const reader = res.body.getReader();
    // eslint-disable-next-line no-constant-condition
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      let chunk = Buffer.from(value);

      if (keystream && headBytesDone < KEYSTREAM_SIZE) {
        const end = Math.min(headBytesDone + chunk.length, KEYSTREAM_SIZE);
        for (let i = headBytesDone; i < end; i++) {
          chunk[i - headBytesDone] ^= keystream[i];
        }
        headBytesDone = end;
      }

      if (firstChunkForCheck === null) {
        firstChunkForCheck = Buffer.from(chunk.subarray(0, Math.min(16, chunk.length)));
      }

      await fh.write(chunk);
      received += chunk.length;
      if (onProgress) {
        onProgress({
          received,
          total,
          percent: total ? Math.min(100, Math.round((received / total) * 100)) : 0,
        });
      }
    }
  } finally {
    await fh.close();
  }

  const validMp4 = keystream && firstChunkForCheck ? isValidMp4(firstChunkForCheck) : false;
  return {
    outputPath,
    size: received,
    decrypted: Boolean(keystream),
    validMp4,
  };
}

/**
 * 解密一个已在本地的加密文件（就地或另存）。
 * @param {object} opts
 * @param {string} opts.inputPath
 * @param {string} opts.outputPath
 * @param {string|number} opts.decodeKey
 * @returns {Promise<{outputPath:string,size:number,validMp4:boolean}>}
 */
async function decryptLocalFile(opts) {
  const { inputPath, outputPath, decodeKey } = opts;
  if (!decodeKey) throw new Error('缺少 decode_key');
  const data = await fs.promises.readFile(inputPath);
  const encLen = Math.min(KEYSTREAM_SIZE, data.length);
  const ks = generateKeystream(decodeKey, encLen);
  for (let i = 0; i < encLen; i++) data[i] ^= ks[i];
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  await fs.promises.writeFile(outputPath, data);
  return { outputPath, size: data.length, validMp4: isValidMp4(data) };
}

module.exports = { downloadAndDecrypt, decryptLocalFile, sanitizeFilename, DEFAULT_HEADERS };
