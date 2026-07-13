# 微信视频号下载器

下载并解密微信视频号视频 / 直播回放的工具。提供三种使用形态：

| 形态 | 说明 | 智能下载（远程直链） | 本地解密 | 自动捕获 |
|------|------|:---:|:---:|:---:|
| **桌面 App（dmg / exe / AppImage）** | Electron 打包，双击即用 | ✅ | ✅ | ✅（配合捕获助手） |
| **本地网页服务**（`npm run web`） | 零依赖 Node 服务 + 浏览器界面 | ✅ | ✅ | ✅（配合捕获助手） |
| **纯静态网页** | 单个 HTML，离线可用 | ❌（浏览器跨域限制） | ✅ | ❌ |

> 仅供个人学习与备份自己发布的内容使用，请遵守相关平台条款与法律法规。

---

## 原理

微信视频号的视频只加密文件**前 128KB（131072 字节）**，其余为明文。加密使用以接口返回的
`decode_key` 为种子的 **ISAAC-64** 伪随机数生成器生成 128KB 密钥流，再对文件头部逐字节 **XOR**。
本工具用同样的算法生成密钥流，再做一次 XOR 即可还原为标准 MP4。

- 解密核心：[`src/shared/decrypt.js`](src/shared/decrypt.js)（纯 JavaScript，Node 与浏览器通用）。
- 正确性：已与公开的 Go 参考实现（ltaoo/wx_channels_download）**逐字节比对一致**，见 `npm test`。

## 快速开始

### 方式一：本地网页服务（推荐，最省事）

```bash
cd wechat-video-downloader
npm install          # 仅打包桌面版才需要；跑 web / test 无需任何依赖
npm run web          # 启动后浏览器打开 http://127.0.0.1:8799
```

### 方式二：桌面 App

```bash
npm install
npm start            # 开发运行
npm run dist:mac     # 打包 macOS .dmg（需在 macOS 上执行）
npm run dist:win     # 打包 Windows .exe
npm run dist:linux   # 打包 Linux .AppImage
```

> **打包 .dmg 需要 macOS 环境。** 本仓库已内置 GitHub Actions（`.github/workflows/build.yml`）：
> 在仓库 **Actions** 页面手动运行 *构建桌面安装包*，即可在云端 macOS runner 上生成 `.dmg`
> 并作为 Artifact 下载；推送 `v*` tag 还会自动创建 Release。

### 方式三：纯静态网页

直接用浏览器打开 `dist-web/index.html`（单文件，含离线解密核心），可在任何电脑上做**本地解密**。

## 使用流程

### A. 已经有 `url` 和 `decode_key` → 智能下载
在「智能下载」页粘贴接口 JSON，或分别填入视频直链与 `decode_key`，点**开始下载并解密**。

### B. 已经下载了加密视频 → 本地解密
在「本地解密」页选择文件、填入 `decode_key`，纯本地运算得到可播放的 MP4。

### C. 自动捕获（无需装证书）
1. 安装 Tampermonkey，添加脚本 [`src/capture/wechat-capture.user.js`](src/capture/wechat-capture.user.js)。
2. 启动本地下载器（`npm run web` 或桌面 App 内置服务）。
3. 打开 `https://channels.weixin.qq.com/` 播放视频，页面右下角弹出捕获卡片，点**发送到下载器**即可。

### 如何手动获取 url 与 decode_key
1. 电脑浏览器打开 `https://channels.weixin.qq.com/`，找到目标视频。
2. `F12` → Network 面板 → 播放视频。
3. 找到含 `object_desc` 的接口，复制 `media[0].url` 与 `media[0].decode_key`。

## 目录结构

```
wechat-video-downloader/
├─ src/
│  ├─ shared/decrypt.js      # ISAAC-64 解密核心（Node + 浏览器通用）
│  ├─ main/                  # Electron 主进程、下载器、输入解析
│  ├─ preload/preload.js     # IPC 桥
│  ├─ renderer/              # 界面（桌面版与网页版共用）
│  ├─ server/web.js          # 零依赖本地网页服务
│  └─ capture/               # 视频号网页捕获助手（Tampermonkey 脚本）
├─ dist-web/index.html       # 纯静态单文件网页（本地解密）
├─ test/decrypt.test.js      # 测试（含端到端下载+解密）
├─ .github/workflows/build.yml
└─ build/icon.png
```

## 测试

```bash
npm test
```

覆盖：密钥流与 Go 参考实现比对、加解密往返、输入解析、端到端下载+流式解密。

## 致谢

解密算法参考自社区逆向成果：
- [ltaoo/wx_channels_download](https://github.com/ltaoo/wx_channels_download)（ISAAC-64 Go 实现，源自 Hanson/WechatSphDecrypt）
- [Evil0ctal/WeChat-Channels-Video-File-Decryption](https://github.com/Evil0ctal/WeChat-Channels-Video-File-Decryption)
- 原始工具形态参考 [qiye45/wechatVideoDownload](https://github.com/qiye45/wechatvideodownload)
