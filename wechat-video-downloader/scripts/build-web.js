/* 生成纯静态单文件网页 dist-web/index.html —— 内联解密核心与样式，离线可用。
 * 同时生成用于在线发布的 body 片段 dist-web/artifact-body.html。
 * 运行：node scripts/build-web.js */
'use strict';
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const decryptSrc = fs.readFileSync(path.join(root, 'src/shared/decrypt.js'), 'utf8');
const styles = fs.readFileSync(path.join(root, 'src/renderer/styles.css'), 'utf8');

const BODY = `
<div class="app">
  <header class="topbar">
    <div class="logo">微</div>
    <div>
      <div class="title">微信视频号下载器 · 本地解密</div>
      <div class="subtitle">纯浏览器端运算 · 不上传任何数据</div>
    </div>
    <div class="spacer"></div>
    <button id="theme-btn" class="icon-btn" title="切换主题">🌙</button>
  </header>
  <main>
    <div class="notice info">
      已经用浏览器 / 下载工具把<strong>加密的视频号视频</strong>存到本地了？在这里选择文件并填入
      <code class="inline">decode_key</code>，即可在本机解密为可正常播放的 MP4。整个过程<b>完全在你的浏览器里完成</b>。
    </div>
    <div class="card">
      <h3>① 选择加密视频文件</h3>
      <div class="dropzone" id="dropzone">
        <p>把加密视频拖到这里，或 <strong>点击选择文件</strong></p>
        <p id="local-file-name" class="job-meta"></p>
        <input type="file" id="local-file" class="hidden" />
      </div>
      <label class="field" style="margin-top:14px">
        <span>② 填入 decode_key（纯数字）</span>
        <input type="text" id="local-key" placeholder="例如 2136343393" />
      </label>
      <div class="actions">
        <button class="primary" id="local-go" disabled>③ 解密并下载</button>
        <span id="local-status" class="job-meta"></span>
      </div>
    </div>
    <div class="card">
      <h3>如何获取加密视频与 decode_key</h3>
      <ol class="steps">
        <li>电脑浏览器打开 <code>https://channels.weixin.qq.com/</code>，找到目标视频。</li>
        <li>按 <span class="kbd">F12</span> → <b>Network（网络）</b> 面板，然后播放视频。</li>
        <li>找到含 <code>object_desc</code> 的接口，记下 <code>media[0].url</code> 与 <code>media[0].decode_key</code>。</li>
        <li>浏览器打开该 <code>url</code> 直接把视频下载到本地（此时是加密的，只能播放前几秒）。</li>
        <li>回到本页选择它 + 填 <code>decode_key</code>，点解密即可。</li>
      </ol>
      <div class="notice info" style="margin-top:6px">
        想要「粘贴链接自动下载」或「网页端一键捕获」？请使用完整版：桌面 App 或
        <code class="inline">npm run web</code> 本地服务（见项目 README）。
      </div>
    </div>
    <div class="card">
      <h3>解密原理</h3>
      <p class="hint">微信视频号只加密文件前 128KB（131072 字节）。加密使用以 <code class="inline">decode_key</code>
        为种子的 ISAAC-64 伪随机数生成器生成 128KB 密钥流，再对文件头部逐字节 XOR。本页用同样算法生成密钥流并再做一次
        XOR 即可还原。核心算法已与公开 Go 参考实现逐字节比对一致。</p>
    </div>
  </main>
  <footer>仅供个人学习与备份自己发布的内容使用，请遵守相关平台条款与法律法规。</footer>
</div>
`;

const SCRIPT = `
<script>${decryptSrc}<\/script>
<script>
(function(){
  'use strict';
  var $=function(id){return document.getElementById(id)};
  var root=document.documentElement;
  $('theme-btn').addEventListener('click',function(){
    var next=root.getAttribute('data-theme')==='dark'?'light':'dark';
    root.setAttribute('data-theme',next);
    $('theme-btn').textContent=next==='dark'?'🌙':'☀️';
    try{localStorage.setItem('theme',next)}catch(e){}
  });
  try{var s=localStorage.getItem('theme');if(s){root.setAttribute('data-theme',s);$('theme-btn').textContent=s==='dark'?'🌙':'☀️';}}catch(e){}
  function fmt(n){if(!n)return'0 B';var u=['B','KB','MB','GB'],i=0;while(n>=1024&&i<3){n/=1024;i++}return n.toFixed(i?1:0)+' '+u[i]}
  var dz=$('dropzone'),fi=$('local-file'),file=null;
  dz.addEventListener('click',function(){fi.click()});
  dz.addEventListener('dragover',function(e){e.preventDefault();dz.classList.add('drag')});
  dz.addEventListener('dragleave',function(){dz.classList.remove('drag')});
  dz.addEventListener('drop',function(e){e.preventDefault();dz.classList.remove('drag');if(e.dataTransfer.files[0])sel(e.dataTransfer.files[0])});
  fi.addEventListener('change',function(){if(fi.files[0])sel(fi.files[0])});
  function sel(f){file=f;$('local-file-name').textContent=f.name+'  ('+fmt(f.size)+')';$('local-go').disabled=false}
  $('local-go').addEventListener('click',async function(){
    if(!file)return;
    var key=$('local-key').value.replace(/[^\\d]/g,'');
    if(!key){alert('请输入 decode_key（纯数字）。');return}
    $('local-status').textContent='解密中…';
    try{
      var buf=new Uint8Array(await file.arrayBuffer());
      window.WxDecrypt.decryptInPlace(buf,key);
      var valid=window.WxDecrypt.isValidMp4(buf);
      var name=file.name.replace(/\\.(mp4|f0|bin|dat)$/i,'')+'_decrypted.mp4';
      var blob=new Blob([buf],{type:'video/mp4'});
      var a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=name;
      document.body.appendChild(a);a.click();a.remove();setTimeout(function(){URL.revokeObjectURL(a.href)},4000);
      $('local-status').innerHTML=valid?'<span class="tag ok">成功</span> 已识别到 MP4 签名，文件已开始下载。':'<span class="tag warn">已保存</span> 未检测到 MP4 签名，decode_key 可能不匹配。';
    }catch(err){$('local-status').innerHTML='<span class="tag err">失败</span> '+err.message}
  });
})();
<\/script>
`;

const full = `<!DOCTYPE html>
<html lang="zh-CN" data-theme="dark">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>微信视频号下载器 · 本地解密</title>
<style>
html,body{margin:0}
${styles}
</style>
</head>
<body>
${BODY}
${SCRIPT}
</body>
</html>
`;

fs.mkdirSync(path.join(root, 'dist-web'), { recursive: true });
fs.writeFileSync(path.join(root, 'dist-web/index.html'), full);
// 供在线发布用的 body 片段（含 style 与 script，不含 html/head/body 外壳）
fs.writeFileSync(path.join(root, 'dist-web/artifact-body.html'),
  `<style>\n${styles}\n</style>\n${BODY}\n${SCRIPT}\n`);

console.log('已生成 dist-web/index.html (' + full.length + ' 字节) 与 dist-web/artifact-body.html');
