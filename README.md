# k3d-nvidia：单机多 GPU 构建多节点 GPU Kubernetes 集群

在**一台多 GPU 物理机**（或 LXD 容器）上，基于 [k3d](https://k3d.io/)（k3s in Docker）快速拉起一个**多节点 Kubernetes 集群**，并让每个"节点"各自绑定**独立的 GPU 子集**，用于模拟真实多机 GPU 集群（LLM 推理/训练环境验证、调度策略测试等），支持秒级删除重建。

## 核心特性

- **多节点模拟**：1 个 Server + N 个 Agent，全部以 Docker 容器形式运行，共享宿主机 NVIDIA 驱动。
- **GPU 按节点切分**：通过"拆分 NVIDIA Device Plugin DaemonSet + 环境变量覆盖"的方式，让 agent-0 只见 GPU 0,1、agent-1 只见 GPU 2,3、agent-2 只见 GPU 4,5（方案可自定义）。
- **合并基础镜像**：`rancher/k3s ⊕ nvidia/cuda ⊕ nvidia-container-toolkit` 三合一，k3s 节点容器内自带 nvidia runtime，Pod 可直接用 `runtimeClassName: nvidia`。
- **离线/半离线镜像分发**：双通道 —— 离线 tar 挂载导入（`save_images.sh` + `load_image.sh`）与 k3d 本地 Registry（`k3d-registry.localhost:5000`，集群删除后镜像不丢）。
- **可选 LXD 层**：`lxd-lxc/` 提供脚本，先在物理机上创建若干 LXC 容器（各自透传指定 GPU、限制 CPU/内存），再把 k3d 集群跑在 LXC 里，实现更强的隔离。

## 架构总览

```
┌────────────────────────── 物理机 (Ubuntu 22.04 + NVIDIA Driver + Docker) ──────────────────────────┐
│                                                                                                    │
│  ┌─────────────── 可选 LXD 层：LXC 容器 k8s-node-0..5（各自透传 1 块 GPU，限 CPU/内存）────────────┐ │
│  │                                                                                                │ │
│  │   ┌────────────────── Docker / nvidia-container-toolkit ─────────────────────────────────┐     │ │
│  │   │                                                                                     │     │ │
│  │   │   k3d-serverlb ── k3d-<cluster>-server-0 ── k3d-<cluster>-agent-0 ── agent-1 ── …    │     │ │
│  │   │   (负载均衡)         (k3s Server, 全 GPU 可见)   (k3s Agent, 各节点全 GPU 可见)       │     │ │
│  │   │                              │                        │                              │     │ │
│  │   │                    /var/lib/rancher/k3s/server/manifests/  (device plugin 自动部署)  │     │ │
│  │   │                              │                        │                              │     │ │
│  │   │              ┌───────────────┴────────────────────────┴───────────────┐              │     │ │
│  │   │              │  NVIDIA Device Plugin（每节点一个 DaemonSet，按节点覆盖  │              │     │ │
│  │   │              │  NVIDIA_VISIBLE_DEVICES=0,1 / 2,3 / 4,5 → 上报切分后的  │              │     │ │
│  │   │              │  nvidia.com/gpu 资源）                                  │              │     │ │
│  │   │              └─────────────────────────────────────────────────────────┘              │     │ │
│  │   │                        │  Pods (runtimeClassName: nvidia, nvidia.com/gpu: 1)         │     │ │
│  │   └───────────────────────────────────────────────────────────────────────────────────────┘     │ │
│  └────────────────────────────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

详细设计原理见 [docs/01-architecture.md](docs/01-architecture.md)。

## 快速开始

> 完整前置条件见 [docs/02-environment.md](docs/02-environment.md)（宿主机需有：NVIDIA 驱动、Docker + nvidia-container-toolkit、k3d、kubectl）。

### Step 1：构建三合一基础镜像

```bash
# 可通过环境变量覆盖 K3S_TAG / CUDA_TAG / IMAGE_REGISTRY / IMAGE_REPOSITORY
IMAGE_REGISTRY=nlc sh ./build.sh
# 产出镜像：nlc/rancher/k3s:v1.33.4-k3s1-cuda-12.2.2-cudnn8-runtime-ubuntu22.04
```

### Step 2：准备离线镜像（首次使用）

```bash
# 在有网的机器上导出 k3s 内置组件 + device plugin 镜像
sh ./save_images.sh
# 把 k3d-base-images.tar 放到挂载目录（默认 /home/zhangpengyi/k3d-data/，可自行修改脚本）
```

### Step 3：创建集群 + 部署 GPU 插件 + 跑 GPU 测试

```bash
sh ./create_cluster.sh     # 集群 llmcluster（离线镜像通道，全流程自动）
# 或
sh ./create_cluster_dev.sh  # 集群 llmclusterdev（本地 registry 通道，只建集群，其余步骤按需手动）
```

### Step 4：验证

```bash
# 节点 GPU 已按 0,1 / 2,3 / 4,5 切分上报
kubectl describe node k3d-llmcluster-agent-0 | grep nvidia.com/gpu
# CUDA 测试 Pod（cuda-vector-add-loop3 由脚本自动部署）
kubectl logs -n kube-system cuda-vector-add-loop3 -f
```

预期输出 `Test PASSED` 循环打印，即 GPU 在 k3d 节点内可用。

## 环境要求摘要

| 组件 | 版本（当前仓库验证过） | 说明 |
| --- | --- | --- |
| 操作系统 | Ubuntu 22.04 | 宿主机 / LXC 均为 22.04 |
| NVIDIA 驱动 | 宿主机安装，LXC 内装 `nvidia-utils-535-server` | 驱动只在宿主机，容器内透传使用 |
| Docker | docker-ce（含 containerd.io） | 宿主机或 LXC 内 |
| nvidia-container-toolkit | stable 源最新 | Docker 与 k3s 镜像内各装一份 |
| k3d | 最新（`install_k3d.sh` 自动装） | 需支持 `--gpus` |
| kubectl | 任意较新版本 | k3d 会自动写 kubeconfig |
| k3s | v1.33.4-k3s1（合并进自定义镜像） | CUDA 12.2.2 + cuDNN 8 runtime |

## 目录结构

```
k3d-nvidia/
├── README.md                        # 本文件：项目入口
├── docs/                            # ★ 交付文档（按序阅读）
│   ├── 01-architecture.md           # 架构设计与核心原理
│   ├── 02-environment.md            # 环境准备（物理机直装 / LXD 两条路径）
│   ├── 03-image-build.md            # 三合一镜像构建 + 离线镜像准备
│   ├── 04-cluster.md                # 集群创建、三种集群配置、本地 Registry
│   ├── 05-gpu-split.md              # ★ GPU 按节点切分（核心 HACK）
│   ├── 06-verify-ops.md             # 验证、测试应用与日常运维
│   └── 07-faq.md                    # 踩坑实录与 FAQ
│
├── Dockerfile / build.sh            # 三合一基础镜像构建
├── save_images.sh                   # 导出 k3s 内置组件离线镜像包
├── load_image.sh / import.sh        # 节点容器内导入离线镜像
│
├── k3d-cluster-example.yaml         # 集群 llmcluster 配置（离线镜像通道）
├── k3d-cluster-dev.yaml             # 集群 llmclusterdev 配置（registry 通道）
├── k3d-cluster-test.yaml            # 集群 llmclustertest 配置（registry 通道）
├── create_cluster.sh                # 一键创建 llmcluster（全流程）
├── create_cluster_dev.sh            # 一键创建 llmclusterdev
├── create_cluster_test.sh           # 一键创建 llmclustertest
│
├── device-plugin-daemonset.yaml                     # device plugin 单 DaemonSet 基础版
├── device-plugin-daemonset-agents-3.yaml            # ★ llmcluster 用：按节点切分（拆 3 个 DS）
├── device-plugin-daemonset-agents-dev-3.yaml        # ★ llmclusterdev 用（镜像走本地 registry）
├── device-plugin-daemonset-multiple.yaml            # gputest 用：含 server-0 共 4 个 DS
├── device-plugin-daemonset-node{0,1,2}.yaml         # 单节点 DS（调试用）
├── device-plugin-daemonset-server0-configmap.yaml   # ConfigMap 方式（有局限，见 05 文档）
├── nvidia-configs.yaml                              # device plugin ConfigMap 分组配置
│
├── cuda-vector-add.yaml             # GPU 测试 Pod（单次）
├── cuda-vector-add-loop{,2,3,4}.yaml # GPU 测试 Pod（循环压测；loop4 镜像走 registry）
├── cuda-vector-add-2.yaml / -3.yaml  # 同上的中间版本
│
├── k3d-example/                     # CPU 侧最小示例：nginx + NodePort + 端口映射拓扑说明
│   ├── README.md                    # 端口映射拓扑图（8085/8087/8443 → LB → Service）
│   ├── deploy-nginx.yaml / nginx-svc-nodeport.yaml
│   ├── k3d-cluster-example.yaml     # 早期无 GPU 的纯 k3d 示例配置
│   └── registries.yaml              # daocloud 镜像加速配置示例
│
├── manifests/                       # k3s v1.33.4 内置组件清单（coredns/traefik/metrics-server 等）
│                                    #   用途：对照 save_images.sh 打离线包；排查组件问题
├── lxd-lxc/                         # 可选 LXD 层脚本（详见 docs/02）
│   ├── create.sh / add_gpu.sh / fix_nvidia.sh
│   ├── install_docker.sh / install_nvidia.sh / install_k3d.sh
│   └── lxc.ref.txt                  # 历史操作日志（参考）
│
├── instructions_ref.md              # 运维命令速查（历史笔记，已整理进 docs/06）
├── registry.md                      # 本地 Registry 方案笔记（历史笔记，已整理进 docs/04、07）
├── reference.md / lxc.ref.txt / 1.txt~4.txt   # ★ 历史命令日志，仅供溯源，交付时可删除
└── load_app_images.sh               # （空文件，占位）
```

## 文档索引

| 文档 | 内容 | 适合谁 |
| --- | --- | --- |
| [01-architecture](docs/01-architecture.md) | 分层架构、GPU 数据通路、为什么这样设计 | 想理解原理的人 |
| [02-environment](docs/02-environment.md) | 宿主机/LXD 环境准备、依赖安装、验证 | 第一次搭建的人 |
| [03-image-build](docs/03-image-build.md) | Dockerfile 解析、build.sh 用法、离线镜像打包 | 维护镜像的人 |
| [04-cluster](docs/04-cluster.md) | 三种集群配置对比、创建流程、本地 Registry | 使用集群的人 |
| [05-gpu-split](docs/05-gpu-split.md) | **GPU 按节点切分原理与部署（核心）** | 所有人必读 |
| [06-verify-ops](docs/06-verify-ops.md) | 验证步骤、测试应用、日常运维命令 | 使用集群的人 |
| [07-faq](docs/07-faq.md) | 踩坑实录（GPU 约束失效、registry 失效、磁盘驱逐…） | 遇到问题时 |

## 已知注意事项（先读为敬）

1. **GPU 切分不能在 k3d 创建层做**：`--gpus`/`CUDA_VISIBLE_DEVICES`/`NVIDIA_VISIBLE_DEVICES` 对 k3d 节点容器**无效（全部透传）**，切分必须在 device plugin DaemonSet 的 env 里做 —— 见 [docs/05](docs/05-gpu-split.md)。
2. **新版 k3s 忽略 `registries.yaml` 镜像加速配置**：containerd 已改为 `certs.d` hosts.toml 模式，需挂载 certs.d 目录，见 [docs/07 FAQ-3](docs/07-faq.md)。
3. **k3d 节点容器磁盘小**，容易触发磁盘压力驱逐：创建时已放宽 `eviction-hard`，测试 Pod 也带了容忍度与 `system-node-critical`，自己部署应用时建议照抄。
4. **集群删除即镜像全丢**（离线导入的也一样），建议使用本地 Registry 常驻镜像，见 [docs/04](docs/04-cluster.md)。
