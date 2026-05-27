# RHEL 8.6 On-Prem AWX 主流部署方案与实施步骤

**用途**：用于验证 `AAP_DB_RU_命令式Runbook完整开发实施方案_v3_AWX验证适配版` 中的 AWX/AAP 自动化对象与流程，包括：

- Project
- Inventory
- Credential
- Job Template
- Workflow Job Template
- Workflow Visualizer
- Approval Node
- Prompt on Launch
- Survey
- Limit
- Extra Vars
- Summary/Gate 节点
- 27 个 DB RU step 的流程编排验证

---

## 1. 结论与部署选择

### 1.1 本方案采用的方式

本方案采用：

```text
RHEL 8.6
  + k3s 单节点 Kubernetes
  + AWX Operator
  + AWX Web UI
  + NodePort 暴露访问
```

这是当前 AWX 主流部署方式中，**最简单、最适合 on-prem 测试验证** 的方式。

### 1.2 为什么选择 k3s + AWX Operator

AWX 当前主流部署方式是通过 **AWX Operator 部署到 Kubernetes 集群**。AWX Operator 官方文档说明：在已有 Kubernetes 集群后，可以使用 Kustomize 部署 AWX Operator，再通过 AWX 自定义资源创建 AWX 实例。

k3s 是轻量级 Kubernetes，适合单机测试环境。它不是 Docker 部署方式，也不需要单独安装 Docker。k3s 默认使用 containerd 作为容器运行时，更适合快速搭建 AWX Web UI 验证环境。

### 1.3 本方案定位

本方案定位为：

```text
用于 DB RU 自动化方案的 AWX 验证环境
不是生产级 AAP 替代环境
不是生产级 AWX HA 环境
```

用于验证：

```text
1. Web UI 操作流程
2. Project / Inventory / Credential / Job Template 配置
3. Workflow Visualizer 串联 27 个 step
4. Approval 节点暂停、批准、拒绝、超时行为
5. Prompt on Launch 传 step_id / limit / variables
6. Summary/Gate 节点输出审批依据
7. 后续迁移到 AAP 时的配置可行性
```

---

## 2. 版本建议

### 2.1 推荐版本

| 组件 | 建议版本 |
|---|---|
| OS | RHEL 8.6 |
| Kubernetes | k3s stable |
| AWX Operator | 2.19.1 |
| AWX | 24.6.1 |
| 访问方式 | NodePort |
| 数据库 | AWX Operator 默认内置 PostgreSQL |
| 存储 | k3s local-path storage |
| 部署模式 | 单节点测试 |

AWX Operator 2.19.1 对应 AWX 24.6.1。该版本适合用于当前 DB RU 自动化方案的 Web UI 与 Workflow 验证。

### 2.2 注意

AWX 是 AAP automation controller 的 upstream 项目。AWX 适合做功能验证和流程验证；最终生产运行仍建议使用 AAP。

迁移到 AAP 时，需要重新验证：

```text
1. Execution Environment
2. Credential 权限
3. RBAC
4. Workflow Approval 权限
5. Project Sync
6. Inventory Source
7. Notification
8. 审计与日志保存策略
```

---

## 3. 环境规划

### 3.1 主机资源建议

| 项目 | 最低建议 | 推荐 |
|---|---:|---:|
| CPU | 4 core | 8 core |
| Memory | 16 GB | 24 GB |
| Disk | 100 GB | 200 GB |
| OS | RHEL 8.6 | RHEL 8.6 |
| Network | 能访问 GitHub / Quay / GHCR | 推荐可访问公网或企业镜像仓库 |
| User | root 或 sudo 用户 | root |

### 3.2 主机规划示例

```text
Hostname : awx-test01
IP       : 192.168.10.50
OS       : RHEL 8.6
AWX URL  : http://192.168.10.50:30080
```

### 3.3 需要访问的外部地址

如果环境可以访问公网，需要至少允许：

