# 03 · 构建三合一镜像与离线镜像准备

本文涉及文件：`Dockerfile`、`build.sh`、`save_images.sh`、`load_image.sh`、`import.sh`。

## 1. 为什么要自制镜像

k3d 默认的 `rancher/k3s` 镜像里没有 CUDA 运行库，也没有 nvidia-container-toolkit，Pod 无法以 `runtimeClassName: nvidia` 运行。自制镜像把三者合并：

```
rancher/k3s:v1.33.4-k3s1               ← k3s 二进制 + containerd + 入口
nvcr.io/nvidia/cuda:12.2.2-cudnn8-runtime-ubuntu22.04   ← CUDA/cuDNN 用户态库（base 层）
nvidia-container-toolkit               ← 让镜像内 containerd 拥有 nvidia runtime
```

最终产物 tag：`<REGISTRY>/rancher/k3s:v1.33.4-k3s1-cuda-12.2.2-cudnn8-runtime-ubuntu22.04`。

## 2. build.sh 用法

```bash
# 全部参数可用环境变量覆盖：
IMAGE_REGISTRY=nlc sh ./build.sh
```

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `K3S_TAG` | `v1.33.4-k3s1` | k3s 版本（基础镜像 tag） |
| `CUDA_TAG` | `12.2.2-cudnn8-runtime-ubuntu22.04` | CUDA 基础镜像 tag |
| `IMAGE_REGISTRY` | `MY_REGISTRY` | 目标 registry 前缀（本仓库实际用 `nlc`） |
| `IMAGE_REPOSITORY` | `rancher/k3s` | 镜像名 |
| `IMAGE` | 由上面拼出 | 完整镜像引用，最高优先级 |

脚本内 `docker push` 被注释掉了，**构建完需要手动 push** 到 `nlc` registry（或改回脚本里的 push 行）：

```bash
docker push nlc/rancher/k3s:v1.33.4-k3s1-cuda-12.2.2-cudnn8-runtime-ubuntu22.04
```

## 3. Dockerfile 逐段解析

```dockerfile
ARG K3S_TAG="v1.33.4-k3s1"
ARG CUDA_TAG="12.2.2-cudnn8-runtime-ubuntu22.04"
FROM rancher/k3s:$K3S_TAG as k3s          # ① 取 k3s 全部文件
FROM nvcr.io/nvidia/cuda:$CUDA_TAG        # ② 以 CUDA 镜像为基础层
```

- **以 CUDA 镜像为 base、把 k3s 叠上去**（而不是反过来），保证 CUDA 库路径、环境变量是原生布局。

```dockerfile
RUN apt-get update && apt-get install -y curl
RUN curl … nvidia-container-toolkit 源配置 …          # ③ 添加 NVIDIA apt 源
RUN apt -o Acquire::https::Verify-Peer=false … update  # ④ 内网自签证书时跳过校验
RUN apt … install -y nvidia-container-toolkit
RUN nvidia-ctk runtime configure --runtime=containerd  # ⑤ 关键：给镜像内 containerd 注册 nvidia runtime
```

- ⑤ 会在 containerd 配置里生成 `nvidia` runtime（指向 `nvidia-container-runtime`），这正是 RuntimeClass `handler: nvidia` 能工作的前提。

```dockerfile
COPY --from=k3s / / --exclude=/bin   # ⑥ 把 k3s 镜像内容合并进来（先覆盖除 /bin 外的一切）
COPY --from=k3s /bin /bin            #    再覆盖 /bin，保证 k3s 二进制最终生效
```

```dockerfile
VOLUME /var/lib/kubelet /var/lib/rancher/k3s /var/lib/cni /var/log   # 与官方 k3s 镜像对齐
ENV PATH="$PATH:/bin/aux"            # k3s 辅助工具路径
COPY load_image.sh /load_image.sh    # ⑦ 离线镜像导入脚本打进镜像
ENTRYPOINT ["/bin/k3s"]
CMD ["agent"]
```

### 被注释掉的方案（留档说明，别解开）

