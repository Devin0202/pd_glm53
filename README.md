# GLM-5.3 双节点 1P1D

2026-09-22 02:45 CST，**已部署并完成真实跨节点验收，服务保持运行**。用户在 DP2 测试结束后授权切换部署。旧 GLM-5.2 DP2 服务已停止，52 阶段测试结果已增量同步本机。此包与 `pd_glm/` 的 5.2 参考方案独立。

> **本副本变更（2026-09-24）**：P/D 节点对调——Prefill/Router 在 launcher，Decode 在 worker；`PD_ROOT` 迁至 `/workspace/volume/data/dy/bench`；启动门禁改为入口生效，`start.sh`（任一角色）与 `router.sh` 均须 `ALLOW_LAUNCHER_PD=1`。

## 部署布局

| 角色 | 节点 | HTTP | 并行 | NIXL 侧通道 |
|---|---|---|---|---|
| Prefill | launcher，10.8.174.126 | 8100 | TP8 / DP1 / EP8 | 5610 |
| Decode | worker，10.9.243.230 | 8200 | TP8 / DP1 / EP8 | 5710 |
| Router | launcher，10.8.174.126 | 8300 | 静态 1P1D | — |

对外调用 Router：`http://10.8.174.126:8300/v1`，model=`glm-5.3`。不要直接调用 Decode 来代替 PD 验收。

两节点各 8 张 MLU590-M9、每卡 96 GiB。直接读取共享权重 `/workspace/volume/data/GLM-5.3-BF16-W4A8`；这是 W4A8 量化模型，共 282 个分片，未复制权重。运行环境 vLLM 0.25.1 / vllm_mlu 0.16.0.pt212、CNIXL 1.2.3。

远端根目录 `/workspace/volume/data/dy/bench`，下文称 `$PD_ROOT`。部署包为 `$PD_ROOT/package/pd_glm53`；每次启动在 `runs/<RUN_ID>/{prefill,decode,router}` 保存参数、脚本快照、PID 和日志，绝不覆盖旧运行目录。缓存放在 `$PD_ROOT/cache/`。本机原始记录镜像在旧部署树 `remote_sync/launcher/pd_glm53_20260922/`，不纳入 Git；P/D 日志都来自共享盘。

## 参数与兼容性修正

- 两端最大上下文均为 **262144**，输入和输出共用此上限。已离线分析的 AgentX 数据最大输入+输出预算 257523，旧 200k 配置不足。
- P 每批最多 8192 tokens，D 256；max-num-seqs=8，显存比例 0.93，chunked prefill 开启，block-size=16。
- NIXL producer/consumer，KV 传输失败策略 `fail`，不允许悄悄回退重算。
- MTP 关闭、APC 关闭、eager 模式。当前为功能基线，不是吞吐最优配置，不能直接与开启缓存的 DP2 成绩作公平比较。
- **必须设置 `PYTORCH_MLU_ALLOC_CONF=expandable_segments:False`**。CNIXL 1.2.3 在实际启动中明确报 `VMM is unsupported in CNIXL`，原单节点的 True 设置不能沿用。
- **必须按节点选择有效 RDMA 端口**，见 `cluster.env`。launcher 使用 mlx5_0–7；worker 使用 mlx5_0、2–8。两边对应 net1–8，但 mlx5 编号不同。使用 `UCX_IB_GID_INDEX=7`，本实例对应 IPv4 RoCE v2；启动前检查映射和类型。
- 不使用 `UCX_NET_DEVICES=all`：实际 Decode 启动误选了容器中不可用的 mlx5_8，出现 `ibv_create_ah ... No such device` 并在 NIXL 注册时崩溃。限定有效端口后，launcher 八卡的小内存注册探针全部成功；完整 P/D 验收另见末尾。
- 平台重建后重新核对主机名、IP、netdev/GID，不能沿用本实例的设备编号。

## 启动与调用

先确认旧服务退出、没有正在运行的压测且两边八卡空闲。脚本会检查卡占用、进程、端口、主机/IP，并通过 flock 防止同角色重复启动。它不会自动停止其他服务。

两端使用同一个新的 RUN_ID。示例在各自节点登录 shell 中执行；不要在现有实例运行时再次执行。**所有启动命令（任一角色及 Router）都必须带 `ALLOW_LAUNCHER_PD=1` 前缀**——入口门禁，表示操作者已确认该节点空闲、可用于 PD；该变量逐次生效，不会留存。

```bash
# launcher
ALLOW_LAUNCHER_PD=1 bash -l /workspace/volume/data/dy/bench/package/pd_glm53/start.sh prefill <NEW_RUN_ID>
# worker
ALLOW_LAUNCHER_PD=1 bash -l /workspace/volume/data/dy/bench/package/pd_glm53/start.sh decode <NEW_RUN_ID>
# 两端 /health 成功后，在 launcher 启动 Router
ALLOW_LAUNCHER_PD=1 bash -l /workspace/volume/data/dy/bench/package/pd_glm53/router.sh <NEW_RUN_ID>
```

