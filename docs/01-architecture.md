# 01 · 架构设计与核心原理

> 本文回答"这套东西为什么长这样"。只想要操作步骤可跳到 [02-environment](02-environment.md)。

## 1. 要解决的问题

一台物理机上插了多块 GPU（如 6 × A100），但我们需要一个**多节点 GPU 集群**来：

- 验证多机 LLM 推理/训练的部署编排（每个"节点"独立的一组 GPU）；
- 测试 GPU 调度策略（节点维度分配、显存碎片等）；
- 随时**秒级重置**整个环境（真机集群做不到）。

直接用 k3d 建集群有两个障碍，本仓库的核心工作就是解决它们：

| 障碍 | 解决方案 |
| --- | --- |
| k3d 默认用 `rancher/k3s` 镜像，**不含 CUDA/NVIDIA runtime**，Pod 用不了 GPU | 自己构建 `k3s ⊕ cuda ⊕ nvidia-container-toolkit` **三合一镜像**（[03](03-image-build.md)） |
| k3d 节点容器能看到宿主机**全部 GPU**，无法按节点划分 GPU 归属 | **拆分 device plugin DaemonSet + 环境变量覆盖**，按节点上报各自的 GPU 子集（[05](05-gpu-split.md)） |

## 2. 分层架构

从下到上共四层（LXD 层可选）：

```
L0  物理机        NVIDIA 驱动 / nvidia-smi / Docker / nvidia-container-toolkit / k3d
                    │  （驱动只装这一层，向上全部透传共享）
L1  LXC 容器(可选) k8s-node-0..5，每个透传指定 GPU、限制 8C/64G
                    │  lxd-lxc/ 脚本负责；提供租户级隔离
L2  k3d 节点容器   k3d-<cluster>-server-0 / agent-N / serverlb（Docker 容器）
                    │  运行三合一镜像；内置 k3s + containerd(nvidia runtime)
L3  Pod           cuda-vector-add、nginx、device plugin 自身等
```

**驱动共享模型（关键）**：NVIDIA 内核驱动只存在于 L0。上层所有容器（LXC、k3d 节点、Pod）都不装驱动，只通过 `nvidia-container-toolkit` 把宿主机的 `libnvidia-ml.so`、`libcuda.so`、`nvidia-smi` 及 `/dev/nvidia*` 设备挂载/注入进来。因此：

- 宿主机升级驱动，所有上层同时生效；
- 三合一镜像里装的是 toolkit（用户态挂载工具），**不是**驱动 —— 这也是 Dockerfile 里 CUDA 基础镜像用 `runtime` 变体的原因。

## 3. GPU 数据通路

一个 Pod 申请到 GPU 的完整链路：

```
Pod (runtimeClassName: nvidia, resources.limits: nvidia.com/gpu: 1)
 │  ① RuntimeClass nvidia → handler: nvidia → containerd 的 nvidia runtime
 │     （由三合一镜像内 nvidia-ctk 配置，见 Dockerfile: nvidia-ctk runtime configure --runtime=containerd）
 ▼
k3d 节点容器内 containerd → 借助宿主机 toolkit 注入 libcuda/libnvidia-ml + /dev/nvidia*
 │  ② 设备插件向 kubelet 上报"本节点有多少 nvidia.com/gpu"
 ▼
NVIDIA Device Plugin Pod（每个 k3d 节点一个 DaemonSet 实例）
     env NVIDIA_VISIBLE_DEVICES=0,1   ← ★ 切分发生在这里（只有在这里设置才生效）
     扫描可见 GPU → 通过 /var/lib/kubelet/device-plugins 注册到 kubelet
```

对应本仓库的文件：

| 环节 | 文件 |
| --- | --- |
| ① RuntimeClass 定义 | 每个 `device-plugin-daemonset*.yaml` 头部（`kind: RuntimeClass, name: nvidia, handler: nvidia`） |
| ② 按节点切分 | `device-plugin-daemonset-agents-3.yaml`（3 个 DS，nodeSelector 各自锁定节点） |
| Pod 侧申请 | `cuda-vector-add*.yaml`（`runtimeClassName: nvidia` + `nvidia.com/gpu: 1`） |

## 4. 网络与端口模型

k3d 会为每个集群创建一个 docker network，并额外起一个 `k3d-<cluster>-serverlb` 负载均衡容器。宿主机端口都映射在 **serverlb** 上：

```
宿主机                          serverlb 容器                 K8s 集群内
localhost:8085 ──────────────▶ 80    ──▶ Traefik(Ingress)  ──▶ Service/Pod（需自建 Ingress 才通）
localhost:8087 ──────────────▶ 30080 ──▶ NodePort Service   ──▶ app-service-nodeport → nginx Pod
localhost:8443 ──────────────▶ 443   ──▶ Traefik(HTTPS)
localhost:6449 ──────────────────────▶ kube-apiserver（kubeAPI.hostPort，kubectl 走这里）
```

