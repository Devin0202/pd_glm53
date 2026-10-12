# GLM-5.3 PD 部署包（可配置 1PND）

2026-09-22 以 1P1D 在实例 `13esfga` 上完成跨节点验收。**2026-10-10 平台重建、节点从 2 个增加到 4 个**（1 launcher + 3 worker），本包改为拓扑数据驱动，可部署任意「M 个 Prefill + N 个 Decode」组合（已定义 `1p1d` / `1p3d` / `2p1d`），以及单机 standalone。

调用方注意：**实例名、节点 label、eth0 IP、`mlx5` 编号都会随平台重建一起变**（本文写作当天就重建了两次：`13esfga` → `jsso4o` → `u4f0c2`）。下表是当前实例的快照；实际取值以 `cluster.json` 为准，`init_check.py` 会自动校正它。

> **本次变更（2026-10-10）**
> - 拓扑数据化：节点清单在 `cluster.json`，每次启动用 `PD_TOPO` 显式声明本次用到哪些节点、谁是 P 谁是 D。脚本里不再有任何写死的节点名、IP 或角色映射。
> - `cluster.env` → `cluster.json`：由新增的 `topology.py` 统一解析（bash 解析表格太别扭）。`topology.py` 同时负责节点 label、角色校验、运行/锁目录、以及给验收用的 `topology.json`。
> - 修掉多 decode 下的两个硬缺陷：**锁**原来按角色命名（`locks/decode.lock`），3 个 decode 节点在同一共享盘上会互抢，现按节点键控；**运行目录**原来都写 `runs/<ID>/decode/`，现带节点 label。
> - 缓存目录按节点隔离：三个 decode 节点共享同一文件系统，原 `cache/decode/<profile>` 会被并发写。
> - `verify.py` 不再硬编码地址，改读 `router.sh` 落下的 `topology.json`，并新增「恰好一个 decode 服务本次请求」的归属断言。
>
> **当前状态**：启动与验收流程已在真机跑通——2026-10-10 的 1P3D（`runs/deploy_20261010_141242/`）、2026-10-12 的 2P1D（`runs/deploy_20261012_072044/`，两个 prefill 都实际承接了请求）。旧实例 `13esfga` 的验收结论保留在文末「历史」一节。

## 节点清单

| 角色 | 节点 label | eth0 | HTTP | NIXL 侧通道 | 有效 RDMA 设备（GID 7） |
|---|---|---|---|---|---|
| Prefill / Router | `u4f0c2-launcher-0` | 10.9.101.152 | 8100 | 5610 | mlx5_0–7 |
| Decode | `u4f0c2-worker-0` | 10.8.174.116 | 8200 | 5710 | mlx5_0–7 |
| Decode | `u4f0c2-worker-1` | 10.8.114.71 | 8200 | 5710 | mlx5_0–7 |
| Decode | `u4f0c2-worker-2` | 10.9.63.167 | 8200 | 5710 | mlx5_2–9 |

节点 label = `hostname -s` 去掉平台前缀后、从实例名起算的那一段（`notebook-devenviron-0920-100724-u4f0c2-worker-0` → `u4f0c2-worker-0`）。四节点各 8 张 MLU590-M9（每卡 96 GiB、共 128 核），共同挂载 `$PD_ROOT`，权重直读 `/workspace/volume/data/GLM-5.3-BF16-W4A8`（W4A8 量化，282 个分片，未复制）。运行环境 vLLM 0.25.1 / vllm_mlu 0.16.0.pt212、CNIXL 1.2.3。

**端口在各节点同角色上相同**（三个 decode 都用 8200/5710）：每节点只跑一个引擎，端口属于各自网络命名空间，互不冲突。前提是**不要把同角色的两个引擎放在同一节点**——那需要各自不同的端口和侧通道。

`$PD_ROOT=/workspace/volume/data/dy/bench`。部署包在 `$PD_ROOT/package/pd_glm53`；每次启动写 `runs/<RUN_ID>/<role>-<label>/`（standalone 与 router 无 label 后缀），绝不覆盖旧运行目录；缓存按节点隔离在 `cache/<profile>/<role>-<label>/`。

## 配置：`cluster.json`

