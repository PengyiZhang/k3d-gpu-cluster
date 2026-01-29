ARG K3S_TAG="v1.33.4-k3s1"
ARG CUDA_TAG="12.2.2-cudnn8-runtime-ubuntu22.04"

FROM rancher/k3s:$K3S_TAG as k3s
FROM nvcr.io/nvidia/cuda:$CUDA_TAG

# Install the NVIDIA container toolkit
RUN apt-get update && apt-get install -y curl
RUN curl -fsSL -k https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -s -L -k https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
      tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# RUN curl -fsSL -k https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
# RUN curl -s -L -k https://nvidia.github.io/libnvidia-container/ubuntu22.04/libnvidia-container.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

RUN apt -o Acquire::https::Verify-Peer=false -o Acquire::https::Verify-Host=false update 
RUN apt -o Acquire::https::Verify-Peer=false -o Acquire::https::Verify-Host=false install -y nvidia-container-toolkit 

RUN nvidia-ctk runtime configure --runtime=containerd

COPY --from=k3s / / --exclude=/bin
COPY --from=k3s /bin /bin

# 新增离线下载的各种依赖，在镜像构建的同时，直接把服务依赖的基础镜像也打包安装进对应的容器
# NOTE: 通过volume挂载的方式拷贝进去会更好一些
# COPY k3d-base-images.tar /root/k3d-base-images.tar

# --------------
# NOTE: 只有服务启动时才能执行该命令，否则会报错找不到 containerd.sock 
# RUN echo "Importing base k3d images..."
# RUN ctr -n k8s.io images import /root/k3d-base-images.tar

# --------------
# NOTE: 需要根据情况修改 device-plugin-daemonset.yaml 文件，以确保插件只扫描指定的 GPU 设备
# 先不拷贝到容器里面，后面再拷贝至容器节点中
# RUN echo "update device-plugin-daemonset.yaml on startup"
# COPY device-plugin-daemonset.yaml /var/lib/rancher/k3s/server/manifests/nvidia-device-plugin-daemonset.yaml

VOLUME /var/lib/kubelet
VOLUME /var/lib/rancher/k3s
VOLUME /var/lib/cni
VOLUME /var/log

ENV PATH="$PATH:/bin/aux"

RUN echo "复制拷贝命令"
COPY load_image.sh /load_image.sh


# 修改入口点
ENTRYPOINT ["/bin/k3s"]
CMD ["agent"]

# COPY import.sh /import.sh

# ENTRYPOINT ["/bin/sh","/import.sh"]

