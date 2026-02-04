#/bin/sh
set -e 

NUM_AGENTS=3
# NOTE: 这个约束没啥作用: 透传所有
# CUDA_VISIBLE_DEVICES=2,3
# NVIDIA_VISIBLE_DEVICES=2,3
k3d cluster create --config ./k3d-cluster-dev.yaml \
    --image=nlc/rancher/k3s:v1.33.4-k3s1-cuda-12.2.2-cudnn8-runtime-ubuntu22.04 \
    --gpus all \
    --network k3d-llmcluster \
    --registry-use k3d-registry.localhost:5000 \
    --k3s-arg '--kubelet-arg=eviction-hard=nodefs.available<100Mi@all' \
    --volume /home/zhangpengyi/k3d-data/:/root/images@all \
    --volume /home/zhangpengyi/k3d-data/containerd-certs:/var/lib/rancher/k3s/agent/etc/containerd/certs.d@all \
    --agents ${NUM_AGENTS}

# NOTE: 基础镜像中已经打包pods创建所需的基础镜像
# 最终使用挂载的方式
# 直接加载images
# docker exec -it k3d-llmcluster-server-0 sh /load_image.sh
# for ((i=0; i<NUM_AGENTS; i++)); do
#     docker exec -it k3d-llmcluster-agent-${i} sh /load_image.sh
# done

# echo "加载基础镜像完毕..."

# # 部署example应用
# kubectl apply -f ./k3d-example/deploy-nginx.yaml && kubectl apply -f ./k3d-example/nginx-svc-nodeport.yaml
# docker exec -it k3d-llmcluster-server-0 ctr -n k8s.io images import /root/images/nginx_1.29.tar
# for ((i=0; i<NUM_AGENTS; i++)); do
#     docker exec -it k3d-llmcluster-agent-${i} ctr -n k8s.io images import /root/images/nginx_1.29.tar
# done

# echo "加载nginx应用镜像完毕..."


# # 拷贝 device-plugin-daemonset.yaml 文件到server节点
# echo "开始配置nvidia-device-plugin..."
# docker cp device-plugin-daemonset-agents-dev-3.yaml k3d-llmclusterdev-server-0:/var/lib/rancher/k3s/server/manifests/nvidia-device-plugin-daemonset.yaml

# # 部署应用并监测
# kubectl apply -f cuda-vector-add-loop3.yaml

# # 导入应用images
# docker exec -it k3d-llmcluster-server-0 ctr -n k8s.io images import /root/images/app.cuda-vector-add.tar
# for ((i=0; i<NUM_AGENTS; i++)); do
#     # 无需拷贝
#     # docker cp app_image.tar k3d-llmcluster-agent-${i}:/root/app_image.tar
#     docker exec -it k3d-llmcluster-agent-${i} ctr -n k8s.io images import /root/images/app.cuda-vector-add.tar
# done
# echo "k3d cluster created with GPU support."

# kubectl get pods -A -w -o wide



# 在集群层面导入镜像的命令示例:
# k3d image import /home/zhangpengyi/k3d-data/mp.tar -c llmcluster


