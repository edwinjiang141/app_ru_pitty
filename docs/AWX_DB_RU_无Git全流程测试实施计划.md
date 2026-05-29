# AWX 无 Git 场景下 DB RU Runbook 全流程测试实施计划

> 适用状态：k3s 单节点、AWX Operator、AWX Web/Task/EE/PostgreSQL/Redis 等 Pod 已经正常 Running；当前阶段准备开始验证 `AAP_DB_RU_命令式Runbook完整开发实施方案_v3_AWX验证适配版.md` 中的 DB RU 自动化方案。
> 关键约束：AWX 所在 k3s 环境暂时无法访问 Git；DB/RAC 目标机器位于 k3s Pod 外部；本计划以“手工导入 Project 内容 + AWX 连接外部目标主机 + mock/check/real 分阶段验证”为主线。
> 最终目标：在 AWX 上完整跑通一次包含 27 个 DB RU step、6 个 Summary/Gate 节点、6 个 Approval 节点和失败日志收集节点的全流程 Workflow。

---

## 1. 测试总体目标和边界

### 1.1 总体目标

本测试不是重新设计 DB RU 自动化方案，而是在已经部署完成的 AWX/k3s 环境中，把前序设计落地为可运行对象：

```text
AWX Workflow Job Template
  + 手工导入的 AWX Project 内容
  + Inventory 指向 k3s Pod 外部目标主机
  + Machine Credential / sudo 权限
  + 3~4 个通用 Job Template
  + playbooks/run_ru_step.yml
  + ru_step_runner.sh
  + 27 个 step 脚本
  + 6 个 Summary/Gate 脚本
  + 6 个 Approval 节点
  + 可选 Step 99 失败日志收集
```

测试完成后，应证明：

1. AWX 能够从 Execution Environment Pod 连接到 k3s 外部目标主机；
2. AWX 能够在无 Git 的情况下运行手工导入的 Project 内容；
3. Workflow Node 能够通过 Prompt on Launch 向通用 Job Template 传递不同 `step_id`、`ru_run_mode`、`platform_mode`、`allow_destructive_step`、`change_id`；
4. 27 个 step 可以按顺序串联执行；
5. Summary/Gate 节点可以读取前序 step 的状态和日志，生成审批摘要；
6. Approval 节点可以正确暂停、批准、拒绝、超时；
7. Workflow 失败时不会继续执行后续高风险 step，并且可以触发或手工执行 Step 99 收集失败日志；
8. mock/check/real 三个阶段的验证边界清晰，不会在早期误执行真实破坏性命令。

### 1.2 测试边界

| 阶段 | 是否执行真实 DB RU | 说明 |
|---|---|---|
| Smoke | 否 | 只验证 AWX、Inventory、Credential、SSH、Project 手工导入、Hello World。 |
| Mock | 否 | 27 个 step 只输出 hostname/whoami/date/touch 状态文件。 |
| Check-only | 否 | 只执行非破坏性 Oracle/Grid 检查命令。 |
| UAT Real | 是，仅限测试 RAC | 执行完整 DB RU 流程，必须由变更窗口和审批人确认。 |
| Production | 不在本计划内 | AWX 验证通过不等于 AAP 生产可上线。 |

---

## 2. 总体实施顺序

建议严格按照以下顺序推进，不要直接从第 1 天跳到真实 DB RU：

```text
阶段 0：记录当前 AWX/k3s 基线
阶段 1：确认 AWX Pod 到外部目标主机的网络连通性
阶段 2：准备目标主机账号、sudo、目录和脚本运行环境
阶段 3：在无 Git 场景下手工导入 Project 内容
阶段 4：创建 AWX Organization / Inventory / Credential
阶段 5：创建通用 Job Template 并完成单步 Smoke 测试
阶段 6：落地 runner、27 个 mock step、6 个 summary step、Step 99
阶段 7：创建完整 Workflow：27 step + 6 summary + 6 approval + failure branch
阶段 8：执行 Full Mock 全流程
阶段 9：执行 Check-only 非破坏性验证
阶段 10：执行 UAT Real 全流程
阶段 11：固化结果，准备后续 AAP 回迁清单
```

每一阶段都必须有明确通过标准。任一阶段不通过，不进入下一阶段。

## 2.1 执行位置约定与傻瓜式总清单

为避免实施时不知道命令应该在哪台机器执行，本文后续所有可执行动作都按以下位置标识：

| 标识 | 含义 | 典型登录方式 | 说明 |
|---|---|---|---|
| **k3s 节点** | 已部署 k3s/AWX 的宿主机 | 以 `root` 或具备 `kubectl` 权限的用户 SSH 登录 | 执行 `kubectl`、生成测试文件、`kubectl cp`、创建本地归档目录。 |
| **AWX UI** | 浏览器访问 AWX Web 控制台 | 浏览器登录 AWX | 创建 Organization、Inventory、Credential、Job Template、Workflow、Approval。 |
| **AWX Task Pod** | AWX 的 task 容器 | 从 k3s 节点用 `kubectl exec` 进入 | 检查或写入 `/var/lib/awx/projects` Manual Project。 |
| **AWX EE/调试 Pod** | AWX Job 实际执行 Ansible 的容器网络环境 | 从 k3s 节点用 `kubectl run` 创建临时 Pod | 验证 Pod 网络能否访问外部 node1/node2。 |
| **node1/node2 目标主机** | k3s 外部 RAC/DB 主机 | 直接 SSH 到 node1/node2 | 创建 `aap_ru`、配置 `authorized_keys`、sudoers、自动化目录。 |
| **primary_exec_node** | 主控执行节点，通常是 node1 | 通过 AWX Limit 或直接 SSH 到 node1 | 执行 precheck、datapatch、Summary/Gate、CRS 对比等单点步骤。 |

傻瓜式执行顺序如下；如果某一步失败，先修复该步骤，不要跳到后面的真实升级步骤：

| 顺序 | 执行位置 | 操作 | 产出/通过标准 |
|---:|---|---|---|
| 0 | k3s 节点 | 记录 `kubectl get nodes/pods/svc/pvc` 等 AWX/k3s 基线。 | 明确 AWX namespace、AWX Task Pod、AWX Web 访问方式。 |
| 1 | k3s 节点 | 创建 `/root/db_ru_awx_test/evidence` 测试归档目录。 | 后续命令输出、截图、Job Output 有统一归档位置。 |
| 2 | k3s 节点 | 从宿主机测试到 node1/node2 的 ping 和 22 端口。 | k3s 节点能访问目标主机。 |
| 3 | AWX EE/调试 Pod | 从 Pod 网络测试到 node1/node2 的 22 端口。 | AWX Job 所在网络能访问目标主机。 |
| 4 | k3s 节点或安全管理机 | 生成 AWX 测试 SSH key pair。 | 得到 `.pub` 公钥和私钥。 |
| 5 | node1/node2 目标主机 | 创建 `aap_ru` 用户，把 `.pub` 公钥追加到 `authorized_keys`。 | `aap_ru` 可用该 key 登录 node1/node2。 |
| 6 | node1/node2 目标主机 | 配置 Smoke/Mock 阶段 sudoers 和 `/u01/patch1930/ru_automation` 目录。 | 目录存在、权限正确、sudoers 语法检查通过。 |
| 7 | k3s 节点 + AWX Task Pod | 手工创建 AWX Manual Project 目录并复制 `run_ru_step.yml`。 | AWX Project 能识别 `playbooks/run_ru_step.yml`。 |
| 8 | AWX UI | 创建 Organization、Inventory、Host、Group、Credential。 | Inventory 能表达 `db_nodes/node1/node2/primary_exec_node`，Credential 使用第 4 步私钥。 |
| 9 | AWX UI | 创建 3~4 个通用 Job Template，开启 Variables/Limit Prompt on Launch。 | 单个 JT 可以 Launch。 |
| 10 | k3s 节点 + node1/node2 | 生成并复制 `ru_step_runner.sh`、mock step、Summary step。 | 目标主机有 runner 和 step 脚本。 |
| 11 | AWX UI | 单独运行 `DB_RU_AWX_RUN_CHECK` 的 `step_id=00`。 | AWX 能 SSH 到目标主机并生成日志/state。 |
| 12 | AWX UI | 创建完整 Workflow：27 step + 6 Summary/Gate + 6 Approval + Step 99。 | Workflow 拓扑和 Limit/Extra Vars 完整。 |
| 13 | AWX UI | 以 `mock` 模式完整运行 Workflow。 | 全链路成功，Approval 可暂停和放行。 |
| 14 | AWX UI | 验证 Approval Deny/Timeout/无权限审批失败。 | 失败后不进入后续高风险 step。 |
| 15 | AWX UI + node1/node2 | 替换检查类脚本并以 `check` 模式运行。 | 只执行非破坏性 Oracle/Grid 检查。 |
| 16 | AWX UI + node1/node2 | 分批替换真实 step，在 UAT RAC 以 `real` 模式执行。 | 测试 RAC 完整 DB RU 成功或按预案中断/接管。 |
| 17 | k3s 节点 + node1/node2 + AWX UI | 归档 AWX Job Output、目标主机日志、状态文件、审批报告、截图。 | 形成 AAP 回迁依据。 |

