# Middleware K8s Stack

一个面向 Kubernetes 的中间件快速部署项目，默认使用 Helm 安装主流中间件，并把运行镜像统一替换为阿里云镜像仓库：

- ZooKeeper
- Kafka
- Redis
- RabbitMQ

默认目标镜像仓库：

```text
registry.cn-guangzhou.aliyuncs.com/tools_y
```

## 设计思路

这个项目不重复造每个中间件的 Helm Chart，而是复用 Bitnami 的成熟 chart，并在本项目里维护：

- 统一的一键部署脚本
- dev/prod 两套 values
- 阿里云镜像覆盖配置
- 缺失镜像的同步脚本
- 可选 Helmfile 编排入口

## 前置条件

本机需要：

```bash
helm version
kubectl version --client
docker version
```

如果阿里云镜像仓库是私有的，先登录：

```bash
docker login registry.cn-guangzhou.aliyuncs.com
```

Kubernetes 集群里也需要镜像拉取密钥：

```bash
kubectl create namespace middleware

kubectl -n middleware create secret docker-registry aliyun-registry \
  --docker-server=registry.cn-guangzhou.aliyuncs.com \
  --docker-username='<your-aliyun-username>' \
  --docker-password='<your-aliyun-password>'
```

因为 Bitnami chart 会校验官方镜像，项目已经在公共 values 里设置：

```yaml
global:
  security:
    allowInsecureImages: true
```

这表示我们明确允许使用同步到阿里云后的镜像。

## 第一步：同步缺失镜像到阿里云

同步全部中间件镜像：

```bash
scripts/mirror-images.sh all
```

只同步部分组件：

```bash
scripts/mirror-images.sh kafka redis
```

默认按 `linux/amd64` 拉取和推送。如果你的 K8s 节点是 ARM：

```bash
PLATFORM=linux/arm64 scripts/mirror-images.sh all
```

脚本默认会优先使用 `docker buildx imagetools create` 做远程复制，这通常比本地完整 `pull/tag/push` 更快，也能尽量保留多架构 manifest。如果远程复制失败，会自动回退到本地拉取再推送。强制使用远程复制：

```bash
COPY_MODE=remote scripts/mirror-images.sh all
```

镜像清单在 [config/images.txt](config/images.txt)，后续加 MySQL、Nacos、MinIO、Elasticsearch 时，先往这里追加镜像映射。

说明：Bitnami 的部分 `docker.io/bitnami/*` 镜像标签现在已经不可直接拉取，镜像同步清单使用 `docker.io/bitnamilegacy/*` 作为上游源，再推送到你的阿里云仓库。

## 第二步：部署

最快路径：

```bash
NAMESPACE=middleware-dev STORAGE_CLASS=local-path scripts/quickstart.sh all
```

生产环境示例：

```bash
ENVIRONMENT=prod NAMESPACE=middleware-prod STORAGE_CLASS=huawei-sc scripts/quickstart.sh all
```

`quickstart.sh` 会自动检查 Helm/kubectl、namespace、StorageClass、镜像拉取 Secret，然后调用 `deploy.sh`。

部署全部：

```bash
scripts/deploy.sh all
```

只部署某几个：

```bash
scripts/deploy.sh redis rabbitmq
```

使用生产配置：

```bash
ENVIRONMENT=prod NAMESPACE=middleware-prod scripts/deploy.sh all
```

部署到不同 namespace，并使用不同 CSI/StorageClass：

```bash
NAMESPACE=middleware-dev STORAGE_CLASS=local-path scripts/deploy.sh all
NAMESPACE=middleware-test STORAGE_CLASS=nfs-csi scripts/deploy.sh all
NAMESPACE=middleware-prod STORAGE_CLASS=huawei-sc ENVIRONMENT=prod scripts/deploy.sh all
```

这里的 `STORAGE_CLASS` 会覆盖 values 里的 `global.defaultStorageClass`。Bitnami chart 会把它传给 PVC 的 `storageClassName`，也就是最终使用哪个 CSI 由 Kubernetes 集群里的 StorageClass 决定。

