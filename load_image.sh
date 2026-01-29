until [ -S /run/k3s/containerd/containerd.sock ]; do
  sleep 1
done

# 挂载的路径 --volume /home/zhangpengyi/k3d-data/:/root/images@all
ctr -n k8s.io images import /root/images/k3d-base-images.tar