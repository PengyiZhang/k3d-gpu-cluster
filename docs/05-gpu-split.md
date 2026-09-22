# 05 · GPU 按节点切分（核心）

> **这是本仓库最关键的一篇。** 目标：agent-0 只见 GPU 0,1；agent-1 只见 GPU 2,3；agent-2 只见 GPU 4,5（6 卡 3 节点场景，方案可自定义）。

## 1. 问题与结论速览

**问题**：k3d 集群里每个节点容器都能看到宿主机全部 GPU（`--gpus all` 透传）。默认 device plugin 会在**每个节点上报全部 6 卡**，"多节点各持一组卡"的模拟就失败了。

**已验证失败的方案**（别再试，留档在 `k3d-cluster-example.yaml` 注释里）：

| 失败方案 | 表现 |
| --- | --- |
| 创建集群时给每节点设 `NVIDIA_VISIBLE_DEVICES=0,1` 等 env | 无效，仍全部透传 |
| `--gpus device=0,1` / `gpuRequest: device=…` / `gpus: ["device=…@agent:0"]` | 无效，仍全部透传 |
| device plugin ConfigMap（`nvidia-configs.yaml`）+ 节点标签 | **在本环境不生效**，原因见下节 |

**结论（唯一有效方案）**：

> 把 device plugin 拆成**每节点一个 DaemonSet**，用 `nodeSelector` 锁定节点，并在 **DaemonSet 的 env 里显式设置 `NVIDIA_VISIBLE_DEVICES`**。

## 2. 原理：为什么只有 DaemonSet env 有效

1. 在 k3d（Docker-in-Docker）环境里，外层容器运行时会向 k3d 节点容器**强行注入** `NVIDIA_VISIBLE_DEVICES=all` 之类的全局环境变量。
2. NVIDIA device plugin 的初始化逻辑中，**环境变量 `NVIDIA_VISIBLE_DEVICES` 的优先级高于配置文件**（ConfigMap）。
3. 因此 ConfigMap 的 `visibleDevices` 分组配置永远被注入的 env 覆盖 → 唯一能赢的办法是在**离插件容器最近的地方**（DaemonSet env）再覆盖一次。

这就是 `device-plugin-daemonset-agents-3.yaml` 里注释写的"HACK: 只有在此处设置才有效"。

## 3. 文件清单与选用

| 文件 | 适用集群 | 内容 |
| --- | --- | --- |
| `device-plugin-daemonset-agents-3.yaml` | **llmcluster**（`create_cluster.sh`） | 3 个 DS（agent-0/1/2），镜像走 `nvcr.io`（离线导入） |
| `device-plugin-daemonset-agents-dev-3.yaml` | **llmclusterdev**（`create_cluster_dev.sh`） | 同上，但节点名 `k3d-llmclusterdev-agent-*`，镜像走 `k3d-registry.localhost:5000/…` |
| `device-plugin-daemonset-multiple.yaml` | gputest（历史集群） | 4 个 DS：3 agent + server-0（2,3,4,5） |
| `device-plugin-daemonset.yaml` | 调试 | 单 DS 全节点版（env=2,3），用于排查 |
| `device-plugin-daemonset-node{0,1,2}.yaml` | 调试 | 单节点单 DS |
| `device-plugin-daemonset-server0-configmap.yaml` + `nvidia-configs.yaml` | **留档** | ConfigMap 方式的尝试，本环境不生效（见 §2） |

## 4. 部署

### 方式一：放入 k3s auto-deploy 目录（脚本采用，推荐）

```bash
# 注意目标文件名固定，k3s 会自动 apply
docker cp device-plugin-daemonset-agents-3.yaml \
    k3d-llmcluster-server-0:/var/lib/rancher/k3s/server/manifests/nvidia-device-plugin-daemonset.yaml
```

优点：不依赖集群外 kubectl；节点重建后 k3s 自动重新 apply。

### 方式二：直接 kubectl

```bash
kubectl apply -f device-plugin-daemonset-agents-3.yaml
```

> dev 集群请换 `device-plugin-daemonset-agents-dev-3.yaml`。

## 5. YAML 结构解析