---

## 3. 阶段 0：记录 AWX/k3s 当前基线

### 3.1 Kubernetes 侧检查

**执行位置：k3s 节点。**

执行：

```bash
kubectl get nodes -o wide
kubectl get ns
kubectl get pods -A -o wide
kubectl get svc -A
kubectl get pvc -A
kubectl get ingress -A
```

记录以下信息：

| 项目 | 记录值 |
|---|---|
| k3s 节点主机名 | `<填写>` |
| k3s 节点 IP | `<填写>` |
| AWX namespace | 通常为 `awx` 或 `awx-operator`，以实际为准 |
| AWX Web Service 名称 | `<填写>` |
| AWX Web NodePort | `<填写>` |
| AWX Web Pod 名称 | `<填写>` |
| AWX Task Pod 名称 | `<填写>` |
| AWX EE 镜像 | `<填写>` |
| PostgreSQL PVC | `<填写>` |

### 3.2 AWX 版本和组件检查

进入 AWX UI，记录：

| 项目 | 路径 | 记录值 |
|---|---|---|
| AWX Version | About 页面 | `<填写>` |
| Ansible Version | Job Output 或 About | `<填写>` |
| 默认 Execution Environment | Administration / Execution Environments | `<填写>` |
| 默认 Organization | Access Management / Organizations | `<填写>` |

### 3.3 结果归档目录

**执行位置：k3s 节点。**

创建本次测试归档目录：

```bash
mkdir -p /root/db_ru_awx_test/evidence/{k8s,awx,project,workflow,logs,screenshots}
```

后续每轮测试的截图、Job Output、Workflow 结果、`kubectl` 输出都放入此目录，便于复盘和迁移到 AAP。

---

## 4. 阶段 1：验证 AWX Pod 到外部目标主机的访问路径

### 4.1 访问关系说明

当前目标主机在 k3s Pod 之外，实际访问链路是：

```text
AWX Job 启动
  -> AWX Task 调度 Runner/Execution Environment Pod
  -> EE Pod 内 ansible 通过 SSH 连接外部目标主机
  -> 目标主机执行命令或脚本
```

因此，不能只验证 k3s 节点能 SSH 目标主机，还必须验证 **AWX Execution Environment Pod 所在的 Pod 网络能访问目标主机的 22 端口**。

### 4.2 确认目标主机清单

先明确本轮测试主机：

| 逻辑名 | 主机名 | IP | 角色 | 初期测试用户 | 备注 |
|---|---|---|---|---|---|
| node1 | `<node1-hostname>` | `<node1-ip>` | RAC node1 | `awx_test` 或 `aap_ru` | 外部主机 |
| node2 | `<node2-hostname>` | `<node2-ip>` | RAC node2 | `awx_test` 或 `aap_ru` | 外部主机 |
| primary_exec_node | `<通常为 node1>` | `<node1-ip>` | 汇总/主控节点 | `awx_test` 或 `aap_ru` | 用于 precheck/datapatch/summary |

### 4.3 从 k3s 节点测试网络

**执行位置：k3s 节点。**

执行：

```bash
ping -c 3 <node1-ip>
ping -c 3 <node2-ip>
nc -vz <node1-ip> 22
nc -vz <node2-ip> 22
```

如果 k3s 节点都无法访问目标主机，需要先处理路由、防火墙、目标主机安全策略或堡垒机策略。

### 4.4 从 AWX Task Pod 或临时调试 Pod 测试网络

**执行位置：k3s 节点。**

优先使用临时调试 Pod，避免修改 AWX 正式 Pod：

```bash
kubectl -n awx run net-debug --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi8/ubi:latest \
  -- bash
```

**执行位置：AWX EE/调试 Pod 内部。**

进入后执行：

```bash
cat /etc/resolv.conf
ip route
getent hosts <node1-hostname> || true
getent hosts <node2-hostname> || true
bash -c '</dev/tcp/<node1-ip>/22' && echo node1_ssh_port_ok
bash -c '</dev/tcp/<node2-ip>/22' && echo node2_ssh_port_ok
```

**执行位置：k3s 节点。**

如果镜像里没有 `bash`、`ip`、`getent` 等工具，可改用 AWX EE 镜像创建调试 Pod，镜像名称以实际 AWX Execution Environment 为准：

```bash
kubectl -n awx get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\n"}{end}{end}'
```

**执行位置：k3s 节点。**

然后：

```bash
kubectl -n awx run ee-debug --rm -it --restart=Never \
  --image=<awx-ee-image> \
  -- bash
```

### 4.5 常见网络问题处理

| 问题 | 现象 | 处理建议 |
|---|---|---|
| Pod 无法访问外部网段 | Pod 内 `</dev/tcp/ip/22` 失败，k3s 节点可访问 | 检查 k3s CNI、节点 FORWARD 策略、firewalld、iptables/nftables、上游网络 ACL。 |
| 目标主机只允许 k3s 节点 IP | Pod 访问被拒绝 | 放行 k3s 节点出接口源地址；如果启用了 SNAT，通常目标看到的是节点 IP。 |
| 目标主机只允许固定堡垒机 | SSH 超时或拒绝 | 测试环境建议临时放行 k3s 节点；若必须走堡垒机，需要在 AWX Credential/SSH config 中配置 ProxyCommand。 |
| DNS 解析失败 | `getent hosts hostname` 失败 | AWX Inventory 先使用 IP；或给 k3s CoreDNS 配置上游 DNS；或在 Inventory 变量中使用 `ansible_host=<ip>`。 |
| known_hosts 失败 | Job 报 host key checking | 测试阶段可在 Job Template Extra Vars 或 settings 中关闭 host key checking；正式阶段建议预置 known_hosts。 |

---

## 5. 阶段 2：准备外部目标主机

### 5.1 推荐账号模型

测试阶段建议使用一个专用自动化账号，例如：

```text
账号：aap_ru 或 awx_test
用途：AWX SSH 登录外部目标主机
权限：按阶段逐步放开 sudo/runuser 权限
```

不要在 AWX 测试阶段保存生产 root 密码。真实生产迁移到 AAP 时，Credential 需要重新创建并按客户安全规范审批。

### 5.2 生成 AWX 测试 SSH 密钥对

`authorized_keys` 中要粘贴的“AWX 测试 SSH 公钥”不是 AWX 自动生成的，需要由实施人员在安全的管理机或 k3s 节点上生成一对专用于本次 AWX 测试的 SSH key。推荐在 k3s 节点生成并保存在测试归档目录中。

**执行位置：k3s 节点，或者企业批准的安全管理机；以下命令以 k3s 节点为例。**


```bash
mkdir -p /root/db_ru_awx_test/ssh
ssh-keygen -t ed25519 \
  -f /root/db_ru_awx_test/ssh/aap_ru_awx_test_ed25519 \
  -C "aap_ru_awx_test_$(date +%Y%m%d)" \
  -N ''
chmod 600 /root/db_ru_awx_test/ssh/aap_ru_awx_test_ed25519
chmod 644 /root/db_ru_awx_test/ssh/aap_ru_awx_test_ed25519.pub
```

生成后会得到两个文件：

| 文件 | 用途 | 放置位置 |
|---|---|---|
| `/root/db_ru_awx_test/ssh/aap_ru_awx_test_ed25519.pub` | 公钥 | 追加到 node1/node2 的 `/home/aap_ru/.ssh/authorized_keys`。 |
| `/root/db_ru_awx_test/ssh/aap_ru_awx_test_ed25519` | 私钥 | 粘贴到 AWX Machine Credential 的 `SSH Private Key` 字段。 |

**执行位置：k3s 节点，或第 5.2 节生成密钥的安全管理机。**

查看需要粘贴到目标主机的公钥内容：

```bash
cat /root/db_ru_awx_test/ssh/aap_ru_awx_test_ed25519.pub
```

**执行位置：k3s 节点，或第 5.2 节生成密钥的安全管理机。**

查看需要粘贴到 AWX Credential 的私钥内容：

```bash
cat /root/db_ru_awx_test/ssh/aap_ru_awx_test_ed25519
```

安全要求：

1. 私钥只进入 AWX Credential，不要写入 Project、Playbook、step 脚本或目标主机文件；
2. 如果企业已有专用自动化密钥，也可以复用企业批准的公钥/私钥，但仍必须满足“公钥放目标主机、私钥放 AWX Credential”的对应关系；
3. 测试结束后，如果该密钥只是临时测试用途，需要从 node1/node2 的 `authorized_keys` 中删除对应公钥，并删除或归档本地私钥。

