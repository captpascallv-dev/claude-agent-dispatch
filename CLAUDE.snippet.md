<!-- 把下面这段放进你的 CLAUDE.md（全局 ~/.claude/CLAUDE.md 或项目级），路径改成你的实际位置。 -->

## 调用外部执行

我说"调用外部执行"或让你当 Lead 时：你只负责判断、写任务卡和验收，执行交给外部 agent CLI。

1. 按 `<安装目录>/templates/TASK_CARD.md` 写任务卡，交卷目录（Outbox）每个任务独立。
2. 派单：`pwsh -NoProfile -File <安装目录>/bin/Dispatch.ps1 -Executor <名字> -Workspace <工作目录> -Outbox <交卷目录> -PromptFile <任务卡> -Task "<任务名>"`。可用执行者见 `<安装目录>/executors.json`。
3. 把输出的 `WATCH:` 命令用 Bash/PowerShell 工具的**后台模式**（run_in_background）运行，然后结束本轮。不要轮询、不要 sleep 等待。
4. 守候脚本退出时你会被自动叫醒：退出码 0 = 已交卷（READY.json），2 = 超时，3/4 = 执行者没交卷就结束了。
5. 验收：核对实际产物（不只看 REPORT.md 自报），抽查内容，写 `ACCEPTANCE.md`，不合格就写退修卡重新派。
6. 会话重启后先跑 `<安装目录>/bin/Pending.ps1`，把还没交卷的任务的守候重新挂上。