| 注释段 | 为什么放弃 |
| --- | --- |
| `COPY k3d-base-images.tar` + 构建期 `ctr images import` | **构建期 containerd 没有运行**，找不到 `containerd.sock`，必然失败。改为运行期由 `load_image.sh` 导入（见下） |
| 构建期 COPY device-plugin-daemonset.yaml 到 `server/manifests/` | device plugin 需要按节点定制（切分 GPU），不能固化在镜像里；改为集群创建后 `docker cp`（见 [05](05-gpu-split.md)） |

## 4. 离线基础镜像包（通道 A 的核心）

### 4.1 save_images.sh

在有网机器上执行：

```bash
sh ./save_images.sh   # 产出 k3d-base-images.tar（当前目录）
```

导出清单与 k3s v1.33.4 内置组件一一对应（依据 `manifests/` 目录）：

| 镜像 | 用途 |
| --- | --- |
| rancher/mirrored-coredns-coredns:1.12.3 | DNS |
| rancher/klipper-helm:v0.9.8-build20250709 | Helm controller 执行器 |
| rancher/mirrored-metrics-server:v0.8.0 | `kubectl top` |
| rancher/mirrored-library-traefik:3.3.6 | Ingress |
| rancher/klipper-lb:v0.4.13 | ServiceLB |
| rancher/local-path-provisioner:v0.0.31 | 本地 PV |
| rancher/mirrored-library-busybox:1.36.1 | 工具箱 |
| rancher/mirrored-pause:3.6 | sandbox |
| nvcr.io/nvidia/k8s-device-plugin:v0.15.0-rc.2 | GPU 设备插件 |

> **k3s 版本升级时务必核对此清单**：对照 `manifests/`（coredns、traefik、metrics-server、local-storage、runtimes、ccm、rolebindings）中的镜像 tag 重新 `docker save`，否则集群起来后系统 Pod 会 `ErrImagePull`。

把 tar 放入挂载目录（默认 `/home/zhangpengyi/k3d-data/`）。

### 4.2 load_image.sh（节点容器内自动导入）

已被 `COPY` 进三合一镜像的 `/load_image.sh`：

```sh
until [ -S /run/k3s/containerd/containerd.sock ]; do sleep 1; done   # 等 containerd 起来
ctr -n k8s.io images import /root/images/k3d-base-images.tar          # 挂载点 /root/images
```

`create_cluster.sh` 在集群创建后对每个节点容器执行：

```bash
docker exec -it k3d-llmcluster-server-0 sh /load_image.sh
docker exec -it k3d-llmcluster-agent-${i} sh /load_image.sh   # i = 0..NUM_AGENTS-1
```

`import.sh` 是它的一个替代入口（后台 import + exec k3s agent），当前主流程未使用，留作参考。

### 4.3 应用镜像离线包

```bash
# nginx 示例
docker save -o /home/zhangpengyi/k3d-data/nginx_1.29.tar nginx:1.29
# CUDA 测试
docker save -o /home/zhangpengyi/k3d-data/app.cuda-vector-add.tar k8s.gcr.io/cuda-vector-add:v0.1
```

导入方式见 [06-verify-ops §3](06-verify-ops.md)。

## 5. 本地 Registry 通道（通道 B 的镜像准备）

如果走 `create_cluster_dev.sh` / `create_cluster_test.sh`，则**不需要** tar 包，改为把镜像推入本地 registry（一次性，集群删除后仍在）：

```bash
k3d registry create registry.localhost --port 5000     # 只做一次
docker tag nvcr.io/nvidia/k8s-device-plugin:v0.15.0-rc.2 \
           localhost:5000/nvcr.io/nvidia/k8s-device-plugin:v0.15.0-rc.2
docker push localhost:5000/nvcr.io/nvidia/k8s-device-plugin:v0.15.0-rc.2
# 注意保留原始仓库路径前缀（nvcr.io/…），这样 yaml 里的镜像名只需把 registry 前缀换掉
```

完整方案与 certs.d 大坑见 [04-cluster §4](04-cluster.md) 和 [07 FAQ-3](07-faq.md)。

## 6. 下一步

- [04-cluster](04-cluster.md)：用这个镜像创建集群