### 5.3 目标主机创建测试账号

**执行位置：node1 和 node2 目标主机，使用 root 或具备创建用户权限的系统管理员账号分别执行。**

在 node1/node2 上执行，其中 `<粘贴 AWX 测试 SSH 公钥>` 来自上一节生成的 `.pub` 文件：

```bash
useradd -m -s /bin/bash aap_ru
mkdir -p /home/aap_ru/.ssh
chmod 700 /home/aap_ru/.ssh
cat >> /home/aap_ru/.ssh/authorized_keys <<'EOF_KEY'
<粘贴 AWX 测试 SSH 公钥>
EOF_KEY
chmod 600 /home/aap_ru/.ssh/authorized_keys
chown -R aap_ru:aap_ru /home/aap_ru/.ssh
```

如果使用密码登录，也可以先跳过 SSH key，但建议尽快改成 key-based 方式。

### 5.4 sudoers 分阶段配置

#### 5.4.1 Smoke/Mock 阶段

**执行位置：node1 和 node2 目标主机，使用 root 分别执行。**

只允许基础命令，不允许破坏性命令：

```bash
cat > /etc/sudoers.d/aap_ru_db_ru_mock <<'EOF_SUDO'
aap_ru ALL=(root) NOPASSWD: /usr/bin/whoami, /usr/bin/hostname, /usr/bin/date, /usr/bin/mkdir, /usr/bin/touch, /usr/bin/cat, /usr/bin/tee, /usr/bin/test, /usr/bin/ls
EOF_SUDO
chmod 440 /etc/sudoers.d/aap_ru_db_ru_mock
visudo -cf /etc/sudoers.d/aap_ru_db_ru_mock
```

#### 5.4.2 Check-only 阶段

**执行位置：node1 和 node2 目标主机，使用 root 分别执行。**

允许切换到 grid/oracle 执行非破坏性检查命令。路径以现场实际为准：

```bash
cat > /etc/sudoers.d/aap_ru_db_ru_check <<'EOF_SUDO'
aap_ru ALL=(grid) NOPASSWD: /bin/bash, /usr/bin/bash, /usr/bin/whoami, /usr/bin/hostname, /usr/bin/date
aap_ru ALL=(oracle) NOPASSWD: /bin/bash, /usr/bin/bash, /usr/bin/whoami, /usr/bin/hostname, /usr/bin/date
EOF_SUDO
chmod 440 /etc/sudoers.d/aap_ru_db_ru_check
visudo -cf /etc/sudoers.d/aap_ru_db_ru_check
```

> 注意：Check-only 阶段只放行非破坏性检查；真实阶段必须按实际命令重新做最小化授权评审。

#### 5.4.3 UAT Real 阶段

真实 DB RU 阶段需要按每个 step 实际命令最小化授权，不建议直接给 `ALL=(ALL) NOPASSWD: ALL`。如果测试窗口紧张，至少应做到：

1. 只在 UAT RAC 节点授权；
2. 只在变更窗口期间授权；
3. sudoers 文件变更前后备份；
4. 所有授权命令路径使用绝对路径；
5. `rm -rf`、`srvctl stop`、`datapatch`、home switch 等高风险命令由 runner 的 `allow_destructive_step` 和 Summary/Approval 双重控制。

### 5.5 创建自动化目录

**执行位置：node1 和 node2 目标主机，使用 root 分别执行。**

在 node1/node2 上创建目录：

```bash
mkdir -p /u01/patch1930/ru_automation/{bin,conf,steps,checks,logs,state,reports,tmp,packages}
chown -R aap_ru:aap_ru /u01/patch1930/ru_automation
chmod -R 750 /u01/patch1930/ru_automation
```

目录用途：

| 目录 | 用途 |
|---|---|
| `bin` | `ru_step_runner.sh` 等通用执行器 |
| `conf` | `ru_env.conf`、`dangerous_paths.conf`、`step_matrix.conf` |
| `steps` | 27 个 step 脚本、6 个 summary 脚本、Step 99 |
| `checks` | 可复用检查脚本 |
| `logs` | 每个 step 的运行日志 |
| `state` | `step_xx.done`、`step_xx.failed`、`step_xx_result.json` |
| `reports` | Approval Summary Markdown 报告 |
| `tmp` | 临时文件 |
| `packages` | RU 包、gold image、脚本包等 |

---

## 6. 阶段 3：无 Git 场景下手工导入 AWX Project 内容

### 6.1 为什么不能只在目标主机放脚本

AWX Job Template 必须有 Project 和 Playbook。即使实际 DB RU 脚本运行在外部目标主机，AWX 仍然需要一个本地 Project 来提供：

```text
playbooks/run_ru_step.yml
inventories 可选样例
README 可选
```

所以无 Git 场景下要解决的是：**如何把 Project 内容放进 AWX 能识别的项目目录**。

### 6.2 推荐方式 A：使用 AWX 内置 Manual Project 目录

AWX 支持 Manual 类型 Project。手动 Project 的内容需要放在 AWX Project 持久化目录中。实际路径与 AWX Operator 配置有关，通常会挂载到 AWX Pod 的类似目录：

```text
/var/lib/awx/projects
```

**执行位置：k3s 节点。**

先确认 AWX Task Pod 的项目目录：

```bash
kubectl -n awx get pods
kubectl -n awx exec -it <awx-task-pod> -- bash -lc 'pwd; ls -ld /var/lib/awx/projects; mount | grep projects || true'
```

**执行位置：k3s 节点，通过 `kubectl exec` 在 AWX Task Pod 内创建目录。**

如果存在 `/var/lib/awx/projects`，创建项目目录：

```bash
kubectl -n awx exec -it <awx-task-pod> -- bash -lc 'mkdir -p /var/lib/awx/projects/db-ru-automation/playbooks'
```

**执行位置：k3s 节点。**

从 k3s 节点复制本地项目文件进去：

```bash
mkdir -p /root/db_ru_awx_test/project/playbooks
cat > /root/db_ru_awx_test/project/playbooks/run_ru_step.yml <<'EOF_PLAYBOOK'
---
- name: Run DB RU step through generic runner
  hosts: all
  gather_facts: false
  become: false

  vars:
    ru_base_dir: "/u01/patch1930/ru_automation"
    ru_run_mode: "{{ ru_run_mode | default('mock') }}"
    platform_mode: "{{ platform_mode | default('awx_test') }}"
    allow_destructive_step: "{{ allow_destructive_step | default(false) }}"
    change_id: "{{ change_id | default('AWX-TEST-CHG0001') }}"
    approval_report_required: "{{ approval_report_required | default(true) }}"

  tasks:
    - name: Validate required variable step_id
      ansible.builtin.assert:
        that:
          - step_id is defined
          - step_id | string | length > 0
        fail_msg: "step_id is required, for example step_id=04"

    - name: Show runtime parameters
      ansible.builtin.debug:
        msg:
          - "platform_mode={{ platform_mode }}"
          - "ru_run_mode={{ ru_run_mode }}"
          - "step_id={{ step_id }}"
          - "change_id={{ change_id }}"
          - "allow_destructive_step={{ allow_destructive_step }}"
          - "approval_report_required={{ approval_report_required }}"
          - "inventory_hostname={{ inventory_hostname }}"

    - name: Run RU step runner
      ansible.builtin.shell: |
        set -o pipefail
        {{ ru_base_dir }}/bin/ru_step_runner.sh \
          --step-id "{{ step_id }}" \
          --run-mode "{{ ru_run_mode }}" \
          --platform-mode "{{ platform_mode }}" \
          --change-id "{{ change_id }}" \
          --allow-destructive-step "{{ allow_destructive_step }}" \
          --approval-report-required "{{ approval_report_required }}"
      args:
        executable: /bin/bash
      register: ru_step_result
      changed_when: true
      failed_when: ru_step_result.rc != 0

    - name: Print RU step output
      ansible.builtin.debug:
        var: ru_step_result.stdout_lines
EOF_PLAYBOOK

kubectl -n awx cp /root/db_ru_awx_test/project/playbooks/run_ru_step.yml \
  <awx-task-pod>:/var/lib/awx/projects/db-ru-automation/playbooks/run_ru_step.yml
```

**执行位置：AWX UI，Resources -> Projects -> Add。**

在 AWX UI 创建 Project：

| 字段 | 值 |
|---|---|
| Name | `DB_RU_AWX_Manual_Project` |
| Organization | `DB_RU_Test_Org` |
| Source Control Type | `Manual` |
| Playbook Directory | `db-ru-automation` |

**执行位置：k3s 节点。**

如果 UI 不显示手工目录，先检查 AWX Task Pod 中是否能看到文件：

