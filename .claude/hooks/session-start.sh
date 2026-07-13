#!/bin/bash
set -euo pipefail

# 仅在 Claude Code 远程（web）环境中运行
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# 安装 Python agent 框架依赖
# --ignore-installed PyJWT：系统自带的 Debian 版 PyJWT 缺少 RECORD 文件，无法被 pip 卸载
pip install --break-system-packages --ignore-installed PyJWT --quiet \
  -r "$CLAUDE_PROJECT_DIR/requirements.txt"

# 安装 TypeScript 版 Claude Agent SDK
if ! npm ls -g @anthropic-ai/claude-agent-sdk >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-agent-sdk >/dev/null 2>&1
fi

echo "Agent 框架依赖安装完成"
