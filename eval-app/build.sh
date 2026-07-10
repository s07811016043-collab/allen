#!/usr/bin/env bash
# 构建脚本：同步网页资源 → 注入 Windows 图标/版本信息 → 编译 Windows(x64) 与 macOS(Apple 芯片) → 组装 macOS .app
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$PATH:/usr/local/go/bin:/root/go/bin:$HOME/go/bin"
VERSION="1.1.0"

echo "[1/5] 同步网页资源 eval-dashboard/ -> web/"
rm -rf web && mkdir web
cp -r ../eval-dashboard/index.html ../eval-dashboard/app.js ../eval-dashboard/styles.css \
      ../eval-dashboard/samples.js ../eval-dashboard/logo.png ../eval-dashboard/favicon.png \
      ../eval-dashboard/vendor ../eval-dashboard/samples ../eval-dashboard/templates web/

echo "[2/5] 生成 Windows 资源（图标 + 版本信息 + 清单）"
rm -f rsrc_windows_*.syso
go-winres simply --arch amd64 --icon assets/icon-1024.png \
  --product-name "搜索与文案生成效果度量台" \
  --file-description "搜索与文案生成效果度量台（本地离线评估工具）" \
  --product-version "$VERSION" --file-version "$VERSION" \
  --copyright "AI NAS Team" --original-filename "度量台.exe" --manifest cli

echo "[3/5] 编译"
rm -rf dist && mkdir dist
LDFLAGS="-s -w"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags "$LDFLAGS" -o dist/度量台.exe .
CGO_ENABLED=0 GOOS=darwin  GOARCH=arm64 go build -ldflags "$LDFLAGS" -o dist/evald-arm64 .
rm -f rsrc_windows_*.syso

echo "[4/5] 组装 macOS .app（Apple 芯片）"
APP="dist/度量台.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv dist/evald-arm64 "$APP/Contents/MacOS/evald"
cp assets/icon.icns "$APP/Contents/Resources/icon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>度量台</string>
  <key>CFBundleDisplayName</key><string>度量台</string>
  <key>CFBundleIdentifier</key><string>com.ainas.eval-dashboard</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# 启动器：在“终端”里运行服务，看得到地址与日志，关闭终端窗口即停止服务
cat > "$APP/Contents/MacOS/launcher" <<'SH'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
osascript -e "tell application \"Terminal\" to do script \"clear; '$DIR/evald'\"" \
          -e 'tell application "Terminal" to activate'
SH
chmod +x "$APP/Contents/MacOS/launcher" "$APP/Contents/MacOS/evald"

# 一键移除隔离脚本（首次打开的信任处理）
cat > "dist/首次打开前双击我-移除隔离.command" <<'SH'
#!/bin/bash
cd "$(dirname "$0")"
xattr -dr com.apple.quarantine "度量台.app" 2>/dev/null
echo ""
echo "  ✓ 已移除系统隔离标记，现在可以直接双击打开「度量台.app」了"
echo ""
read -n 1 -s -r -p "  按任意键关闭本窗口"
SH
chmod +x "dist/首次打开前双击我-移除隔离.command"

echo "[5/5] 打包"
cp 使用说明.txt dist/ 2>/dev/null || true
( cd dist && zip -qr 度量台-macOS-Apple芯片.zip 度量台.app 首次打开前双击我-移除隔离.command 使用说明.txt )
( cd dist && zip -q  度量台-Windows.zip 度量台.exe 使用说明.txt )
ls -lh dist/