```bash
kubectl -n awx exec -it <awx-task-pod> -- bash -lc 'find /var/lib/awx/projects -maxdepth 3 -type f -print -exec sed -n "1,20p" {} \;'
```

### 6.2.1 Playbook 目录下拉框为空时的原因和处理

如果执行上面的 `find` 已经能在 **AWX Task Pod** 中看到：

```text
/var/lib/awx/projects/db-ru-automation/playbooks/run_ru_step.yml
```

但 AWX UI 仍提示：

```text
/var/lib/awx/projects 中没有可用的 playbook 目录
```

通常不是 playbook 内容问题，而是以下原因之一：

| 原因 | 现象 | 处理方式 |
|---|---|---|
| 只复制到了 AWX Task Pod，AWX Web Pod 看不到 | `task` Pod 中 `find` 能看到文件，但 UI 下拉框为空 | 同时检查 AWX Web Pod；如果 Web Pod 看不到，需要复制到 Web Pod，或配置 projects persistence。 |
| `/var/lib/awx/projects` 没有持久化共享 PVC | Pod 重启后文件消失，Web/Task 看到的内容不一致 | 使用 AWX Operator 配置 projects persistence，或测试阶段临时同时复制到 web/task。 |
| 目录层级选择不匹配 | 文件在 `db-ru-automation/playbooks/run_ru_step.yml`，但下拉框期望选择实际包含 playbook 的目录 | 优先选择 `db-ru-automation/playbooks`；如果仍不出现，按下面的 flat layout 处理。 |
| 文件权限/属主不合适 | Pod 内 root 能看到，但 `awx` 用户不可读 | 调整目录为 `755`、文件为 `644`，必要时 `chown -R awx:awx`。 |
| UI 缓存或 Project 页面未刷新 | 文件已复制但下拉框仍旧为空 | 退出 Project 创建页后重新进入，或刷新浏览器页面。 |

#### 第 1 步：同时确认 Web Pod 和 Task Pod 是否都能看到文件

**执行位置：k3s 节点。**

先找出 AWX Web/Task Pod 名称：

```bash
kubectl -n awx get pods -o wide
kubectl -n awx get pods -o name | egrep 'web|task'
```

分别检查 Web Pod 和 Task Pod 的 `/var/lib/awx/projects`：

```bash
AWX_WEB_POD=<填写-awx-web-pod-name>
AWX_TASK_POD=<填写-awx-task-pod-name>

kubectl -n awx exec -it "${AWX_WEB_POD}" -- bash -lc 'id; ls -ld /var/lib/awx/projects; find /var/lib/awx/projects -maxdepth 4 -type f \( -name "*.yml" -o -name "*.yaml" \)'
kubectl -n awx exec -it "${AWX_TASK_POD}" -- bash -lc 'id; ls -ld /var/lib/awx/projects; find /var/lib/awx/projects -maxdepth 4 -type f \( -name "*.yml" -o -name "*.yaml" \)'
```

判断方式：

| 检查结果 | 结论 | 下一步 |
|---|---|---|
| Web/Task 都能看到同一个 `run_ru_step.yml` | 共享或复制已正确 | 继续检查目录层级和权限。 |
| 只有 Task 能看到，Web 看不到 | UI 下拉框为空的最常见原因 | 按第 2 步复制到 Web Pod，或配置 projects persistence。 |
| Web/Task 都看不到 | 文件没有成功导入 AWX Project 目录 | 回到 6.2 重新执行 `kubectl cp`。 |

#### 第 2 步：测试阶段临时同时复制到 Web Pod 和 Task Pod

**执行位置：k3s 节点。**

如果当前只是为了尽快测试，而且还没有配置 projects persistence，可以临时把 Project 文件同时复制到 Web Pod 和 Task Pod：

```bash
AWX_WEB_POD=<填写-awx-web-pod-name>
AWX_TASK_POD=<填写-awx-task-pod-name>

for pod in "${AWX_WEB_POD}" "${AWX_TASK_POD}"; do
  kubectl -n awx exec -it "${pod}" -- bash -lc 'mkdir -p /var/lib/awx/projects/db-ru-automation/playbooks'
  kubectl -n awx cp /root/db_ru_awx_test/project/playbooks/run_ru_step.yml \
    "${pod}":/var/lib/awx/projects/db-ru-automation/playbooks/run_ru_step.yml
  kubectl -n awx exec -it "${pod}" -- bash -lc 'chmod -R a+rX /var/lib/awx/projects/db-ru-automation; find /var/lib/awx/projects/db-ru-automation -maxdepth 4 -type f -print'
done
```

> 注意：这是测试阶段的临时做法。只复制到 Pod 文件系统时，Pod 重建后文件可能丢失；稳定做法是配置 AWX projects persistence，或改用内网临时 Git。

#### 第 3 步：优先使用扁平目录降低 AWX 下拉框识别问题

**执行位置：k3s 节点。**

有些 AWX 版本在 Manual Project 下拉框中更容易识别“直接包含 playbook 的一级目录”。如果 `db-ru-automation/playbooks` 不出现在下拉框，可以把 playbook 直接放到 `db-ru-automation` 目录下：

```bash
AWX_WEB_POD=<填写-awx-web-pod-name>
AWX_TASK_POD=<填写-awx-task-pod-name>

for pod in "${AWX_WEB_POD}" "${AWX_TASK_POD}"; do
  kubectl -n awx exec -it "${pod}" -- bash -lc 'mkdir -p /var/lib/awx/projects/db-ru-automation'
  kubectl -n awx cp /root/db_ru_awx_test/project/playbooks/run_ru_step.yml \
    "${pod}":/var/lib/awx/projects/db-ru-automation/run_ru_step.yml
  kubectl -n awx exec -it "${pod}" -- bash -lc 'chmod -R a+rX /var/lib/awx/projects/db-ru-automation; find /var/lib/awx/projects/db-ru-automation -maxdepth 3 -type f -print'
done
```

然后在 AWX UI 创建 Project 时使用：

| 字段 | 值 |
|---|---|
| Source Control Type | `Manual` |
| Playbook Directory | `db-ru-automation` |

后续 Job Template 的 Playbook 字段应选择：

```text
run_ru_step.yml
```

如果仍采用原来的子目录方式，则 Project 的 Playbook Directory 应优先选择：

```text
db-ru-automation/playbooks
```

后续 Job Template 的 Playbook 字段选择：

```text
run_ru_step.yml
```

不要把 Project 的 Playbook Directory 选成 `db-ru-automation`，同时又在 Job Template 中填写 `playbooks/run_ru_step.yml`，否则不同 AWX 版本的 UI 扫描行为可能不一致。

#### 第 4 步：确认权限和刷新 UI

**执行位置：k3s 节点。**

```bash
AWX_WEB_POD=<填写-awx-web-pod-name>
AWX_TASK_POD=<填写-awx-task-pod-name>

for pod in "${AWX_WEB_POD}" "${AWX_TASK_POD}"; do
  kubectl -n awx exec -it "${pod}" -- bash -lc 'ls -ld /var/lib/awx/projects /var/lib/awx/projects/db-ru-automation; find /var/lib/awx/projects/db-ru-automation -maxdepth 3 -type f -ls'
done
```

如果 Pod 内存在 `awx` 用户，可以进一步设置属主：

```bash
for pod in "${AWX_WEB_POD}" "${AWX_TASK_POD}"; do
  kubectl -n awx exec -it "${pod}" -- bash -lc 'id awx >/dev/null 2>&1 && chown -R awx:awx /var/lib/awx/projects/db-ru-automation || true; chmod -R a+rX /var/lib/awx/projects/db-ru-automation'
done
```

最后回到 AWX UI：

1. 退出当前 Project 创建页面；
2. 重新进入 `Resources -> Projects -> Add`；
3. `Source Control Type` 选择 `Manual`；
4. 再打开 `Playbook Directory` 下拉框；
5. 如果使用扁平目录，选择 `db-ru-automation`；如果使用子目录方式，选择 `db-ru-automation/playbooks`。

### 6.3 备选方式 B：使用本地临时 Git 服务

如果 AWX Manual Project 不方便，也可以在 k3s 节点临时启动一个只在内网访问的 Git HTTP 服务或 Gitea。但本计划优先使用 Manual Project，因为当前约束是无法访问 Git，且测试目标是尽快跑通流程。

---

## 7. 阶段 4：创建 AWX 基础对象

### 7.1 Organization

**执行位置：AWX UI，使用浏览器登录 AWX。**

AWX UI：

```text
Access Management -> Organizations -> Add
```

建议：

| 字段 | 值 |
|---|---|
| Name | `DB_RU_Test_Org` |

### 7.2 Inventory

**执行位置：AWX UI，使用浏览器登录 AWX。**

AWX UI：

