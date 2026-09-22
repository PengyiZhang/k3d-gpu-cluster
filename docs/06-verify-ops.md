# 06 · 验证、测试应用与日常运维

> 本文是集群起来之后的操作手册。命令速查整理自 `instructions_ref.md`。

## 1. 部署后检查清单（新集群必做）

```bash
# ① 节点 Ready
kubectl get nodes -o wide

# ② 系统 Pod（coredns / traefik / metrics-server / local-path / device-plugin 均 Running）
kubectl get pods -A -o wide
kubectl get pods -A -w -o wide          # 持续观察

# ③ GPU 已按节点切分上报（agent-0 应为 2，即 0,1）
kubectl describe node k3d-llmcluster-agent-0 | grep nvidia.com -C 9

# ④ metrics-server 正常
kubectl top nodes
```

> traefik 的 helm-install Job 偶现 `Pending/ContainerStatusUnknown`（历史输出中出现过），不影响 GPU 功能，可忽略或 `kubectl delete job -n kube-system helm-install-traefik-crd-xxx` 清理。

## 2. GPU 测试应用

### 2.1 cuda-vector-add 家族

| 文件 | 行为 | 镜像 | 备注 |
| --- | --- | --- | ---|
| `cuda-vector-add.yaml` | 单次向量加法 | `k8s.gcr.io/cuda-vector-add:v0.1` | 最快冒烟 |
| `cuda-vector-add-2/3.yaml` | 同上（迭代版） | 同上 | -3 为当前脚本默认 |
| `cuda-vector-add-loop.yaml` / `loop2` / `loop3` | `while true; do ./vectorAdd; done` 持续压测 | 同上 | **loop3 由 create_cluster.sh 自动部署** |
| `cuda-vector-add-loop4.yaml` | 同上 | `k3d-registry.localhost:5000/cuda-vector-add:v0.1` | registry 通道版 |

共同的关键字段（自定义 GPU 应用照抄）：

```yaml
namespace: kube-system
priorityClassName: system-node-critical     # 抗驱逐
runtimeClassName: nvidia                    # 走 nvidia runtime
tolerations:                                # 容忍磁盘压力污点
- key: "node.kubernetes.io/disk-pressure"
  operator: "Exists"
  effect: "NoSchedule"
- key: "node.kubernetes.io/disk-pressure"
  operator: "Exists"
  effect: "NoExecute"
resources:
  limits: { nvidia.com/gpu: 1 }
```

### 2.2 运行与观察

```bash
kubectl apply -f cuda-vector-add-loop3.yaml
kubectl logs -n kube-system cuda-vector-add-loop3 -f     # 应不断打印 Test PASSED
kubectl describe pods -n kube-system cuda-vector-add-loop3

# 看 Pod 落在哪个节点、该节点 GPU 负载
NODE_NAME=$(kubectl get pod -n kube-system cuda-vector-add-loop3 -o jsonpath='{.spec.nodeName}')
echo "当前 Pod 运行在: $NODE_NAME"
docker exec $NODE_NAME nvidia-smi                          # 节点容器视角的 GPU 占用
```

## 3. 给集群导入应用镜像（三种方式）

| 方式 | 命令 | 适用 |
| --- | --- | --- |
| 节点内 ctr import（脚本采用） | `docker exec -it k3d-llmcluster-agent-0 ctr -n k8s.io images import /root/images/app.cuda-vector-add.tar` | 离线通道；需**每个节点**执行 |
| k3d 集群级导入 | `k3d image import /path/to/app.tar -c llmcluster` | 离线通道；一条命令打到所有节点 |
| 推本地 registry | `docker tag app localhost:5000/app:tag && docker push localhost:5000/app:tag`，yaml 里镜像写 `k3d-registry.localhost:5000/app:tag` | registry 通道；推一次永久用 |

## 4. CPU 应用与端口访问（nginx 示例）

```bash
kubectl apply -f k3d-example/deploy-nginx.yaml
kubectl apply -f k3d-example/nginx-svc-nodeport.yaml
curl http://localhost:8087        # NodePort 路径（8087→serverlb:30080→Service:80→Pod）
```

- dev 集群没有映射 30080，改用 `8180→80`（Traefik 路径，需自建 Ingress）或自己加端口映射。
- 端口映射拓扑图见 [`k3d-example/README.md`](../k3d-example/README.md)。

## 5. 日常运维速查

### 5.1 观察

```bash
kubectl get pods -A -w -o wide                       # 全量 Pod 监控
kubectl describe pods <pod> -n kube-system           # 单 Pod 详情（Events 看 scheduling）
kubectl describe node k3d-llmcluster-agent-0 | grep nvidia.com -C 9   # 节点 GPU 分配
kubectl top pods -A                                  # 资源占用（metrics-server）
docker exec k3d-llmcluster-agent-0 nvidia-smi        # 节点容器内 GPU 负载
kubectl exec -it <device-plugin-pod> -n kube-system -- nvidia-smi     # 插件容器内 GPU
```

### 5.2 device plugin 配置调整

```bash
# ConfigMap 方式（留档，见 05 §7）
kubectl apply -f nvidia-configs.yaml
kubectl edit configmap nvidia-plugin-configs -n kube-system
kubectl label node k3d-llmcluster-agent-1 nvidia.com/device-plugin-config=group-1 --overwrite

# 改完配置触发滚动更新（无需手动删 Pod）
kubectl rollout restart daemonset -n kube-system -l name=nvidia-device-plugin-ds
```

### 5.3 集群生命周期

```bash
k3d cluster list
k3d cluster stop llmcluster / k3d cluster start llmcluster   # 停/起（不删数据）
k3d cluster delete llmcluster                                 # 删除（镜像随之丢失，registry/tar 不受影响）
k3d cluster delete -a                                         # 删除全部
sh ./create_cluster.sh                                        # 重建（离线通道全流程约几分钟）
docker ps | grep k3d-registry                                 # 确认本地 registry 常驻
```

### 5.4 进入节点容器排障

```bash
docker exec -it k3d-llmcluster-server-0 bash
# 常用：crictl ps / crictl logs <id>；ctr -n k8s.io images ls；k3s kubectl …
# auto-deploy 目录：
ls /var/lib/rancher/k3s/server/manifests/
```

## 6. 排障入口

症状 → [07-faq](07-faq.md) 对照表。
