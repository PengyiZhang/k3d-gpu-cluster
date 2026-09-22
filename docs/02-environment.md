# 02 · 环境准备

两条路径二选一：

- **路径一（推荐，简单）**：物理机直装 —— k3d 集群直接跑在物理机的 Docker 上。大多数场景够用。
- **路径二（可选，隔离强）**：LXD 路径 —— 先创建若干 LXC 容器，每个容器透传指定 GPU，k3d 集群跑在某个 LXC 里。适合多人共用物理机、需要资源隔离时。

## 0. 版本基线

当前仓库验证过的组合：

| 项 | 值 |
| --- | --- |
| 宿主机 OS | Ubuntu 22.04（内核 5.15） |
| NVIDIA 驱动 | 宿主机安装（`nvidia-smi` 可用即可），LXC 内匹配安装 `nvidia-utils-535-server` |
| k3s | v1.33.4-k3s1（来自三合一镜像） |
| CUDA / cuDNN | 12.2.2 / 8（镜像内 runtime 变体） |
| device plugin | nvcr.io/nvidia/k8s-device-plugin:v0.15.0-rc.2 |

## 1. 路径一：物理机直装

### 1.1 验证驱动

```bash
nvidia-smi   # 必须正常列出所有 GPU，否则先修驱动
```

### 1.2 安装 Docker + nvidia-container-toolkit

> 内容即 `lxd-lxc/install_docker.sh`，在物理机上去掉 `sudo lxc exec` 包装直接执行即可。

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io --fix-missing

# nvidia-container-toolkit（内网环境加 -k 跳过证书校验，参考仓库内脚本）
distribution=ubuntu22.04
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker
```

### 1.3 安装 k3d 与 kubectl

```bash
# k3d（仓库内自带安装脚本 lxd-lxc/install_k3d.sh，即官方 get 脚本）
sh lxd-lxc/install_k3d.sh

# kubectl：从镜像站下载或 apt 安装，版本与 k3s v1.33.x 对齐即可
```

### 1.4 端到端验证 GPU 容器可用

```bash
docker run --rm --gpus all nvidia/cuda:12.2.2-cudnn8-runtime-ubuntu22.04 nvidia-smi
```

能看到 GPU 列表即环境就绪。

### 1.5 准备 k3d-data 挂载目录

`create_cluster*.sh` 里把宿主机目录挂载进所有节点容器：

```
--volume /home/zhangpengyi/k3d-data/:/root/images@all
```

请按需修改脚本中的路径。目录内容：

```
k3d-data/
├── k3d-base-images.tar        # save_images.sh 产出（必配）
├── nginx_1.29.tar             # docker save nginx:1.29（用 create_cluster.sh 部署 nginx 时需要）
├── app.cuda-vector-add.tar    # docker save k8s.gcr.io/cuda-vector-add:v0.1（GPU 测试需要）
└── containerd-certs/          # 本地 registry 的 certs.d hosts.toml（registry 通道需要）
    └── k3d-registry.localhost:5000/hosts.toml
```

## 2. 路径二：LXD 层（可选）

> 脚本位于 `lxd-lxc/`。目标：6 个 LXC 容器 `k8s-node-0..5`，各自独占一块 GPU。

### 2.1 脚本一览（按执行顺序）

| 顺序 | 脚本 | 作用 | 备注 |
| --- | --- | --- | --- |
| 1 | `create.sh` | 创建 6 个 `ubuntu:22.04` LXC；每容器限 `limits.cpu 8`、`limits.memory 64GiB`；按 **PCI 总线序**给第 i 个容器透传第 i 块 GPU（`lxc config device add … gpu pci=$GPU_PCI`） | 需要 LXD 已初始化、宿主机 `nvidia-smi` 正常 |
| 2 | `install_nvidia.sh` | 批量在各容器内装 `nvidia-utils-535-server`（只装用户态工具，不装内核驱动） | **版本必须与宿主机驱动大版本匹配**，按实际改 |
| 3 | `install_docker.sh` | 批量装 Docker + nvidia-container-toolkit | 进容器内执行，或用 `lxc exec` 包装 |
| 4 | `fix_nvidia.sh` | 给容器开 `security.privileged=true`、`nvidia.driver.capabilities=all`、`nvidia.runtime=true`，然后重启容器 | LXD 的 NVIDIA runtime 集成开关 |
| 5 | `add_gpu.sh` | 备选的按 **GPU id** 添加设备（`gpu id=1..6`），与 create.sh 的 pci 方式二选一 | id 与 nvidia-smi 序号对应 |
| 6 | `install_k3d.sh` | 在容器内安装 k3d | 官方 get 脚本原样 |

### 2.2 注意事项

- **GPU 透传两种方式**：`pci=<bus_id>`（create.sh 用，按物理槽位）与 `id=<nvidia-smi 序号>`（add_gpu.sh 用）。两者别对同一容器重复加。
- LXC 内的 `nvidia-smi` 依赖宿主机驱动与 LXD 的 nvidia runtime 支持；`fix_nvidia.sh` 里 `nvidia.runtime=true` 是让 LXD 自动挂驱动库的关键。
- 换 apt 国内源（阿里/清华）可大幅加速容器初始化，历史操作可参考 `lxd-lxc/lxc.ref.txt`（sudo 日志）。
- k3d 集群后续创建流程与路径一完全相同，只是在某个 LXC 容器内执行。

### 2.3 验证

```bash
lxc exec k8s-node-0 -- nvidia-smi          # 应只看到透传给它的那 1 块 GPU
lxc exec k8s-node-0 -- docker run --rm --gpus all nvidia/cuda:12.2.2-cudnn8-runtime-ubuntu22.04 nvidia-smi
```

## 3. 常见环境问题速查

| 症状 | 原因/处理 |
| --- | --- |
| `docker run --gpus all … nvidia-smi` 报 `could not select device driver` | nvidia-container-toolkit 未装或 Docker 未重启；`nvidia-ctk runtime configure --runtime=docker && systemctl restart docker` |
| LXC 内 `nvidia-smi` 报 `Failed to initialize NVML` | 未执行 `fix_nvidia.sh` 或没重启容器；确认宿主机驱动版本与容器内 nvidia-utils 匹配 |
| k3d `--gpus` 报错 | k3d 版本过旧，升级（`install_k3d.sh`） |
| 内网拉取 apt/镜像超时 | 参考 `k3d-example/registries.yaml`（daocloud mirror）与各脚本中的 `-k` 跳过证书校验 |

## 4. 下一步

- [03-image-build](03-image-build.md)：构建三合一镜像