```text
Resources -> Inventories -> Add
```

建议名称：

```text
DB_RU_AWX_TEST_Inventory
```

创建 Host：

| Host | Variables |
|---|---|
| `node1` | `ansible_host: <node1-ip>` |
| `node2` | `ansible_host: <node2-ip>` |

创建 Group：

| Group | Hosts | 用途 |
|---|---|---|
| `db_nodes` | `node1`, `node2` | 两节点都执行 |
| `node1` | `node1` | 节点一滚动升级 |
| `node2` | `node2` | 节点二滚动升级 |
| `primary_exec_node` | `node1` | precheck、datapatch、summary、CRS 对比 |

**执行位置：AWX UI 的 Inventory Variables 编辑框。**

Inventory Variables 建议：

```yaml
ansible_user: aap_ru
ansible_connection: ssh
ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ru_base_dir: "/u01/patch1930/ru_automation"
```

> 测试阶段可以关闭 StrictHostKeyChecking；迁移到 AAP 或正式 UAT 时建议改为预置 known_hosts。

### 7.3 Credential

**执行位置：AWX UI，使用浏览器登录 AWX。**

AWX UI：

```text
Resources -> Credentials -> Add
```

初期建议只创建一个测试 Machine Credential：

| 字段 | 值 |
|---|---|
| Name | `DB_RU_AWX_aap_ru_credential` |
| Organization | `DB_RU_Test_Org` |
| Credential Type | Machine |
| Username | `aap_ru` |
| SSH Private Key | 粘贴 `/root/db_ru_awx_test/ssh/aap_ru_awx_test_ed25519` 的完整私钥内容，必须包含 `-----BEGIN OPENSSH PRIVATE KEY-----` 和 `-----END OPENSSH PRIVATE KEY-----` |
| Privilege Escalation Method | `sudo`，如需要 |
| Privilege Escalation Username | `root`，如需要 |

如果后续要模拟 root/grid/oracle 三类 Job Template，可逐步拆成：

```text
DB_RU_AWX_root_credential
DB_RU_AWX_grid_credential
DB_RU_AWX_oracle_credential
```

但第一轮 Smoke/Mock 建议先用一个 `aap_ru` credential 降低复杂度。

---

## 8. 阶段 5：创建通用 Job Template

### 8.1 Job Template 列表

建议在 AWX 中创建以下 JT，命名加 `AWX` 以免与未来 AAP 正式对象混淆：

| Job Template | Credential | 用途 |
|---|---|---|
| `DB_RU_AWX_RUN_ROOT` | `DB_RU_AWX_aap_ru_credential` + sudo | root 类或 mock root 类 step |
| `DB_RU_AWX_RUN_GRID` | `DB_RU_AWX_aap_ru_credential` | grid 类 step，测试阶段由 runner 内部控制 |
| `DB_RU_AWX_RUN_ORACLE` | `DB_RU_AWX_aap_ru_credential` | oracle 类 step，测试阶段由 runner 内部控制 |
| `DB_RU_AWX_RUN_CHECK` | `DB_RU_AWX_aap_ru_credential` | 检查/Summary/Gate 类 step |

### 8.2 每个 JT 的共同配置

| 字段 | 值 |
|---|---|
| Job Type | Run |
| Inventory | `DB_RU_AWX_TEST_Inventory` |
| Project | `DB_RU_AWX_Manual_Project` |
| Playbook | `playbooks/run_ru_step.yml` |
| Execution Environment | 先用默认 EE，必要时改为客户目标 EE |
| Credentials | `DB_RU_AWX_aap_ru_credential` |
| Limit | 勾选 Prompt on Launch |
| Variables | 勾选 Prompt on Launch |
| Verbosity | 1 或 2 |
| Timeout | Smoke/Mock 600 秒；真实阶段按 step 调整 |

### 8.3 单步 Smoke 测试

**执行位置：AWX UI，打开 `DB_RU_AWX_RUN_CHECK` 并点击 Launch。**

先在 AWX UI 直接 Launch `DB_RU_AWX_RUN_CHECK`：

| Prompt 字段 | 值 |
|---|---|
| Limit | `primary_exec_node` |
| Extra Vars | 见下 |

**执行位置：AWX UI，本段 YAML 填入 Launch Prompt 的 Extra Vars。**

```yaml
step_id: "00"
ru_run_mode: "mock"
platform_mode: "awx_test"
change_id: "AWX-TEST-SMOKE-0001"
allow_destructive_step: false
approval_report_required: false
```

此时目标主机还没有 runner，预期会失败在 `ru_step_runner.sh not found`。这个失败可以接受，说明 AWX 已经能运行 Project playbook 并尝试连接目标主机。随后进入 runner 落地。

---

## 9. 阶段 6：落地 Runner、Step 脚本和 Summary 脚本

### 9.1 Runner 设计要求

`ru_step_runner.sh` 必须承担以下职责：

1. 解析 `--step-id`、`--run-mode`、`--platform-mode`、`--change-id`、`--allow-destructive-step`；
2. 校验 step id 合法；
3. 根据 mock/check/real 模式选择脚本；
4. 创建统一日志；
5. 写入统一状态文件；
6. 对高风险 step 做二次保护；
7. step 失败时返回非 0，让 AWX Workflow 自动中断或进入失败分支。

### 9.2 初始 mock runner

**执行位置：k3s 节点。**

在 k3s 节点生成 runner：

```bash
cat > /root/db_ru_awx_test/ru_step_runner.sh <<'EOF_RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail

RU_BASE_DIR="/u01/patch1930/ru_automation"
STEP_ID=""
RUN_MODE="mock"
PLATFORM_MODE="awx_test"
CHANGE_ID="AWX-TEST-CHG0001"
ALLOW_DESTRUCTIVE_STEP="false"
APPROVAL_REPORT_REQUIRED="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --step-id) STEP_ID="$2"; shift 2 ;;
    --run-mode) RUN_MODE="$2"; shift 2 ;;
    --platform-mode) PLATFORM_MODE="$2"; shift 2 ;;
    --change-id) CHANGE_ID="$2"; shift 2 ;;
    --allow-destructive-step) ALLOW_DESTRUCTIVE_STEP="$2"; shift 2 ;;
    --approval-report-required) APPROVAL_REPORT_REQUIRED="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${STEP_ID}" ]]; then
  echo "ERROR: --step-id is required" >&2
  exit 2
fi

case "${STEP_ID}" in
  00|01|02|03|04|05|05A|06|07|08|09|10|10A|11|12|13|14|14A|15|16|17|18|18A|19|19A|20|21|22|23|24|24A|25|26|27|99) ;;
  *) echo "ERROR: unsupported step id: ${STEP_ID}" >&2; exit 2 ;;
esac

mkdir -p "${RU_BASE_DIR}"/{logs,state,reports,tmp}
TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${RU_BASE_DIR}/logs/step_${STEP_ID}_${TS}.log"
RESULT_FILE="${RU_BASE_DIR}/state/step_${STEP_ID}_result.json"
DONE_FILE="${RU_BASE_DIR}/state/step_${STEP_ID}.done"
FAILED_FILE="${RU_BASE_DIR}/state/step_${STEP_ID}.failed"
SCRIPT_FILE="${RU_BASE_DIR}/steps/step_${STEP_ID}.sh"

DESTRUCTIVE_STEPS="03 11 12 15 16 20 25 26"
if [[ " ${DESTRUCTIVE_STEPS} " == *" ${STEP_ID} "* ]]; then
  if [[ "${RUN_MODE}" == "real" && "${ALLOW_DESTRUCTIVE_STEP}" != "true" ]]; then
    echo "ERROR: step ${STEP_ID} is destructive, allow_destructive_step=true is required in real mode" | tee -a "${LOG_FILE}"
    exit 9
  fi
fi

export RU_BASE_DIR STEP_ID RUN_MODE PLATFORM_MODE CHANGE_ID ALLOW_DESTRUCTIVE_STEP APPROVAL_REPORT_REQUIRED LOG_FILE RESULT_FILE

{
  echo "===== DB RU STEP START ====="
  echo "timestamp=$(date -Is)"
  echo "hostname=$(hostname)"
  echo "whoami=$(whoami)"
  echo "step_id=${STEP_ID}"
  echo "run_mode=${RUN_MODE}"
  echo "platform_mode=${PLATFORM_MODE}"
  echo "change_id=${CHANGE_ID}"
  echo "allow_destructive_step=${ALLOW_DESTRUCTIVE_STEP}"
  echo "script_file=${SCRIPT_FILE}"
  echo "log_file=${LOG_FILE}"

  if [[ ! -x "${SCRIPT_FILE}" ]]; then
    echo "ERROR: script not found or not executable: ${SCRIPT_FILE}"
    exit 3
  fi

  "${SCRIPT_FILE}"
  RC=$?
  echo "step_rc=${RC}"
  exit "${RC}"
} 2>&1 | tee -a "${LOG_FILE}"
RC=${PIPESTATUS[0]}

if [[ ${RC} -eq 0 ]]; then
  rm -f "${FAILED_FILE}"
  touch "${DONE_FILE}"
  STATUS="success"
else
  rm -f "${DONE_FILE}"
  touch "${FAILED_FILE}"
  STATUS="failed"
fi

cat > "${RESULT_FILE}" <<EOF_JSON
{
  "step_id": "${STEP_ID}",
  "status": "${STATUS}",
  "rc": ${RC},
  "run_mode": "${RUN_MODE}",
  "platform_mode": "${PLATFORM_MODE}",
  "change_id": "${CHANGE_ID}",
  "host": "$(hostname)",
  "user": "$(whoami)",
  "log_file": "${LOG_FILE}",
  "timestamp": "$(date -Is)"
}
EOF_JSON

cat "${RESULT_FILE}"
exit "${RC}"
EOF_RUNNER
chmod +x /root/db_ru_awx_test/ru_step_runner.sh
```

