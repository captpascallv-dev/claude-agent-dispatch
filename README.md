# claude-agent-dispatch

让 Claude Code 当 Lead，把活派给其他 agent CLI（Codex、Cursor、Grok Build、PI、DeepSeek DSH……），执行者交卷时**自动叫醒** Claude 验收。不需要模型轮询，也不需要中转服务。

> Let Claude Code act as a lead: dispatch task cards to other agent CLIs (Codex, Cursor, Grok Build, PI, DeepSeek DSH, …) as detached processes, and get woken up automatically when the work is delivered — no model polling, no relay service.

## 原理

Claude Code 的后台命令（Bash/PowerShell 工具的 `run_in_background`）**退出时会重新唤醒会话**。于是：

```
Claude(Lead) ──写任务卡──> Dispatch.ps1 ──后台隐藏进程──> agent CLI（干活，写交卷目录）
     ▲                                                          │
     │                                                  最后写 READY.json
     └──── 唤醒 <── Wait-Delivery.ps1（纯本地文件检查，后台运行）<──┘
```

- 派单后 Claude 结束本轮，不占上下文、不花额度等待。
- 守候脚本只做文件存在性检查（每 20 秒一次），不调用任何模型。
- 执行者通过后台进程启动；会话重启后用 `Pending.ps1` 重新挂守候。能否跨宿主退出继续存活取决于启动环境，见下方限制。
- Claude Code 的后台命令大约 30 分钟会被强制停掉（2026-10-02 实测）。派单打出的守候最多 29 分钟一轮；这一轮以退出码 2 结束而执行者还在，就再挂一轮。

## 目录

```
bin/Dispatch.ps1        派单：按 executors.json 组装命令，后台启动，输出最多 29 分钟一轮的 WATCH 命令
bin/Run-Agent.ps1       后台进程里实际执行 agent CLI，写 agent.log / exit_code.txt
bin/Wait-Delivery.ps1   守候：READY.json 出现→退出码0；执行者没交卷就退出→4；超时→2
bin/Pending.ps1         列出未交卷任务并给出重挂守候命令（跳过放了 CLOSED.txt 的任务）
executors.example.json  执行者配置样例（复制为 executors.json 后按需修改）
templates/TASK_CARD.md  任务卡模板（含交卷约定）
CLAUDE.snippet.md       放进 CLAUDE.md 的一段说明，让 Claude 知道怎么用
jobs/<id>/              每次派单的记录：job.json、spec.json、任务卡副本、agent.log。放 CLOSED.txt 表示不再重挂守候
```

## 安装

1. 需要 PowerShell 7（`pwsh`）。目前在 Windows 11 上实测；脚本本身跨平台，Linux/macOS 未测。
2. 装好并登录你要用的 agent CLI（各自官方方式登录，本工具不碰凭据）。
3. `cp executors.example.json executors.json`，删掉你没有的执行者，改成你要的模型。
4. 把 `CLAUDE.snippet.md` 的内容放进你的 `CLAUDE.md`，路径改成实际位置。

然后对 Claude 说"调用外部执行，让 codex 做 XXX"即可。

## 执行者配置

`executors.json` 里每个执行者是一条命令模板：

| 字段 | 含义 |
| --- | --- |
| `command` | PATH 上的命令名（`codex`、`cursor-agent`、`grok`、`pi`、`dsh`） |
| `args` | 参数列表，可用占位符 |
| `stdin_card` | `true` 时把任务卡全文从标准输入喂给它（如 `codex exec -`） |
| `cwd` | 工作目录，默认 `{workspace}` |
| `env` | 额外环境变量（空值会被忽略）。**不要把 API key 写进这里**，用 CLI 自己的登录或系统环境变量 |

占位符：`{workspace}` `{outbox}` `{card}`（任务卡绝对路径）`{carddir}` `{jobdir}` `{pointer}`。

`{pointer}` 是一句"请读取任务卡文件 {card} 并严格执行"的短提示（可在配置顶层 `pointer` 改写）。任务卡不直接塞进命令行，避免 Windows 命令行长度限制和转义问题，执行者自己去读卡文件。

### 各 CLI 的非交互用法（样例里已配好）

| 执行者 | 关键参数 | 说明 |
| --- | --- | --- |
| Codex CLI | `codex exec -m <model> -c model_reasoning_effort=<档> -s workspace-write -C <ws> -` | 任务卡走 stdin；有沙箱，写权限限于工作区和 `--add-dir`。想用另一个账号，设 `env.CODEX_HOME` 指向单独的 Codex 目录 |
| Cursor CLI | `cursor-agent -p --model <model> --force --trust --workspace <ws>` | `--force` 表示自动批准命令 |
| Grok Build | `grok --prompt-file <card> -m <model> --reasoning-effort <档> --always-approve --cwd <ws>` | 原生支持从文件读 prompt |
| PI | `pi -p --provider <p> --model <m> --thinking <档> --no-session` | |
| DeepSeek DSH | `dsh --profile headless "<task>"` | 内置 headless profile；模型取 DSH 自己的设置 |

