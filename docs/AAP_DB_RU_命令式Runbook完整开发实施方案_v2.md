# AAP 调度命令式 Runbook 实现 Oracle RAC DB RU 升级：完整开发与配置方案 V2

> 适用场景：在不开发完整 Ansible Role/YAML 的前提下，基于 AAP 对现有 Oracle RAC DB RU 升级 runbook 进行流程化、受控化、可审计化调度。  
> 核心原则：少写 YAML，复用现有命令；但必须满足生产环境对权限、安全、审批、日志、失败中断、状态检查和人工接管的要求。

---

## 1. 背景与目标

当前已有一套 Oracle RAC DB RU 升级步骤，共 27 个操作点，内容包括：创建目录、解压 RU 脚本、清理旧 image、执行 precheck、备份当前环境、保存 Grid/Oracle Home 软连接、保存 CRS 状态、解压 gold image、检查数据库、分别滚动升级节点二和节点一、执行 datapatch、恢复参数和软连接、升级后检查、清理中间环境以及最终 CRS 状态对比。

本方案的目标不是把所有命令重写成复杂 Ansible Role，而是采用：

```text
AAP Workflow Job Template
    + 通用 Job Templates
    + 极薄 Ansible Wrapper
    + Shell Step Runner
    + 27 个 Step 脚本
    + 标准化检查脚本
    + Approval 人工审批点
```

实现以下目标：

- 复用现有 27 步 DB RU 升级命令；
- 降低 Ansible YAML 开发和测试工作量；
- 在 AAP 中实现流程编排、权限控制、人工审批和执行审计；
- 每一步有明确检查结果和是否进入下一步的条件；
- 任一步失败后自动中断，不继续执行高风险步骤；
- 满足生产环境对可控、可查、可停、可恢复的要求；
- 后续可以逐步演进为标准 Ansible Role。

---

## 2. 总体结论

推荐方案：

```text
AAP Workflow + 3~4 个通用 Job Template + run_ru_step.yml + ru_step_runner.sh + 27 个 step 脚本
```

不推荐方案：

```text
把 27 个裸命令直接复制到 AAP 中顺序执行
```

原因：裸命令方式无法可靠满足以下生产要求：

- 统一日志和状态文件；
- 标准化返回码；
- 失败自动中断；
- 防止越级执行；
- 防止危险步骤重复执行；
- `rm -rf` 路径白名单保护；
- 非交互式权限切换；
- 人工审批节点；
- 变更审计和责任追踪。

最终落地形态：

```text
27 个步骤不是靠 27 个 Job Template 实现，
而是靠 27 个 Workflow Node 实现；
这些 Workflow Node 复用 3~4 个通用 Job Template，
每个 Node 通过 Prompt 传入不同的 step_id、target_group 和 step_name。
```

---

## 3. 官方机制与本方案对应关系

Red Hat AAP 的 Job Template 通常用于定义一次可重复执行的自动化作业，包含 Inventory、Project、Playbook、Credential、Variables、Limit 等信息。官方 Workshop 也说明，一个 Job Template 至少需要 Inventory、Credential 和包含 Playbook 的 Project。

Workflow Job Template 用于把多个 Job Template、Workflow Template、Project Sync、Inventory Sync、Approval 等节点串成一个整体流程。官方 Workflow Exercise 的例子是：先执行 backup，成功后继续执行后续 job，失败后执行 restore。本方案借用同样机制，只是把流程改成 DB RU 的 27 个强顺序步骤。

| 官方 Exercise / AAP 概念 | 本方案中的对应实现 |
|---|---|
| Project | `DB_RU_Automation_Project`，保存 `run_ru_step.yml`、runner、step 脚本和检查脚本 |
| Inventory | `DB_RU_Inventory`，定义 `db_nodes`、`node1`、`node2`、`primary_exec_node` |
| Credential | root/grid/oracle 或 aap_ru + sudo 的机器凭据 |
| Job Template | 3~4 个通用 JT，例如 `DB_RU_RUN_ROOT`、`DB_RU_RUN_GRID`、`DB_RU_RUN_ORACLE` |
| Workflow Job Template | `WF_DB_RU_1930_Command_Runbook` |
| Workflow Visualizer | 用来串联 27 个 step 和 Approval 节点 |
| Approval Node | 关键阶段人工审批，例如备份完成后、节点二完成后、datapatch 前、清理前 |
| Prompt on launch | 每个 Workflow Node 传入不同的 `step_id` 和 `target_group` |
| On Success | 上一步成功才进入下一步 |
| On Failure | 失败后停止或进入日志收集节点 |

参考资料：

- Red Hat AAP Job Templates：<https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.4/html/automation_controller_user_guide/controller-job-templates>
- Red Hat AAP Workflow Job Templates：<https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.4/html/automation_controller_user_guide/controller-workflow-job-templates>
- AAP 2.5 Workflow Job Templates：<https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.5/html/using_automation_execution/controller-workflow-job-templates>
- Red Hat Workshop - Creating a Job Template：<https://labs.demoredhat.com/exercises/ansible_network/6-controller-job-template/>
- Red Hat Workshop - Creating a Workflow：<https://labs.demoredhat.com/exercises/ansible_network/9-controller-workflow/>
- Red Hat CoP AAP Configuration as Code Template：<https://github.com/redhat-cop/aap_configuration_template>

---

## 4. 总体架构设计

### 4.1 架构图

```text
AAP Workflow Job Template: WF_DB_RU_1930_Command_Runbook
        |
        +-- Workflow Node 01  -> Job Template: DB_RU_RUN_ROOT   -> step_id=01
        +-- Workflow Node 02  -> Job Template: DB_RU_RUN_ROOT   -> step_id=02
        +-- Workflow Node 03  -> Job Template: DB_RU_RUN_ROOT   -> step_id=03
        +-- Workflow Node 04  -> Job Template: DB_RU_RUN_ORACLE -> step_id=04
        +-- Workflow Node 05  -> Job Template: DB_RU_RUN_ORACLE -> step_id=05
        +-- Approval A
        +-- ...
        +-- Workflow Node 27  -> Job Template: DB_RU_RUN_GRID   -> step_id=27
```

每个 Job Template 实际执行：

```text
AAP Job Template
        |
        +-- playbooks/run_ru_step.yml
                |
                +-- /u01/patch1930/ru_automation/bin/ru_step_runner.sh <step_id>
                        |
                        +-- /u01/patch1930/ru_automation/steps/step_xx_xxx.sh
                        +-- /u01/patch1930/ru_automation/checks/check_xxx.sh
                        +-- /u01/patch1930/ru_automation/logs/step_xx_yyyymmdd_hhmiss.log
                        +-- /u01/patch1930/ru_automation/state/step_xx.done / step_xx.failed
```

### 4.2 AAP 与脚本职责边界

| 组件 | 职责 |
|---|---|
| AAP Project | 管理自动化代码来源和版本 |
| AAP Inventory | 管理 RAC 节点和执行范围 |
| AAP Credential | 管理 root/grid/oracle/aap_ru 登录和 sudo 权限 |
| AAP Job Template | 调用通用 playbook 执行一个 step |
| AAP Workflow | 串联 27 个 step 和审批节点 |
| Approval Node | 在关键阶段暂停，等待人工放行 |
| `run_ru_step.yml` | 极薄 wrapper，只负责调用 step runner |
| `ru_step_runner.sh` | 控制 step 合法性、前置条件、锁、日志、返回码、状态文件 |
| `steps/*.sh` | 执行具体升级命令 |
| `checks/*.sh` | 执行机器可判断的检查，并返回标准 exit code |

