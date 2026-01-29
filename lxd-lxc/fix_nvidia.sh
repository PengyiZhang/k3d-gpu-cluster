for i in 0 1 2 3 4 5; do
  lxc config set k8s-node-$i security.privileged true
  # 开启驱动透传
  lxc config set k8s-node-$i nvidia.driver.capabilities all
  # 也可以强制指定版本匹配（可选）
  lxc config set k8s-node-$i nvidia.runtime true
  
  # 重启容器生效
  lxc restart k8s-node-$i
done
