---
name: pd-deploy
description: 启停 GLM-5.3 PD 服务（pd_glm53）。当用户要求部署/启动/停止/重启 PD 服务，或切换部署方案（1P1D / 2P1D / 1P3D）时使用。参数：<start|stop> [拓扑名，默认 1p3d]。
---

# PD 服务启停

在**任意一个节点**（通常是 launcher）执行即可：脚本会读 `cluster.json` 判断哪个节点扮演哪个角色，再通过 SSH 编排其他节点。各节点的 `start.sh` / `router.sh` / `stop.sh` 本身不变，仍是逐节点脚本。

```bash
# 启动（ALLOW_LAUNCHER_PD=1 是操作者确认门禁：确认这些节点空闲、可用于 PD）
ALLOW_LAUNCHER_PD=1 bash /workspace/volume/data/dy/bench/package/pd_glm53/deploy.sh start --topo 1p3d

# 停止
bash /workspace/volume/data/dy/bench/package/pd_glm53/deploy.sh stop --topo 1p3d
```

## 参数

| 参数 | 说明 |
|---|---|
| 第一个位置参数 | `start` 或 `stop` |
| 第二个位置参数 | 拓扑名，默认 `1p3d`；`cluster.json` 的 `topologies` 里定义，目前有 `1p3d`、`1p1d`、`2p1d` |
| `--run-id ID` | 指定运行编号；start 不填则按 UTC 时间生成，stop 不填则用包目录下的 `last_run` |
| `--force` | 仅 stop：跳过排空，直接停 |
| `--drain-timeout SECS` | 仅 stop：等待队列排空的秒数（默认 120） |
| `--health-timeout SECS` | 仅 start：等待每个引擎健康的秒数（默认 1800） |

## 执行要点

1. **start 先预检**：跑 `init_check.py`，任一节点有卡占用或不可达即拒绝启动，不会半启动；同时它会把 `cluster.json` 的实例名/label/IP/RoCE 设备校正到当前实况。
2. **加载耗时**：262k 上下文权重加载需要数分钟，`--health-timeout` 默认 1800s 足够；超时会打印对应节点的 launch 日志尾部。
3. **启动顺序**：所有引擎 → 各自 `/health` 200 → prefill 节点上的 Router。Router 就绪以 `/get_loads` 有 HTTP 响应判定（Router 自身不提供 `/health`）。
4. **stop 顺序**：先停 Router（不再有新请求进引擎），再逐节点停引擎（各自等本节点队列排空）。

## 完成后要做的事

冒烟测试（`glm_chat.sh` 的默认地址是旧实例的，**必须用 `ROUTER` 覆盖**）：

```bash
ROUTER=http://<router_ip>:8300 bash /workspace/volume/data/dy/plg/glm_chat.sh '你好'
```

向用户报告：拓扑名、run id、入口地址、冒烟结果（回答内容 + token 数）。
失败时给出日志路径：`$PD_ROOT/logs/<run_id>-<role>-<label>.launch.log`，以及引擎自己的 `$PD_ROOT/runs/<run_id>/<role>-<label>/server.log`。

## 相关文件

- `deploy.sh` — 本 skill 的驱动脚本（跨节点编排）
- `init_check.py` — 预检 + 校正清单
- `start.sh` / `router.sh` / `stop.sh` — 逐节点脚本，可单独使用
- `cluster.json` — 节点清单与 `topologies` 定义
