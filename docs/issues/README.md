# 自托管部署问题记录（issues）

部署 Capgo + 自托管 Supabase 过程中遇到的问题，以**简体中文** Markdown 记录在本目录。

## 命名规范

- 文件名：`NNN-简短中文标题.md`
- `NNN`：三位数字，从 `001` 起递增（如 `001-kong-预签名含8000端口.md`）
- 标题与文件名一致，便于检索

## 文档模板

每篇建议包含以下章节（可复制为新文件开头）：

```markdown
# NNN - 标题

## 背景
（正在执行的计划阶段、相关服务）

## 现象
（错误信息、HTTP 状态、日志片段——**勿贴真实密钥**）

## 根因
（简要技术分析）

## 全栈文档对照
- 相关章节：**§x.x**（必填，如 §3.5、§5.4、§12.1）
- 参考：[/root/SELF_HOSTED_FULL_STACK.zh-CN.md](/root/SELF_HOSTED_FULL_STACK.zh-CN.md)

## 解决步骤
1. …
2. …

## 验证方式
（如何确认已修复）

## 关联文件
- 配置/脚本路径
```

## 写作要求

- 语言：**简体中文**
- **必须**引用 [`/root/SELF_HOSTED_FULL_STACK.zh-CN.md`](/root/SELF_HOSTED_FULL_STACK.zh-CN.md) 的章节号（如 **§12.1**）
- 禁止写入密钥、JWT、`API_SECRET` 等明文；用 `***` 占位
- 索引入口：[`../self-hosted-deploy-index.md`](../self-hosted-deploy-index.md)
