#!/usr/bin/env bash
# 构建脚本：同步网页资源 → 交叉编译 Windows / macOS / Linux 三平台可执行文件
set -euo pipefail
cd "$(dirname "$0")"

echo "[1/3] 同步网页资源 eval-dashboard/ -> web/"
rm -rf web && mkdir web
cp -r ../eval-dashboard/index.html ../eval-dashboard/app.js ../eval-dashboard/styles.css \
      ../eval-dashboard/samples.js ../eval-dashboard/vendor ../eval-dashboard/samples web/

echo "[2/3] 交叉编译"
mkdir -p dist
LDFLAGS="-s -w"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags "$LDFLAGS" -o dist/度量台-windows.exe .
CGO_ENABLED=0 GOOS=darwin  GOARCH=arm64 go build -ldflags "$LDFLAGS" -o dist/度量台-macos-apple芯片 .
CGO_ENABLED=0 GOOS=darwin  GOARCH=amd64 go build -ldflags "$LDFLAGS" -o dist/度量台-macos-intel .
CGO_ENABLED=0 GOOS=linux   GOARCH=amd64 go build -ldflags "$LDFLAGS" -o dist/度量台-linux .
chmod +x dist/度量台-macos-apple芯片 dist/度量台-macos-intel dist/度量台-linux

echo "[3/3] 完成"
ls -lh dist/
