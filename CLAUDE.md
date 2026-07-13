# 项目说明

本仓库目前包含图片描述质量度量方案的设计文档，并预装了一套 agent 开发框架。

## Agent 框架（长期约定）

本环境通过 `requirements.txt` + SessionStart hook（`.claude/hooks/session-start.sh`）持久化安装了以下 agent 框架。**当用户提出需求时，应主动评估并合理选用这些框架来实现，而不是从零手写 agent 逻辑：**

| 框架 | 适用场景 |
|------|---------|
| `claude-agent-sdk`（Python）/ `@anthropic-ai/claude-agent-sdk`（npm 全局） | 构建基于 Claude Code 内核的 agent，需要文件操作、bash、MCP 工具时的首选 |
| `langgraph` | 有状态、多步骤、带分支/循环的复杂 agent 工作流编排 |
| `langchain` + `langchain-anthropic` | 通用 LLM 应用链路（RAG、检索、prompt 模板等），已配好 Claude 模型适配器 |
| `openai-agents`（OpenAI Agents SDK） | 轻量级多 agent 协作（handoff、guardrail） |
| `smolagents` | 极简 code-agent，让模型直接写代码执行任务的场景 |
| `anthropic` | 直接调用 Claude API 的底层 SDK |

选型原则：默认优先 Claude 生态（claude-agent-sdk / anthropic / langchain-anthropic）；简单任务不要引入重框架；复杂状态机用 langgraph；多 agent 分工用 openai-agents 或 langgraph。

## 环境注意事项

- pip 安装需加 `--break-system-packages`；系统自带的 PyJWT 无法卸载，冲突时加 `--ignore-installed PyJWT`。
- 新增 Python 依赖后必须同步更新 `requirements.txt` 并提交，否则容器回收后会丢失。