需要后台保持时，使用 `nohup ... > "$PD_ROOT/<唯一文件名>.launch.log" 2>&1 < /dev/null &`。Router 二进制沿用已验证的 v0.1.15，SHA256 `2ee688193e800ac5a32eacb3dd12440ab49b31eb73b08a8ea80ff79aefe28e06`，从原 5.2 部署包复制到本包 `bin/`，不进入 Git。

```bash
curl http://10.8.174.126:8300/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"glm-5.3","messages":[{"role":"user","content":"计算17+25，只输出数字结果。"}],"temperature":0,"max_tokens":256,"reasoning_effort":"low","chat_template_kwargs":{"reasoning_effort":"low","clear_thinking":true}}'
```

GLM-5.3 模板不读取 `enable_thinking=false`，不可用它关闭思考。模型模板使用 `reasoning_effort=low/high/max`；需要分离思考内容时同时使用正确的 glm45 解析器。low 的 reasoning 允许为空。

**Router v0.1.15 的顶层 reasoning_effort 只接受 low/medium/high。** 使用 GLM `max` 时，省略顶层 reasoning_effort，仅传 `"chat_template_kwargs":{"reasoning_effort":"max","clear_thinking":true}`。已实测通过，并返回独立 reasoning 字段。不要同时传顶层 high：当前 vLLM 会用非空顶层值覆盖模板参数。原始顶层 max 的 422 响应保存在首轮验收目录，属于 Router 参数校验失败。

本地访问可用 `ssh -N -L 8300:10.8.174.126:8300 hwj-launcher`，然后访问 `http://127.0.0.1:8300/v1`。这些地址仅用于当前集群/SSH 通道，未配置公网入口或访问认证。

停止时先排空 Router 与两端请求，再根据当次目录的 PID 和 `/proc/<pid>/cmdline` 核实进程身份，向对应进程发送 TERM。启动过程中 API 退出不一定立即终止其所有加载子进程，须复查进程、端口和 cnmon；禁止按历史 PID 或使用全局 pkill 清理。

## 验收与历史

`verify.py --root <新的证据目录>` 通过 Router 验证非流式、SSE 与 max 思考请求，保存原始请求/响应、P/D 前后指标；要求 Decode 有非零 NIXL 传输字节、外部 KV tokens，且传输失败计数无增长。`--long` 单独生成接近 258000 tokens 的长输入，并要求服务 usage 与离线模板分词完全一致。

历史 `runs/initial/` 保留 VMM 失败记录，`runs/native_alloc/` 保留关闭 VMM 后 P 成功、D 选错 RDMA 端口失败的记录。P 为统一 RDMA 参数做过计划重启，原因和排空指标存于当次目录。端口预检已允许 SO_REUSEADDR，避免把已退出服务的 TIME_WAIT 误当成端口仍被监听。

当前运行编号 `rdma_filtered`，P/D/Router 均通过健康检查。实际 KV 容量 P=335312、D=349008 tokens；`max-num-seqs=8` 是调度上限，不表示能同时驻留 8 条 262k 请求。

短请求最终验收 `verification/smoke_v2/`：普通计算输出 42；SSE 输出 21 且有 DONE；max 思考输出 156，reasoning 与 content 分离。3/3 通过，每条 Decode 外部 KV tokens 均等于完整输入（22、23、21），本地 prefill 计算增量为零。每条 NIXL 共 8 次传输，按 8 个 rank 汇总的传输量为 28114944 字节，失败、通知失败、KV 过期计数增量均为零。首次推理含 JIT 开销，功能验收用时不能作为压测性能结论。

长输入最终验收 `verification/long258k_v2/`：**257991 输入 tokens + 7 输出 tokens**，返回 `青松7319`，finish_reason=stop，实际输入 usage 与离线模板分词完全一致。Decode 全部 257991 输入 tokens 来自外部 KV，本地计算输入增量为零；8 个 rank 合计 NIXL 传输计数 226676736000 字节（约 211.11 GiB，rank 汇总口径），全部成功，失败/通知失败/过期增量均为零。单请求端到端 74.19 秒，包含 Prefill、KV 传输及输出；不是并发压测成绩。

首轮 `verification/long258k/` 的验证脚本误将 Transformers 5 模板返回字典的长度当成 token 数，生成超长请求后被服务以 HTTP 400 拒绝；未通过、未混入最终结果。已改为渲染模板文本再编码，增加 `256000 < tokens <= 258000` 断言，修正后的请求完成上述验收。首轮短请求 `verification/smoke_rdma_filtered/` 为前两项通过、顶层 max 被 Router 422 拒绝；最终三项全通过的是 `smoke_v2/`。

最终 `verification/final/` 保存 P/D/Router 的健康和模型响应、两端指标和 cnmon。三端健康均为 200，P/D 请求队列已排空。运行 PID 是历史快照：P API 25897、D API 242641、Router 33929；操作前须重新核查。

尚未执行 AgentX 正式压测、长输出、并发容量测试或长期稳定性测试。当前 APC 关闭，后续 AgentX 缓存收益对照前须单独验证并启用合适的缓存配置；262144 是长度上限，不能据此承诺高并发下长请求的 SLA。
