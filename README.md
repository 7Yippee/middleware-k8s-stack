# Middleware K8s Stack

面向 Kubernetes 的中间件快速部署项目。复用 Bitnami Helm Chart，运行镜像统一走私有/阿里云镜像仓库，配套脚本解决「私有集群 + 不方便访问公网」场景下的痛点。

包含的中间件：

- ZooKeeper
- Kafka
- Redis
- RabbitMQ

默认目标镜像仓库：

```text
registry.cn-guangzhou.aliyuncs.com/tools_y
```

## 什么时候用哪条命令

| 场景 | 推荐命令 |
| --- | --- |
| 第一次接入一个新集群 | `make doctor ENVIRONMENT=dev NAMESPACE=middleware-dev` |
| 镜像仓库还没有这些镜像 | `make mirror COMPONENTS=all` |
| 快速部署到测试 namespace | `make quickstart ENVIRONMENT=dev NAMESPACE=middleware-dev STORAGE_CLASS=local-path COMPONENTS=all` |
| 部署生产配置 | `make quickstart ENVIRONMENT=prod NAMESPACE=middleware-prod STORAGE_CLASS=huawei-sc COMPONENTS=all` |
| 只更新某个组件 | `make deploy COMPONENTS=redis NAMESPACE=middleware-dev` |
| 只看渲染结果，不部署 | `make dry-run COMPONENTS=rabbitmq NAMESPACE=middleware-dev` |
| 升级镜像版本 | `scripts/set-image-tag.sh ...` 后执行 `make mirror COMPONENTS=<component>` 和 `make deploy COMPONENTS=<component>` |

最高效的日常流程是：镜像只在第一次或升级版本时同步；平时部署直接跑 `quickstart` 或 `deploy`。不要每次部署都开 `MIRROR_IMAGES=true`，除非你明确知道阿里云仓库缺镜像。

## 设计思路

不重复造每个中间件的 Helm Chart，而是复用 Bitnami 的成熟 chart，并在本项目里维护：

- 统一的一键部署脚本（`scripts/`）和 Makefile 入口
- `dev` / `prod` 两套 values + 可选 `_hardening.yaml` 生产硬化覆盖层
- 阿里云/私有镜像覆盖配置
- 缺失镜像的同步脚本，支持 skopeo / crane / docker 多后端 + 离线打包
- 密码通过 Kubernetes Secret 注入，不入库
- `config/components.txt` 作为组件清单单一来源，`deploy.sh` / `uninstall.sh` / `helmfile.yaml` 共用

## 前置条件

本机需要：

```bash
helm version
kubectl version --client
# 至少一个镜像同步后端
skopeo --version   # 推荐（无需 docker daemon）
# 或者
crane version
# 或者
docker version
```

如果目标集群里镜像仓库是私有的，登录并准备好凭据：

```bash
docker login registry.cn-guangzhou.aliyuncs.com
# 或者用文件保存密码，避免进 shell history
echo 'your-password' > ~/.aliyun-password && chmod 600 ~/.aliyun-password
```

跑一次体检，确认集群、StorageClass、镜像仓库都就位：

```bash
scripts/doctor.sh
```

## 最快路径（推荐）

如果镜像已经在私有仓库里，直接部署：

```bash
make quickstart ENVIRONMENT=dev NAMESPACE=middleware-dev STORAGE_CLASS=local-path COMPONENTS=all
```

如果是第一次准备一个全新环境，按下面顺序跑：

```bash
# 1. 体检
make doctor ENVIRONMENT=dev NAMESPACE=middleware-dev

# 2. 生成随机密码（写入 k8s Secret，不落盘）
make secrets NAMESPACE=middleware-dev

# 3. 同步镜像到你的私有仓库
make mirror COMPONENTS=all

# 4. 部署
make quickstart ENVIRONMENT=dev NAMESPACE=middleware-dev COMPONENTS=all STORAGE_CLASS=local-path
```

等价的纯脚本路径：

```bash
NAMESPACE=middleware-dev STORAGE_CLASS=local-path GEN_SECRETS=true scripts/quickstart.sh all
```

## 镜像同步

### 在线环境

```bash
# 默认 auto 后端，优先用 skopeo > crane > docker
scripts/mirror-images.sh all

# 只同步部分组件（会自动带上 shared 镜像）
scripts/mirror-images.sh kafka redis

# 强制指定后端
BACKEND=skopeo scripts/mirror-images.sh all
BACKEND=crane  scripts/mirror-images.sh all
BACKEND=docker scripts/mirror-images.sh all

# ARM 节点
PLATFORM=linux/arm64 scripts/mirror-images.sh all
```

说明：Bitnami 的部分 `docker.io/bitnami/*` 镜像标签现在已经不可直接拉取，清单使用 `docker.io/bitnamilegacy/*` 作为上游源，再推送到你的仓库。Bitnami chart 会校验官方镜像，项目已在公共 values 里设置 `global.security.allowInsecureImages: true`。

### 离线/内网环境

跳板机上先打包：

```bash
EXPORT_DIR=./offline-bundle scripts/mirror-images.sh all
# 或
make offline-export
```