---

## 5. 生产目录结构设计

建议在每个数据库节点创建统一目录：

```bash
/u01/patch1930/ru_automation/
├── bin/
│   └── ru_step_runner.sh
├── conf/
│   ├── ru_env.conf
│   ├── step_matrix.conf
│   └── dangerous_paths.conf
├── steps/
│   ├── step_01_create_backup_dir.sh
│   ├── step_02_unzip_ru_script.sh
│   ├── step_03_clean_old_image.sh
│   ├── step_04_precheck.sh
│   ├── step_05_backup_current_home.sh
│   ├── step_06_save_grid_symlink.sh
│   ├── step_07_save_oracle_symlink.sh
│   ├── step_08_save_crs_status.sh
│   ├── step_09_unzip_goldimage.sh
│   ├── step_10_pre_db_check.sh
│   ├── step_11_stop_node2_instance.sh
│   ├── step_12_switch_node2_home.sh
│   ├── step_13_start_node2_instance.sh
│   ├── step_14_check_node2.sh
│   ├── step_15_stop_node1_instance.sh
│   ├── step_16_switch_node1_home.sh
│   ├── step_17_start_node1_instance.sh
│   ├── step_18_check_node1.sh
│   ├── step_19_set_job_zero.sh
│   ├── step_20_datapatch.sh
│   ├── step_21_restore_job_param.sh
│   ├── step_22_restore_oracle_symlink.sh
│   ├── step_23_restore_grid_symlink.sh
│   ├── step_24_post_db_check.sh
│   ├── step_25_clean_oracle_backup_home.sh
│   ├── step_26_clean_grid_backup_home.sh
│   ├── step_27_compare_crs_status.sh
│   └── step_99_collect_failure_logs.sh
├── checks/
│   ├── check_crs_dbrole.sh
│   ├── check_dbrole.sh
│   ├── check_pdb.sh
│   ├── check_invalid_obj.sh
│   ├── check_version.sh
│   └── check_sqlpatch.sh
├── logs/
├── state/
├── backup/
└── tmp/
```

目录权限建议：

```bash
chown -R root:oinstall /u01/patch1930/ru_automation
chmod -R 750 /u01/patch1930/ru_automation
chmod 750 /u01/patch1930/ru_automation/bin/ru_step_runner.sh
chmod 750 /u01/patch1930/ru_automation/steps/*.sh
chmod 750 /u01/patch1930/ru_automation/checks/*.sh
```

生产要求：

- patch 包、gold image 包不要放入 Git；
- Git 中只保存 playbook、runner、step 脚本、检查脚本、README；
- 环境相关路径全部放到 `ru_env.conf`；
- 不同客户、不同 RU 版本只改配置文件，不改主流程。

---

## 6. 配置文件设计

### 6.1 `ru_env.conf`

文件位置：

```bash
/u01/patch1930/ru_automation/conf/ru_env.conf
```

示例：

```bash
export PATCH_BASE=/u01/patch1930
export RU_DIR=/u01/patch1930/ru.20260325
export BACKUP_DIR=/u01/patch1930/rac1_backup1930

export GRID_HOME_OLD=/u01/app/19.0.0.0/grid
export GRID_HOME_NEW=/u01/app/19.0.0.0/grid2
export DB_HOME_OLD=/u01/app/oracle/product/19.0.0.0/dbhome_1
export DB_HOME_NEW=/u01/app/oracle/product/19.0.0.0/dbhome_2

export GRID_IMAGE=/u01/patch1930/grid_home_2026-03-08_03-07-34PM.zip
export DB_IMAGE=/u01/patch1930/db_home_2026-03-08_03-18-48PM.zip

export NODE1=cnzhjxd001dbadm01
export NODE2=cnzhjxd001dbadm02

export BEFORE_CRS_STATUS=/tmp/before_crs_stats.log
export AFTER_CRS_STATUS=/u01/patch1930/ru_automation/logs/after_upgrade.log

export BASE_DIR=/u01/patch1930/ru_automation
export LOG_DIR=/u01/patch1930/ru_automation/logs
export STATE_DIR=/u01/patch1930/ru_automation/state
export TMP_DIR=/u01/patch1930/ru_automation/tmp
```

### 6.2 `dangerous_paths.conf`

用于限制允许删除的路径。

```bash
/u01/patch1928
/u01/app/oracle/product/19.0.0.0/dbhome_1.backup.for.switch_back
/u01/app/19.0.0.0/grid.backup.for.switch_back
```

生产原则：

- 所有 `rm -rf` 操作必须匹配白名单；
- 目标变量不能为空；
- 清理步骤必须放在最终检查和人工审批之后；
- 清理前必须保留 AAP 审批记录。

### 6.3 `step_matrix.conf` 可选

用于后续配置每个 step 的前置依赖、允许节点、推荐用户。

```text
01|none|db_nodes|root|create_backup_dir
02|01|db_nodes|root|unzip_ru_script
03|02|db_nodes|root|clean_old_image
04|03|primary_exec_node|oracle|precheck
05|04|primary_exec_node|oracle|backup_current_home
...
27|26|primary_exec_node|grid|compare_crs_status
```

第一版也可以不做复杂矩阵，直接在 runner 中用顺序检查控制。

---

## 7. Step Runner 设计

### 7.1 职责

`ru_step_runner.sh` 是本方案的核心控制点，职责包括：

- 检查 `step_id` 是否为空；
- 根据 `step_id` 找到对应脚本；
- 加锁，防止并发执行；
- 检查前置步骤是否完成；
- 禁止重复执行危险步骤；
- 执行 step 脚本；
- 记录完整日志；
- 生成 `.done` / `.failed` 状态文件；
- 返回 AAP 可识别的 exit code；
- 输出标准化结果，如 `STEP_RESULT=PASS`。

### 7.2 示例代码