```text
get.k3s.io
github.com
raw.githubusercontent.com
quay.io
ghcr.io
docker.io
registry.k8s.io
rpm.rancher.io
```

如果是内网隔离环境，需要提前准备：

```text
1. k3s 安装包
2. k3s-selinux RPM
3. AWX Operator 镜像
4. AWX Web/Task/EE/PostgreSQL/Redis 相关镜像
5. Git 仓库镜像或内网 GitLab
```

本方案优先按 **可访问公网或企业代理** 的方式编写，便于快速开始测试。

---

## 4. 部署拓扑

```text
+------------------------------------------------------+
| RHEL 8.6: awx-test01                                 |
|                                                      |
|  +-----------------------------------------------+   |
|  | k3s single-node Kubernetes                    |   |
|  |                                               |   |
|  |  Namespace: awx                               |   |
|  |                                               |   |
|  |  +----------------------------+               |   |
|  |  | AWX Operator               |               |   |
|  |  +----------------------------+               |   |
|  |                                               |   |
|  |  +----------------------------+               |   |
|  |  | AWX Web / Task / EE        |               |   |
|  |  +----------------------------+               |   |
|  |                                               |   |
|  |  +----------------------------+               |   |
|  |  | PostgreSQL                 |               |   |
|  |  +----------------------------+               |   |
|  |                                               |   |
|  |  Service: NodePort 30080                      |   |
|  +-----------------------------------------------+   |
|                                                      |
|  Browser: http://awx-test01:30080                    |
+------------------------------------------------------+
```

---

## 5. 部署前准备

以下操作建议使用 root 用户执行。

### 5.1 设置主机名

```bash
hostnamectl set-hostname awx-test01
```

检查：

```bash
hostnamectl
```

配置 `/etc/hosts`：

```bash
cat >> /etc/hosts <<'EOF'
192.168.10.50 awx-test01
EOF
```

将 `192.168.10.50` 替换为实际 IP。

---

### 5.2 配置时间同步

```bash
timedatectl status
```

如果未启用 chrony：

```bash
dnf install -y chrony
systemctl enable --now chronyd
chronyc tracking
```

---

### 5.3 安装基础工具

```bash
dnf install -y \
  git \
  curl \
  wget \
  tar \
  unzip \
  jq \
  vim \
  lsof \
  net-tools \
  bind-utils \
  openssl \
  python3 \
  python3-pip
```

---

### 5.4 关闭 swap

```bash
swapoff -a
```

检查：

```bash
free -h
```

如 `/etc/fstab` 中有 swap 配置，建议注释掉：

```bash
cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d_%H%M%S)
vi /etc/fstab
```

---

## 6. 防火墙与 SELinux 设置

### 6.1 firewalld 处理方式

k3s 官方文档建议关闭 firewalld；如果保留 firewalld，则需要开放 Kubernetes API Server、Pod CIDR 和 Service CIDR。

#### 方式 A：快速测试环境，关闭 firewalld

适合临时测试环境：

```bash
systemctl disable --now firewalld
systemctl status firewalld
```

#### 方式 B：保留 firewalld

如果必须保留 firewalld：

```bash
firewall-cmd --permanent --add-port=6443/tcp
firewall-cmd --permanent --add-port=30080/tcp
firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16
firewall-cmd --reload
```

检查：

```bash
firewall-cmd --list-all
firewall-cmd --zone=trusted --list-all
```

> 测试阶段为了减少网络干扰，建议优先使用方式 A。  
> 如果后续客户环境要求保留 firewalld，再按方式 B 固化。

---

### 6.2 SELinux 处理方式

建议先检查当前状态：

```bash
getenforce
```

#### 推荐方式：尽量保留 Enforcing

k3s 支持 SELinux。安装时可使用 `--selinux` 参数。

#### 快速测试方式：临时设置为 Permissive

如果安装或 Pod 启动过程中遇到 SELinux 拦截，可以临时设置：

```bash
setenforce 0
getenforce
```