```json
{
  "instance": "u4f0c2",
  "pd_root": "/workspace/volume/data/dy/bench",
  "nodes": [{"label": "u4f0c2-worker-0", "ip": "10.8.174.116", "ucx": "mlx5_0:1,mlx5_1:1,..."}],
  "ports": {"prefill_http": 8100, "decode_http": 8200, "router": 8300,
            "prefill_side": 5610, "decode_side": 5710},
  "ucx_ib_gid_index": 7
}
```

- **新增节点**：在 `nodes` 里加一条即可，脚本不用改。
- `ucx` 只列**容器内可见**的 RDMA 端口，且**按节点**给出——即使每台机器都暴露 net1–net8，`mlx5` 编号也可能不同（worker-1 就与其余三台不同）。
- **平台重建后必须重新核对整张表**：实例名、`hostname -s`、eth0 IP、`mlx5` 编号会同时变化。`topology.py` 用 `instance` 做陈旧性校验——hostname 里找不到实例名、或 label 不在清单里，启动会直接失败并提示重建。

导出某节点的有效设备（RoCE v2 + IPv4）：

```bash
python3 - <<'PY'
import glob,os
from pathlib import Path
for dev in sorted(glob.glob('/sys/class/infiniband/mlx5_*'),key=lambda p:int(p.split('_')[-1])):
    root=Path(dev)/'ports'/'1'
    for g in sorted((root/'gids').glob('*'),key=lambda p:int(p.name)):
        ndev=(root/'gid_attrs'/'ndevs'/g.name).read_text().strip()
        typ=(root/'gid_attrs'/'types'/g.name).read_text().strip()
        if typ=='RoCE v2' and ':ffff:' in g.read_text():
            print(os.path.basename(dev),f'gid{g.name}',ndev)
PY
```

## 检查节点占用与校正清单

启动前用 `init_check.py` 逐节点查 MLU、主机内存与 RoCE 状态。每行一个节点：GPU 状态 + 内存用量 + RoCE（MTU / 速率 / 链路）；只有异常（有占用卡、节点连不上、清单漂移、MTU 不一致、链路非 ACTIVE、端口数不足）才展开细节。

RoCE 一栏读的是**实际承载流量的 netdev**：MTU 不在 IB 端口上（RoCE 的 `ports/1/mtu` 为空），而在 `/sys/class/net/<netdev>/mtu`（本集群为 4192）。**MTU 不一致是最隐蔽的故障**——NIXL 按路径 MTU 决定传输大小，8 个端口里若有一个是 1500 而其余是 4192，那个 rank 会静默降速甚至失败，不会报错，因此不一致会被单独列出（只列偏离多数的端口，不把 8 个全铺开）。

```bash
python3 init_check.py                                    # cluster.json 里的所有节点
python3 init_check.py --node u4f0c2-worker-1 --node u4f0c2-worker-2
python3 init_check.py --no-update                        # 只报告漂移，不写回
```

**连接顺序**：先试 `cluster.json` 里记录的 eth0 IP；连不上才回退到 `~/.ssh/config` 里同名条目（按 label 的角色后缀匹配，例如 `worker-0`——平台重建会同时改掉两边的前缀，后缀是唯一稳定的部分）。

**回写 `cluster.json`**：无论用哪条路径连上，节点都会自报 hostname、eth0 IP 和有效 RoCE 设备列表；三者与清单不符时会**自动改正 `cluster.json`**（含实例名与 label），并逐条打印改了什么。这正是平台重建后的常规操作：直接跑一次即可，不必手工重导设备编号。不想要这个副作用就加 `--no-update`，它只报告不改。

退出码 `0` 全部空闲、`1` 至少一张卡有占用、`2` 至少一个节点查不到（状态未知）。**`2` 不等于空闲**：查不到就无法确认，不能当作可用。卡数不是 8 张或显存字段读不出来同样判为 UNKNOWN，避免把残缺读数误读成空闲。

## 启动与调用

`PD_TOPO` **必填、无默认**，本次运行涉及的每条启动命令都要带同一个值：

```bash
PD_TOPO="prefill=u4f0c2-launcher-0 decode=u4f0c2-worker-0,u4f0c2-worker-1,u4f0c2-worker-2"
```

