#!/bin/bash
cd "$(dirname "$0")"
xattr -dr com.apple.quarantine "度量台.app" 2>/dev/null
echo ""
echo "  ✓ 已移除系统隔离标记，现在可以直接双击打开「度量台.app」了"
echo ""
read -n 1 -s -r -p "  按任意键关闭本窗口"
