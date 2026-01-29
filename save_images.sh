#!/bin/bash
set -e
docker save -o k3d-base-images.tar \
    rancher/mirrored-coredns-coredns:1.12.3 \
    rancher/klipper-helm:v0.9.8-build20250709 \
    rancher/mirrored-metrics-server:v0.8.0 \
    rancher/mirrored-library-traefik:3.3.6 \
    rancher/klipper-lb:v0.4.13 \
    rancher/local-path-provisioner:v0.0.31 \
    rancher/mirrored-library-busybox:1.36.1 \
    rancher/mirrored-pause:3.6 \
    nvcr.io/nvidia/k8s-device-plugin:v0.15.0-rc.2

echo "Saved k3d base images to k3d-base-images.tar"