先确认旧服务退出、没有正在运行的压测且相关节点八卡空闲。脚本会校验节点角色、卡占用、进程、端口、主机/IP，并用 flock 防止同节点重复启动；它不会自动停止其他服务。**所有启动命令（任一角色及 Router）都必须带 `ALLOW_LAUNCHER_PD=1`** ——入口门禁，表示操作者已确认该节点空闲、可用于 PD；该变量逐次生效，不留存。

1P3D 启动序列（在各自节点的登录 shell 中执行）：

```bash
# launcher-0
PD_TOPO="prefill=u4f0c2-launcher-0 decode=u4f0c2-worker-0,u4f0c2-worker-1,u4f0c2-worker-2" ALLOW_LAUNCHER_PD=1 \
  bash -l /workspace/volume/data/dy/bench/package/pd_glm53/start.sh prefill <NEW_RUN_ID>
# worker-0 / worker-1 / worker-2 各一次（同一条命令，脚本按本机 label 判定 decode 身份与目录）
PD_TOPO="prefill=u4f0c2-launcher-0 decode=u4f0c2-worker-0,u4f0c2-worker-1,u4f0c2-worker-2" ALLOW_LAUNCHER_PD=1 \
  bash -l /workspace/volume/data/dy/bench/package/pd_glm53/start.sh decode <NEW_RUN_ID>
# 四端 /health 均 200 后，在 launcher-0 启动 Router
PD_TOPO="prefill=u4f0c2-launcher-0 decode=u4f0c2-worker-0,u4f0c2-worker-1,u4f0c2-worker-2" ALLOW_LAUNCHER_PD=1 \
  bash -l /workspace/volume/data/dy/bench/package/pd_glm53/router.sh <NEW_RUN_ID>
```

需要后台保持时用 `nohup ... > "$PD_ROOT/<唯一文件名>.launch.log" 2>&1 < /dev/null &`。Router 二进制沿用已验证的 v0.1.15，SHA256 `2ee688193e800ac5a32eacb3dd12440ab49b31eb73b08a8ea80ff79aefe28e06`，位于本包 `bin/`，不进入 Git。Router 的 `--prefill`/`--decode` 是**可重复标志**（逗号分隔不会被切分），`router.sh` 按拓扑逐个展开。

对外调用 Router：`http://10.9.101.152:8300/v1`，model=`glm-5.3`。不要直接调用单个 Decode 来代替 PD 验收。

### 单节点（standalone）模式

用于非 PD 的对照测试/调试：在拓扑的 prefill 节点上启动一个常规 vLLM 实例（`configs/standalone.yaml`，与 prefill 相同但去掉了 NIXL connector）：

```bash
PD_TOPO="prefill=u4f0c2-launcher-0 decode=" ALLOW_LAUNCHER_PD=1 \
  bash -l /workspace/volume/data/dy/bench/package/pd_glm53/start.sh standalone <RUN_ID>
```

两种调用方式：直连引擎 `http://10.9.101.152:8100/v1`；或让 Router 以普通反代模式挂到 8300（`router.sh <RUN_ID> standalone`），客户端入口与 PD 模式一致，两种模式对照时代理开销相同。standalone 与 PD 互斥：卡占用/进程检查会拒绝重复启动，节点锁也保证同一节点上两者不能并存。运行记录在 `runs/<RUN_ID>/standalone/`，Router 仍在 `runs/<RUN_ID>/router/`。

```bash
curl http://10.9.101.152:8300/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"glm-5.3","messages":[{"role":"user","content":"计算17+25，只输出数字结果。"}],"temperature":0,"max_tokens":256,"reasoning_effort":"low","chat_template_kwargs":{"reasoning_effort":"low","clear_thinking":true}}'
```

GLM-5.3 模板不读取 `enable_thinking=false`，不可用它关闭思考。模型模板使用 `reasoning_effort=low/high/max`；需要分离思考内容时同时使用正确的 glm45 解析器。low 的 reasoning 允许为空。

**Router v0.1.15 的顶层 reasoning_effort 只接受 low/medium/high。** 使用 GLM `max` 时，省略顶层 reasoning_effort，仅传 `"chat_template_kwargs":{"reasoning_effort":"max","clear_thinking":true}`。不要同时传顶层 high：当前 vLLM 会用非空顶层值覆盖模板参数。