如需永久改为 Permissive：

```bash
cp /etc/selinux/config /etc/selinux/config.bak.$(date +%Y%m%d_%H%M%S)
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
```

> 测试阶段可以使用 Permissive 快速排除问题。  
> 后续进入 AAP 生产环境时，应重新评估安全策略。

---

## 7. 安装 k3s

### 7.1 安装 k3s 单节点

执行：

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_CHANNEL=stable \
  INSTALL_K3S_EXEC="server --write-kubeconfig-mode=644 --disable traefik --selinux" \
  sh -
```

说明：

| 参数 | 说明 |
|---|---|
| `server` | 安装单节点 server |
| `--write-kubeconfig-mode=644` | 允许普通用户读取 kubeconfig |
| `--disable traefik` | 本方案使用 NodePort，不需要默认 Traefik |
| `--selinux` | 尽量启用 SELinux 支持 |

如果 `--selinux` 导致安装失败，可先改用：

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_CHANNEL=stable \
  INSTALL_K3S_EXEC="server --write-kubeconfig-mode=644 --disable traefik" \
  sh -
```

---

### 7.2 配置 kubectl

k3s 会自带 kubectl。

检查：

```bash
kubectl version --client
kubectl get nodes -o wide
```

如果提示找不到 kubeconfig：

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

可写入 root 环境：

```bash
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /root/.bashrc
source /root/.bashrc
```

---

### 7.3 验证 k3s 状态

```bash
systemctl status k3s --no-pager
kubectl get nodes -o wide
kubectl get pods -A
kubectl get sc
```

正常应看到：

```text
node 状态为 Ready
local-path storage class 存在
kube-system 相关 pod Running
```

示例：

```bash
kubectl get sc
```

预期：

```text
NAME                   PROVISIONER
local-path (default)   rancher.io/local-path
```

---

## 8. 部署 AWX Operator

### 8.1 设置版本变量

```bash
export AWX_NAMESPACE=awx
export AWX_NAME=awx-db-ru
export AWX_OPERATOR_TAG=2.19.1
export AWX_NODEPORT=30080
```

---

### 8.2 准备目录

```bash
mkdir -p /opt/awx/awx-operator
cd /opt/awx/awx-operator
```

---

### 8.3 创建 `kustomization.yaml`

```bash
cat > kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - github.com/ansible/awx-operator/config/default?ref=${AWX_OPERATOR_TAG}

images:
  - name: quay.io/ansible/awx-operator
    newTag: ${AWX_OPERATOR_TAG}

namespace: ${AWX_NAMESPACE}
EOF
```

---

### 8.4 部署 AWX Operator

```bash
kubectl apply -k .
```

检查：

```bash
kubectl get ns
kubectl -n ${AWX_NAMESPACE} get pods
```

等待 Operator Running：

```bash
kubectl -n ${AWX_NAMESPACE} wait \
  --for=condition=available \
  deployment/awx-operator-controller-manager \
  --timeout=300s
```

查看日志：

```bash
kubectl -n ${AWX_NAMESPACE} logs -f \
  deployment/awx-operator-controller-manager \
  -c awx-manager
```

---

## 9. 部署 AWX 实例

### 9.1 创建 AWX 自定义资源文件

```bash
cd /opt/awx/awx-operator

cat > awx-db-ru.yml <<EOF
---
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: ${AWX_NAME}
spec:
  service_type: NodePort
  nodeport_port: ${AWX_NODEPORT}
  ingress_type: none

  replicas: 1

  postgres_storage_requirements:
    requests:
      storage: 20Gi

  web_resource_requirements:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "2Gi"

  task_resource_requirements:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "3Gi"

  ee_resource_requirements:
    requests:
      cpu: "250m"
      memory: "512Mi"
    limits:
      cpu: "1"
      memory: "1Gi"
EOF
```

说明：