把 `offline-bundle/` 整个拷贝到内网机器，然后推送到内网私有仓库：

```bash
ALIYUN_REGISTRY=harbor.internal ALIYUN_NAMESPACE=middleware \
IMPORT_FROM=./offline-bundle scripts/mirror-images.sh all
# 或
make offline-import
```

离线模式要求 `skopeo` 或 `crane`。

### Chart 离线缓存

```bash
scripts/pull-charts.sh all          # 下载到 ./charts/<name>-<version>.tgz
USE_LOCAL_CHARTS=true scripts/deploy.sh all   # 部署时只用本地缓存
```

## 密码管理

项目默认不再把密码写进 values，而是从 Kubernetes Secret 读取（Bitnami chart 的 `existingSecret` 模式）：

| 组件 | Secret | key |
| --- | --- | --- |
| RabbitMQ | `rabbitmq-auth` | `rabbitmq-password`, `rabbitmq-erlang-cookie` |
| Redis | `redis-auth` | `redis-password` |

生成/轮换：

```bash
# 不存在时创建，存在则跳过
scripts/gen-secrets.sh

# 只处理某一个
scripts/gen-secrets.sh redis

# 强制轮换（覆盖现有 Secret；注意重启 Pod 才会生效）
ROTATE=true scripts/gen-secrets.sh

# 预览 manifest 不落库
DRY_RUN=true scripts/gen-secrets.sh

# 使用自定义密码
RABBITMQ_PASSWORD='my-pw' scripts/gen-secrets.sh rabbitmq
```

阿里云仓库凭据同样不要直接走环境变量写进 history：

```bash
ALIYUN_USERNAME=xxx ALIYUN_PASSWORD_FILE=~/.aliyun-password scripts/quickstart.sh all
```

## 部署

```bash
scripts/deploy.sh all                     # 部署全部
scripts/deploy.sh redis rabbitmq          # 部署部分
ENVIRONMENT=prod NAMESPACE=middleware-prod scripts/deploy.sh all
NAMESPACE=middleware-dev STORAGE_CLASS=local-path scripts/deploy.sh all
MIRROR_IMAGES=true scripts/deploy.sh all  # 部署前先同步镜像
DRY_RUN=true scripts/deploy.sh all        # 只渲染不应用
```

### 本地覆盖

针对具体环境某个组件的临时调整，写到 `envs/<env>/<component>.local.yaml`（已被 `.gitignore` 忽略），`deploy.sh` 会自动叠加：

```bash
echo 'replicaCount: 5' > envs/prod/rabbitmq.local.yaml
scripts/deploy.sh rabbitmq
```

也可以显式传入：

```bash
EXTRA_VALUES=path/to/extra.yaml:path/to/another.yaml scripts/deploy.sh rabbitmq
```

### 生产硬化

`envs/prod/_hardening.yaml` 是 prod 默认叠加层，包含：反亲和、PDB、可选 NetworkPolicy 开关。

```bash
# 默认：prod 自动叠加，dev 不叠加
ENVIRONMENT=prod scripts/deploy.sh all

# 强制叠加 / 强制关闭
HARDENING=on  scripts/deploy.sh all
HARDENING=off scripts/deploy.sh all
```

## 替换镜像版本

```bash
# 改映射表 + 所有环境 values
scripts/set-image-tag.sh rabbitmq rabbitmq 4.1.4-debian-12-r0 \
  docker.io/bitnamilegacy/rabbitmq:4.1.4-debian-12-r0

# 再同步镜像 + 部署
scripts/mirror-images.sh rabbitmq
scripts/deploy.sh rabbitmq

# 只改 dev
ENVIRONMENT=dev scripts/set-image-tag.sh redis redis 8.6.4 docker.io/bitnamilegacy/redis:8.6.4-debian-12-r0
```

临时测试某个 tag 不落盘：

```bash
helm upgrade --install rabbitmq oci://registry-1.docker.io/bitnamicharts/rabbitmq \
  --version 16.0.14 -n middleware \
  -f envs/dev/global.yaml -f envs/dev/rabbitmq.yaml \
  --set-string image.tag=4.1.4-debian-12-r0
```

## 运维

查看状态：

```bash
scripts/status.sh                       # helm + pods/svc/pvc + top
VERBOSE=true scripts/status.sh          # 追加 non-Ready pod 的 describe + events
NAMESPACE=middleware-prod scripts/status.sh
```

拉日志：

```bash
scripts/logs.sh rabbitmq
NAMESPACE=middleware-prod TAIL_LINES=500 FOLLOW=false scripts/logs.sh kafka
```

卸载：

```bash
scripts/uninstall.sh all
DELETE_PVC=true scripts/uninstall.sh all           # 连 PVC 一起删（数据丢失）
DELETE_PVC=true DELETE_SECRETS=true scripts/uninstall.sh all  # 彻底清理
```

## 访问方式

