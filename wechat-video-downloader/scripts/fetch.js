/* 一键下载 + 解密。
 * 用法：
 *   node scripts/fetch.js '<接口JSON 或 视频直链>' [decode_key] [输出路径]
 * 输入可以是：
 *   - 微信视频号接口返回的整段 JSON（自动提取 url 与 decode_key）
 *   - 视频直链 URL（此时 decode_key 作为第二个参数传入）
 */
'use strict';

const path = require('path');
const { parseInput } = require('../src/main/parser.js');
const { downloadAndDecrypt, sanitizeFilename } = require('../src/main/downloader.js');

process.env.NODE_EXTRA_CA_CERTS = process.env.NODE_EXTRA_CA_CERTS || '/root/.ccr/ca-bundle.crt';

async function main() {
  const [, , rawInput, keyArg, outArg] = process.argv;
  if (!rawInput) {
    console.error('用法: node scripts/fetch.js \'<JSON 或 URL>\' [decode_key] [输出路径]');
    process.exit(2);
  }

  const parsed = parseInput({ text: rawInput, decodeKey: keyArg });
  if (!parsed.url) {
    console.error('❌ 未能从输入中识别出视频直链 url');
    process.exit(1);
  }
  if (!parsed.decodeKey) {
    console.error('⚠️  未识别到 decode_key，将只下载不解密（视频可能只能播放前几秒）');
  }

  const outDir = path.join(__dirname, '..', 'out');
  const name = sanitizeFilename(parsed.title || 'wechat_video') + '.mp4';
  const outputPath = outArg || path.join(outDir, name);

  console.log('▶ 视频直链:', parsed.url.slice(0, 90) + (parsed.url.length > 90 ? '…' : ''));
  console.log('▶ decode_key:', parsed.decodeKey || '(无)');
  console.log('▶ 输出:', outputPath);

  let lastLine = 0;
  const result = await downloadAndDecrypt({
    url: parsed.url,
    decodeKey: parsed.decodeKey,
    outputPath,
    onProgress: (p) => {
      const now = Date.now();
      if (now - lastLine > 400 || p.percent === 100) {
        lastLine = now;
        const mb = (p.received / 1048576).toFixed(1);
        const tot = p.total ? '/' + (p.total / 1048576).toFixed(1) : '';
        process.stdout.write(`\r  下载 ${p.percent}%  (${mb}${tot} MB)   `);
      }
    },
  });

  process.stdout.write('\n');
  console.log('✅ 完成');
  console.log('   文件大小:', (result.size / 1048576).toFixed(2), 'MB');
  console.log('   解密:', result.decrypted ? '是' : '否');
  console.log('   MP4 签名校验:', result.validMp4 ? '通过 ✓' : '未通过（decode_key 可能不匹配）');
  console.log('   路径:', result.outputPath);
}

main().catch((e) => {
  console.error('\n❌ 失败:', e.message);
  process.exit(1);
});