```bash
#!/bin/bash
set -o pipefail

STEP_ID="${1:-}"
BASE_DIR=/u01/patch1930/ru_automation
CONF_FILE=${BASE_DIR}/conf/ru_env.conf
LOCK_FILE=${BASE_DIR}/state/ru_upgrade.lock

if [ ! -f "${CONF_FILE}" ]; then
  echo "STEP_RESULT=FAIL"
  echo "ERROR=conf file not found: ${CONF_FILE}"
  exit 10
fi

source ${CONF_FILE}

if [ -z "${STEP_ID}" ]; then
  echo "STEP_RESULT=FAIL"
  echo "ERROR=step_id is required"
  exit 10
fi

STEP_NUM=$(printf "%02d" ${STEP_ID#0} 2>/dev/null)
STEP_SCRIPT=$(ls ${BASE_DIR}/steps/step_${STEP_NUM}_*.sh 2>/dev/null | head -1)
LOG_FILE=${LOG_DIR}/step_${STEP_NUM}_$(date +%Y%m%d_%H%M%S).log
DONE_FILE=${STATE_DIR}/step_${STEP_NUM}.done
FAILED_FILE=${STATE_DIR}/step_${STEP_NUM}.failed

mkdir -p ${LOG_DIR} ${STATE_DIR} ${TMP_DIR}

if [ -z "${STEP_SCRIPT}" ] || [ ! -x "${STEP_SCRIPT}" ]; then
  echo "STEP_RESULT=FAIL"
  echo "ERROR=step script not found or not executable: ${STEP_NUM}"
  exit 11
fi

exec 9>${LOCK_FILE}
flock -n 9
if [ $? -ne 0 ]; then
  echo "STEP_RESULT=FAIL"
  echo "ERROR=another RU step is running"
  exit 12
fi

if [ -f "${DONE_FILE}" ]; then
  echo "STEP_RESULT=SKIPPED"
  echo "MESSAGE=step ${STEP_NUM} already completed"
  exit 0
fi

if [ "${STEP_NUM}" != "01" ]; then
  PREV_NUM=$(printf "%02d" $((10#${STEP_NUM}-1)))
  if [ ! -f "${STATE_DIR}/step_${PREV_NUM}.done" ]; then
    echo "STEP_RESULT=FAIL"
    echo "ERROR=previous step ${PREV_NUM} not completed"
    exit 13
  fi
fi

rm -f ${FAILED_FILE}

{
  echo "STEP=${STEP_NUM}"
  echo "SCRIPT=${STEP_SCRIPT}"
  echo "HOST=$(hostname)"
  echo "USER=$(id -un)"
  echo "START_TIME=$(date '+%Y-%m-%d %H:%M:%S')"
} | tee -a ${LOG_FILE}

bash ${STEP_SCRIPT} >> ${LOG_FILE} 2>&1
RC=$?

{
  echo "END_TIME=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "RC=${RC}"
} | tee -a ${LOG_FILE}

if [ ${RC} -eq 0 ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') step ${STEP_NUM} done" > ${DONE_FILE}
  echo "STEP_RESULT=PASS"
  echo "LOG_FILE=${LOG_FILE}"
  exit 0
elif [ ${RC} -eq 2 ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') step ${STEP_NUM} warning" > ${FAILED_FILE}
  echo "STEP_RESULT=WARNING"
  echo "LOG_FILE=${LOG_FILE}"
  exit 2
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') step ${STEP_NUM} failed" > ${FAILED_FILE}
  echo "STEP_RESULT=FAIL"
  echo "LOG_FILE=${LOG_FILE}"
  exit ${RC}
fi
```

### 7.3 返回码规范

| 返回码 | 含义 | AAP 行为 |
|---:|---|---|
| 0 | 成功 | 进入下一步 |
| 1 | 普通执行失败 | 停止 workflow |
| 2 | Warning，需要人工判断 | 停止 workflow，不进入下一步 |
| 10 | 参数或配置错误 | 停止 workflow |
| 11 | step 脚本不存在或不可执行 | 停止 workflow |
| 12 | 已有 RU 任务运行 | 停止 workflow |
| 13 | 前置步骤未完成 | 停止 workflow |
| 20 | 检查不通过 | 停止 workflow |
| 30 | 危险命令保护触发 | 停止 workflow |

---

## 8. 27 个 Step 拆分设计

| Step | 脚本 | 原始动作 | 推荐执行用户 | 推荐执行范围 |
|---:|---|---|---|---|
| 01 | `step_01_create_backup_dir.sh` | 创建备份目录 | root | `db_nodes` 或 `primary_exec_node` |
| 02 | `step_02_unzip_ru_script.sh` | 更新 / 解压 goldimage 脚本 | root | `primary_exec_node` |
| 03 | `step_03_clean_old_image.sh` | 清理上次 image 数据 | root | `primary_exec_node` |
| 04 | `step_04_precheck.sh` | 执行 precheck | oracle | `primary_exec_node` |
| 05 | `step_05_backup_current_home.sh` | 备份现有环境 | oracle/root | `primary_exec_node` |
| 06 | `step_06_save_grid_symlink.sh` | 保存 Grid Home 软连接 | grid/root | `db_nodes` |
| 07 | `step_07_save_oracle_symlink.sh` | 保存 Oracle Home 软连接 | oracle/root | `db_nodes` |
| 08 | `step_08_save_crs_status.sh` | 保存 CRS 状态 | grid | `primary_exec_node` |
| 09 | `step_09_unzip_goldimage.sh` | 解压 goldimage | root | `db_nodes` 或按脚本要求 |
| 10 | `step_10_pre_db_check.sh` | 升级前数据库检查 | oracle/grid | `primary_exec_node` |
| 11 | `step_11_stop_node2_instance.sh` | 停止节点二实例 | grid | `node2` |
| 12 | `step_12_switch_node2_home.sh` | 节点二执行 goldimage 升级 | root | `node2` |
| 13 | `step_13_start_node2_instance.sh` | 启动节点二实例 | grid | `node2` |
| 14 | `step_14_check_node2.sh` | 检查节点二实例 | oracle/grid | `node2` 或 `primary_exec_node` |
| 15 | `step_15_stop_node1_instance.sh` | 停止节点一实例 | grid | `node1` |
| 16 | `step_16_switch_node1_home.sh` | 节点一执行 goldimage 升级 | root | `node1` |
| 17 | `step_17_start_node1_instance.sh` | 启动节点一实例 | grid | `node1` |
| 18 | `step_18_check_node1.sh` | 检查节点一实例 | oracle/grid | `node1` 或 `primary_exec_node` |
| 19 | `step_19_set_job_zero.sh` | 修改 job 参数为 0 | oracle | `primary_exec_node` |
| 20 | `step_20_datapatch.sh` | 执行 datapatch | root/oracle | `primary_exec_node` |
| 21 | `step_21_restore_job_param.sh` | 还原 job 参数为 160 | oracle | `primary_exec_node` |
| 22 | `step_22_restore_oracle_symlink.sh` | 还原 Oracle Home 软连接 | oracle/root | `db_nodes` |
| 23 | `step_23_restore_grid_symlink.sh` | 还原 Grid Home 软连接 | root | `db_nodes` |
| 24 | `step_24_post_db_check.sh` | 版本和 sqlpatch 检查 | oracle | `primary_exec_node` |
| 25 | `step_25_clean_oracle_backup_home.sh` | 清理 Oracle Home 中间环境 | oracle/root | `db_nodes` |
| 26 | `step_26_clean_grid_backup_home.sh` | 清理 Grid Home 中间环境 | root | `db_nodes` |
| 27 | `step_27_compare_crs_status.sh` | CRS 状态对比 | grid | `primary_exec_node` |
| 99 | `step_99_collect_failure_logs.sh` | 失败日志收集 | root/grid/oracle | 按失败场景 |

---

## 9. Step 脚本开发示例

### 9.1 Step 04：precheck

```bash
#!/bin/bash
set -euo pipefail
source /u01/patch1930/ru_automation/conf/ru_env.conf

cd ${RU_DIR}
perl upgrade_ru_with_opatch --step_00_precheck

# 如果工具自身有明确日志路径，建议改成检查工具日志，而不是检查 runner 日志。
if find ${RU_DIR} -type f -name "*.log" -mtime -1 -exec grep -Ei "ERROR|FAILED|FATAL" {} \; | grep -q .; then
  echo "CHECK_RESULT=FAIL"
  echo "CHECK_ITEM=PRECHECK"
  exit 20
fi

echo "CHECK_RESULT=PASS"
echo "CHECK_ITEM=PRECHECK"
exit 0
```

### 9.2 Step 11：停止节点二实例