```bash
# RabbitMQ 管理台
kubectl -n middleware port-forward svc/rabbitmq 15672:15672
# http://127.0.0.1:15672 (账号 admin，密码在 Secret rabbitmq-auth 里)
kubectl -n middleware get secret rabbitmq-auth -o jsonpath='{.data.rabbitmq-password}' | base64 -d; echo

# Redis
kubectl -n middleware port-forward svc/redis-master 6379:6379
kubectl -n middleware get secret redis-auth -o jsonpath='{.data.redis-password}' | base64 -d; echo

# Kafka
kubectl -n middleware port-forward svc/kafka 9092:9092

# ZooKeeper
kubectl -n middleware port-forward svc/zookeeper 2181:2181
```

## Helmfile 可选路径

`helmfile.yaml` 已经改造成从 `config/components.txt` 动态生成 releases，和 `deploy.sh` 共用同一份组件清单：

```bash
helmfile -e dev apply
helmfile -e prod apply
```

## 扩展到更多组件

`config/components.txt` 支持可选第 4 列，覆盖 chart 仓库：

```text
# component chart_name chart_version [chart_registry]
zookeeper zookeeper 13.8.7
kafka kafka 32.4.3
redis redis 25.5.2
rabbitmq rabbitmq 16.0.14
# nacos nacos 2.1.x https://nacos-group.github.io/nacos-k8s
# minio minio 14.x oci://registry-1.docker.io/bitnamicharts
```

加新组件时记得：

1. 在 `config/components.txt` 追加一行
2. 在 `envs/dev/<name>.yaml` 和 `envs/prod/<name>.yaml` 准备 values
3. 如果镜像要同步到私仓，在 `config/images.txt` 追加镜像映射
4. `config/images.txt` 里 `ALIYUN_NAMESPACE` 可通过环境变量覆盖，`set-image-tag.sh` 也支持

## Makefile 入口

```bash
make help                 # 查看所有 target
make doctor               # 体检
make pull-charts          # 本地缓存 chart
make mirror               # 同步镜像
make quickstart           # 预检 + namespace/secret 准备 + 部署
make secrets              # 生成/轮换密码 Secret
make deploy               # 部署
make dry-run              # 渲染不应用
make status               # 看状态
make logs COMPONENTS=kafka
make uninstall
make offline-export       # 离线打包
make offline-import       # 离线导入
```

常用变量：`ENVIRONMENT` / `NAMESPACE` / `COMPONENTS` / `STORAGE_CLASS`。

## 版本矩阵

| 组件 | Chart | 应用版本 | 默认镜像 |
| --- | --- | --- | --- |
| Kafka | bitnami/kafka `32.4.3` | `4.0.0` | `registry.cn-guangzhou.aliyuncs.com/tools_y/kafka:4.0.0-debian-12-r10` |
| Redis | bitnami/redis `25.5.2` | `8.6.3` | `registry.cn-guangzhou.aliyuncs.com/tools_y/redis:8.6.3` |
| RabbitMQ | bitnami/rabbitmq `16.0.14` | `4.1.3` | `registry.cn-guangzhou.aliyuncs.com/tools_y/rabbitmq:4.1.3-debian-12-r1` |
| ZooKeeper | bitnami/zookeeper `13.8.7` | `3.9.3` | `registry.cn-guangzhou.aliyuncs.com/tools_y/zookeeper:3.9.3-debian-12-r21` |

## 生产建议

- dev 配置偏轻量，适合快速验证；prod 副本数更高并默认叠加 `_hardening.yaml`（反亲和 / PDB）。
- 密码走 Secret，不要手写进 values。定期 `ROTATE=true scripts/gen-secrets.sh` 并配合 pod 重启生效。
- Kafka 默认使用 KRaft，不依赖 ZooKeeper；ZooKeeper 留作兼容/其他组件使用。
- 完全离线集群：先 `EXPORT_DIR=... mirror-images.sh`，再在内网 `IMPORT_FROM=... mirror-images.sh`，chart 用 `pull-charts.sh` + `USE_LOCAL_CHARTS=true`。
- 更严肃的生产运维可逐步引入 Kafka/RabbitMQ 官方 Operator。

## 目录结构

```
config/
  components.txt       # 组件 + chart 版本（唯一来源）
  images.txt           # 上游镜像 -> 私仓镜像 映射
envs/
  dev/
    global.yaml
    <component>.yaml
  prod/
    global.yaml
    _hardening.yaml    # prod 自动叠加
    <component>.yaml
scripts/
  lib/common.sh        # 日志、组件注册、密码生成等共享函数
  doctor.sh            # 预检
  quickstart.sh        # 一键：namespace/SC/pull-secret/Secret + deploy
  pull-charts.sh       # 离线缓存 chart
  mirror-images.sh     # 镜像同步（skopeo/crane/docker + 离线打包）
  gen-secrets.sh       # 生成/轮换 auth Secret
  set-image-tag.sh     # 统一改 images.txt + values
  deploy.sh            # helm upgrade --install
  status.sh            # 运行态快照
  logs.sh              # 按组件拉日志
  uninstall.sh         # 卸载 + 可选删 PVC/Secret
helmfile.yaml          # 可选路径（从 components.txt 生成）
Makefile               # make help 查看全部
```
