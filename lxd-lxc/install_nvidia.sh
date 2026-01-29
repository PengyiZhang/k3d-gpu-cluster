# 批量在所有节点更新并安装基本的 NVIDIA 工具
for i in 0 1 2 3 4 5; do
  echo "正在配置节点 k8s-node-$i ..."
  # 更新源并安装 nvidia-utils (不需要安装完整驱动，只需工具)
  lxc exec k8s-node-$i -- apt-get update
  lxc exec k8s-node-$i -- apt-get install -y nvidia-utils-535-server # 根据你宿主机驱动版本调整
done
