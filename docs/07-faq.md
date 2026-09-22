# 07 · 踩坑实录与 FAQ

> 这些坑全部实测踩过，每条都给出原因与定论。搭建前通读一遍可省大量时间。

---

## FAQ-1 · 在 k3d 创建层按节点分配 GPU —— 无效

**现象**：想给 agent-0 只分配 GPU 0,1，尝试了以下所有姿势，节点容器内仍能看到全部 6 卡：

- 创建时 env：`NVIDIA_VISIBLE_DEVICES=0,1`（per-node nodeFilters）
- `CUDA_VISIBLE_DEVICES=2,3`
- `--gpus device=0,1`
- 配置文件 `options.runtime.gpuRequest: device=…`（per-filter）
- 配置文件 `gpus: ["device=0,1@agent:0", …]` 列表语法

**结论**：在 k3d/DinD 环境下这些约束**全部无效，GPU 全部透传**（留档见 `k3d-cluster-example.yaml` 注释、`create_cluster.sh` 顶部注释）。切分唯一有效的位置是 device plugin DaemonSet 的 env，见 [05-gpu-split](05-gpu-split.md)。

**正确姿势**：创建集群就老实用 `--gpus all`，让每个节点容器看到全部卡，再由插件决定"上报哪几张"。

---

## FAQ-2 · device plugin 的 ConfigMap visibleDevices 不生效

**现象**：`nvidia-configs.yaml`（group-N: visibleDevices）+ 节点标签的方式，插件仍然上报全部 GPU。

**原因**：外层容器运行时向 k3d 节点容器注入了 `NVIDIA_VISIBLE_DEVICES=all`；**插件初始化时环境变量优先级高于配置文件**，ConfigMap 被覆盖。

**解决**：拆分为每节点一个 DaemonSet（nodeSelector 锁定），在 DS env 里显式写 `NVIDIA_VISIBLE_DEVICES="0,1"`。这是实测唯一有效的方式（yaml 内注释"HACK: 只有在此处设置才有效"）。

---

## FAQ-3 · 新版 k3s 忽略 registries.yaml / mirror 不生效（仍走 HTTPS 拉取失败）

**现象**：明明在 `registries.yaml`（或 k3d 配置的 `registries.config`）里把 registry mirror 指到 `http://k3d-registry.localhost:5000`，拉镜像还是直连外网/报 HTTPS 证书错误。

**原因**：新版 K3s 的 containerd 启用了 **Hosts 目录模式**（`config.toml` 末尾）：

```toml
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = "/var/lib/rancher/k3s/agent/etc/containerd/certs.d"
```

此模式下 containerd **完全忽略旧的 registries.yaml mirrors**，转而在 `certs.d/` 下按"域名目录 + hosts.toml"查找配置。

**解决**：为本地 registry 创建 hosts.toml 并挂载进所有节点：

```bash
# 宿主机 k3d-data/containerd-certs/k3d-registry.localhost:5000/hosts.toml
server = "http://k3d-registry.localhost:5000"
[host."http://k3d-registry.localhost:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
```

```bash
# 创建集群时挂载（create_cluster_dev.sh / create_cluster_test.sh 已带）
--volume …/containerd-certs:/var/lib/rancher/k3s/agent/etc/containerd/certs.d@all

# 已运行集群：docker restart k3d-llmclusterdev-server-0（及各 agent）
```

**验证**（注意 `ctr` 有时不读配置，务必带 `--plain-http`）：

```bash
ctr images pull --plain-http k3d-registry.localhost:5000/busybox:latest
```

---

## FAQ-4 · 本地 registry 与集群网络不通

**现象**：Pod 拉取 `k3d-registry.localhost:5000/...` 超时 / DNS 解析不到。

**解决**：

```bash
# 把 registry 容器连入集群网络并起别名
docker network connect --alias k3d-registry.localhost k3d-llmcluster k3d-registry.localhost
```

dev/test 集群创建时用 `--network k3d-llmcluster` + `--registry-use k3d-registry.localhost:5000` 可避免此问题。集群内访问宿主机服务的网关地址通常为 `172.22.0.1` / `172.17.0.1`（docker 网段）。