- **NodePort 路径**（8087→30080）是开箱即用的：`k3d-example/deploy-nginx.yaml` + `nginx-svc-nodeport.yaml`。
- **Ingress 路径**（8085→80→Traefik）需要再写 Ingress 资源才有意义，否则 404。
- 完整拓扑图见 [`k3d-example/README.md`](../k3d-example/README.md)。

三种集群的端口分配（避免同时运行时冲突）：

| 集群 | kubeAPI | LB:HTTP | LB:NodePort/L4 | LB:HTTPS |
| --- | --- | --- | --- | --- |
| llmcluster | 6449 | 8085→80 | 8087→30080 | 8443→443 |
| llmclusterdev | 6450 | 8180→80 | 8200→9200 | 9443→443 |
| llmclustertest | 6451 | 8181→8000 | 8201→9200 | 9444→8443 |

## 5. 镜像分发模型（双通道）

### 通道 A：离线 tar 挂载导入（`create_cluster.sh` 使用）

```
有网机器                       宿主机 k3d-data 目录                k3d 节点容器内
save_images.sh ─▶ k3d-base-images.tar ──(k3d --volume 挂载)──▶ /root/images/k3d-base-images.tar
                                                                    │ load_image.sh 等待 containerd.sock 就绪
                                                                    ▼
                                                        ctr -n k8s.io images import …
```

- `save_images.sh`：导出 k3s v1.33.4 全部内置组件（coredns、traefik、metrics-server、pause、busybox、klipper-lb、klipper-helm、local-path-provisioner）+ nvidia device plugin 镜像。清单依据就是仓库里的 `manifests/` 目录。
- `load_image.sh`：打进三合一镜像里（`COPY load_image.sh /load_image.sh`），等 `/run/k3s/containerd/containerd.sock` 出现后自动 import——因为**构建期 containerd 没起，无法在 Dockerfile 里 import**。
- 应用镜像（nginx、cuda-vector-add 的 tar）也放同一目录，创建后手动 `ctr import`。

### 通道 B：k3d 本地 Registry（`create_cluster_dev.sh` / `create_cluster_test.sh` 使用）

```
docker tag/push ─▶ registry 容器 k3d-registry.localhost:5000（独立于集群，常驻）
                          ▲
集群创建时 --registry-use ─┘  + 各 registry 的 mirror 指向它（见 k3d-cluster-dev.yaml registries.config）
```

- 集群删除重建后镜像**不丢**，秒级拉取；
- 大坑：新版 k3s 的 containerd 走 `certs.d` hosts.toml 模式，`registries.yaml` 的 mirror **不生效**，必须额外挂载 `containerd-certs` 目录（dev/test 脚本已带）。详见 [07 FAQ-3](07-faq.md)。

两条通道如何选：**一次性测试用 A（零依赖），长期反复重建用 B（一次推送永久使用）**。

## 6. 关键设计决策记录

| 决策 | 原因 |
| --- | --- |
| 集群创建用 `--gpus all` 而非按节点 `--gpus device=0,1` | 实测 k3d/DinD 层面的 GPU 约束**不生效（全部透传）**，遂把切分下沉到 device plugin 层（见 [05](05-gpu-split.md)、[07 FAQ-1](07-faq.md)） |
| 所有节点（含无 GPU 的 server）都注入 `NVIDIA_DRIVER_CAPABILITIES=all` | 否则 server 节点报 `LIBRARY_NOT_FOUND` 这种误导性错误；注入后报 `No device found`，符合预期（`k3d-cluster-example.yaml` 中注释） |
| device plugin 镜像在 dev/test 集群里写成 `k3d-registry.localhost:5000/nvcr.io/nvidia/...` | 集群处于半离线环境，统一从本地 registry 拉（含 nvcr.io 前缀路径，推 registry 时保留原始路径） |
| device plugin 用 `docker cp` 进 server 的 `server/manifests/` 目录 | k3s 的 auto-deploy 机制会自动 apply 该目录，无需集群外 kubectl，且随节点重建自动恢复 |
| 测试 Pod 放 `kube-system` + `system-node-critical` + disk-pressure 容忍 | k3d 节点容器磁盘小，容易被驱逐；详见 [07 FAQ-5](07-faq.md) |
| `eviction-hard=nodefs.available<100Mi` | 同上，放宽 kubelet 磁盘驱逐阈值 |

## 7. 下一步

- 搭环境 → [02-environment](02-environment.md)
- 构建镜像 → [03-image-build](03-image-build.md)
