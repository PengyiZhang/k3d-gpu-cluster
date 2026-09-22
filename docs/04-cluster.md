# 04 · 创建集群与本地 Registry

本文涉及文件：`create_cluster.sh`、`create_cluster_dev.sh`、`create_cluster_test.sh`、`k3d-cluster-example.yaml`、`k3d-cluster-dev.yaml`、`k3d-cluster-test.yaml`、`registry.md`（历史笔记）。

> 前置：三合一镜像已构建（[03](03-image-build.md)），离线 tar 或本地 registry 已就绪。

## 1. 三种集群一览

| | `create_cluster.sh` | `create_cluster_dev.sh` | `create_cluster_test.sh` |
| --- | --- | --- | --- |
| 集群名 | `llmcluster` | `llmclusterdev` | `llmclustertest` |
| 配置文件 | k3d-cluster-example.yaml | k3d-cluster-dev.yaml | k3d-cluster-test.yaml |
| kubeAPI 端口 | 6449 | 6450 | 6451 |
| 镜像通道 | **离线 tar 挂载导入** | **本地 registry** | **本地 registry** |
| docker network | 默认（k3d 自建） | 复用 `k3d-llmcluster` | 复用 `k3d-llmcluster` |
| 挂载 | 仅 k3d-data→/root/images | 额外挂载 `containerd-certs`→certs.d | 同 dev |
| 脚本自动化程度 | **全流程自动**（建集群→导镜像→nginx→GPU 插件→CUDA 测试） | 仅创建集群，后续步骤注释保留手动执行 | 同 dev |

建议：第一次交付/验收用 `create_cluster.sh`（一条命令到底）；日常反复重建用 dev/test + registry。

## 2. create_cluster.sh 全流程解析

脚本默认 `NUM_AGENTS=3`（1 server + 3 agents = 4 节点）。命令行 `--agents 3` **会覆盖**配置文件里的 `agents: 2`，两者不一致时以脚本为准。

### Step 1 · 创建集群

```bash
k3d cluster create --config ./k3d-cluster-example.yaml \
    --image=nlc/rancher/k3s:v1.33.4-k3s1-cuda-12.2.2-cudnn8-runtime-ubuntu22.04 \
    --gpus all \
    --k3s-arg '--kubelet-arg=eviction-hard=nodefs.available<100Mi@all' \
    --volume /home/zhangpengyi/k3d-data/:/root/images@all \
    --agents 3
```

| 参数 | 含义 |
| --- | --- |
| `--image` | 三合一镜像（[03](03-image-build.md)） |
| `--gpus all` | 所有节点容器可见全部 GPU。**不要试图在这里按节点切分——实测无效**（见 [07 FAQ-1](07-faq.md)），切分在 [05](05-gpu-split.md) 做 |
| `--k3s-arg eviction-hard…` | 放宽 kubelet 磁盘驱逐（k3d 容器磁盘小），见 [07 FAQ-5](07-faq.md) |
| `--volume k3d-data:/root/images@all` | 把离线 tar 挂进所有节点（`@all` = server+agents） |

配置文件 `k3d-cluster-example.yaml` 里还有两个关键项：

```yaml
env:
  - envVar: NVIDIA_DRIVER_CAPABILITIES=all
    nodeFilters: [all]        # 所有节点注入驱动能力，无 GPU 的 server 也报准确错误而非 LIBRARY_NOT_FOUND
options:
  runtime:
    gpuRequest: all           # 等价 --gpus all
```

文件内大段注释是**各种失败的 GPU 切分尝试留档**（`NVIDIA_VISIBLE_DEVICES` per-node env、`gpuRequest: device=0,1@agent:0`、`gpus:` 列表语法等），结论都一样：k3d 层约束无效，别浪费时间重试。

### Step 2 · 导入离线基础镜像

```bash
docker exec -it k3d-llmcluster-server-0 sh /load_image.sh
for ((i=0; i<NUM_AGENTS; i++)); do
    docker exec -it k3d-llmcluster-agent-${i} sh /load_image.sh
done
```

`load_image.sh` 会等 containerd socket 就绪再 `ctr import`（见 [03 §4.2](03-image-build.md)）。

### Step 3 · 部署 nginx 示例（CPU 侧冒烟）

```bash
kubectl apply -f ./k3d-example/deploy-nginx.yaml && kubectl apply -f ./k3d-example/nginx-svc-nodeport.yaml
# 每个节点导入 nginx tar
docker exec -it k3d-llmcluster-server-0 ctr -n k8s.io images import /root/images/nginx_1.29.tar
…
```

访问 `http://<宿主机>:8087` 验证 NodePort 链路（8087→LB:30080→Service）。

### Step 4 · 部署 NVIDIA device plugin（GPU 切分）

```bash
docker cp device-plugin-daemonset-agents-3.yaml \
    k3d-llmcluster-server-0:/var/lib/rancher/k3s/server/manifests/nvidia-device-plugin-daemonset.yaml
```