```bash
#!/bin/bash
set -euo pipefail
source /u01/patch1930/ru_automation/conf/ru_env.conf
source /home/grid/.bash_profile

srvctl stop instance -node ${NODE2} -f -drain_timeout 1
sleep 10

srvctl status database -verbose > ${TMP_DIR}/step11_db_status.out

# 这里需要结合实际 DB unique name / instance name 优化判断。
# 最低要求：节点二实例停止，节点一实例仍正常。
if grep -Ei "${NODE2}.*running|${NODE2}.*ONLINE" ${TMP_DIR}/step11_db_status.out; then
  echo "CHECK_RESULT=FAIL"
  echo "CHECK_DETAIL=instance still running on ${NODE2}"
  exit 20
fi

echo "CHECK_RESULT=PASS"
echo "CHECK_DETAIL=instance stopped on ${NODE2}"
exit 0
```

### 9.3 Step 12：节点二切换 Home

```bash
#!/bin/bash
set -euo pipefail
source /u01/patch1930/ru_automation/conf/ru_env.conf

cd ${RU_DIR}
/usr/bin/perl upgrade_ru_with_gold_image \
  --step_52_switch_one_node_to_original_path_not_start_instance \
  --target_grid_home=${GRID_HOME_NEW} \
  --target_oracle_home=${DB_HOME_NEW}

# 执行后应增加检查：home 软连接、inventory、CRS 核心状态等。
echo "CHECK_RESULT=PASS"
exit 0
```

### 9.4 Step 20：datapatch

```bash
#!/bin/bash
set -euo pipefail
source /u01/patch1930/ru_automation/conf/ru_env.conf

cd ${RU_DIR}
perl upgrade_ru_with_gold_image \
  --step_08_datapatch \
  --create_restore_point_before_datapatch

/u01/patch1930/ru_automation/checks/check_sqlpatch.sh
exit $?
```

### 9.5 Step 25：清理 Oracle Home 中间环境

```bash
#!/bin/bash
set -euo pipefail
source /u01/patch1930/ru_automation/conf/ru_env.conf

TARGET=/u01/app/oracle/product/19.0.0.0/dbhome_1.backup.for.switch_back
WHITE_LIST=/u01/patch1930/ru_automation/conf/dangerous_paths.conf

if [ -z "${TARGET}" ]; then
  echo "DANGEROUS_PATH_BLOCKED=empty target"
  exit 30
fi

if ! grep -Fxq "${TARGET}" ${WHITE_LIST}; then
  echo "DANGEROUS_PATH_BLOCKED=${TARGET}"
  exit 30
fi

rm -rf ${TARGET}

echo "CHECK_RESULT=PASS"
echo "CLEANED_PATH=${TARGET}"
exit 0
```

---

## 10. 检查脚本规范

所有检查脚本必须满足：

- 正常返回 `exit 0`；
- 检查失败返回 `exit 20`；
- 不确定或需要人工确认返回 `exit 2`；
- 输出必须包含 `CHECK_RESULT=PASS|FAIL|WARNING`；
- 输出必须包含 `CHECK_ITEM` 和 `CHECK_DETAIL`；
- 不允许只打印结果给人看，而不返回明确状态；
- AAP 判断通过 exit code，不靠人工看日志。

示例：`check_sqlpatch.sh`

```bash
#!/bin/bash
set -euo pipefail
source /home/oracle/.bash_profile

OUT=/tmp/check_sqlpatch_$$.out

sqlplus -s / as sysdba <<'SQL' > ${OUT}
set heading off feedback off pages 0 trimspool on
select count(*)
from dba_registry_sqlpatch
where status = 'SUCCESS'
and action = 'APPLY';
SQL

CNT=$(cat ${OUT} | tr -d '[:space:]')

if [ "${CNT}" -ge 1 ]; then
  echo "CHECK_RESULT=PASS"
  echo "CHECK_ITEM=SQLPATCH"
  echo "CHECK_DETAIL=successful datapatch apply record found"
  exit 0
else
  echo "CHECK_RESULT=FAIL"
  echo "CHECK_ITEM=SQLPATCH"
  echo "CHECK_DETAIL=no successful datapatch apply record found"
  exit 20
fi
```

---

## 11. 极薄 Ansible Playbook

AAP Project 中只需要一个通用 playbook。

文件：

```text
playbooks/run_ru_step.yml
```

内容：

```yaml
---
- name: Run DB RU upgrade step
  hosts: "{{ target_group | default('db_nodes') }}"
  gather_facts: false
  serial: "{{ serial_num | default(1) }}"
  become: "{{ use_become | default(false) }}"
  become_user: "{{ become_to | default('root') }}"

  vars:
    runner: /u01/patch1930/ru_automation/bin/ru_step_runner.sh

  tasks:
    - name: Validate required variable step_id
      ansible.builtin.assert:
        that:
          - step_id is defined
          - step_id | string | length > 0
        fail_msg: "step_id is required"

    - name: Run RU step
      ansible.builtin.shell: "{{ runner }} {{ step_id }}"
      args:
        executable: /bin/bash
      register: ru_step_result
      changed_when: "'STEP_RESULT=PASS' in ru_step_result.stdout"
      failed_when: >-
        ru_step_result.rc not in [0]
        or 'STEP_RESULT=FAIL' in ru_step_result.stdout
        or 'STEP_RESULT=WARNING' in ru_step_result.stdout

    - name: Show RU step output
      ansible.builtin.debug:
        var: ru_step_result.stdout_lines
```

说明：

- Playbook 只负责调用 runner；
- 不把 Oracle 升级逻辑写入 YAML；
- `target_group`、`step_id`、`serial_num` 由 Workflow Node 通过 Prompt 传入；
- 后续可以逐步把高风险步骤改造成原生 Ansible task。

---

## 12. AAP Inventory 设计

### 12.1 Inventory 示例

```ini
[db_nodes]
cnzhjxd001dbadm01
cnzhjxd001dbadm02

[node1]
cnzhjxd001dbadm01

[node2]
cnzhjxd001dbadm02

[primary_exec_node]
cnzhjxd001dbadm01
```

### 12.2 执行范围原则

| 类型 | 推荐范围 |
|---|---|
| 单点检查 / datapatch | `primary_exec_node` |
| 节点二滚动操作 | `node2` |
| 节点一滚动操作 | `node1` |
| 两节点都需要恢复软连接 | `db_nodes` |
| 清理本地中间目录 | `db_nodes`，但必须路径白名单 |

---

## 13. AAP Project 配置

### 13.1 UI 配置路径

AAP 2.4 常见路径：

```text
Resources -> Projects -> Add
```

AAP 2.5/2.6 新 UI 可能在：

```text
Automation Execution -> Projects -> Create project
```

### 13.2 推荐配置

```text
Name: DB_RU_Automation_Project
SCM Type: Git
SCM URL: http://git.xxx/db-ru-automation.git
SCM Branch: main
Update Revision on Launch: Yes
```

Git 仓库建议结构：

```text
db-ru-automation/
├── playbooks/
│   └── run_ru_step.yml
├── bin/
│   └── ru_step_runner.sh
├── conf/
│   ├── ru_env.conf.example
│   └── dangerous_paths.conf.example
├── steps/
│   ├── step_01_create_backup_dir.sh
│   └── ...
├── checks/
│   ├── check_sqlpatch.sh
│   └── ...
└── README.md
```

生产节点实际配置文件可以从 `.example` 拷贝生成，避免把生产路径、主机名和敏感信息直接写入 Git。