**执行位置：k3s 节点；命令会通过 SSH/SCP 写入 node1/node2 目标主机。**

复制到 node1/node2：

```bash
scp /root/db_ru_awx_test/ru_step_runner.sh aap_ru@<node1-ip>:/u01/patch1930/ru_automation/bin/ru_step_runner.sh
scp /root/db_ru_awx_test/ru_step_runner.sh aap_ru@<node2-ip>:/u01/patch1930/ru_automation/bin/ru_step_runner.sh
ssh aap_ru@<node1-ip> 'chmod +x /u01/patch1930/ru_automation/bin/ru_step_runner.sh'
ssh aap_ru@<node2-ip> 'chmod +x /u01/patch1930/ru_automation/bin/ru_step_runner.sh'
```

### 9.3 生成 27 个 mock step

**执行位置：k3s 节点。**

```bash
mkdir -p /root/db_ru_awx_test/steps
for step in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 99; do
  cat > "/root/db_ru_awx_test/steps/step_${step}.sh" <<'EOF_STEP'
#!/usr/bin/env bash
set -Eeuo pipefail

echo "[MOCK/CHECK STEP] start"
echo "STEP_ID=${STEP_ID}"
echo "RUN_MODE=${RUN_MODE}"
echo "PLATFORM_MODE=${PLATFORM_MODE}"
echo "CHANGE_ID=${CHANGE_ID}"
echo "host=$(hostname)"
echo "user=$(whoami)"
date -Is

case "${RUN_MODE}" in
  mock)
    echo "mock mode: no real DB/RAC command will be executed"
    ;;
  check)
    echo "check mode: placeholder for non-destructive checks"
    ;;
  real)
    echo "real mode placeholder: replace this script with real implementation after approval"
    ;;
  *)
    echo "ERROR: unsupported RUN_MODE=${RUN_MODE}" >&2
    exit 2
    ;;
esac

echo "[MOCK/CHECK STEP] success"
EOF_STEP
  chmod +x "/root/db_ru_awx_test/steps/step_${step}.sh"
done
```

**执行位置：k3s 节点；命令会通过 SSH/SCP 写入 node1/node2 目标主机。**

复制到目标主机：

```bash
scp /root/db_ru_awx_test/steps/step_*.sh aap_ru@<node1-ip>:/u01/patch1930/ru_automation/steps/
scp /root/db_ru_awx_test/steps/step_*.sh aap_ru@<node2-ip>:/u01/patch1930/ru_automation/steps/
ssh aap_ru@<node1-ip> 'chmod +x /u01/patch1930/ru_automation/steps/step_*.sh'
ssh aap_ru@<node2-ip> 'chmod +x /u01/patch1930/ru_automation/steps/step_*.sh'
```

### 9.4 生成 6 个 Summary/Gate 脚本

Summary 脚本作为特殊 step：`05A/10A/14A/18A/19A/24A`。

**执行位置：k3s 节点；命令会生成脚本并通过 SCP 写入 node1/node2 目标主机。**

```bash
for step in 05A 10A 14A 18A 19A 24A; do
  cat > "/root/db_ru_awx_test/steps/step_${step}.sh" <<'EOF_SUMMARY'
#!/usr/bin/env bash
set -Eeuo pipefail

REPORT_FILE="${RU_BASE_DIR}/reports/approval_${STEP_ID}_summary.md"
mkdir -p "${RU_BASE_DIR}/reports"

{
  echo "# Approval Summary for Step ${STEP_ID}"
  echo
  echo "- Change ID: ${CHANGE_ID}"
  echo "- Host: $(hostname)"
  echo "- User: $(whoami)"
  echo "- Run Mode: ${RUN_MODE}"
  echo "- Platform Mode: ${PLATFORM_MODE}"
  echo "- Generated At: $(date -Is)"
  echo
  echo "## Recent Step Results"
  echo
  for f in "${RU_BASE_DIR}"/state/step_*_result.json; do
    [[ -f "$f" ]] || continue
    echo "### $(basename "$f")"
    echo '```json'
    cat "$f"
    echo '```'
  done
  echo
  echo "## Gate Result"
  echo
  echo "PASS: mock summary generated successfully. Replace this logic with real gate checks before UAT real run."
} > "${REPORT_FILE}"

cat "${REPORT_FILE}"
EOF_SUMMARY
  chmod +x "/root/db_ru_awx_test/steps/step_${step}.sh"
done

scp /root/db_ru_awx_test/steps/step_05A.sh /root/db_ru_awx_test/steps/step_10A.sh /root/db_ru_awx_test/steps/step_14A.sh \
    /root/db_ru_awx_test/steps/step_18A.sh /root/db_ru_awx_test/steps/step_19A.sh /root/db_ru_awx_test/steps/step_24A.sh \
    aap_ru@<node1-ip>:/u01/patch1930/ru_automation/steps/
scp /root/db_ru_awx_test/steps/step_05A.sh /root/db_ru_awx_test/steps/step_10A.sh /root/db_ru_awx_test/steps/step_14A.sh \
    /root/db_ru_awx_test/steps/step_18A.sh /root/db_ru_awx_test/steps/step_19A.sh /root/db_ru_awx_test/steps/step_24A.sh \
    aap_ru@<node2-ip>:/u01/patch1930/ru_automation/steps/