| 配置 | 说明 |
|---|---|
| `service_type: NodePort` | 通过节点端口访问 Web UI |
| `nodeport_port: 30080` | 固定访问端口，便于浏览器访问 |
| `ingress_type: none` | 不使用 Ingress，降低部署复杂度 |
| `postgres_storage_requirements` | 为内置 PostgreSQL 分配持久化存储 |
| `resource_requirements` | 限制资源，避免测试机资源被耗尽 |

---

### 9.2 将 AWX CR 加入 `kustomization.yaml`

```bash
cat > kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - github.com/ansible/awx-operator/config/default?ref=${AWX_OPERATOR_TAG}
  - awx-db-ru.yml

images:
  - name: quay.io/ansible/awx-operator
    newTag: ${AWX_OPERATOR_TAG}

namespace: ${AWX_NAMESPACE}
EOF
```

---

### 9.3 创建 AWX 实例

```bash
kubectl apply -k .
```

观察部署过程：

```bash
watch -n 5 "kubectl -n ${AWX_NAMESPACE} get pods,svc,pvc"
```

也可以查看 Operator 日志：

```bash
kubectl -n ${AWX_NAMESPACE} logs -f \
  deployment/awx-operator-controller-manager \
  -c awx-manager
```

正常情况下会看到类似资源：

```text
awx-db-ru-postgres-0
awx-db-ru-xxxxx
awx-db-ru-service
```

Pod 全部 Running 后继续下一步。

---

## 10. 访问 AWX Web UI

### 10.1 获取服务信息

```bash
kubectl -n ${AWX_NAMESPACE} get svc
```

确认 `awx-db-ru-service` 的 NodePort：

```bash
kubectl -n ${AWX_NAMESPACE} get svc ${AWX_NAME}-service
```

如果按本文设置，应为：

```text
http://<RHEL主机IP>:30080
```

例如：

```text
http://192.168.10.50:30080
```

---

### 10.2 获取 admin 密码

默认用户名：

```text
admin
```

获取密码：

```bash
kubectl -n ${AWX_NAMESPACE} get secret ${AWX_NAME}-admin-password \
  -o jsonpath="{.data.password}" | base64 --decode ; echo
```

---

### 10.3 浏览器登录

访问：

```text
http://192.168.10.50:30080
```

登录：

```text
Username: admin
Password: 上一步获取的密码
```

---

## 11. AWX 基础健康检查

登录前后都可以执行以下检查。

### 11.1 Kubernetes 侧检查

```bash
kubectl -n ${AWX_NAMESPACE} get pods -o wide
kubectl -n ${AWX_NAMESPACE} get svc
kubectl -n ${AWX_NAMESPACE} get pvc
kubectl -n ${AWX_NAMESPACE} get awx
```

### 11.2 AWX Pod 日志

```bash
kubectl -n ${AWX_NAMESPACE} logs deploy/${AWX_NAME} -c awx-web --tail=200
kubectl -n ${AWX_NAMESPACE} logs deploy/${AWX_NAME} -c awx-task --tail=200
```

如果 deployment 名称不一致，先执行：

```bash
kubectl -n ${AWX_NAMESPACE} get deploy
```

---

## 12. 用于 DB RU 自动化方案的 AWX 配置验证

AWX 部署完成后，开始验证前面 DB RU 自动化方案。

---

### 12.1 创建 Organization

AWX UI：

```text
Access Management -> Organizations -> Add
```

建议名称：

```text
DB_RU_Test_Org
```

---

### 12.2 创建 Project

AWX UI：

```text
Resources -> Projects -> Add
```

建议配置：

| 字段 | 值 |
|---|---|
| Name | `DB_RU_Automation_Project` |
| Organization | `DB_RU_Test_Org` |
| Source Control Type | Git |
| Source Control URL | `http://<git-server>/db-ru-automation.git` |
| Source Control Branch | `dev` 或 `main` |
| Update Revision on Launch | 建议启用 |
| Clean | 测试阶段可启用 |
| Delete | 测试阶段可关闭 |

