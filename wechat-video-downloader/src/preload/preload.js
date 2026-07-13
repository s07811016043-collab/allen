/* Electron 预加载脚本：把主进程能力以最小面积暴露给渲染层。 */
'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('desktopAPI', {
  parse: (payload) => ipcRenderer.invoke('parse', payload),
  getSettings: () => ipcRenderer.invoke('get-settings'),
  chooseDir: () => ipcRenderer.invoke('choose-dir'),
  reveal: (p) => ipcRenderer.invoke('reveal', p),
  /**
   * 开始下载。onEvent 会被多次调用：
   *   {type:'progress',received,total,percent} / {type:'done',outputPath} / {type:'error',message}
   */
  startDownload: (opts, onEvent) => {
    const channel = 'dl-' + Date.now() + '-' + Math.floor(performance.now());
    ipcRenderer.on(channel, (_e, evt) => onEvent(evt));
    ipcRenderer.invoke('start-download', { ...opts, channel });
  },
});