---

## 14. AAP Credential 设计

有两种可选模式。

### 14.1 模式 A：三个用户凭据

| Credential | 类型 | 用途 |
|---|---|---|
| `DB_RU_root_credential` | Machine | root 类步骤 |
| `DB_RU_grid_credential` | Machine | CRS / srvctl / grid 类步骤 |
| `DB_RU_oracle_credential` | Machine | DB 检查 / SQL / datapatch 检查类步骤 |

优点：职责清晰。  
缺点：凭据较多，AAP 配置更复杂。

### 14.2 模式 B：专用自动化用户 + sudo

推荐生产优先考虑此模式。

```text
Linux User: aap_ru
```

要求：

- 只能从 AAP 控制节点登录数据库服务器；
- 使用 SSH key，不使用明文密码；
- sudo 权限最小化；
- sudo 日志接入系统审计；
- 不允许脚本中使用交互式 `su - root`。

示例 sudoers：

```bash
aap_ru ALL=(root) NOPASSWD: /bin/bash /u01/patch1930/ru_automation/bin/ru_step_runner.sh *
```

更严格可以拆分为：

```bash
aap_ru ALL=(root) NOPASSWD: /u01/patch1930/ru_automation/bin/ru_step_runner.sh
```

然后在 runner 内部通过白名单控制 `step_id` 和实际脚本。

### 14.3 禁止事项

脚本中不允许出现：

```bash
su - root
su - grid
su - oracle
```

需要改成：

- AAP Credential 直接以对应用户执行；
- 或 AAP 使用 `become` / sudo；
- 或 runner 由 root 发起，再使用 `runuser -u grid -- <command>` 执行个别命令。

---

## 15. AAP Job Template 设计

## 15.1 为什么是 3~4 个通用 JT，而不是 27 个 JT

不建议创建：

```text
DB_RU_Step_01_JT
DB_RU_Step_02_JT
...
DB_RU_Step_27_JT
```

原因：

- 维护量大；
- 后续调整 playbook、credential、timeout 会重复修改 27 次；
- 不利于标准化；
- 不符合“通用 JT + 参数化 step”的目标。

推荐创建：

```text
DB_RU_RUN_ROOT
DB_RU_RUN_GRID
DB_RU_RUN_ORACLE
DB_RU_RUN_CHECK   # 可选
```

每个 Workflow Node 选择其中一个 JT，并通过 Prompt 传入：

```yaml
step_id: "12"
step_name: "switch_node2_home"
target_group: "node2"
serial_num: 1
```

### 15.2 Job Template：`DB_RU_RUN_ROOT`

| 配置项 | 值 |
|---|---|
| Name | `DB_RU_RUN_ROOT` |
| Job Type | Run |
| Inventory | `DB_RU_Inventory` |
| Project | `DB_RU_Automation_Project` |
| Playbook | `playbooks/run_ru_step.yml` |
| Credential | `DB_RU_root_credential` 或 `aap_ru` |
| Privilege Escalation | 视 credential 模式决定 |
| Limit | 勾选 Prompt on launch |
| Variables | 勾选 Prompt on launch |
| Timeout | 默认建议 7200 秒，特殊步骤单独调整 |

适用步骤：

```text
01, 02, 03, 09, 12, 16, 20, 23, 26
```

### 15.3 Job Template：`DB_RU_RUN_GRID`

| 配置项 | 值 |
|---|---|
| Name | `DB_RU_RUN_GRID` |
| Inventory | `DB_RU_Inventory` |
| Project | `DB_RU_Automation_Project` |
| Playbook | `playbooks/run_ru_step.yml` |
| Credential | `DB_RU_grid_credential` 或 `aap_ru + sudo/runuser` |
| Limit | 勾选 Prompt on launch |
| Variables | 勾选 Prompt on launch |

适用步骤：

```text
08, 11, 13, 15, 17, 27
```

### 15.4 Job Template：`DB_RU_RUN_ORACLE`

| 配置项 | 值 |
|---|---|
| Name | `DB_RU_RUN_ORACLE` |
| Inventory | `DB_RU_Inventory` |
| Project | `DB_RU_Automation_Project` |
| Playbook | `playbooks/run_ru_step.yml` |
| Credential | `DB_RU_oracle_credential` 或 `aap_ru + sudo/runuser` |
| Limit | 勾选 Prompt on launch |
| Variables | 勾选 Prompt on launch |

适用步骤：

```text
04, 05, 07, 10, 14, 18, 19, 21, 22, 24, 25
```

### 15.5 Job Template：`DB_RU_RUN_CHECK` 可选

可用于检查类步骤，便于单独设置更短 timeout 或更严格配置。

适用步骤：

```text
10, 14, 18, 24, 27
```

如果希望简洁，第一版可以不创建这个 JT。

### 15.6 必须启用 Prompt on launch

以下字段必须启用 Prompt on launch：

```text
Variables
Limit
```

原因：Workflow 里 27 个节点复用同一个 JT，必须能在每个节点里覆盖：

```yaml
step_id: "04"
target_group: "primary_exec_node"
step_name: "precheck"
```

如果不启用 Prompt on launch，Workflow Node 中无法为每个节点传不同变量。

---

## 16. AAP Workflow Job Template 设计

### 16.1 创建 Workflow

AAP 2.4 常见路径：

```text
Resources -> Templates -> Add -> Add workflow template
```

AAP 2.5/2.6 新 UI 常见路径：

```text
Automation Execution -> Templates -> Create workflow job template
```

推荐配置：

```text
Name: WF_DB_RU_1930_Command_Runbook
Inventory: DB_RU_Inventory
Organization: <客户或项目组织>
```

可选启用 Survey，用于输入变更信息：

| Survey 字段 | 类型 | 示例 | 用途 |
|---|---|---|---|
| `change_id` | Text | `CHG20260526001` | 变更单号 |
| `ru_version` | Text | `19.30` | 目标 RU 版本 |
| `operator` | Text | `xxx` | 执行人 |
| `maintenance_window` | Text | `2026-xx-xx 22:00-02:00` | 变更窗口 |

这些变量可以在每个节点中继续传入，也可以由 runner 记录到日志。

### 16.2 打开 Workflow Visualizer

保存 Workflow 后进入：

```text
Visualizer
```

从 `Start` 节点开始添加第一个 Job Template Node。

---

## 17. 在 Workflow Visualizer 中配置 27 个 Step

### 17.1 配置 Step 01

操作路径：

```text
Start -> + -> Node Type: Template
```

选择：

```text
Job Template: DB_RU_RUN_ROOT
```

点击：

```text
PROMPT
```

填写 Limit：

```text
db_nodes
```

填写 Extra Variables：

```yaml
step_id: "01"
step_name: "create_backup_directory"
target_group: "db_nodes"
serial_num: 1
```

保存。

实际执行效果：

```bash
ansible-playbook playbooks/run_ru_step.yml \
  -l db_nodes \
  -e step_id=01 \
  -e target_group=db_nodes \
  -e serial_num=1
```

最终调用：

```bash
/u01/patch1930/ru_automation/bin/ru_step_runner.sh 01
```

### 17.2 配置 Step 02

在 Step 01 节点上点击 `+`：

```text
Edge Type: On Success
Node Type: Template
Job Template: DB_RU_RUN_ROOT
```

点击 `PROMPT`，填写：