项目目录建议保持：

```text
db-ru-automation/
├── playbooks/
│   └── run_ru_step.yml
├── scripts/
│   ├── ru_step_runner.sh
│   ├── steps/
│   ├── checks/
│   └── reports/
└── inventory/
```

验证点：

```text
1. Project Sync 成功
2. AWX 能识别 playbooks/run_ru_step.yml
3. Git 凭据、证书、代理没有问题
```

---

### 12.3 创建 Inventory

AWX UI：

```text
Resources -> Inventories -> Add
```

建议名称：

```text
DB_RU_Inventory
```

创建 Groups：

```text
db_nodes
node1
node2
```

添加 Hosts：

```text
cnzhjxd001dbadm01 -> node1, db_nodes
cnzhjxd001dbadm02 -> node2, db_nodes
```

测试阶段如果没有真实 RAC 主机，可以先添加 AWX 主机或两台 Linux 测试机，使用 mock step 验证 Workflow。

---

### 12.4 创建 Credentials

AWX UI：

```text
Resources -> Credentials -> Add
```

建议创建：

| Credential | Credential Type | 用途 |
|---|---|---|
| `DB_RU_root_credential` | Machine | root 类 step |
| `DB_RU_grid_credential` | Machine | grid 类 step |
| `DB_RU_oracle_credential` | Machine | oracle 类 step |
| `DB_RU_git_credential` | Source Control | Git 拉取项目 |

注意：

```text
1. 不要在脚本中写 su - root
2. 不要把密码写进 Git
3. 测试阶段可以用 SSH key
4. 如果使用 sudo/become，需要在 Credential 中配置 Privilege Escalation
```

---

### 12.5 创建通用 Job Templates

AWX UI：

```text
Resources -> Templates -> Add -> Add job template
```

创建 3~4 个通用 Job Template：

#### Job Template 1：DB_RU_RUN_ROOT

| 字段 | 值 |
|---|---|
| Name | `DB_RU_RUN_ROOT` |
| Inventory | `DB_RU_Inventory` |
| Project | `DB_RU_Automation_Project` |
| Playbook | `playbooks/run_ru_step.yml` |
| Credential | `DB_RU_root_credential` |
| Limit | 勾选 Prompt on Launch |
| Variables | 勾选 Prompt on Launch |
| Timeout | 7200 |

#### Job Template 2：DB_RU_RUN_GRID

| 字段 | 值 |
|---|---|
| Name | `DB_RU_RUN_GRID` |
| Inventory | `DB_RU_Inventory` |
| Project | `DB_RU_Automation_Project` |
| Playbook | `playbooks/run_ru_step.yml` |
| Credential | `DB_RU_grid_credential` |
| Limit | 勾选 Prompt on Launch |
| Variables | 勾选 Prompt on Launch |

#### Job Template 3：DB_RU_RUN_ORACLE

| 字段 | 值 |
|---|---|
| Name | `DB_RU_RUN_ORACLE` |
| Inventory | `DB_RU_Inventory` |
| Project | `DB_RU_Automation_Project` |
| Playbook | `playbooks/run_ru_step.yml` |
| Credential | `DB_RU_oracle_credential` |
| Limit | 勾选 Prompt on Launch |
| Variables | 勾选 Prompt on Launch |

#### Job Template 4：DB_RU_RUN_CHECK

可选，但建议创建：

| 字段 | 值 |
|---|---|
| Name | `DB_RU_RUN_CHECK` |
| Inventory | `DB_RU_Inventory` |
| Project | `DB_RU_Automation_Project` |
| Playbook | `playbooks/run_ru_step.yml` |
| Credential | 视检查脚本选择 |
| Limit | 勾选 Prompt on Launch |
| Variables | 勾选 Prompt on Launch |

---

### 12.6 单独测试 Job Template

先不要直接建完整 Workflow，先测试单个 JT。

