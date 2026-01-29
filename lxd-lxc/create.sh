#!/bin/bash

# 确保脚本以 bash 运行
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

echo "开始创建 6 个虚拟 K8s 节点..."

for i in {0..5}; do
  CONTAINER_NAME="k8s-node-$i"
  
  # 创建容器
  lxc launch ubuntu:22.04 "$CONTAINER_NAME"
  
  # 资源限制：防止挤兑物理机
  lxc config set "$CONTAINER_NAME" limits.cpu 8
  lxc config set "$CONTAINER_NAME" limits.memory 64GiB
  
  # GPU 透传：按索引绑定 A100
  # 注意：这需要 nvidia-smi 正常工作
  GPU_PCI=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader | sed -n "$((i+1))p")
  lxc config device add "$CONTAINER_NAME" "gpu$i" gpu gid=1000 pci="$GPU_PCI"
  
  echo "节点 $CONTAINER_NAME 已启动并绑定 GPU: $GPU_PCI"
done

echo "所有节点创建完成。你可以开始安装 K3s 了。"