---

## FAQ-5 · Pod 被驱逐 / Pending：磁盘压力（k3d 节点容器磁盘小）

**现象**：Pod 反复 Evicted 或调度不上，`kubectl describe` 里出现 `node.kubernetes.io/disk-pressure` 污点；历史输出中 traefik 的 helm-install Job 也 Pending 过。

**原因**：k3d 节点容器文件系统小，kubelet 默认 `nodefs.available<10%` 就驱逐，很快触顶。

**多层缓解（本仓库全部启用）**：

1. **放宽阈值**（创建时）：`--k3s-arg '--kubelet-arg=eviction-hard=nodefs.available<100Mi@all'`
2. **Pod 容忍污点 + 提优先级**（应用 yaml）：
   ```yaml
   priorityClassName: system-node-critical
   tolerations:
   - key: "node.kubernetes.io/disk-pressure"
     operator: "Exists"
     effect: "NoSchedule"
   - key: "node.kubernetes.io/disk-pressure"
     operator: "Exists"
     effect: "NoExecute"
   ```
3. （可选）禁止镜像 GC：`--k3s-arg "--kubelet-arg=image-gc-high-threshold=100@all"`

自定义部署时建议照抄 2；临时排障可 `docker exec <node> sh -c 'rm -rf /var/lib/rancher/k3s/agent/containerd/*'` 后重启节点容器（会丢已导入镜像，需重导）。

---

## FAQ-6 · 集群删除后镜像全丢，每次重建都要重新 import

**方案对比**：

| 方案 | 集群删除后镜像还在吗 | 推荐度 |
| --- | --- | --- |
| `k3d image import` / ctr import tar | ❌ | 临时测试 |
| **k3d 本地 registry**（`k3d registry create registry.localhost --port 5000`） | ✅（独立容器常驻） | ★★★★★ |

完整操作见 [04-cluster §4](04-cluster.md)。

---

## FAQ-7 · Dockerfile 构建期 ctr import 失败

**现象**：想在构建镜像时直接 `ctr images import k3d-base-images.tar`，报找不到 `containerd.sock`。

**原因**：构建期 containerd 未运行（k3s 进程才是它的启动者）。

**解决**：运行期导入 —— 镜像内置 `/load_image.sh`（等 socket 出现后 import），集群创建后 `docker exec … sh /load_image.sh`。见 [03 §4.2](03-image-build.md)。

---

## FAQ-8 · 无 GPU 的 server 节点报 LIBRARY_NOT_FOUND

**现象**：server-0 未分配 GPU，插件/容器报 `LIBRARY_NOT_FOUND`，疑似驱动问题。

**原因**：节点容器没挂 NVIDIA 驱动库时，错误信息具有误导性。

**解决**：给**所有节点**（含 server）注入 `NVIDIA_DRIVER_CAPABILITIES=all`（`k3d-cluster-example.yaml` env 段已配）。这样 server 报 `No device found` —— 这才是无 GPU 节点的**预期**错误，可安全配合 `FAIL_ON_INIT_ERROR=false` 忽略。

---

## FAQ-9 · 节点内 nvidia-smi 显示 6 卡，但 kubectl 只显示 2 卡 —— 正常吗？

**正常**。切分只约束 device plugin 向 kubelet **上报**的数量（`nvidia.com/gpu` Capacity），不改变节点容器内的设备可见性。Pod 被分配到的 GPU 由插件控制，互不冲突。验证分配看：

```bash
kubectl describe node k3d-llmcluster-agent-0 | grep nvidia.com/gpu
```

---

## FAQ-10 · 常用兜底命令

```bash
# 全部重来
k3d cluster delete -a && sh ./create_cluster.sh

# 某节点异常，单独重启
docker restart k3d-llmcluster-agent-0

# 重置 kubeconfig
k3d kubeconfig merge llmcluster --kubeconfig-merge-default

# k3s 内置组件清单比对（排查 ErrImagePull 该补哪个离线镜像）
ls manifests/            # coredns / traefik / metrics-server / local-storage / runtimes / ccm / rolebindings
```