**新增任何 CLI**：只要它能①非交互运行一个 prompt、②读写本地文件，就能加一条配置接进来，脚本不用改。

## 交卷约定

任务卡里必须写明：产物写进交卷目录，写 `REPORT.md`，**最后一步**写 `READY.json`。统一格式：

```json
{"status":"completed|blocked|failed","deliverables":["相对工作目录的路径"],"notes":"一句话"}
```

三个字段必须在，名字不能改。任务专属数字（条数、字数等）可以加在后面。`blocked` 和 `failed` 也要写 `REPORT.md` 和 `READY.json`，不要静默退出，不要把没完成写成 `completed`。

守候脚本只认交卷目录里有没有 `READY.json`，不判 status 对不对：文件一出现就以退出码 0 叫醒 Lead。执行者进程结束了却没写它，守候以退出码 4 叫醒，由 Lead 查 `jobs/<id>/agent.log`。

## Lead 怎么验收

- 核对实际产物，不要只信 `REPORT.md` 的自报。
- **越界检查**：对照任务卡看执行者有没有扩大范围，有没有加任务卡没要求的测试、工具或文件。有就写进验收，并决定是否退回。
- **量级**：派单时写明预期（大概多久、用哪个执行者的额度、改动规模）；验收时报实际值。两者差得多，要说明原因。
- 退修换一个新的交卷目录和新任务卡，不覆盖旧交卷。

## 安全提醒

- `--force` / `--always-approve` 等于允许执行者在你机器上跑任意命令。优先用有沙箱的执行者（如 Codex 的 `workspace-write`），并让工作目录只包含该任务需要的东西。
- 本工具不读取或复制各 CLI 的认证文件；各 CLI 用自己的登录状态。不要在配置的 `env` 中填密钥，该字段会写入本地 `jobs/<id>/spec.json`。
- 验收时核对实际产物，不要只信执行者的自报。

## 实测状态

维护者提供的链路烟测记录如下（2026-09-30，Windows 11，PowerShell 7.6；原始任务日志未纳入公开包）。

| 执行者 | 版本 | 测试模型 | 结果 | 派单→交卷 |
| --- | --- | --- | --- | --- |
| Codex CLI | 0.159.2 | gpt-6-luna / max | 通过 | 20 秒 |
| Cursor CLI | 2026.09.28 | grok-4.7-xhigh | 通过 | 64 秒 |
| Grok Build | — | grok-4.7 / xhigh | 通过 | 16 秒 |
| PI | — | gpt-6-luna / max（openai-codex） | 通过 | 19 秒 |
| DeepSeek DSH | — | DSH 默认设置 | 通过 | 4 秒 |

测试任务：读任务卡 → 写一行中文 REPORT.md → 写 READY.json；五个并行派出，守候脚本全部以退出码 0 叫醒。这只证明链路通，不代表复杂任务的质量。2026-10-11 更新文档时没有重跑上表，数字仍是 2026-09-30 那一次。

## 当前限制

- 后台命令大约 30 分钟会被强制停掉。这是 2026-10-02 在 Claude Code 后台任务上看到的，不是把上面的链路烟测重跑了一遍。`Dispatch.ps1` 和 `Pending.ps1` 打出的守候因此最多 29 分钟：到点以退出码 2 退出并叫醒 Lead。执行者进程还在，就再挂一轮，只看进程还在不在、交卷目录里有没有 `READY.json`，不读日志正文。`Wait-Delivery.ps1` 自己的默认超时仍是 720 分钟，给直接在终端里跑、不受这个后台上限约束的情况用。一条命令挂数小时，在 Claude Code 后台任务里站不住；多轮重挂能不能覆盖更长的任务，没有另做实测。
- 当前实测环境仅为 Windows 11 / PowerShell 7.6；Linux、macOS 和完整宿主退出后的存活未验证。后台进程不保证脱离宿主的 Windows Job Object，守候或执行者可能随宿主退出一起停。宿主关掉时守候会停，交卷文件照常落盘，会话回来后用 `Pending.ps1` 重挂。
- `Pending.ps1` 恢复的是本地守候，不会自动重跑执行任务，也不是持久通知服务。必须由 Claude Code 当前会话以后台工具方式运行守候，退出通知才能回到该会话。
- 守候超时只结束守候，不终止执行者。PID 检查目前没有绑定进程启动时间；长时间恢复时应核对任务和日志，避免把复用的 PID 当成原任务。
- `READY.json` 存在就会唤醒 Lead，包括 `blocked`、`failed` 或无法解析的文件；退出码 0 表示发现交卷标记，不能替代结果验收。执行器退出或守候超时同样需要 Lead 查明。

## License

MIT，见 [LICENSE](LICENSE)。