```yaml
step_id: "02"
step_name: "unzip_ru_script"
target_group: "primary_exec_node"
serial_num: 1
```

Limit：

```text
primary_exec_node
```

保存。

含义：

```text
只有 Step 01 成功，才执行 Step 02。
```

### 17.3 配置规则

主链路全部使用：

```text
On Success
```

不要使用：

```text
Always
```

除非是专门的失败日志收集节点。

失败分支可以使用：

```text
On Failure -> DB_RU_COLLECT_FAILURE_LOGS
```

---

## 18. Workflow 27 个节点完整配置表

| Workflow Node | 选择的 Job Template | Limit | Extra Vars |
|---:|---|---|---|
| Step 01 创建目录 | `DB_RU_RUN_ROOT` | `db_nodes` | `step_id: "01"` |
| Step 02 更新 goldimage 脚本 | `DB_RU_RUN_ROOT` | `primary_exec_node` | `step_id: "02"` |
| Step 03 清理上次 image 数据 | `DB_RU_RUN_ROOT` | `primary_exec_node` | `step_id: "03"` |
| Step 04 执行 precheck | `DB_RU_RUN_ORACLE` | `primary_exec_node` | `step_id: "04"` |
| Step 05 备份现有环境 | `DB_RU_RUN_ORACLE` | `primary_exec_node` | `step_id: "05"` |
| Approval A | Approval | N/A | 备份完成后人工确认 |
| Step 06 保存 Grid Home 软连接 | `DB_RU_RUN_GRID` 或 `DB_RU_RUN_ROOT` | `db_nodes` | `step_id: "06"` |
| Step 07 保存 Oracle Home 软连接 | `DB_RU_RUN_ORACLE` | `db_nodes` | `step_id: "07"` |
| Step 08 保存集群状态 | `DB_RU_RUN_GRID` | `primary_exec_node` | `step_id: "08"` |
| Step 09 解压 goldimage | `DB_RU_RUN_ROOT` | `db_nodes` | `step_id: "09"` |
| Step 10 检查数据库 | `DB_RU_RUN_ORACLE` 或 `DB_RU_RUN_CHECK` | `primary_exec_node` | `step_id: "10"` |
| Approval B | Approval | N/A | 升级前检查确认 |
| Step 11 停止节点二实例 | `DB_RU_RUN_GRID` | `node2` | `step_id: "11"` |
| Step 12 节点二 goldimage 升级 | `DB_RU_RUN_ROOT` | `node2` | `step_id: "12"` |
| Step 13 启动节点二实例 | `DB_RU_RUN_GRID` | `node2` | `step_id: "13"` |
| Step 14 检查节点二实例 | `DB_RU_RUN_ORACLE` 或 `DB_RU_RUN_CHECK` | `node2` 或 `primary_exec_node` | `step_id: "14"` |
| Approval C | Approval | N/A | 节点二升级完成后确认 |
| Step 15 停止节点一实例 | `DB_RU_RUN_GRID` | `node1` | `step_id: "15"` |
| Step 16 节点一 goldimage 升级 | `DB_RU_RUN_ROOT` | `node1` | `step_id: "16"` |
| Step 17 启动节点一实例 | `DB_RU_RUN_GRID` | `node1` | `step_id: "17"` |
| Step 18 检查节点一实例 | `DB_RU_RUN_ORACLE` 或 `DB_RU_RUN_CHECK` | `node1` 或 `primary_exec_node` | `step_id: "18"` |
| Approval D | Approval | N/A | 两节点 binary 升级完成后确认 |
| Step 19 修改 job 参数为 0 | `DB_RU_RUN_ORACLE` | `primary_exec_node` | `step_id: "19"` |
| Approval E | Approval | N/A | datapatch 前确认 |
| Step 20 执行 datapatch | `DB_RU_RUN_ROOT` 或 `DB_RU_RUN_ORACLE` | `primary_exec_node` | `step_id: "20"` |
| Step 21 还原 job 参数为 160 | `DB_RU_RUN_ORACLE` | `primary_exec_node` | `step_id: "21"` |
| Step 22 还原 Oracle 软连接 | `DB_RU_RUN_ORACLE` 或 `DB_RU_RUN_ROOT` | `db_nodes` | `step_id: "22"` |
| Step 23 还原 Grid 软连接 | `DB_RU_RUN_ROOT` | `db_nodes` | `step_id: "23"` |
| Step 24 数据库检查 | `DB_RU_RUN_ORACLE` 或 `DB_RU_RUN_CHECK` | `primary_exec_node` | `step_id: "24"` |
| Approval F | Approval | N/A | 清理中间环境前确认 |
| Step 25 清理 Oracle Home 中间环境 | `DB_RU_RUN_ORACLE` 或 `DB_RU_RUN_ROOT` | `db_nodes` | `step_id: "25"` |
| Step 26 清理 Grid Home 中间环境 | `DB_RU_RUN_ROOT` | `db_nodes` | `step_id: "26"` |
| Step 27 检查 CRS 状态并对比 | `DB_RU_RUN_GRID` 或 `DB_RU_RUN_CHECK` | `primary_exec_node` | `step_id: "27"` |

---

## 19. Approval 节点配置

### 19.1 Approval 添加方法

在 Workflow Visualizer 中：

```text
Step 05 -> + -> Node Type: Approval
```

填写审批节点信息后保存，再从 Approval 节点添加后续 Step：

```text
Approval A -> On Success -> Step 06
```

如果审批拒绝：

```text
Approval A -> On Failure -> Stop
```

或：

```text
Approval A -> On Failure -> DB_RU_COLLECT_FAILURE_LOGS
```

### 19.2 Approval A：备份完成后确认

| 配置项 | 值 |
|---|---|
| Name | `APPROVAL_A_AFTER_BACKUP` |
| Description | `Confirm precheck and home backup result before continuing.` |
| Timeout | `86400` 秒 |
| On Success | Step 06 |
| On Failure | Stop 或日志收集 |

审批确认内容：

```text
1. Step 04 precheck PASS
2. Step 05 backup 成功
3. backup 目录存在
4. 日志无 ERROR / FAILED / FATAL
5. 允许进入 image 解压和状态保存阶段
```

### 19.3 Approval B：升级前检查确认

| 配置项 | 值 |
|---|---|
| Name | `APPROVAL_B_BEFORE_ROLLING_UPGRADE` |
| Description | `Confirm DB/CRS/PDB/invalid object checks before stopping node2 instance.` |
| Timeout | `86400` 秒 |
| On Success | Step 11 |
| On Failure | Stop |

审批确认内容：

```text
1. CRS 状态正常
2. DB role 正确
3. PDB 状态正常
4. invalid object 无异常增长
5. 允许停止节点二实例
```

### 19.4 Approval C：节点二升级后确认

| 配置项 | 值 |
|---|---|
| Name | `APPROVAL_C_AFTER_NODE2_UPGRADE` |
| Description | `Confirm node2 upgrade result before upgrading node1.` |
| Timeout | `86400` 秒 |
| On Success | Step 15 |
| On Failure | Stop |

审批确认内容：

```text
1. 节点二实例已启动
2. 节点二 CRS/DB 检查通过
3. 服务状态符合预期
4. 允许继续节点一升级
```

### 19.5 Approval D：两节点 binary 升级后确认

