# 基于k3d在单节点多GPU下构建独立显卡多节点集群的环境

## Step 1: 构建兼容镜像

- 编辑Dockerfile

```bash
IMAGE_REGISTRY=nlc sh ./build.sh
```

## Step 2: 创建集群+部署测试应用

```bash
sh ./create_cluster.sh
```