本地访问可用 `ssh -N -L 8300:10.9.101.152:8300 <launcher 主机别名>`，然后访问 `http://127.0.0.1:8300/v1`。这些地址仅用于当前集群/SSH 通道，未配置公网入口或访问认证。

停止见下节「停止」。禁止按历史 PID 或使用全局 pkill 清理。

## 停止

`stop.sh` 与 `start.sh` 对称：**在哪个节点启动，就在哪个节点停止**，用同一个 `RUN_ID`。

```bash
# 在启动过引擎的每个节点各执行一次（含跑 Router 的 prefill 节点）
bash -l /workspace/volume/data/dy/bench/package/pd_glm53/stop.sh <RUN_ID>
# 只停其一
bash -l .../stop.sh <RUN_ID> router      # 只停 Router
bash -l .../stop.sh <RUN_ID> engine      # 只停本节点引擎
```

- **顺序**：先 TERM Router（不再有新请求进到引擎），再轮询本节点引擎的 `vllm:num_requests_running` 直到为 0，然后才 TERM 引擎。
- 默认 120s 内没排空就**只报告、不杀**（`--drain-timeout` 可调）；确认要强停加 `--force`。停 Router 会切断在途请求的客户端连接，所以排空的等待放在 Router 之后、引擎之前。
- **绝不按名字或历史 PID 杀进程**：`server.pid` / `router.pid` 里的 PID 先与 `/proc/<pid>/cmdline` 比对——引擎须同时含 `vllm`、`serve` 和本次 run 的 config 路径，Router 须含 `vllm-router`；比对不过就拒绝执行并打印现场。PID 被系统复用也不会误杀。
- Router 的 pid 文件在共享盘上，其 PID 只在本节点有意义：脚本比对 `topology.json` 里的 router IP，不在本机就提示去对应节点停。
- 结束后报告三项：进程是否退出、端口是否释放、八卡是否已归零。若仍有本次 run 的子进程存活（父进程退出不保证子进程全退），**只列出 PID 供人工判断，不做自动清理**。
- 退出码 `0` 正常、`1` 有残留进程或等待超时、`2` 拒绝执行或队列未排空。
- 只有四个节点都执行过 `stop.sh`，整组才算停干净。
- 停止**不需要** `ALLOW_LAUNCHER_PD`：那是启动门禁，任何时刻都应能停下来。

## 验收

```bash
python3 verify.py --topology "$PD_ROOT/runs/<RUN_ID>/router/topology.json" --root "$PD_ROOT/evidence/<RUN_ID>_smoke"
```

`topology.json` 由 `router.sh` 在启动时写入，记录本次 router 实际接线的 P/D 端点，是验收的唯一地址来源。脚本通过 Router 验证非流式、SSE 与 max 思考请求，保存原始请求/响应与每个引擎的前后指标。

PD 模式的判定是**归属式**的：`round_robin` 把每个请求只发给一个 decode，因此每个 case 必须**恰好有一个** decode 出现非零 NIXL 传输；该节点还须有外部 KV tokens，且所有引擎的失败/过期计数无增长。`round_robin` 下不能假设第 k 个 case 命中第 k 个 decode，`results.json` 的 `served_by` 记录实际服务节点。零个 decode 有传输说明 PD 没发生，多于一个说明归属不明（可能是上一请求的残留传输，或发生了重试），两种情况都会判定失败。

`--long` 单独生成接近 258000 tokens 的长输入，并要求服务 usage 与离线模板分词完全一致。standalone 拓扑（`topology.json` 的 `mode=standalone`）自动跳过 PD 断言，只校验响应正确性。

## 拓扑切换

拓扑在 `cluster.json` 的 `topologies` 里定义，**用角色后缀而非完整 label**
（平台重建只换实例前缀，后缀不变，所以定义不用跟着改）：

```json
"topologies": {
  "1p1d": {"prefill": ["launcher-0"],             "decode": ["worker-0"]},
  "1p3d": {"prefill": ["launcher-0"],             "decode": ["worker-0", "worker-1", "worker-2"]},
  "2p1d": {"prefill": ["launcher-0", "worker-0"], "decode": ["worker-1"]}
}
```

启动时按名字选，`PD_TOPO` 由 `deploy.sh` 解析，不必手写：

