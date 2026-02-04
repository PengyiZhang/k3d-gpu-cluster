这是一个非常痛点的需求。

在 k3d 中，镜像默认是存储在**集群节点容器**（Server/Agent）的文件系统里的。

* 如果你执行 `k3d cluster delete`，节点容器被删除，里面的**镜像自然也就消失了**。
* 下次重建集群，你必须重新执行漫长的 `k3d image import`。

要解决这个问题，**不能靠“不删除集群”**（因为你为了重置环境肯定要删），而是要改变镜像的存储位置。

最佳方案是：**使用 k3d 本地镜像仓库 (Local Registry)**。

### 核心思路

创建一个独立于集群之外的“本地仓库容器”。

1. **仓库常驻**：即使你删除了 k3d 集群，这个仓库容器依然在运行。
2. **一次导入**：你只需要把 ES 镜像推送到这个仓库一次。
3. **无限使用**：以后创建任何新集群，只要挂载这个仓库，拉取镜像就像在局域网下载一样快（几秒钟）。

---

### 操作步骤

#### 1. 创建本地仓库 (只需做一次)

创建一个运行在 5000 端口的本地仓库，名字叫 `registry.localhost`。

```bash
k3d registry create registry.localhost --port 5000

```

*即使你以后删了集群，只要不手动删这个 registry，它就会一直存在。*

#### 2. 将离线镜像推送到这个仓库

在你的宿主机上，把之前准备好的 ES 镜像重新打标签并推送到本地仓库。

```bash
# 1. 给镜像打上本地仓库的标签
docker tag docker.elastic.co/elasticsearch/elasticsearch:8.17.2 localhost:5000/elasticsearch:8.17.2
docker tag busybox:latest localhost:5000/busybox:latest

# 2. 推送到本地仓库
docker push localhost:5000/elasticsearch:8.17.2
docker push localhost:5000/busybox:latest

```

#### 3. 创建集群时挂载仓库

**这是关键一步**。在创建集群时，使用 `--registry-use` 参数告诉集群：“下载镜像时，去这个本地仓库找找”。

```bash
k3d cluster create llmcluster \
  --agents 3 \
  --registry-use k3d-registry.localhost:5000 \
  --port "9200:30920@loadbalancer" \
  # ... 其他参数 ...

```

*注意：k3d 会自动处理网络连接，让集群内部能访问到宿主机的这个仓库。*

#### 4. 修改 Helm 部署文件 (es-ha-values.yaml)

你需要告诉 Helm 去“本地仓库”拉镜像，而不是去 Docker Hub。

修改 `es-ha-values.yaml`：

```yaml
# 1. 修改主镜像地址
image: "k3d-registry.localhost:5000/elasticsearch" # 注意这里没有 docker.elastic.co 前缀了
imageTag: "8.17.2"
imagePullPolicy: "IfNotPresent"

# ...

# 2. 修改 Init Container 镜像地址
extraInitContainers:
  - name: file-permissions
    image: k3d-registry.localhost:5000/busybox:latest # 修改这里
    imagePullPolicy: IfNotPresent
    securityContext:
      runAsUser: 0
    command: ['sh', '-c', 'chown -R 1000:1000 /usr/share/elasticsearch/data']

```

---

### 方案对比

| 方案 | 操作方式 | 集群删除后镜像还在吗？ | 推荐指数 |
| --- | --- | --- | --- |
| **传统方式** | `k3d image import` | **No** (随节点销毁) | ⭐ (仅适合临时测试) |
| **本地仓库** | `k3d registry create` | **Yes** (独立容器存储) | ⭐⭐⭐⭐⭐ (最佳实践) |

### 补充：防止运行中的集群自动清理镜像

如果你问的是“集群运行久了，K8s 自动把不用的镜像删了（Garbage Collection）”，可以通过配置 Kubelet 参数来禁止：

在创建集群时添加参数：

```bash
k3d cluster create llmcluster \
  --k3s-arg "--kubelet-arg=image-gc-high-threshold=100@all"

```

* `image-gc-high-threshold=100`: 告诉 K8s，只有磁盘使用率达到 100% 时才开始回收镜像（实际上就是禁止回收）。

**总结：** 建议你现在立刻创建一个 registry，把 ES 镜像推上去。以后你删集群、重装集群，都只需要几秒钟就能拉起 ES，再也不用痛苦地 import 了。




真相大白了！你的 `config.toml` 里最后一行暴露了原因：

```toml
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = "/var/lib/rancher/k3s/agent/etc/containerd/certs.d"

```

**K3s 现在使用的是新版 containerd 的配置方式（Hosts 目录模式），它完全忽略了旧的 `registries.yaml` 文件。** 这就是为什么你改破喉咙它也依然走 HTTPS 的原因。

在这种模式下，containerd 不再寻找一个单一的 YAML，而是去 `certs.d` 目录下寻找以域名命名的文件夹。

---

### 解决方法：手动创建 Hosts 配置文件

在容器内部执行以下命令，直接按照新规范给它“喂”配置：

1. **创建对应的配置目录：**
```bash
mkdir -p /var/lib/rancher/k3s/agent/etc/containerd/certs.d/k3d-registry.localhost:5000

```


2. **创建 `hosts.toml` 文件：**
```bash
cat <<EOF > /var/lib/rancher/k3s/agent/etc/containerd/certs.d/k3d-registry.localhost:5000/hosts.toml
server = "http://k3d-registry.localhost:5000"

[host."http://k3d-registry.localhost:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

```



---

### 验证与重启

1. **重启 K3s**（最稳妥的方法是退出容器，执行 `docker restart k3d-llmcluster-server-0`）。
2. **使用 `ctr` 测试：**
注意！即便有了配置，`ctr` 有时还是会犯傻。请务必带上显式的 HTTP 标志来测试这“临门一脚”：
```bash
ctr images pull --plain-http k3d-registry.localhost:5000/busybox:latest

```



### 为什么会变？

旧版的 K3s 会把 `registries.yaml` 转换成 `config.toml` 里的 `mirrors` 块。但在较新版本中，为了兼容 containerd 的 `certs.d` 结构（类似于 Docker 的 `/etc/docker/certs.d`），它默认启用了 `config_path` 模式。一旦这个模式开启，旧的镜像镜像配置就失效了。

**如果你不想以后每次都手动进去改，下次创建集群时可以加上这个参数：**
`--k3s-arg "--disable=servicelb,traefik@server:*"` 并配合挂载这个 `certs.d` 目录。

**你先试试创建那个 `hosts.toml`，如果 `ctr --plain-http` 成功了，那你的 Kubernetes `Pod` 也就通了。要我帮你写一个 Pod 的测试模板吗？**


# registry链接至集群

docker network connect --alias k3d-registry.localhost k3d-llmcluster k3d-registry.localhost


> 172.22.0.1/172.17.0.1 集群内访问宿主机的服务