| 配置项 | 值 |
|---|---|
| Name | `APPROVAL_D_AFTER_BINARY_SWITCH` |
| Description | `Confirm both nodes switched to new Grid/DB home before DB-level changes.` |
| Timeout | `86400` 秒 |
| On Success | Step 19 |
| On Failure | Stop |

审批确认内容：

```text
1. 节点一、节点二实例均正常
2. CRS 资源正常
3. DB Home/Grid Home 指向符合预期
4. 允许进入 SQL 层处理
```

### 19.6 Approval E：datapatch 前确认

| 配置项 | 值 |
|---|---|
| Name | `APPROVAL_E_BEFORE_DATAPATCH` |
| Description | `Confirm before executing datapatch and creating restore point.` |
| Timeout | `86400` 秒 |
| On Success | Step 20 |
| On Failure | Stop |

审批确认内容：

```text
1. job 参数已设置为 0
2. restore point 策略确认
3. 业务窗口仍有效
4. 允许执行 datapatch
```

### 19.7 Approval F：清理中间环境前确认

| 配置项 | 值 |
|---|---|
| Name | `APPROVAL_F_BEFORE_CLEANUP` |
| Description | `Confirm version/sqlpatch checks before removing switch-back backup directories.` |
| Timeout | `86400` 秒 |
| On Success | Step 25 |
| On Failure | Stop |

审批确认内容：

```text
1. check_version.sh 通过
2. check_sqlpatch.sh 通过
3. dba_registry_sqlpatch 状态 SUCCESS
4. CRS 状态正常
5. 不再需要立即 switch back
6. 允许清理 dbhome_1.backup.for.switch_back 和 grid.backup.for.switch_back
```

该审批最关键。Step 25、26 清理中间环境前必须人工确认。

---

## 20. Workflow 最终主链路

```text
01 创建目录
  -> 02 更新脚本
  -> 03 清理旧 image
  -> 04 precheck
  -> 05 backup
  -> Approval A：备份确认
  -> 06 保存 Grid 软连接
  -> 07 保存 Oracle 软连接
  -> 08 保存 CRS 状态
  -> 09 解压 goldimage
  -> 10 升级前检查
  -> Approval B：升级前确认
  -> 11 停节点二实例
  -> 12 切节点二 home
  -> 13 启节点二实例
  -> 14 检查节点二
  -> Approval C：节点二确认
  -> 15 停节点一实例
  -> 16 切节点一 home
  -> 17 启节点一实例
  -> 18 检查节点一
  -> Approval D：binary 升级确认
  -> 19 job 参数设为 0
  -> Approval E：datapatch 前确认
  -> 20 datapatch
  -> 21 job 参数恢复
  -> 22 恢复 Oracle 软连接
  -> 23 恢复 Grid 软连接
  -> 24 版本/sqlpatch 检查
  -> Approval F：清理前确认
  -> 25 清理 Oracle 中间环境
  -> 26 清理 Grid 中间环境
  -> 27 CRS 状态对比
```

---

## 21. 每一步进入下一步的条件

| Step | 动作 | 进入下一步条件 |
|---:|---|---|
| 01 | 创建备份目录 | 目录存在，权限正确 |
| 02 | 解压 RU 脚本 | RU 目录存在，核心脚本存在 |
| 03 | 清理旧 image | 目标路径匹配白名单，命令成功 |
| 04 | precheck | 返回码 0，日志无 ERROR/FAILED/FATAL |
| 05 | 备份现有环境 | 备份目录存在，脚本返回成功 |
| 06 | 保存 Grid Home 软连接 | 输出文件存在且非空 |
| 07 | 保存 Oracle Home 软连接 | 输出文件存在且非空 |
| 08 | 保存 CRS 状态 | before 文件存在且非空 |
| 09 | 解压 goldimage | 新 Grid Home 和 DB Home 目录存在 |
| 10 | 升级前 DB 检查 | CRS、DB role、PDB、invalid object 检查通过 |
| 11 | 停止节点二实例 | 节点二实例停止，节点一实例正常 |
| 12 | 节点二切换 home | 脚本返回成功，节点 CRS 正常 |
| 13 | 启动节点二实例 | 节点二实例启动成功 |
| 14 | 节点二检查 | CRS、DB role、PDB 检查通过 |
| 15 | 停止节点一实例 | 节点一实例停止，节点二实例正常 |
| 16 | 节点一切换 home | 脚本返回成功，节点 CRS 正常 |
| 17 | 启动节点一实例 | 节点一实例启动成功 |
| 18 | 节点一检查 | CRS、DB role、PDB 检查通过 |
| 19 | 修改 job 参数为 0 | 参数确认生效 |
| 20 | datapatch | sqlpatch 检查成功，restore point 策略确认 |
| 21 | 恢复 job 参数 | 参数恢复为预期值 |
| 22 | 恢复 Oracle Home 软连接 | 软连接存在且指向正确 |
| 23 | 恢复 Grid Home 软连接 | 软连接存在且指向正确 |
| 24 | 升级后 DB 检查 | version 和 sqlpatch 均符合目标 RU |
| 25 | 清理 Oracle Home 中间环境 | Step 24 已完成，Approval F 已批准，路径匹配白名单 |
| 26 | 清理 Grid Home 中间环境 | Step 24 已完成，Approval F 已批准，路径匹配白名单 |
| 27 | CRS 状态对比 | 核心资源状态与升级前一致，差异经过确认 |

---

## 22. 失败分支设计

第一版不建议做自动回滚，建议只做：

```text
失败自动停止 + 自动收集日志 + 人工判断
```

可选增加 Job Template：

```text
DB_RU_COLLECT_FAILURE_LOGS
```

对应 step：

```yaml
step_id: "99"
step_name: "collect_failure_logs"
target_group: "db_nodes"
```

建议对以下关键节点加 On Failure：

| 节点 | On Failure 动作 |
|---|---|
| Step 04 precheck | `DB_RU_COLLECT_FAILURE_LOGS` |
| Step 05 backup | `DB_RU_COLLECT_FAILURE_LOGS` |
| Step 12 node2 switch | `DB_RU_COLLECT_FAILURE_LOGS` |
| Step 16 node1 switch | `DB_RU_COLLECT_FAILURE_LOGS` |
| Step 20 datapatch | `DB_RU_COLLECT_FAILURE_LOGS` |
| Step 24 post check | `DB_RU_COLLECT_FAILURE_LOGS` |

不建议第一版自动执行：

```text
自动 switch back
自动 datapatch rollback
自动 flashback restore point
```

这些动作需要单独设计回退 Workflow，并经过独立测试。

---

## 23. 生产运行控制要求

### 23.1 禁止交互式命令

脚本中禁止：

```bash
su - root
su - grid
su - oracle
```

应改为：

- AAP Credential 直接以目标用户执行；
- 或 AAP 使用 become/sudo；
- 或 root runner 使用 `runuser -u grid --` 执行指定命令。

### 23.2 禁止无保护的 `rm -rf`

不允许：

```bash
rm -rf ${TARGET}
```

必须：

- 校验变量非空；
- 匹配 `dangerous_paths.conf` 白名单；
- 只允许删除明确的中间目录；
- 清理动作必须在最终检查和 Approval F 之后。

### 23.3 禁止并发执行

runner 必须使用 lock 文件：

```bash
/u01/patch1930/ru_automation/state/ru_upgrade.lock
```

同一套 RAC 环境同一时间只允许一个 RU workflow 执行。

### 23.4 禁止越级执行

例如：