```bash
bash deploy.sh start --topo 2p1d      # 2 prefill + 1 decode，余下节点保持空闲
```

新增或调整方案只改 `cluster.json` 那几行，**脚本不用动**；分配建议「顺序取用、余下留空」，
各方案之间就不易互相踩（`2p1d` 占 3 台、`1p3d` 占 4 台）。仍可显式传 `PD_TOPO=...` 直接跑逐节点脚本。
换 RUN_ID 即可并存多组记录；缺席的节点不会被启动，Router 也会因健康检查失败而在启动前报错。

## 参数与兼容性修正

- 两端最大上下文均为 **262144**，输入和输出共用此上限。已离线分析的 AgentX 数据最大输入+输出预算 257523，旧 200k 配置不足。
- P 每批最多 8192 tokens，D 256；max-num-seqs=8，显存比例 0.93，chunked prefill 开启，block-size=16；MTP 关闭、APC 关闭、eager 模式。当前为功能基线，不是吞吐最优配置。
- NIXL producer/consumer，KV 传输失败策略 `fail`，不允许悄悄回退重算。
- **必须设置 `PYTORCH_MLU_ALLOC_CONF=expandable_segments:False`**：CNIXL 1.2.3 明确报 `VMM is unsupported in CNIXL`。
- **必须按节点选择有效 RDMA 端口**（见 `cluster.json`），启动前脚本会校验每个端口的 ndev/type（RoCE v2）与 IPv4 GID。不使用 `UCX_NET_DEVICES=all`：曾误选容器中不可用的 mlx5_8，出现 `ibv_create_ah ... No such device` 并在 NIXL 注册时崩溃。使用 `UCX_IB_GID_INDEX=7`。
- `configs/*.yaml` 是 JSON。`start.sh` 只在 `cluster.json` 的端口与文件内 `port` 不一致时做逐字替换，一致时文件字节不变。

## 风险与注意

- **锁按节点键控**是 1PND 能跑起来的前提；不要改回按角色命名。
- **平台重建后**先按 `hostname -s`、eth0 IP、`mlx5` 编号重新导出 `cluster.json`，再启动。`instance` 与 label 的双重校验会拦住复用旧清单。
- **缓存按节点隔离**意味着三个 decode 节点各自冷启动一次 JIT；若后续确认并发写共享缓存安全，可再改为共享以复用暖缓存。
- **Router 二进制 SHA 固定**，换二进制会 fail closed。
- 262144 是长度上限，不能据此承诺高并发下长请求的 SLA。

## 历史（旧实例 13esfga，2 节点 1P1D）

`$PD_ROOT/runs/test/` 是上一实例遗留的 standalone 冒烟记录（`run.info` 里 host 仍为 `13esfga-launcher-0`，退出码 130），仅作历史参考，不要按它的目录结构推断本次布局。旧实例的其余记录（`runs/initial/` 的 VMM 失败、`runs/native_alloc/` 的 RDMA 端口选错、`runs/rdma_filtered/` 的最终运行、以及 `verification/` 下的验收证据）镜像在旧部署树 `remote_sync/launcher/pd_glm53_20260922/`，不纳入本 Git 仓库。

旧实例的验收结论（供对照，不代表新实例已复现）：

- 短请求 `verification/smoke_v2/` 3/3 通过：普通计算输出 42；SSE 输出 21 且有 DONE；max 思考输出 156，reasoning 与 content 分离。每条 Decode 外部 KV tokens 等于完整输入（22、23、21），本地 prefill 计算增量为零；每条 NIXL 按 8 个 rank 汇总传输 28114944 字节，失败/通知失败/过期增量均为零。
- 长输入 `verification/long258k_v2/`：257991 输入 tokens + 7 输出，返回 `青松7319`，finish_reason=stop，usage 与离线模板分词完全一致；Decode 全部输入 tokens 来自外部 KV；8 rank 合计 NIXL 传输 226676736000 字节（约 211.11 GiB），无失败；单请求端到端 74.19 秒（含 Prefill、KV 传输与输出，不是并发压测成绩）。
- 实际 KV 容量 P=335312、D=349008 tokens；`max-num-seqs=8` 是调度上限，不表示能同时驻留 8 条 262k 请求。
- 尚未执行 AgentX 正式压测、长输出、并发容量测试或长期稳定性测试。