利用 k3s **auto-deploy**（server 的 `manifests/` 目录自动 apply）。也可以直接 `kubectl apply -f device-plugin-daemonset-agents-3.yaml`，效果相同；放 manifests 的好处是节点重建后自动恢复。细节见 [05](05-gpu-split.md)。

### Step 5 · 部署 CUDA 测试并导入应用镜像

```bash
kubectl apply -f cuda-vector-add-loop3.yaml
docker exec -it k3d-llmcluster-server-0 ctr -n k8s.io images import /root/images/app.cuda-vector-add.tar
for ((i=0; i<NUM_AGENTS; i++)); do
    docker exec -it k3d-llmcluster-agent-${i} ctr -n k8s.io images import /root/images/app.cuda-vector-add.tar
done
kubectl get pods -A -w -o wide
```

## 3. create_cluster_dev.sh / create_cluster_test.sh（registry 通道）

与上面相比的差异：

```bash
k3d cluster create --config ./k3d-cluster-dev.yaml \
    --image=…三合一镜像 \
    --gpus all \
    --network k3d-llmcluster \                    # ① 挂到已有网络（与 llmcluster 同网）
    --registry-use k3d-registry.localhost:5000 \  # ② 使用本地 registry
    --k3s-arg '…eviction-hard…' \
    --volume k3d-data/:/root/images@all \
    --volume k3d-data/containerd-certs:/var/lib/rancher/k3s/agent/etc/containerd/certs.d@all \  # ③ 关键
    --agents 3
```

- ②+配置文件里的 `registries.config`（docker.io/quay.io/gcr.io/k8s.gcr.io/ghcr.io/registry.k8s.io/nvcr.io/docker.elastic.co 全部 mirror 到 `http://k3d-registry.localhost:5000`）实现"所有拉取都走本地 registry"。
- ③ 是新版 k3s 的**必需品**：containerd 走 `certs.d` hosts.toml 模式后，`registries.yaml` 的 mirror 会被忽略，必须把 hosts.toml 目录挂进去（[07 FAQ-3](07-faq.md)）。
- 脚本后半段（导镜像、nginx、插件、测试）全部注释保留——走 registry 后系统组件自动拉取，无需手动 import；需要部署插件/测试时把对应段落解开或参照 [05](05-gpu-split.md)、[06](06-verify-ops.md) 手动执行（注意 dev 集群要用 `device-plugin-daemonset-agents-dev-3.yaml`，其中节点名和插件镜像都已换成 dev 版）。

## 4. 本地 Registry（通道 B 详解）

> 本节整理自 `registry.md`（历史笔记）。

### 4.1 为什么

| 方案 | 操作 | 集群删除后镜像还在吗 | 评价 |
| --- | --- | --- | --- |
| `k3d image import` / ctr import | 每次重建后重新导入 | ❌ 随节点销毁 | 只适合临时测试 |
| 本地 registry | `k3d registry create` | ✅ 独立容器常驻 | **最佳实践** |

### 4.2 标准操作

```bash
# ① 创建（只做一次）
k3d registry create registry.localhost --port 5000

# ② 推镜像（保留原仓库路径前缀，便于 yaml 只改 registry 前缀）
docker tag <image> localhost:5000/<原完整路径>:<tag>
docker push localhost:5000/<原完整路径>:<tag>

# ③ 创建集群时挂载使用
k3d cluster create … --registry-use k3d-registry.localhost:5000

# ④ 若 registry 容器与集群网络不通（手动补救）
docker network connect --alias k3d-registry.localhost k3d-llmcluster k3d-registry.localhost
```

### 4.3 certs.d hosts.toml（dev/test 脚本挂载的内容）

`k3d-data/containerd-certs/k3d-registry.localhost:5000/hosts.toml`：

```toml
server = "http://k3d-registry.localhost:5000"

[host."http://k3d-registry.localhost:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
```

改完配置后重启节点容器生效：`docker restart k3d-llmclusterdev-server-0`。验证：

```bash
docker exec -it k3d-llmclusterdev-server-0 ctr images pull --plain-http k3d-registry.localhost:5000/busybox:latest
```

### 4.4 防止运行中集群 GC 清理镜像（可选）

```bash
k3d cluster create … --k3s-arg "--kubelet-arg=image-gc-high-threshold=100@all"
```

## 5. 集群访问与删除

```bash
kubectl config use-context k3d-llmcluster        # k3d 已自动写入 kubeconfig
kubectl get nodes -o wide

k3d cluster delete llmcluster                     # 删除集群（registry 与 tar 不受影响）
k3d cluster delete -a                             # 删除所有集群
docker ps | grep k3d-registry                     # 确认 registry 仍在
```

## 6. 下一步

- [05-gpu-split](05-gpu-split.md)：部署 device plugin 并按节点切分 GPU（**必读**）
