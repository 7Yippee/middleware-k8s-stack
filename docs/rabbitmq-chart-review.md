# rabbitmq-k8s-chart 部署文档优化建议

仓库：`https://github.com/7Yippee/rabbitmq-k8s-chart`

## 主要问题

1. README 里的默认值和实际 `values.yaml` 不一致。

   README 写的是 `192.168.3.53/base/rabbitmq:3.9.12-debian-10-r0`、`huawei-sc`、`10Gi`，实际 values 是 `registry.cn-guangzhou.aliyuncs.com/tools_y/rabbitmq:4.1.3-debian-12-r1`、`local-path`、`1Gi`。

2. `helm install --namespace rabbitmq-system` 不会真正部署到该 namespace。

   模板里写死使用 `.Values.namespace | default "default"`，所以只传 Helm 的 `--namespace` 时，渲染出来的资源仍然是 `default`。要么删除 values 里的 `namespace` 字段，统一使用 `.Release.Namespace`；要么文档必须要求 `--set namespace=rabbitmq-system`。

3. `Chart.yaml` 的 `appVersion` 仍是 `3.9.12`，但实际镜像是 RabbitMQ `4.1.3`。

   这会误导排障和审计，也会让 Helm labels 里的版本信息不准确。

4. `rabbitmq.persistence.enabled` 在模板里没有生效。

   即使设置 `rabbitmq.persistence.enabled=false`，`volumeClaimTemplates` 仍然会渲染出来。文档写了开关，但实际没有实现。

5. 反亲和性模板缩进有问题。

   渲染后 `matchLabels` 下面的 labels 会跑到同级，导致 `matchLabels` 为空，反亲和性基本不会按预期工作。

6. Secret 模板在使用 `existingSecret` 时仍然渲染一个空 Secret。

   更推荐在 `existingSecret` 不为空时不创建该 Secret，避免无意义资源和误解。

7. README 集群部署示例过轻。

   只写 `replicaCount: 3` 不够，还应该说明 StorageClass、反亲和性、资源请求、Erlang Cookie、密码 Secret、集群状态验证和 PVC 清理策略。

8. `NOTES.txt` 密码提示不准确。

   当前 values 里设置了 `rabbitmq.auth.password`，但 NOTES 在非 `existingSecret` 场景提示“请设置 existingSecret”，没有给出实际获取自动 Secret 的命令。

## 更快捷稳定的方式

对你这种“经常用 Helm 部署中间件”的场景，我建议不要每个中间件都自写一套 chart。更稳的路径是：

1. 使用成熟 chart 作为底座，例如 Bitnami chart。

2. 在自己的仓库里维护统一 values、镜像仓库覆盖、部署脚本和环境分层。

3. 部署前先同步镜像到自己的阿里云仓库，K8s 运行时只从内网或国内镜像仓库拉取。

4. 真正生产级 RabbitMQ/Kafka 再考虑 Operator。

   RabbitMQ 可以看官方 RabbitMQ Cluster Operator；Kafka 可以看 Strimzi。Operator 在扩缩容、滚动升级、证书、故障恢复方面更适合长期维护。