部署前自动同步镜像：

```bash
MIRROR_IMAGES=true scripts/deploy.sh all
```

## 替换镜像版本

替换镜像版本需要做两件事：

- 更新 [config/images.txt](config/images.txt)，让同步脚本知道从哪里拉新镜像、推到阿里云哪个 tag。
- 更新对应环境的 values，让 Helm 部署时使用新 tag。

推荐用脚本统一改，避免漏改：

```bash
scripts/set-image-tag.sh rabbitmq rabbitmq 4.1.4-debian-12-r0 docker.io/bitnamilegacy/rabbitmq:4.1.4-debian-12-r0
scripts/mirror-images.sh rabbitmq
scripts/deploy.sh rabbitmq
```

只改 dev 环境：

```bash
ENVIRONMENT=dev scripts/set-image-tag.sh redis redis 8.6.4 docker.io/bitnamilegacy/redis:latest
scripts/mirror-images.sh redis
scripts/deploy.sh redis
```

只临时测试某个镜像 tag，也可以不改文件，直接用 Helm 的 `--set-string`：

```bash
helm upgrade --install rabbitmq oci://registry-1.docker.io/bitnamicharts/rabbitmq \
  --version 16.0.14 \
  -n middleware \
  -f envs/dev/global.yaml \
  -f envs/dev/rabbitmq.yaml \
  --set-string image.tag=4.1.4-debian-12-r0
```

## 查看状态

```bash
scripts/status.sh
```

指定命名空间：

```bash
NAMESPACE=middleware-prod scripts/status.sh
```

## 访问方式

RabbitMQ 管理台：

```bash
kubectl -n middleware port-forward svc/rabbitmq 15672:15672
```

浏览器打开：

```text
http://127.0.0.1:15672
```

默认账号密码：

```text
admin / rabbitmq@123456
```

Redis 本地访问：

```bash
kubectl -n middleware port-forward svc/redis-master 6379:6379
```

Kafka 本地访问：

```bash
kubectl -n middleware port-forward svc/kafka 9092:9092
```

ZooKeeper 本地访问：

```bash
kubectl -n middleware port-forward svc/zookeeper 2181:2181
```

## 卸载

卸载全部 release：

```bash
scripts/uninstall.sh all
```

连 PVC 一起删：

```bash
DELETE_PVC=true scripts/uninstall.sh all
```

## Helmfile 可选用法

如果你安装了 `helmfile`，也可以批量部署：

```bash
helmfile -e dev apply
helmfile -e prod apply
```

当前脚本入口不强依赖 Helmfile，更适合在新机器上快速拉起。

## 版本矩阵

| 组件 | Chart | 应用版本 | 默认阿里云镜像 |
| --- | --- | --- | --- |
| Kafka | bitnami/kafka `32.4.3` | `4.0.0` | `registry.cn-guangzhou.aliyuncs.com/tools_y/kafka:4.0.0-debian-12-r10` |
| Redis | bitnami/redis `25.5.2` | `8.6.3` | `registry.cn-guangzhou.aliyuncs.com/tools_y/redis:8.6.3` |
| RabbitMQ | bitnami/rabbitmq `16.0.14` | `4.1.3` | `registry.cn-guangzhou.aliyuncs.com/tools_y/rabbitmq:4.1.3-debian-12-r1` |
| ZooKeeper | bitnami/zookeeper `13.8.7` | `3.9.3` | `registry.cn-guangzhou.aliyuncs.com/tools_y/zookeeper:3.9.3-debian-12-r21` |

## 生产建议

- dev 默认配置偏轻量，适合测试环境快速验证。
- prod 默认副本数更高，但密码仍是示例值，上生产前请改成 Secret 或外部密钥管理。
- Kafka 默认使用 KRaft，不依赖 ZooKeeper。
- RabbitMQ、Kafka 如果后续要做更严肃的生产运维，建议逐步引入官方 Operator 管理扩缩容、滚动升级和故障恢复。
