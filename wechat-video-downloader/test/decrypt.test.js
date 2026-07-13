/* 测试：解密核心正确性、解析器、端到端下载+解密流水线。
 * 运行：npm test （零依赖，仅用 Node 内置模块） */
'use strict';

const assert = require('assert');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const { generateKeystream, decrypt, decryptInPlace, isValidMp4 } = require('../src/shared/decrypt.js');
const { parseInput } = require('../src/main/parser.js');
const { downloadAndDecrypt, decryptLocalFile } = require('../src/main/downloader.js');

let pass = 0, fail = 0;
async function test(name, fn) {
  try { await fn(); console.log('  ✓ ' + name); pass++; }
  catch (e) { console.log('  ✗ ' + name + '\n      ' + e.message); fail++; }
}

(async () => {
  console.log('\n=== 1. 密钥流与 Go 参考实现比对 ===');
  const REF = {
    '2136343393': '49b96d6fc75ba5215fbb773ce98f6b20f6441a7ac40abc9582b1e42c5f3cd9d8',
    '1': '39d98f5b25cc52f0996f7ef9e1022156cb029901be6a11ebbdd7469c6ffd5839',
    '123456789': '1f972db9d304b9c779a59f9830f1b03c98e247a4e1102d926996dd61b60d8e67',
  };
  for (const [key, sha] of Object.entries(REF)) {
    await test('keystream sha256 匹配 key=' + key, () => {
      const ks = generateKeystream(key, 131072);
      const h = crypto.createHash('sha256').update(Buffer.from(ks)).digest('hex');
      assert.strictEqual(ks.length, 131072);
      assert.strictEqual(h, sha);
    });
  }

  console.log('\n=== 2. 加解密往返 ===');
  await test('XOR 两次还原原始数据', () => {
    const orig = crypto.randomBytes(300000);
    const enc = decrypt(orig, 2136343393);           // 模拟加密
    assert.notDeepStrictEqual(Buffer.from(enc.slice(0, 100)), orig.slice(0, 100));
    const dec = decrypt(enc, 2136343393);            // 解密
    assert.deepStrictEqual(Buffer.from(dec), orig);
  });
  await test('只影响前 131072 字节，其余不变', () => {
    const orig = crypto.randomBytes(200000);
    const enc = decrypt(orig, 42);
    assert.deepStrictEqual(Buffer.from(enc.slice(131072)), orig.slice(131072));
  });
  await test('小于 128KB 的文件也能整体还原', () => {
    const orig = crypto.randomBytes(1000);
    const dec = decrypt(decrypt(orig, 7), 7);
    assert.deepStrictEqual(Buffer.from(dec), orig);
  });

  console.log('\n=== 3. MP4 签名识别 ===');
  await test('识别 ftyp 签名', () => {
    const b = Buffer.concat([Buffer.from([0, 0, 0, 24]), Buffer.from('ftypmp42')]);
    assert.strictEqual(isValidMp4(b), true);
    assert.strictEqual(isValidMp4(Buffer.from('xxxxxxxx')), false);
  });

  console.log('\n=== 4. 输入解析 ===');
  await test('解析官方 JSON 结构', () => {
    const json = JSON.stringify({ data: { object_desc: { media: [{ url: 'https://finder.video.qq.com/a.mp4', decode_key: 2136343393, }], }, description: '我的视频' } });
    const r = parseInput({ text: json });
    assert.strictEqual(r.url, 'https://finder.video.qq.com/a.mp4');
    assert.strictEqual(r.decodeKey, '2136343393');
    assert.strictEqual(r.title, '我的视频');
  });
  await test('解析纯 URL 文本 + 显式 key', () => {
    const r = parseInput({ text: '看这个 https://x.qq.com/v.mp4 很棒', decodeKey: 'key=123456' });
    assert.strictEqual(r.url, 'https://x.qq.com/v.mp4');
    assert.strictEqual(r.decodeKey, '123456');
  });
  await test('显式字段覆盖文本识别', () => {
    const r = parseInput({ text: '{"url":"https://a/b.mp4","decode_key":1}', url: 'https://override/c.mp4' });
    assert.strictEqual(r.url, 'https://override/c.mp4');
    assert.strictEqual(r.decodeKey, '1');
  });

  console.log('\n=== 5. 端到端：本地 HTTP 服务器下载 + 流式解密 ===');
  await test('下载加密视频并解密为合法 MP4', async () => {
    // 构造一个「明文 MP4」：前 8 字节符合 ftyp 签名，总长跨越 128KB 边界
    const plain = Buffer.concat([
      Buffer.from([0, 0, 0, 24]), Buffer.from('ftypmp42'),
      crypto.randomBytes(150000),
    ]);
    const key = 2136343393;
    // 用同一算法「加密」（XOR 前 128KB）后放到 HTTP 服务器上
    const encrypted = Buffer.from(plain);
    decryptInPlace(encrypted, key); // XOR 一次 = 加密

    const srv = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'video/mp4', 'Content-Length': encrypted.length });
      res.end(encrypted);
    });
    await new Promise((r) => srv.listen(0, '127.0.0.1', r));
    const port = srv.address().port;

    const out = path.join(os.tmpdir(), 'wvd_test_' + crypto.randomBytes(4).toString('hex') + '.mp4');
    let lastPercent = 0;
    const result = await downloadAndDecrypt({
      url: `http://127.0.0.1:${port}/v.mp4`,
      decodeKey: key,
      outputPath: out,
      onProgress: (p) => { lastPercent = p.percent; },
    });
    srv.close();

    assert.strictEqual(result.validMp4, true, '应识别为合法 MP4');
    const got = fs.readFileSync(out);
    assert.deepStrictEqual(got, plain, '解密结果应与原始明文完全一致');
    assert.strictEqual(lastPercent, 100, '进度应到 100%');
    fs.unlinkSync(out);
  });

  await test('decryptLocalFile 还原本地加密文件', async () => {
    const plain = Buffer.concat([Buffer.from([0, 0, 0, 24]), Buffer.from('ftypisom'), crypto.randomBytes(50000)]);
    const key = 123456789;
    const enc = Buffer.from(plain); decryptInPlace(enc, key);
    const inPath = path.join(os.tmpdir(), 'wvd_in_' + crypto.randomBytes(4).toString('hex') + '.mp4');
    const outPath = path.join(os.tmpdir(), 'wvd_out_' + crypto.randomBytes(4).toString('hex') + '.mp4');
    fs.writeFileSync(inPath, enc);
    const r = await decryptLocalFile({ inputPath: inPath, outputPath: outPath, decodeKey: key });
    assert.strictEqual(r.validMp4, true);
    assert.deepStrictEqual(fs.readFileSync(outPath), plain);
    fs.unlinkSync(inPath); fs.unlinkSync(outPath);
  });

  console.log('\n─────────────────────────────');
  console.log(`  通过 ${pass} · 失败 ${fail}`);
  console.log('─────────────────────────────\n');
  process.exit(fail ? 1 : 0);
})();