```text
step_11.done 存在后，才允许 step_12 执行。
```

如果需要从中间步骤恢复执行，必须由人工确认状态文件，并保留变更记录。

### 23.5 保留失败现场

失败后不自动清理：

- backup 目录；
- switch back 目录；
- logs 目录；
- state 目录；
- restore point；
- 工具日志。

---

## 24. 日志与审计

每一步日志格式：

```text
/u01/patch1930/ru_automation/logs/step_04_20260526_213000.log
```

日志必须包含：

- step 编号；
- step 名称；
- 执行节点；
- 执行用户；
- 开始时间；
- 结束时间；
- 原始命令输出；
- 返回码；
- 标准化结果；
- 日志路径。

AAP 侧保留：

- 谁发起 Workflow；
- 谁批准 Approval；
- 每个 Job Template 的执行结果；
- 每一步 stdout/stderr；
- 失败节点和失败原因。

---

## 25. 开发实施步骤

### 第 1 步：整理 27 个命令

把现有 runbook 拆成 27 个 step 脚本。

要求：

- 每个脚本只做一件事；
- 每个脚本引用 `ru_env.conf`；
- 每个脚本有明确返回码；
- 禁止交互式命令；
- 危险命令加白名单；
- 检查逻辑必须机器可判断。

### 第 2 步：开发 `ru_step_runner.sh`

完成：

```bash
/u01/patch1930/ru_automation/bin/ru_step_runner.sh
```

手工测试：

```bash
/u01/patch1930/ru_automation/bin/ru_step_runner.sh 01
/u01/patch1930/ru_automation/bin/ru_step_runner.sh 02
```

### 第 3 步：改造检查脚本

重点改造：

```text
check_crs_dbrole.sh
check_dbrole.sh
check_pdb.sh
check_invalid_obj.sh
check_version.sh
check_sqlpatch.sh
```

确保返回码标准化。

### 第 4 步：配置 AAP Project / Inventory / Credential

完成：

```text
DB_RU_Automation_Project
DB_RU_Inventory
DB_RU_root_credential / DB_RU_grid_credential / DB_RU_oracle_credential
```

或使用：

```text
aap_ru machine credential + sudo
```

### 第 5 步：创建 Job Templates

创建：

```text
DB_RU_RUN_ROOT
DB_RU_RUN_GRID
DB_RU_RUN_ORACLE
DB_RU_RUN_CHECK   # 可选
```

必须勾选：

```text
Variables -> Prompt on launch
Limit -> Prompt on launch
```

### 第 6 步：创建 Workflow

创建：

```text
WF_DB_RU_1930_Command_Runbook
```

在 Workflow Visualizer 里按 27 个节点配置，每个节点选择对应通用 JT，并通过 Prompt 传入：

```yaml
step_id: "xx"
step_name: "xxxx"
target_group: "node1|node2|db_nodes|primary_exec_node"
serial_num: 1
```

### 第 7 步：插入 Approval 节点

至少插入 6 个审批点：

```text
Approval A：Step 05 后，备份完成确认
Approval B：Step 10 后，升级前检查确认
Approval C：Step 14 后，节点二升级确认
Approval D：Step 18 后，两节点 binary 升级确认
Approval E：Step 19 后 / Step 20 前，datapatch 前确认
Approval F：Step 24 后 / Step 25 前，清理前确认
```

### 第 8 步：测试环境全流程演练

至少完成三类测试：

| 测试类型 | 内容 |
|---|---|
| 正常流程测试 | 27 步完整执行 |
| 失败中断测试 | 人为让某个检查失败，确认 workflow 停止 |
| 重复执行测试 | 重跑已完成 step，确认不会重复执行危险动作 |
| 审批测试 | 验证 Approval approve/deny/timeout 行为 |
| 权限测试 | 验证 root/grid/oracle/aap_ru 权限边界 |
| 清理保护测试 | 验证非法路径不会被 `rm -rf` |

### 第 9 步：生产变更前检查

生产执行前确认：

- patch 包和 gold image 已校验；
- 备份目录空间充足；
- RAC 两节点状态正常；
- ADG/备份/业务连接方案已确认；
- AAP Inventory 节点无误；
- Workflow 审批人已配置；
- 回退方案已准备；
- 变更窗口已确认；
- AAP 执行用户和 sudo 权限已审批；
- 所有脚本在 UAT 至少完整跑通 2~3 次。

---

## 26. 验收标准

| 验收项 | 标准 |
|---|---|
| AAP 可调度 | 可通过 AAP 执行任意指定 step |
| Workflow 可编排 | 可按 27 步顺序执行 |
| JT 可复用 | 27 个 Workflow Node 复用 3~4 个通用 JT |
| Prompt 可传参 | 每个节点可传不同 `step_id` 和 `target_group` |
| Approval 可用 | 关键节点可 approve/deny/timeout |
| 失败可中断 | 任一步失败，后续步骤不继续 |
| 状态可追踪 | 每一步有 `.done` 或 `.failed` 文件 |
| 日志可审计 | 每一步有独立日志，AAP 有执行记录 |
| 权限可控 | 无交互式 su，无明文密码 |
| 危险命令可控 | `rm -rf` 有白名单保护 |
| 可重复演练 | 测试环境可多次演练，不破坏状态 |
| 生产可运行 | 满足变更窗口内人工可控执行 |

---

## 27. 后续演进路线

| 阶段 | 内容 | 目标 |
|---|---|---|
| V1 | AAP Workflow + Step Runner | 快速落地，满足生产控制 |
| V2 | 检查脚本标准化 | 提升判断准确性和复用性 |
| V3 | 高风险步骤 Ansible task 化 | 提升幂等和可维护性 |
| V4 | 完整 Ansible Role | 支持长期产品化和多客户复用 |
| V5 | AAP Configuration as Code | Project/Inventory/JT/Workflow 全部代码化 |

---

## 28. 最终建议

本方案适合当前时间紧、需要尽快启动开发和测试的场景。

实施原则：

```text
不要把 27 个步骤直接做成裸命令串联。
也不要一开始就重写成完整复杂 Ansible Role。
先用 AAP Workflow 管流程，用通用 Job Template 管执行入口，用 step runner 管状态和安全边界。
```

这样可以在较短时间内实现：

- 流程可视化；
- 步骤可控；
- 审批可追踪；
- 失败可中断；
- 日志可审计；
- 后续可演进。

---

## 29. 附录：开发交付物清单

| 交付物 | 说明 |
|---|---|
| `playbooks/run_ru_step.yml` | AAP 通用 playbook |
| `bin/ru_step_runner.sh` | Step Runner 主控脚本 |
| `conf/ru_env.conf.example` | 环境配置模板 |
| `conf/dangerous_paths.conf.example` | 危险路径白名单模板 |
| `steps/step_01_*.sh` 至 `steps/step_27_*.sh` | 27 个升级步骤脚本 |
| `steps/step_99_collect_failure_logs.sh` | 失败日志收集脚本，可选 |
| `checks/check_*.sh` | 标准化检查脚本 |
| `README.md` | 部署和执行说明 |
| AAP Project | `DB_RU_Automation_Project` |
| AAP Inventory | `DB_RU_Inventory` |
| AAP Credentials | root/grid/oracle 或 aap_ru |
| AAP Job Templates | 3~4 个通用 JT |
| AAP Workflow Job Template | 27 step + Approval 的完整流程 |