启动 `DB_RU_RUN_ORACLE`，传入：

```yaml
step_id: "04"
step_name: "precheck_mock"
```

Limit：

```text
node1
```

验证：

```text
1. Job 能启动
2. 正确连接目标主机
3. 正确调用 run_ru_step.yml
4. 正确调用 ru_step_runner.sh
5. Job Output 中能看到 step_id
6. 返回码为 0 时 Job 成功
7. 返回码非 0 时 Job 失败
```

---

### 12.7 创建 Workflow Job Template

AWX UI：

```text
Resources -> Templates -> Add -> Add workflow template
```

建议名称：

```text
DB_RU_19_30_Rolling_Upgrade_Workflow
```

配置：

| 字段 | 值 |
|---|---|
| Organization | `DB_RU_Test_Org` |
| Inventory | `DB_RU_Inventory` |
| Survey | 建议启用 |
| Webhook | 可不启用 |

建议 Survey 字段：

| Survey 字段 | 示例 |
|---|---|
| `change_id` | `CHG20260527001` |
| `ru_version` | `19.30` |
| `operator` | `jiangtao` |
| `dry_run` | `true/false` |

---

### 12.8 在 Workflow Visualizer 中添加节点

进入：

```text
Workflow Template -> Visualizer
```

按以下原则配置：

```text
1. 27 个执行 step 用 Template Node
2. 每个 Template Node 复用 3~4 个通用 Job Template
3. 每个 Node 通过 Prompt 传入不同 step_id
4. 主链路全部使用 On Success
5. 失败分支可连接 Step 99 collect_failure_logs
6. 高风险步骤前插入 Summary/Gate + Approval
```

示例：Step 04

```text
Node Type: Template
Job Template: DB_RU_RUN_ORACLE
Limit: node1
Extra Vars:
  step_id: "04"
  step_name: "precheck"
```

示例：Step 12

```text
Node Type: Template
Job Template: DB_RU_RUN_ROOT
Limit: node2
Extra Vars:
  step_id: "12"
  step_name: "switch_node2_home"
```

---

### 12.9 添加 Approval 节点

建议 Workflow 形态：

```text
Step 04 -> Step 05 -> Step 05A -> Approval A -> Step 06
Step 10 -> Step 10A -> Approval B -> Step 11
Step 14 -> Step 14A -> Approval C -> Step 15
Step 18 -> Step 18A -> Approval D -> Step 19
Step 19 -> Step 19A -> Approval E -> Step 20
Step 24 -> Step 24A -> Approval F -> Step 25
```

Approval A 示例：

| 字段 | 值 |
|---|---|
| Name | `APPROVAL_A_AFTER_BACKUP` |
| Description | 查看 Step 05A Job Output，确认 precheck、backup、backup 目录和日志扫描均 PASS 后批准 |
| Timeout | 86400 |

连接：

```text
Step 05A On Success -> Approval A
Approval A On Success -> Step 06
Approval A On Failure -> Stop 或 Step 99
```

验证：

```text
1. Workflow 到 Approval A 后暂停
2. 审批人可以看到 Pending Approval
3. Approve 后进入 Step 06
4. Deny 后流程停止或进入失败分支
5. 超时后自动 Denied
```

---

## 13. 推荐的 AWX 验证顺序

不要一开始就直接执行真实 DB RU。建议分 4 轮验证。

### 13.1 第一轮：AWX 平台基础验证

验证：

```text
1. AWX Web UI 可访问
2. admin 可登录
3. Project 可同步
4. Inventory 可创建
5. Credential 可连接测试主机
6. Job Template 可运行 Hello World playbook
```

---

### 13.2 第二轮：Mock Step 验证

step 脚本只执行：

```bash
hostname
whoami
date
echo "step_id=${STEP_ID}"
touch /tmp/step_${STEP_ID}.done
```

验证：

```text
1. 27 个节点可串联
2. Prompt on Launch 生效
3. Limit 生效
4. Credential 生效
5. Approval 生效
6. Summary/Gate 生效
```