```

### 9.5 单步 runner 验证

**执行位置：AWX UI，Launch `DB_RU_AWX_RUN_CHECK` 时填写 Prompt。**

在 AWX 直接运行 `DB_RU_AWX_RUN_CHECK`：

```yaml
step_id: "00"
ru_run_mode: "mock"
platform_mode: "awx_test"
change_id: "AWX-TEST-RUNNER-0001"
allow_destructive_step: false
approval_report_required: false
```

通过标准：

1. AWX Job 成功；
2. Job Output 打印 runtime parameters；
3. 目标主机生成 `logs/step_00_*.log`；
4. 目标主机生成 `state/step_00.done` 和 `state/step_00_result.json`。

---

## 10. 阶段 7：创建完整 Workflow

### 10.1 Workflow 名称

**执行位置：AWX UI，Resources -> Templates -> Add -> Workflow Job Template。**

创建：

```text
DB_RU_AWX_19_30_Rolling_Upgrade_TEST
```

配置：

| 字段 | 值 |
|---|---|
| Organization | `DB_RU_Test_Org` |
| Inventory | 可空，节点使用 JT Prompt Limit |
| Allow Simultaneous | 关闭 |
| Survey | 可选，建议用于统一输入 `change_id`、`ru_run_mode` |

### 10.2 建议 Survey

| 变量 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `change_id` | Text | `AWX-TEST-CHG0001` | 本次测试/变更编号 |
| `ru_run_mode` | Multiple Choice | `mock` | `mock/check/real` |
| `platform_mode` | Multiple Choice | `awx_test` | 当前平台 |
| `allow_destructive_step` | Multiple Choice | `false` | real 模式高风险开关 |
| `approval_report_required` | Multiple Choice | `true` | 是否要求审批报告 |

### 10.3 Workflow 节点配置表

| 顺序 | 节点 | JT/类型 | Limit | Extra Vars |
|---:|---|---|---|---|
| 1 | Step 01 创建目录 | `DB_RU_AWX_RUN_ROOT` | `db_nodes` | `step_id: "01"` |
| 2 | Step 02 更新 goldimage 脚本 | `DB_RU_AWX_RUN_ROOT` | `primary_exec_node` | `step_id: "02"` |
| 3 | Step 03 清理上次 image 数据 | `DB_RU_AWX_RUN_ROOT` | `primary_exec_node` | `step_id: "03"` |
| 4 | Step 04 precheck | `DB_RU_AWX_RUN_ORACLE` | `primary_exec_node` | `step_id: "04"` |
| 5 | Step 05 backup | `DB_RU_AWX_RUN_ORACLE` | `primary_exec_node` | `step_id: "05"` |
| 6 | Step 05A Approval A Summary | `DB_RU_AWX_RUN_CHECK` | `primary_exec_node` | `step_id: "05A"` |
| 7 | Approval A | Approval | N/A | 备份完成后确认 |
| 8 | Step 06 保存 Grid 软连接 | `DB_RU_AWX_RUN_GRID` | `db_nodes` | `step_id: "06"` |
| 9 | Step 07 保存 Oracle 软连接 | `DB_RU_AWX_RUN_ORACLE` | `db_nodes` | `step_id: "07"` |
| 10 | Step 08 保存 CRS 状态 | `DB_RU_AWX_RUN_GRID` | `primary_exec_node` | `step_id: "08"` |
| 11 | Step 09 解压 goldimage | `DB_RU_AWX_RUN_ROOT` | `db_nodes` | `step_id: "09"` |
| 12 | Step 10 升级前 DB 检查 | `DB_RU_AWX_RUN_ORACLE` | `primary_exec_node` | `step_id: "10"` |
| 13 | Step 10A Approval B Summary | `DB_RU_AWX_RUN_CHECK` | `primary_exec_node` | `step_id: "10A"` |
| 14 | Approval B | Approval | N/A | 升级前确认 |
| 15 | Step 11 停止节点二实例 | `DB_RU_AWX_RUN_GRID` | `node2` | `step_id: "11"` |
| 16 | Step 12 节点二 goldimage 升级 | `DB_RU_AWX_RUN_ROOT` | `node2` | `step_id: "12"` |
| 17 | Step 13 启动节点二实例 | `DB_RU_AWX_RUN_GRID` | `node2` | `step_id: "13"` |
| 18 | Step 14 检查节点二 | `DB_RU_AWX_RUN_CHECK` | `node2` | `step_id: "14"` |
| 19 | Step 14A Approval C Summary | `DB_RU_AWX_RUN_CHECK` | `primary_exec_node` | `step_id: "14A"` |
| 20 | Approval C | Approval | N/A | 节点二升级后确认 |
| 21 | Step 15 停止节点一实例 | `DB_RU_AWX_RUN_GRID` | `node1` | `step_id: "15"` |
| 22 | Step 16 节点一 goldimage 升级 | `DB_RU_AWX_RUN_ROOT` | `node1` | `step_id: "16"` |
| 23 | Step 17 启动节点一实例 | `DB_RU_AWX_RUN_GRID` | `node1` | `step_id: "17"` |
| 24 | Step 18 检查节点一 | `DB_RU_AWX_RUN_CHECK` | `node1` | `step_id: "18"` |
| 25 | Step 18A Approval D Summary | `DB_RU_AWX_RUN_CHECK` | `primary_exec_node` | `step_id: "18A"` |
| 26 | Approval D | Approval | N/A | 两节点 binary 升级后确认 |
| 27 | Step 19 修改 job 参数为 0 | `DB_RU_AWX_RUN_ORACLE` | `primary_exec_node` | `step_id: "19"` |
| 28 | Step 19A Approval E Summary | `DB_RU_AWX_RUN_CHECK` | `primary_exec_node` | `step_id: "19A"` |
| 29 | Approval E | Approval | N/A | datapatch 前确认 |
| 30 | Step 20 datapatch | `DB_RU_AWX_RUN_ROOT` | `primary_exec_node` | `step_id: "20"` |
| 31 | Step 21 还原 job 参数 | `DB_RU_AWX_RUN_ORACLE` | `primary_exec_node` | `step_id: "21"` |
| 32 | Step 22 还原 Oracle 软连接 | `DB_RU_AWX_RUN_ORACLE` | `db_nodes` | `step_id: "22"` |
| 33 | Step 23 还原 Grid 软连接 | `DB_RU_AWX_RUN_ROOT` | `db_nodes` | `step_id: "23"` |
| 34 | Step 24 post DB check | `DB_RU_AWX_RUN_CHECK` | `primary_exec_node` | `step_id: "24"` |
| 35 | Step 24A Approval F Summary | `DB_RU_AWX_RUN_CHECK` | `primary_exec_node` | `step_id: "24A"` |
| 36 | Approval F | Approval | N/A | 清理前确认 |
| 37 | Step 25 清理 Oracle 中间环境 | `DB_RU_AWX_RUN_ORACLE` | `db_nodes` | `step_id: "25"` |
| 38 | Step 26 清理 Grid 中间环境 | `DB_RU_AWX_RUN_ROOT` | `db_nodes` | `step_id: "26"` |
| 39 | Step 27 CRS 状态对比 | `DB_RU_AWX_RUN_CHECK` | `primary_exec_node` | `step_id: "27"` |

### 10.4 Extra Vars 传递方式

**执行位置：AWX UI，Workflow Visualizer 中每个 Workflow Node 的 Prompt/Extra Vars。**

每个节点除 `step_id` 不同外，建议统一包含：

```yaml
ru_run_mode: "{{ ru_run_mode | default('mock') }}"
platform_mode: "awx_test"
change_id: "AWX-TEST-CHG0001"
allow_destructive_step: false
approval_report_required: true
```

**执行位置：AWX UI，Workflow Visualizer 中每个 Workflow Node 的 Prompt/Extra Vars。**

如果 AWX Workflow 节点无法直接引用 Survey 变量，则在每个节点手工填写固定值。第一轮 Full Mock 可以统一写死：

```yaml
ru_run_mode: "mock"
platform_mode: "awx_test"
change_id: "AWX-TEST-FULL-MOCK-0001"
allow_destructive_step: false
approval_report_required: true
```

### 10.5 失败分支

建议从以下关键节点增加 Failure 分支到 Step 99：

| 来源节点 | Failure 目标 |
|---|---|
| Step 04 precheck | Step 99 |
| Step 05A Summary | Step 99 |
| Approval A Deny/Timeout | Step 99 |
| Step 10A Summary | Step 99 |
| Approval B Deny/Timeout | Step 99 |
| Step 14A Summary | Step 99 |
| Approval C Deny/Timeout | Step 99 |
| Step 19A Summary | Step 99 |
| Approval E Deny/Timeout | Step 99 |
| Step 20 datapatch | Step 99 |
| Step 24A Summary | Step 99 |
| Approval F Deny/Timeout | Step 99 |

Step 99 配置：

| 字段 | 值 |
|---|---|
| JT | `DB_RU_AWX_RUN_CHECK` |
| Limit | `db_nodes` 或 `primary_exec_node` |
| Extra Vars | `step_id: "99"` |

---

## 11. 阶段 8：执行 Full Mock 全流程

### 11.1 启动参数

**执行位置：AWX UI，打开 `DB_RU_AWX_19_30_Rolling_Upgrade_TEST` 并点击 Launch。**

启动 Workflow：

```yaml
ru_run_mode: "mock"
platform_mode: "awx_test"
change_id: "AWX-TEST-FULL-MOCK-0001"
allow_destructive_step: false
approval_report_required: true
```

### 11.2 观察重点

| 检查点 | 通过标准 |
|---|---|
| 27 个 step | 全部按顺序执行成功 |
| `db_nodes` Limit | node1/node2 都执行 |
| `node1` Limit | 只在 node1 执行 |
| `node2` Limit | 只在 node2 执行 |
| `primary_exec_node` Limit | 只在主控节点执行 |
| Approval A-F | Workflow 暂停，Approve 后继续 |
| Summary A-F | 输出 Markdown 审批摘要 |
| 状态文件 | 每个 step 生成 done/result.json |
| 日志文件 | 每个 step 生成独立日志 |
| 无破坏性命令 | mock 阶段不执行 stop/datapatch/rm/switch home |

### 11.3 Mock 阶段必须额外测试 Deny 和 Timeout

至少单独跑两次短链路或全链路：

1. 在 Approval B 点击 Deny，验证后续 Step 11 不执行；
2. 配置一个短超时 Approval，验证 Timeout 后不继续执行高风险步骤；
3. 使用无审批权限用户尝试审批，验证失败。

---

## 12. 阶段 9：执行 Check-only 非破坏性验证

### 12.1 Check-only 范围

允许命令：

```text
hostname
whoami
date
crsctl status resource -t
srvctl status database
srvctl status instance
sqlplus 只读查询 v$instance
sqlplus 只读查询 dba_registry_sqlpatch
检查 PDB open mode
检查 invalid object 数量
检查 ORACLE_HOME / GRID_HOME 当前软连接
检查磁盘空间
检查 RU 包文件是否存在
```

禁止命令：

```text
srvctl stop instance
srvctl start instance，除非仅验证状态不改变
切换 ORACLE_HOME / GRID_HOME
runInstaller/applyRU/rootupgrade 等实际升级命令
datapatch
rm -rf
修改数据库参数
```

### 12.2 替换部分 step 为 check 实现

先不要替换所有 step。建议只增强这些检查类 step：

| Step | check-only 内容 |
|---|---|
| 04 | precheck 命令，如环境、空间、版本、连通性 |
| 08 | `crsctl status resource -t` 保存当前 CRS 状态 |
| 10 | 升级前 DB/PDB/sqlpatch/invalid object 检查 |
| 14 | node2 当前实例状态检查，不做启停 |
| 18 | node1 当前实例状态检查，不做启停 |
| 24 | 当前版本和 sqlpatch 只读检查 |
| 27 | CRS 状态对比框架验证 |

### 12.3 启动参数

**执行位置：AWX UI，Launch Workflow 时填写 Survey 或 Extra Vars。**

```yaml
ru_run_mode: "check"
platform_mode: "awx_test"
change_id: "AWX-TEST-CHECK-0001"
allow_destructive_step: false
approval_report_required: true
```

通过标准：

1. 所有 check step 成功；
2. Summary/Gate 能引用真实检查结果；
3. Approval 摘要能给出可读结论；
4. 禁止列表中的命令没有执行；
5. 失败时 Workflow 停止并进入 Step 99 或保留失败现场。

---

## 13. 阶段 10：执行 UAT Real 全流程

### 13.1 进入 UAT Real 前置条件

必须同时满足：

1. Full Mock 至少完整成功 2 次；
2. Approval Deny/Timeout/无权限审批失败均验证通过；
3. Check-only 至少完整成功 1 次；
4. 所有真实 step 脚本完成评审；
5. sudoers 权限完成安全评审；
6. RU 包、gold image、备份目录、回退方案准备完成；
7. 测试 RAC 可接受中断和回退演练；
8. 变更窗口、审批人、DBA、系统管理员均到位；
9. `allow_destructive_step=true` 只在真实 UAT 变更窗口启用；
10. Step 99 失败日志收集可以正常运行。

### 13.2 真实 step 替换策略

不要一次性把 27 个 mock step 全部替换成真实逻辑。建议分批替换：

| 批次 | Step | 说明 |
|---|---|---|
| 批次 1 | 01,02,04,05,06,07,08,09,10 | 前置准备和检查，低风险到中风险。 |
| 批次 2 | 11,12,13,14 | node2 滚动升级闭环。 |
| 批次 3 | 15,16,17,18 | node1 滚动升级闭环。 |
| 批次 4 | 19,20,21,24 | datapatch 与升级后 DB 检查。 |
| 批次 5 | 22,23,25,26,27 | 恢复软连接、清理、最终 CRS 对比。 |

每替换一批，先单独跑相关 step，再进入完整 Workflow。

### 13.3 UAT Real 启动参数

**执行位置：AWX UI，Launch Workflow 时填写 Survey 或 Extra Vars；仅在 UAT 变更窗口执行。**

```yaml
ru_run_mode: "real"
platform_mode: "awx_test"
change_id: "UAT-DBRU-1930-0001"
allow_destructive_step: true
approval_report_required: true
```

### 13.4 UAT Real 中必须人工确认的点

| Approval | 进入前自动摘要 | 人工确认重点 |
|---|---|---|
| A | Step 04/05/05A | precheck 通过、备份可用、日志无严重错误。 |
| B | Step 06-10/10A | 软连接/CRS 状态/gold image/升级前 DB 状态均正常。 |
| C | Step 11-14/14A | node2 已恢复服务，业务/实例状态符合预期。 |
| D | Step 15-18/18A | node1 已恢复服务，两节点 binary 状态符合预期。 |
| E | Step 19/19A | datapatch 前 DB/PDB 状态、job 参数、窗口确认。 |
| F | Step 20-24/24A | datapatch 成功、sqlpatch/版本检查通过，允许清理。 |

---

## 14. AWX Pod 和资源配置注意事项

### 14.1 不建议直接修改 AWX Pod 内文件作为长期方案

手工 Project 文件复制到 AWX Pod 适合当前无 Git 测试，但它依赖 AWX Project PVC 或容器内目录持久性。需要确认：

**执行位置：k3s 节点。**

```bash
kubectl -n awx exec -it <awx-task-pod> -- bash -lc 'df -h /var/lib/awx/projects; mount | grep awx'
```

如果 `/var/lib/awx/projects` 没有持久化，Pod 重建后文件会丢失。此时必须：

1. 给 AWX 配置 projects persistence；或
2. 每次测试前重新 `kubectl cp`；或
3. 在内网搭一个临时 Git 服务；或
4. 用 AWX API/awx.awx collection 后续固化配置。

### 14.2 Execution Environment 镜像能力

默认 EE 至少需要：

```text
ansible-core
ssh client
python
bash
基础 shell 工具
```

如果 Job 报 `ssh` 不存在、Python 依赖缺失或 collection 缺失，需要构建自定义 EE 或换用包含所需工具的 EE。

### 14.3 AWX 到外部主机 SSH 私钥

SSH 私钥应存在 AWX Credential 中，不应写入 Project 文件或脚本。测试完成后，如使用临时密钥，应在目标主机 `authorized_keys` 中清理。

### 14.4 AWX 日志与目标主机日志的关系

| 日志位置 | 内容 | 用途 |
|---|---|---|
| AWX Job Output | Ansible 执行输出、runner stdout | 审计、快速排错 |
| 目标主机 `logs` | step 原始运行日志 | 生产排错主证据 |
| 目标主机 `state` | step 状态/result json | Summary/Gate 判断依据 |
| 目标主机 `reports` | Approval 摘要 | 人工审批依据 |
| k3s 归档目录 | 截图和导出结果 | 测试证据归档 |

---

## 15. 失败处理和回滚原则

### 15.1 Mock/Check 阶段失败

处理原则：

1. 不跳过失败 step；
2. 先看 AWX Job Output；
3. 再登录目标主机看 `logs/step_xx_*.log`；
4. 检查 `state/step_xx_result.json`；
5. 修复后从失败 step 单独验证，再重跑 Workflow。

### 15.2 Real 阶段失败

处理原则：

1. Workflow 必须停止，不得自动继续后续高风险 step；
2. 执行或手工触发 Step 99 收集日志；
3. 由 DBA/系统管理员判断是继续、回退还是人工接管；
4. 不允许未经审批直接重新运行破坏性 step；
5. 对已完成节点的 `.done` 和 `.result.json` 做归档，不要覆盖现场。

---

## 16. 最终验收标准

AWX 全流程测试通过至少应满足：

| 类别 | 标准 |
|---|---|
| 网络 | AWX EE Pod 能 SSH 到 node1/node2。 |
| Project | 无 Git 场景下 Manual Project 可被 AWX 正常识别。 |
| Inventory | `db_nodes`、`node1`、`node2`、`primary_exec_node` Limit 生效。 |
| Credential | AWX Credential 可登录目标主机并按需 sudo。 |
| Job Template | 3~4 个通用 JT 可复用执行不同 step。 |
| Prompt | 每个 Workflow Node 可传入不同 `step_id`。 |
| Runner | runner 可生成日志、状态、result json，并正确返回 rc。 |
| 27 Step | Full Mock 中 27 个 step 全部跑通。 |
| Summary/Gate | 6 个 Summary/Gate 节点可生成审批摘要。 |
| Approval | Approve/Deny/Timeout/无权限审批均验证。 |
| Failure | 关键失败场景不会继续执行后续高风险 step。 |
| Check-only | 非破坏性 Oracle/Grid 检查可跑通。 |
| UAT Real | 测试 RAC 完整 DB RU 流程按审批链路跑通。 |
| 证据 | AWX Job Output、目标日志、状态文件、报告、截图均归档。 |

---

## 17. 后续迁移到 AAP 的准备清单

AWX 验证完成后，迁移到 AAP 前需要整理：

1. 最终版 `run_ru_step.yml`；
2. 最终版 `ru_step_runner.sh`；
3. 27 个真实 step 脚本；
4. 6 个 Summary/Gate 脚本；
5. `conf` 配置文件模板；
6. AWX Inventory 分组设计；
7. AWX Job Template 配置截图或导出；
8. Workflow 节点顺序、Limit、Extra Vars、Approval 配置；
9. Credential 权限矩阵；
10. sudoers 最小授权清单；
11. Mock、Check-only、UAT Real 三轮测试证据；
12. 已知问题和 AAP 回迁复核项。

迁移到 AAP 时，不能直接认为 AWX 通过就等于生产可上线。AAP 侧仍需重新创建或重新验证 Organization、Project、Inventory、Credential、Execution Environment、RBAC、Approval 权限、审计通知和生产 RAC 访问权限。
