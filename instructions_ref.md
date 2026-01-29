# 1. 确认节点
```bash

NODE_NAME=$(kubectl get pod <你的Pod名> -o jsonpath='{.spec.nodeName}')
echo "当前 Pod 运行在: $NODE_NAME"
```

# 2. 对应的在宿主机查看该节点的 GPU 负载
```bash
docker exec $NODE_NAME nvidia-smi
```

# 3. 监测所有 Pod 的状态

```bash
kubectl get pods -A -w -o wide
```
```bash
NAMESPACE     NAME                                            READY   STATUS                   RESTARTS   AGE    IP           NODE                   NOMINATED NODE   READINESS GATES
kube-system   coredns-64fd4b4794-5kr4g                        1/1     Running                  0          149m   10.42.1.12   k3d-gputest-agent-1    <none>           <none>
kube-system   cuda-vector-add-3                               1/1     Running                  0          23m    10.42.0.12   k3d-gputest-agent-0    <none>           <none>
kube-system   cuda-vector-add-loop2                           1/1     Running                  0          14m    10.42.0.16   k3d-gputest-agent-0    <none>           <none>
kube-system   cuda-vector-add-loop3                           1/1     Running                  0          12m    10.42.3.4    k3d-gputest-server-0   <none>           <none>
kube-system   helm-install-traefik-crd-44g7g                  0/1     Pending                  0          149m   <none>       <none>                 <none>           <none>
kube-system   helm-install-traefik-crd-wjtdk                  0/1     ContainerStatusUnknown   0          149m   <none>       k3d-gputest-agent-0    <none>           <none>
kube-system   helm-install-traefik-pw426                      0/1     ContainerStatusUnknown   0          149m   <none>       k3d-gputest-agent-2    <none>           <none>
kube-system   helm-install-traefik-zbmrz                      0/1     Pending                  0          149m   <none>       <none>                 <none>           <none>
kube-system   local-path-provisioner-774c6665dc-xx8qf         1/1     Running                  0          149m   10.42.1.11   k3d-gputest-agent-1    <none>           <none>
kube-system   metrics-server-7bfffcd44-jztxp                  1/1     Running                  0          149m   10.42.0.7    k3d-gputest-agent-0    <none>           <none>
kube-system   nvidia-device-plugin-daemonset-agent-0-kjt46    1/1     Running                  0          149m   10.42.0.8    k3d-gputest-agent-0    <none>           <none>
kube-system   nvidia-device-plugin-daemonset-agent-1-9bscd    1/1     Running                  0          149m   10.42.1.10   k3d-gputest-agent-1    <none>           <none>
kube-system   nvidia-device-plugin-daemonset-agent-2-sjcjw    1/1     Running                  0          149m   10.42.2.6    k3d-gputest-agent-2    <none>           <none>
kube-system   nvidia-device-plugin-daemonset-server-0-tv4cl   1/1     Running                  0          149m   10.42.3.3    k3d-gputest-server-0   <none>           <none>
```

# 4. 查看特定 Pod 的详细信息
kubectl describe pods cuda-vector-add-3 -n kube-system

# 5. 查看节点的 GPU 分配情况
kubectl describe node k3d-gputest-agent-0 |grep nvidia.com -C 9

# 创建ConfigMap以配置NVIDIA设备插件
kubectl apply -f nvidia-configs.yaml

# 编辑ConfigMap（如果需要修改配置）
kubectl edit configmap nvidia-plugin-configs -n kube-system

# 给节点打标签以应用特定配置
kubectl label node k3d-gputest-server-0 nvidia.com/device-plugin-config=group-3 --overwrite

kubectl label node k3d-gputest-agent-1 nvidia.com/device-plugin-config=group-1 --overwrite

# 查看某个pod中的GPU使用情况（docker in docker container）
kubectl exec -it nvidia-device-plugin-daemonset-server-0-tv4cl -n kube-system -- nvidia-smi



# 因为改了配置想让它重新加载，不需要手动关闭，直接用这个命令触发滚动更新：

```Bash
kubectl rollout restart daemonset <daemonset-name> -n <namespace>
```
