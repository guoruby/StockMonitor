# 项目规则

## Git 提交规范

### 本地开发模式（当前）

每次开发任务完成后，自动执行 git add + git commit。

- **提交范围**：只提交本次任务修改的文件，不要 `git add .`
- **提交信息**：简洁描述本次改动，用中文，格式如 `优化OCR采集：强制返回JSON格式、精简提示词、裁剪替代压缩`
- **自动 push**：commit 后自动 push 到远程仓库
- **敏感文件**：不提交敏感文件（.env、credentials 等），已通过 .gitignore 排除

## 构建规范

每次代码改动后，必须重新编译并打包 App：

1. 编译：`find Sources -name "*.swift" | xargs swiftc -O -framework Cocoa -framework Vision -framework Carbon -o .build/release/StockMonitor`
2. 打包：`bash build.sh`
3. 产物：`dist/股票价格监控.app`