---

### 13.3 第三轮：非破坏性 Oracle 检查验证

允许执行：

```text
crsctl status resource -t
srvctl status database
srvctl status instance
sqlplus 查询 v$instance
sqlplus 查询 dba_registry_sqlpatch
检查 PDB 状态
检查 invalid object
```

不执行：

```text
srvctl stop instance
switch home
datapatch
rm -rf
```

---

### 13.4 第四轮：测试 RAC 完整 DB RU 验证

执行完整流程：

```text
27 个执行 step
+ 6 个 Summary/Gate step
+ 6 个 Approval node
+ 失败日志收集 step
```

---

## 14. 常见问题处理

### 14.1 AWX Web UI 无法访问

检查 service：

```bash
kubectl -n awx get svc
```

检查端口：

```bash
ss -lntp | grep 30080
```

从本机测试：

```bash
curl -I http://127.0.0.1:30080
```

如果本机可以，外部不行，检查防火墙：

```bash
firewall-cmd --list-all
```

---

### 14.2 Pod 一直 Pending

检查：

```bash
kubectl -n awx describe pod <pod_name>
kubectl get sc
kubectl -n awx get pvc
```

常见原因：

```text
1. local-path storage class 不存在
2. 磁盘空间不足
3. 资源不足
```

---

### 14.3 ImagePullBackOff

检查：

```bash
kubectl -n awx describe pod <pod_name>
```

常见原因：

```text
1. 不能访问 quay.io / ghcr.io / docker.io
2. 企业代理未配置
3. TLS/CA 证书不受信
4. 镜像被防火墙拦截
```

处理方向：

```text
1. 配置 HTTP/HTTPS 代理
2. 使用企业镜像仓库
3. 配置 k3s registries.yaml
4. 提前导入离线镜像
```

---

### 14.4 Project Sync 失败

检查：

```text
1. Git URL 是否可访问
2. Git Credential 是否正确
3. AWX 容器内是否信任 Git 证书
4. 分支名是否正确
5. playbook 路径是否正确
```

---

### 14.5 Job Template 连接目标主机失败

检查：

```text
1. Inventory 主机名是否可解析
2. Credential 用户是否正确
3. SSH key 是否配置
4. 目标主机防火墙是否允许 SSH
5. AWX Pod 到目标主机网络是否可达
```

可在目标机检查：

```bash
tail -f /var/log/secure
```

---

### 14.6 Workflow 到 Approval 不暂停

检查：

```text
1. 是否真的添加了 Approval Node
2. Step 05A 是否成功
3. Step 05A 与 Approval A 的连接是否为 On Success
4. Approval A 是否连接到 Step 06
5. 审批用户是否有权限
```

---

## 15. AWX 卸载

### 15.1 删除 AWX 实例

```bash
kubectl -n awx delete awx awx-db-ru
```

等待资源释放：

```bash
watch -n 5 "kubectl -n awx get pods,svc,pvc"
```

如需保留数据，不要删除 PVC。

---

### 15.2 删除 AWX Operator

```bash
cd /opt/awx/awx-operator
kubectl delete -k .
```

---

### 15.3 卸载 k3s

```bash
/usr/local/bin/k3s-uninstall.sh
```

---

## 16. 迁移到 AAP 时需要注意

AWX 验证通过后，迁移到 AAP 时建议按以下方式处理。

### 16.1 可直接复用的内容

| 内容 | 是否复用 |
|---|---|
| Git 代码仓库 | 可以 |
| `run_ru_step.yml` | 可以 |
| `ru_step_runner.sh` | 可以 |
| 27 个 step 脚本 | 可以 |
| 6 个 Summary/Gate 脚本 | 可以 |
| Inventory 分组设计 | 可以 |
| Job Template 命名设计 | 可以 |
| Workflow 拓扑设计 | 可以 |
| Approval 设计 | 可以 |

