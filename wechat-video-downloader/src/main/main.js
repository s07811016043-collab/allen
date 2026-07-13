/* Electron 主进程：创建窗口、处理 IPC、下载与解密。 */
'use strict';

const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const { parseInput } = require('./parser.js');
const { downloadAndDecrypt, sanitizeFilename } = require('./downloader.js');

const SETTINGS_PATH = () => path.join(app.getPath('userData'), 'settings.json');

function loadSettings() {
  try { return JSON.parse(fs.readFileSync(SETTINGS_PATH(), 'utf8')); } catch (_) {
    return { outputDir: app.getPath('downloads') };
  }
}
function saveSettings(s) {
  try { fs.writeFileSync(SETTINGS_PATH(), JSON.stringify(s, null, 2)); } catch (_) {}
}

let mainWindow;
function createWindow() {
  mainWindow = new BrowserWindow({
    width: 940,
    height: 800,
    minWidth: 720,
    minHeight: 560,
    title: '微信视频号下载器',
    backgroundColor: '#0f1115',
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });

/* ---------------- IPC ---------------- */
ipcMain.handle('parse', (_e, payload) => parseInput(payload || {}));

ipcMain.handle('get-settings', () => loadSettings());

ipcMain.handle('choose-dir', async () => {
  const r = await dialog.showOpenDialog(mainWindow, { properties: ['openDirectory', 'createDirectory'] });
  if (r.canceled || !r.filePaths[0]) return null;
  const s = loadSettings(); s.outputDir = r.filePaths[0]; saveSettings(s);
  return r.filePaths[0];
});

ipcMain.handle('reveal', (_e, p) => { if (p && fs.existsSync(p)) shell.showItemInFolder(p); });

ipcMain.handle('start-download', async (_e, opts) => {
  const { channel } = opts;
  const send = (evt) => { if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(channel, evt); };
  try {
    const settings = loadSettings();
    const dir = opts.outputDir || settings.outputDir || app.getPath('downloads');
    const name = sanitizeFilename(opts.title || 'wechat_video') + '.mp4';
    const outputPath = uniquePath(path.join(dir, name));
    const result = await downloadAndDecrypt({
      url: opts.url,
      decodeKey: opts.decodeKey,
      outputPath,
      onProgress: (p) => send({ type: 'progress', ...p }),
    });
    send({ type: 'done', outputPath: result.outputPath, validMp4: result.validMp4 });
  } catch (err) {
    send({ type: 'error', message: err.message });
  }
});

function uniquePath(p) {
  if (!fs.existsSync(p)) return p;
  const dir = path.dirname(p), ext = path.extname(p), base = path.basename(p, ext);
  let i = 1;
  while (fs.existsSync(path.join(dir, `${base}(${i})${ext}`))) i++;
  return path.join(dir, `${base}(${i})${ext}`);
}