每个 DS 长这样（以 agent-0 为例）：

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia                      # ① 对应三合一镜像里 containerd 的 nvidia runtime
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset-agent-0
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds   # ② 所有 DS 共用 label（互不冲突，因 selector 匹配新建 pod）
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      runtimeClassName: nvidia        # ③ 插件自己也用 nvidia runtime 跑
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      - key: "node.kubernetes.io/disk-pressure"   # ④ 抗磁盘驱逐（k3d 容器磁盘小）
        operator: "Exists"
        effect: "NoSchedule"
      priorityClassName: "system-node-critical"
      nodeSelector:
        kubernetes.io/hostname: k3d-llmcluster-agent-0   # ⑤ 锁定节点
      containers:
      - image: nvcr.io/nvidia/k8s-device-plugin:v0.15.0-rc.2
        name: nvidia-device-plugin-ctr
        env:
          - name: FAIL_ON_INIT_ERROR
            value: "false"            # ⑥ 无 GPU 的节点插件起不来也不算失败
          - name: NVIDIA_VISIBLE_DEVICES
            value: "0,1"              # ⑦ ★ 核心：本节点只上报 GPU 0,1
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/device-plugins   # ⑧ 与 kubelet 握手的 socket 目录
```

当前 3+1 节点的分配方案：

| k3d 节点 | NVIDIA_VISIBLE_DEVICES | 上报 nvidia.com/gpu |
| --- | --- | --- |
| k3d-llmcluster-agent-0 | `0,1` | 2 |
| k3d-llmcluster-agent-1 | `2,3` | 2 |
| k3d-llmcluster-agent-2 | `4,5` | 2 |
| （server-0，可选，见 multiple 版） | `2,3,4,5` | 4 |

## 6. 修改 GPU 分配

1. 编辑对应 yaml 中的 `value: "0,1"`（改为如 `"0"` 或 `"0,1,2"`）；
2. 重新应用：
   - kubectl 方式：`kubectl apply -f …` 后触发滚动：`kubectl rollout restart daemonset -n kube-system -l name=nvidia-device-plugin-ds`
   - auto-deploy 方式：重新 `docker cp`（k3s 检测到文件变化会自动重新 apply；不放心就 rollout restart）；
3. 验证：

```bash
kubectl describe node k3d-llmcluster-agent-0 | grep -A 9 nvidia.com/gpu
#  Capacity/Allocatable 里 nvidia.com/gpu 应等于你设的数量
```

> GPU 索引以**宿主机 `nvidia-smi`** 为准。节点容器内 `docker exec k3d-llmcluster-agent-0 nvidia-smi` 看到的是全部 6 卡——**这是正常的**（切分只约束插件上报，不约束节点内可见性；Pod 拿到的设备由插件分配）。

## 7. ConfigMap 方式留档（为什么不用于生产）

`nvidia-configs.yaml` 定义了分组（group-0: 0,1 / group-1: 2,3 / group-2: 4,5 / group-3: 全部），配合 `device-plugin-daemonset-server0-configmap.yaml`（`CONFIG_FILE_SPEC=nvidia.com/device-plugin-config` + 挂载 ConfigMap）与节点标签：

```bash
kubectl apply -f nvidia-configs.yaml
kubectl label node k3d-llmcluster-agent-1 nvidia.com/device-plugin-config=group-1 --overwrite
```

该方案是 device plugin 官方 v0.15 的多配置支持，**在普通 K8s 集群可用**；但在本 k3d 环境，因 §2 所述的 env 注入覆盖问题**不生效**，故仅留档。如果未来升级 k3d/nvidia runtime 后注入行为改变，可优先回到这套更优雅的方案。

## 8. 验证清单

```bash
# 1. 插件 Pod 每节点一个、Running
kubectl get pods -n kube-system -o wide | grep device-plugin

# 2. 各节点 GPU 上报数正确
kubectl describe nodes | grep -B 5 nvidia.com/gpu

# 3. 插件容器内可见 GPU（应为节点容器内全部卡；切分只影响上报）
kubectl exec -it -n kube-system <device-plugin-pod> -- nvidia-smi

# 4. 跑一个真正用 GPU 的 Pod
kubectl apply -f cuda-vector-add.yaml && kubectl logs -n kube-system cuda-vector-add
# 预期最后一行：Test PASSED
```

Pod 侧两个必要字段（照抄到自己的应用 yaml）：

```yaml
spec:
  runtimeClassName: nvidia
  containers:
    - resources:
        limits:
          nvidia.com/gpu: 1
```

## 9. 下一步

- [06-verify-ops](06-verify-ops.md)：测试应用与日常运维
