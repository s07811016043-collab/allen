/**
 * 微信视频号视频解密核心 —— 纯 JavaScript 实现（Node 与浏览器通用）。
 *
 * 原理：微信视频号仅对视频文件的前 131072 字节（128KB）做加密，其余为明文。
 * 加密使用 ISAAC-64 伪随机数生成器，以接口返回的 decode_key 作为种子生成
 * 128KB 密钥流，再对文件头部逐字节做 XOR。解密即再做一次相同的 XOR。
 *
 * ISAAC-64 变体算法移植自 ltaoo/wx_channels_download（其源自
 * Hanson/WechatSphDecrypt），已用 Go 参考实现逐字节比对验证一致。
 *
 * 该文件不依赖任何运行环境特定 API，可在 Node.js 与浏览器中直接使用。
 */
(function (root, factory) {
  const mod = factory();
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = mod;
  } else {
    root.WxDecrypt = mod;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // 加密作用的字节数（密钥流长度）
  const KEYSTREAM_SIZE = 131072;
  const MASK = (1n << 64n) - 1n; // uint64 掩码
  const GOLDEN = 0x9e3779b97f4a7c13n;

  const u64 = (x) => x & MASK;
  const shl = (x, n) => (x << n) & MASK; // 逻辑左移（uint64）
  const shr = (x, n) => (x & MASK) >> n; // 逻辑右移（uint64）

  // ISAAC-64 上下文
  class RandCtx64 {
    constructor(seed) {
      this.randCnt = 255;
      this.seed = new Array(256).fill(0n);
      this.mm = new Array(256).fill(0n);
      this.aa = 0n;
      this.bb = 0n;
      this.cc = 0n;
      this._init(u64(seed));
    }

    _mix(s) {
      // s: 长度为 8 的 BigInt 数组 [a,b,c,d,e,f,g,h]
      let [a, b, c, d, e, f, g, h] = s;
      a = u64(a - e); f ^= shr(h, 9n); h = u64(h + a);
      b = u64(b - f); g ^= shl(a, 9n); a = u64(a + b);
      c = u64(c - g); h ^= shr(b, 23n); b = u64(b + c);
      d = u64(d - h); a ^= shl(c, 15n); c = u64(c + d);
      e = u64(e - a); b ^= shr(d, 14n); d = u64(d + e);
      f = u64(f - b); c ^= shl(e, 20n); e = u64(e + f);
      g = u64(g - c); d ^= shr(f, 17n); f = u64(f + g);
      h = u64(h - d); e ^= shl(g, 14n); g = u64(g + h);
      s[0] = a; s[1] = b; s[2] = c; s[3] = d;
      s[4] = e; s[5] = f; s[6] = g; s[7] = h;
    }

    _init(encKey) {
      const s = [GOLDEN, GOLDEN, GOLDEN, GOLDEN, GOLDEN, GOLDEN, GOLDEN, GOLDEN];

      this.seed[0] = encKey;
      for (let i = 1; i < 256; i++) this.seed[i] = 0n;

      for (let i = 0; i < 4; i++) this._mix(s);

      for (let i = 0; i < 256; i += 8) {
        for (let j = 0; j < 8; j++) s[j] = u64(s[j] + this.seed[i + j]);
        this._mix(s);
        for (let j = 0; j < 8; j++) this.mm[i + j] = s[j];
      }

      for (let i = 0; i < 256; i += 8) {
        for (let j = 0; j < 8; j++) s[j] = u64(s[j] + this.mm[i + j]);
        this._mix(s);
        for (let j = 0; j < 8; j++) this.mm[i + j] = s[j];
      }

      this._isaac64();
    }

    _isaac64() {
      this.cc = u64(this.cc + 1n);
      this.bb = u64(this.bb + this.cc);

      for (let i = 0; i < 256; i++) {
        switch (i % 4) {
          case 0: this.aa = u64(~(this.aa ^ shl(this.aa, 21n))); break;
          case 1: this.aa ^= shr(this.aa, 5n); break;
          case 2: this.aa ^= shl(this.aa, 12n); break;
          case 3: this.aa ^= shr(this.aa, 33n); break;
        }
        this.aa = u64(this.aa + this.mm[(i + 128) % 256]);
        const x = this.mm[i];
        const y = u64(this.mm[Number(shr(x, 3n) % 256n)] + this.aa + this.bb);
        this.mm[i] = y;
        this.bb = u64(this.mm[Number(shr(y, 11n) % 256n)] + x);
        this.seed[i] = this.bb;
      }
    }

    next() {
      const result = this.seed[this.randCnt];
      if (this.randCnt === 0) {
        this._isaac64();
        this.randCnt = 255;
      } else {
        this.randCnt--;
      }
      return result;
    }
  }

  /**
   * 生成指定长度的密钥流。
   * @param {number|bigint|string} decodeKey 接口返回的 decode_key
   * @param {number} length 密钥流字节数（默认 131072）
   * @returns {Uint8Array}
   */
  function generateKeystream(decodeKey, length = KEYSTREAM_SIZE) {
    const key = BigInt(decodeKey);
    const ctx = new RandCtx64(key);
    const out = new Uint8Array(length);
    for (let i = 0; i < length; i += 8) {
      let rnd = ctx.next();
      // BigEndian 写入 8 字节
      for (let j = 0; j < 8; j++) {
        const idx = i + j;
        if (idx >= length) break;
        out[idx] = Number(shr(rnd, BigInt((7 - j) * 8)) & 0xffn);
      }
    }
    return out;
  }

  /**
   * 就地解密：对 data 的前 KEYSTREAM_SIZE 字节做 XOR。
   * @param {Uint8Array} data 加密视频数据（会被就地修改）
   * @param {number|bigint|string} decodeKey
   * @returns {Uint8Array} 同一个 data 引用
   */
  function decryptInPlace(data, decodeKey) {
    const encLen = Math.min(KEYSTREAM_SIZE, data.length);
    const ks = generateKeystream(decodeKey, encLen);
    for (let i = 0; i < encLen; i++) data[i] ^= ks[i];
    return data;
  }

  /**
   * 返回解密后的新数组（不修改入参）。
   */
  function decrypt(data, decodeKey) {
    const copy = data instanceof Uint8Array ? new Uint8Array(data) : Uint8Array.from(data);
    return decryptInPlace(copy, decodeKey);
  }

  /**
   * 校验解密结果是否为合法 MP4（偏移 4 处应为 'ftyp'）。
   */
  function isValidMp4(data) {
    if (data.length < 8) return false;
    return data[4] === 0x66 && data[5] === 0x74 && data[6] === 0x79 && data[7] === 0x70; // 'ftyp'
  }

  return {
    KEYSTREAM_SIZE,
    RandCtx64,
    generateKeystream,
    decryptInPlace,
    decrypt,
    isValidMp4,
  };
});