### 16.2 需要在 AAP 重新创建或重新验证的内容

| 内容 | 处理方式 |
|---|---|
| Organization | AAP 重新创建 |
| Project | AAP 重新创建并指向正式 Git |
| Inventory | AAP 重新创建或导入 |
| Credential | AAP 重新创建，不从 AWX 导出明文 |
| Job Template | AAP 重新创建或配置即代码导入 |
| Workflow Template | AAP 重新创建或配置即代码导入 |
| Approval 权限 | AAP 重新配置 |
| Execution Environment | AAP 重新验证 |
| RBAC | AAP 重新设计 |
| Audit / Notification | AAP 按客户规范配置 |

### 16.3 不建议做的事

```text
1. 不建议把 AWX 数据库直接迁移成 AAP 数据库
2. 不建议把 AWX 当作生产 AAP 替代
3. 不建议在 AWX 中保存生产 root 密码
4. 不建议在测试阶段直接执行生产 DB RU
```

---

## 17. 验收标准

AWX 部署验收：

| 检查项 | 通过标准 |
|---|---|
| k3s Node | Ready |
| AWX Operator | Running |
| AWX Web/Task Pod | Running |
| PostgreSQL Pod | Running |
| AWX Service | NodePort 30080 |
| Web UI | 可登录 |
| Admin 密码 | 可获取 |
| Project Sync | 成功 |
| Inventory | node1/node2/db_nodes 可用 |
| Credential | 可连接目标测试主机 |
| Job Template | 可运行 |
| Workflow | 可串联节点 |
| Approval | 可暂停、批准、拒绝 |
| Summary/Gate | 可输出审批依据 |

DB RU 自动化验证验收：

| 检查项 | 通过标准 |
|---|---|
| step_id 传递 | 每个节点可正确传入 |
| Limit | node1/node2/db_nodes 执行范围正确 |
| Credential | root/grid/oracle 权限隔离正确 |
| Summary | 可生成审批摘要 |
| Approval | 审批后才进入高风险步骤 |
| Failure | 失败后停止或进入日志收集 |
| Logs | AAP/AWX Job Output 与服务器日志均可追溯 |
| Mock Workflow | 27 step + 6 Summary + 6 Approval 全流程通过 |
| 非破坏性检查 | CRS/DB/PDB/sqlpatch 查询通过 |

---

## 18. 官方参考资料

1. AWX Operator Basic Install  
   https://docs.ansible.com/projects/awx-operator/en/latest/installation/basic-install.html

2. AWX Operator Network and TLS Configuration  
   https://docs.ansible.com/projects/awx-operator/en/latest/user-guide/network-and-tls-configuration.html

3. AWX Operator GitHub Repository  
   https://github.com/ansible/awx-operator

4. AWX GitHub Repository  
   https://github.com/ansible/awx

5. K3s Installation Requirements  
   https://docs.k3s.io/installation/requirements

6. K3s Advanced Configuration / SELinux  
   https://docs.k3s.io/advanced

7. AWX Community Documentation  
   https://docs.ansible.com/projects/awx/

---

## 19. 最终建议

用于当前 DB RU 自动化方案测试验证，建议采用以下路径：

```text
1. RHEL 8.6 单机安装 k3s
2. 通过 AWX Operator 部署 AWX 24.6.1
3. 使用 NodePort 暴露 Web UI
4. 在 AWX Web UI 中配置 Project / Inventory / Credential / Job Template
5. 用 Workflow Visualizer 构建 27 step + 6 Summary + 6 Approval
6. 先跑 mock step，再跑非破坏性 Oracle 检查
7. 最后在测试 RAC 上跑完整 RU 流程
8. 验证通过后，将设计迁移到 AAP UAT
```

一句话总结：

> **这个方案不是为了建设生产级 AWX，而是为了最快获得接近 AAP 的 Web UI、Workflow、Approval、Job Template 测试环境，用于验证 DB RU 自动化方案。**
