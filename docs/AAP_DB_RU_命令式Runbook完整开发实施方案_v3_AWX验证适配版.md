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


---

## 30. 附录：Approval 节点详细实施机制（补充）

> 本章节为 V2 方案的补充说明，用于细化 AAP Workflow 中 Approval 节点的实际操作形式、审批依据来源、审批前自动检查方式，以及 6 个关键 Approval 节点的具体确认内容。前文原有设计、目录结构、Job Template、Workflow、Step Runner 等内容保持不变。

### 30.1 Approval 节点的本质

AAP Workflow 中的 Approval 节点不是自动检查程序，而是一个 **Workflow 暂停点 + 人工 Approve / Deny 操作**。

Workflow 执行到 Approval 节点后会暂停，等待有权限的审批人登录 AAP UI，对当前节点执行：

```text
Approve：批准，Workflow 继续走 On Success 路径
Deny：拒绝，Workflow 走 On Failure 路径或停止
Timeout：超时未审批，按 Deny / Failure 处理
```

因此，Approval 节点本身不负责判断：

```text
precheck 是否 PASS
backup 是否成功
backup 目录是否存在
日志是否存在 ERROR / FAILED / FATAL
是否可以进入下一阶段
```

这些判断必须由 Approval 前置的自动检查节点完成。审批人只根据自动检查节点生成的摘要结果进行人工放行。

核心原则是：

```text
机器负责检查，人负责放行；
机器提供证据，人做变更决策。
```

---

### 30.2 为什么 Approval 前需要 Summary / Gate 节点

以 Approval A 为例，原始流程是：

```text
Step 04 precheck
  -> Step 05 backup
  -> Approval A
  -> Step 06
```

生产环境中不建议直接这样做。因为审批人进入 Approval A 时，如果没有结构化摘要，只能手工翻 Step 04、Step 05 的 Job Output 或登录服务器查日志，效率低且容易漏看。

推荐改为：

```text
Step 04 precheck
  -> Step 05 backup
  -> Step 05A approval_A_summary
  -> Approval A
  -> Step 06
```

其中 `Step 05A approval_A_summary` 是自动检查节点，负责：

```text
1. 读取 Step 04 执行结果
2. 读取 Step 05 执行结果
3. 检查 backup 目录是否存在
4. 扫描 Step 04 / Step 05 日志是否包含 ERROR / FAILED / FATAL
5. 生成 approval_A_summary.md 审批摘要
6. 在 AAP Job Output 中打印摘要
7. 如果硬性条件不满足，则直接 exit 1，不进入 Approval A
```

这样审批人看到的是一个明确结论，而不是零散日志。

---

### 30.3 推荐增加的 6 个 Summary / Gate 节点

为了让所有 Approval 都有清晰依据，建议在 6 个 Approval 前分别增加一个 Summary / Gate 节点。

| Summary 节点 | 位置 | 作用 |
|---|---|---|
| Step 05A | Approval A 前 | 汇总 precheck + backup 结果 |
| Step 10A | Approval B 前 | 汇总软连接保存、CRS 状态保存、gold image 解压、升级前 DB 检查 |
| Step 14A | Approval C 前 | 汇总节点二停实例、home 切换、启动和检查结果 |
| Step 18A | Approval D 前 | 汇总节点一停实例、home 切换、启动和两节点 binary 状态 |
| Step 19A | Approval E 前 | 汇总 datapatch 前置状态、job 参数和 DB/PDB 状态 |
| Step 24A | Approval F 前 | 汇总 datapatch 后状态、版本、sqlpatch、软连接恢复和清理前条件 |

加入 Summary 节点后的完整 Workflow 形态为：

```text
Step 01 创建目录
-> Step 02 更新 goldimage 脚本
-> Step 03 清理上次 image 数据
-> Step 04 precheck
-> Step 05 backup
-> Step 05A 生成 Approval A 摘要
-> Approval A 备份后确认

-> Step 06 保存 Grid 软连接
-> Step 07 保存 Oracle 软连接
-> Step 08 保存 CRS 状态
-> Step 09 解压 goldimage
-> Step 10 升级前数据库检查
-> Step 10A 生成 Approval B 摘要
-> Approval B 升级前确认

-> Step 11 停止节点二实例
-> Step 12 节点二 goldimage 切换
-> Step 13 启动节点二实例
-> Step 14 检查节点二
-> Step 14A 生成 Approval C 摘要
-> Approval C 节点二确认

-> Step 15 停止节点一实例
-> Step 16 节点一 goldimage 切换
-> Step 17 启动节点一实例
-> Step 18 检查节点一
-> Step 18A 生成 Approval D 摘要
-> Approval D binary 升级确认

-> Step 19 修改 job 参数为 0
-> Step 19A 生成 Approval E 摘要
-> Approval E datapatch 前确认

-> Step 20 执行 datapatch
-> Step 21 还原 job 参数为 160
-> Step 22 还原 Oracle 软连接
-> Step 23 还原 Grid 软连接
-> Step 24 数据库检查
-> Step 24A 生成 Approval F 摘要
-> Approval F 清理前确认

-> Step 25 清理 Oracle Home 中间环境
-> Step 26 清理 Grid Home 中间环境
-> Step 27 CRS 状态对比
```

---

### 30.4 每个 Step 必须输出的标准结果

为了让 Summary 节点能够自动汇总，每个 Step 执行完成后，除了 AAP Job Output 外，还应该在服务器本地生成结构化状态文件。

建议每个 Step 生成：

```text
/u01/patch1930/ru_automation/state/step_04.result.json
/u01/patch1930/ru_automation/state/step_04.done
/u01/patch1930/ru_automation/logs/step_04_YYYYMMDD_HHMMSS.log
```

示例：Step 04 precheck 成功后的 `step_04.result.json`：

```json
{
  "step_id": "04",
  "step_name": "precheck",
  "status": "PASS",
  "return_code": 0,
  "host": "cnzhjxd001dbadm01",
  "start_time": "2026-05-27 21:10:00",
  "end_time": "2026-05-27 21:18:00",
  "log_file": "/u01/patch1930/ru_automation/logs/step_04_20260527_211000.log",
  "error_count": 0,
  "failed_count": 0,
  "fatal_count": 0
}
```

示例：Step 05 backup 成功后的 `step_05.result.json`：

```json
{
  "step_id": "05",
  "step_name": "backup_home",
  "status": "PASS",
  "return_code": 0,
  "host": "cnzhjxd001dbadm01",
  "backup_dir": "/u01/patch1930/rac1_backup1930",
  "backup_dir_exists": true,
  "log_file": "/u01/patch1930/ru_automation/logs/step_05_20260527_212000.log",
  "error_count": 0,
  "failed_count": 0,
  "fatal_count": 0
}
```

Summary 节点根据这些 JSON、日志和文件系统状态生成审批摘要。

---

### 30.5 Approval A：备份完成后确认

#### 30.5.1 位置

```text
Step 04 precheck
-> Step 05 backup
-> Step 05A approval_A_summary
-> Approval A
-> Step 06 保存 Grid Home 软连接
```

#### 30.5.2 审批目的

确认 precheck 和备份已经完成，并且具备继续进入 image 解压和状态保存阶段的条件。

#### 30.5.3 需要确认的内容

| 审批项 | 自动获取方式 | 通过条件 |
|---|---|---|
| Step 04 precheck PASS | 读取 `state/step_04.result.json` | `status = PASS` 且 `return_code = 0` |
| Step 05 backup 成功 | 读取 `state/step_05.result.json` | `status = PASS` 且 `return_code = 0` |
| backup 目录存在 | `test -d /u01/patch1930/rac1_backup1930` | 目录存在 |
| 日志无 ERROR / FAILED / FATAL | grep Step 04 / Step 05 日志 | 关键错误数为 0 |
| 允许进入 image 解压和状态保存阶段 | Step 05A 汇总判断 | 前四项全部 PASS |

#### 30.5.4 审批人看到的摘要示例

`Step 05A approval_A_summary` 应在 AAP Job Output 中打印：

```text
========== APPROVAL A SUMMARY ==========
Change ID       : CHG20260527001
RU Version      : 19.30
Cluster         : cnzhjxd001dbadm01/cnzhjxd001dbadm02

[1] Step 04 precheck
    Result      : PASS
    Return Code : 0
    Log File    : /u01/patch1930/ru_automation/logs/step_04_20260527_211000.log

[2] Step 05 backup
    Result      : PASS
    Return Code : 0
    Log File    : /u01/patch1930/ru_automation/logs/step_05_20260527_212000.log

[3] Backup directory
    Path        : /u01/patch1930/rac1_backup1930
    Exists      : YES

[4] Log scan
    ERROR       : 0
    FAILED      : 0
    FATAL       : 0

[5] Gate decision
    Result      : PASS
    Recommendation:
    Approve only if the above results match the change plan.
========================================
```

#### 30.5.5 Approval A 节点配置

在 Workflow Visualizer 中添加 Approval 节点：

```text
Node Type:
Approval

Name:
APPROVAL_A_AFTER_BACKUP

Description:
确认 Step 04 precheck、Step 05 backup 和 backup 目录检查结果。
审批前请查看上一节点 Step 05A 的 Job Output：
1. Step 04 precheck = PASS
2. Step 05 backup = PASS
3. backup 目录存在
4. 日志无 ERROR / FAILED / FATAL
5. Gate decision = PASS
确认后点击 Approve，进入 Step 06 image 解压和状态保存阶段。

Timeout:
86400
```

连接关系：

```text
Step 05A approval_A_summary
    On Success -> Approval A

Approval A
    On Success -> Step 06

Approval A
    On Failure -> Stop 或 Step 99 collect_failure_logs
```

---

### 30.6 Approval B：升级前检查确认

#### 30.6.1 位置

```text
Step 06 保存 Grid 软连接
-> Step 07 保存 Oracle 软连接
-> Step 08 保存 CRS 状态
-> Step 09 解压 goldimage
-> Step 10 数据库检查
-> Step 10A approval_B_summary
-> Approval B
-> Step 11 停止节点二实例
```

#### 30.6.2 审批目的

确认在真正停止节点二实例之前，环境状态已经保存，gold image 已经解压，数据库状态允许进入 rolling upgrade。

#### 30.6.3 需要确认的内容

| 审批项 | 自动获取方式 | 通过条件 |
|---|---|---|
| Grid 软连接保存 | Step 06 result/log | PASS |
| Oracle 软连接保存 | Step 07 result/log | PASS |
| CRS 状态保存 | `/tmp/before_crs_stats.log` 或 Step 08 result | 文件存在且非空 |
| gold image 解压 | Step 09 result/log | PASS |
| DB role 检查 | Step 10 result/log | 正确 |
| PDB 状态检查 | Step 10 result/log | 正常 |
| invalid object 检查 | Step 10 result/log | 无异常增长 |
| Gate 判断 | Step 10A 汇总 | PASS |

#### 30.6.4 审批动作

审批人查看 `Step 10A approval_B_summary` 的 AAP Job Output，确认全部 PASS 后点击 Approve，才允许进入：

```text
Step 11 停止节点二实例
```

该审批点非常关键，因为 Step 11 开始进入实例滚动停启阶段。

---

### 30.7 Approval C：节点二升级完成后确认

#### 30.7.1 位置

```text
Step 11 停止节点二实例
-> Step 12 节点二 goldimage 切换
-> Step 13 启动节点二实例
-> Step 14 检查节点二
-> Step 14A approval_C_summary
-> Approval C
-> Step 15 停止节点一实例
```

#### 30.7.2 审批目的

确认节点二升级完成且恢复正常后，才允许升级节点一，避免在节点二状态不稳定时继续影响节点一。

#### 30.7.3 需要确认的内容

| 审批项 | 自动获取方式 | 通过条件 |
|---|---|---|
| 节点二实例停止 | Step 11 result/log | PASS |
| 节点二 Home 切换 | Step 12 result/log | PASS |
| 节点二实例启动 | Step 13 result/log | PASS |
| 节点二 CRS/DB 检查 | Step 14 result/log | PASS |
| 节点二服务状态 | `srvctl status service` 或检查脚本 | 正常 |
| Gate 判断 | Step 14A 汇总 | PASS |

#### 30.7.4 审批动作

审批人查看 `Step 14A approval_C_summary`，确认节点二没有异常后点击 Approve，才允许执行：

```text
Step 15 停止节点一实例
```

这个审批点用于防止：

```text
节点二升级异常，但流程继续停止节点一，导致 RAC 整体风险扩大。
```

---

### 30.8 Approval D：两节点 binary 切换完成后确认

#### 30.8.1 位置

```text
Step 15 停止节点一实例
-> Step 16 节点一 goldimage 切换
-> Step 17 启动节点一实例
-> Step 18 检查节点一
-> Step 18A approval_D_summary
-> Approval D
-> Step 19 修改 job 参数为 0
```

#### 30.8.2 审批目的

确认两个 RAC 节点 binary/home 切换都完成，且实例、CRS、服务状态正常，再进入 SQL 层处理。

#### 30.8.3 需要确认的内容

| 审批项 | 自动获取方式 | 通过条件 |
|---|---|---|
| 节点一实例停止 | Step 15 result/log | PASS |
| 节点一 Home 切换 | Step 16 result/log | PASS |
| 节点一实例启动 | Step 17 result/log | PASS |
| 节点一 DB 检查 | Step 18 result/log | PASS |
| 两节点 CRS 状态 | CRS 检查脚本 | 正常 |
| Grid/DB Home 指向 | 检查脚本 | 符合目标路径 |
| Gate 判断 | Step 18A 汇总 | PASS |

#### 30.8.4 审批动作

审批人查看 `Step 18A approval_D_summary`，确认 binary 层稳定后点击 Approve，才允许进入：

```text
Step 19 修改 job 参数为 0
```

---

### 30.9 Approval E：datapatch 前确认

#### 30.9.1 位置

```text
Step 19 修改 job 参数为 0
-> Step 19A approval_E_summary
-> Approval E
-> Step 20 执行 datapatch
```

#### 30.9.2 审批目的

`datapatch` 是 SQL 层字典变更，风险级别高于 binary 切换。该审批点用于确认数据库状态、PDB 状态、job 参数、restore point 策略和业务窗口都满足要求。

#### 30.9.3 需要确认的内容

| 审批项 | 自动获取方式 | 通过条件 |
|---|---|---|
| job 参数调整 | Step 19 result/log | PASS |
| job 参数当前值 | SQL 查询 | 确认为 0 |
| DB 状态 | 检查脚本 | 正常 |
| PDB 状态 | 检查脚本 | 正常 |
| restore point 策略 | 配置项或检查脚本 | 已确认 |
| 业务窗口 | 变更输入变量或人工确认 | 仍有效 |
| Gate 判断 | Step 19A 汇总 | PASS 或 WAIT_APPROVAL |

#### 30.9.4 Approval E 节点描述建议

```text
Name:
APPROVAL_E_BEFORE_DATAPATCH

Description:
确认 Step 19 已将 job 参数调整为 0，DB/PDB 状态正常，业务窗口仍有效，restore point 策略已确认。
批准后将执行 Step 20 datapatch，该操作涉及数据库 SQL patch 字典变更。
请审批人查看上一节点 Step 19A 的 Job Output，确认 Gate decision 为 PASS 后再点击 Approve。

Timeout:
86400
```

#### 30.9.5 审批动作

审批人确认后点击 Approve，Workflow 执行：

```text
Step 20 执行 datapatch
```

---

### 30.10 Approval F：清理中间环境前确认

#### 30.10.1 位置

```text
Step 20 执行 datapatch
-> Step 21 还原 job 参数为 160
-> Step 22 还原 Oracle 软连接
-> Step 23 还原 Grid 软连接
-> Step 24 数据库检查
-> Step 24A approval_F_summary
-> Approval F
-> Step 25 清理 Oracle Home 中间环境
-> Step 26 清理 Grid Home 中间环境
-> Step 27 CRS 状态对比
```

#### 30.10.2 审批目的

这是清理前的关键审批点。Step 25 和 Step 26 会删除 switch back 中间环境：

```text
dbhome_1.backup.for.switch_back
grid.backup.for.switch_back
```

所以必须确认升级已经成功、SQL patch 已成功、CRS 状态正常、短期内不需要立即 switch back，才能继续清理。

#### 30.10.3 需要确认的内容

| 审批项 | 自动获取方式 | 通过条件 |
|---|---|---|
| datapatch 结果 | Step 20 result/log | PASS |
| `dba_registry_sqlpatch` | SQL 查询 | 目标 RU SUCCESS |
| job 参数恢复 | Step 21 result/log | PASS |
| Oracle 软连接恢复 | Step 22 result/log | PASS |
| Grid 软连接恢复 | Step 23 result/log | PASS |
| version 检查 | Step 24 result/log | 目标版本 |
| sqlpatch 检查 | Step 24 result/log | SUCCESS |
| CRS 状态 | 检查脚本 | 正常 |
| Gate 判断 | Step 24A 汇总 | PASS |

#### 30.10.4 审批动作

审批人查看 `Step 24A approval_F_summary`，确认全部 PASS 后点击 Approve，才允许执行：

```text
Step 25 清理 Oracle Home 中间环境
Step 26 清理 Grid Home 中间环境
```

#### 30.10.5 生产建议

生产环境可以更保守地处理 Step 25 / Step 26：

```text
主升级流程执行到 Step 24 + Approval F 后结束；
Step 25 / Step 26 / Step 27 作为单独的清理 Workflow 手动执行。
```

这样可以避免升级刚完成后过早清理 switch back 目录。

---

### 30.11 Summary 节点脚本示例：Step 05A

下面是 `Step 05A approval_A_summary` 的示例脚本：

```bash
#!/bin/bash
set -euo pipefail

BASE_DIR="/u01/patch1930/ru_automation"
STATE_DIR="${BASE_DIR}/state"
LOG_DIR="${BASE_DIR}/logs"
REPORT_DIR="${BASE_DIR}/reports"
BACKUP_DIR="/u01/patch1930/rac1_backup1930"

mkdir -p "${REPORT_DIR}"

STEP04_JSON="${STATE_DIR}/step_04.result.json"
STEP05_JSON="${STATE_DIR}/step_05.result.json"
REPORT_FILE="${REPORT_DIR}/approval_A_summary_$(date +%Y%m%d_%H%M%S).md"

FAIL_COUNT=0

echo "========== APPROVAL A SUMMARY ==========" | tee "${REPORT_FILE}"

if [ -f "${STEP04_JSON}" ] && grep -q '"status": "PASS"' "${STEP04_JSON}"; then
  echo "[1] Step 04 precheck: PASS" | tee -a "${REPORT_FILE}"
else
  echo "[1] Step 04 precheck: FAIL" | tee -a "${REPORT_FILE}"
  FAIL_COUNT=$((FAIL_COUNT+1))
fi

if [ -f "${STEP05_JSON}" ] && grep -q '"status": "PASS"' "${STEP05_JSON}"; then
  echo "[2] Step 05 backup: PASS" | tee -a "${REPORT_FILE}"
else
  echo "[2] Step 05 backup: FAIL" | tee -a "${REPORT_FILE}"
  FAIL_COUNT=$((FAIL_COUNT+1))
fi

if [ -d "${BACKUP_DIR}" ]; then
  echo "[3] Backup directory exists: YES - ${BACKUP_DIR}" | tee -a "${REPORT_FILE}"
else
  echo "[3] Backup directory exists: NO - ${BACKUP_DIR}" | tee -a "${REPORT_FILE}"
  FAIL_COUNT=$((FAIL_COUNT+1))
fi

ERROR_COUNT=$(grep -Eih "ERROR|FAILED|FATAL" "${LOG_DIR}"/step_04_*.log "${LOG_DIR}"/step_05_*.log 2>/dev/null | wc -l || true)

if [ "${ERROR_COUNT}" -eq 0 ]; then
  echo "[4] Log scan ERROR/FAILED/FATAL: PASS, count=0" | tee -a "${REPORT_FILE}"
else
  echo "[4] Log scan ERROR/FAILED/FATAL: FAIL, count=${ERROR_COUNT}" | tee -a "${REPORT_FILE}"
  FAIL_COUNT=$((FAIL_COUNT+1))
fi

if [ "${FAIL_COUNT}" -eq 0 ]; then
  echo "[5] Gate decision: PASS. Approval A can be approved." | tee -a "${REPORT_FILE}"
  echo "Report file: ${REPORT_FILE}" | tee -a "${REPORT_FILE}"
  exit 0
else
  echo "[5] Gate decision: FAIL. Do not continue." | tee -a "${REPORT_FILE}"
  echo "Report file: ${REPORT_FILE}" | tee -a "${REPORT_FILE}"
  exit 1
fi
```

其他 Summary 节点可以复用同样模式，只需要调整读取的 Step 结果、日志范围和检查项。

---

### 30.12 Step Runner 对 Summary 节点的支持

如果采用 `step_id` 方式调度，需要在 `ru_step_runner.sh` 中增加 Summary Step 映射。

示例：

```bash
case "${STEP_ID}" in
  01) STEP_SCRIPT="${STEP_DIR}/01_create_dir.sh" ;;
  02) STEP_SCRIPT="${STEP_DIR}/02_unzip_ru_script.sh" ;;
  03) STEP_SCRIPT="${STEP_DIR}/03_clean_old_image.sh" ;;
  04) STEP_SCRIPT="${STEP_DIR}/04_precheck.sh" ;;
  05) STEP_SCRIPT="${STEP_DIR}/05_backup_home.sh" ;;
  05A) STEP_SCRIPT="${STEP_DIR}/05A_approval_A_summary.sh" ;;
  06) STEP_SCRIPT="${STEP_DIR}/06_save_grid_symlink.sh" ;;
  07) STEP_SCRIPT="${STEP_DIR}/07_save_oracle_symlink.sh" ;;
  08) STEP_SCRIPT="${STEP_DIR}/08_save_crs_status.sh" ;;
  09) STEP_SCRIPT="${STEP_DIR}/09_unzip_goldimage.sh" ;;
  10) STEP_SCRIPT="${STEP_DIR}/10_check_database_before_upgrade.sh" ;;
  10A) STEP_SCRIPT="${STEP_DIR}/10A_approval_B_summary.sh" ;;
  11) STEP_SCRIPT="${STEP_DIR}/11_stop_node2_instance.sh" ;;
  12) STEP_SCRIPT="${STEP_DIR}/12_switch_node2_home.sh" ;;
  13) STEP_SCRIPT="${STEP_DIR}/13_start_node2_instance.sh" ;;
  14) STEP_SCRIPT="${STEP_DIR}/14_check_node2.sh" ;;
  14A) STEP_SCRIPT="${STEP_DIR}/14A_approval_C_summary.sh" ;;
  15) STEP_SCRIPT="${STEP_DIR}/15_stop_node1_instance.sh" ;;
  16) STEP_SCRIPT="${STEP_DIR}/16_switch_node1_home.sh" ;;
  17) STEP_SCRIPT="${STEP_DIR}/17_start_node1_instance.sh" ;;
  18) STEP_SCRIPT="${STEP_DIR}/18_check_node1.sh" ;;
  18A) STEP_SCRIPT="${STEP_DIR}/18A_approval_D_summary.sh" ;;
  19) STEP_SCRIPT="${STEP_DIR}/19_set_job_param_zero.sh" ;;
  19A) STEP_SCRIPT="${STEP_DIR}/19A_approval_E_summary.sh" ;;
  20) STEP_SCRIPT="${STEP_DIR}/20_run_datapatch.sh" ;;
  21) STEP_SCRIPT="${STEP_DIR}/21_restore_job_param.sh" ;;
  22) STEP_SCRIPT="${STEP_DIR}/22_restore_oracle_symlink.sh" ;;
  23) STEP_SCRIPT="${STEP_DIR}/23_restore_grid_symlink.sh" ;;
  24) STEP_SCRIPT="${STEP_DIR}/24_check_version_sqlpatch.sh" ;;
  24A) STEP_SCRIPT="${STEP_DIR}/24A_approval_F_summary.sh" ;;
  25) STEP_SCRIPT="${STEP_DIR}/25_clean_oracle_home_backup.sh" ;;
  26) STEP_SCRIPT="${STEP_DIR}/26_clean_grid_home_backup.sh" ;;
  27) STEP_SCRIPT="${STEP_DIR}/27_compare_crs_status.sh" ;;
  99) STEP_SCRIPT="${STEP_DIR}/99_collect_failure_logs.sh" ;;
  *)
    echo "ERROR: unknown step_id=${STEP_ID}"
    exit 11
    ;;
esac
```

---

### 30.13 AAP Workflow Visualizer 中的配置方式

以 Approval A 为例，在 Workflow Visualizer 中配置如下：

#### 30.13.1 添加 Step 05A Summary 节点

从 Step 05 节点点击 `+`，添加子节点：

```text
Node Type: Template
Job Template: DB_RU_RUN_CHECK 或 DB_RU_RUN_ORACLE
Edge Type: On Success
```

点击 `PROMPT`，填写：

```yaml
step_id: "05A"
step_name: "approval_A_summary"
```

Limit：

```text
node1
```

#### 30.13.2 添加 Approval A 节点

从 Step 05A 节点点击 `+`，添加子节点：

```text
Node Type: Approval
Name: APPROVAL_A_AFTER_BACKUP
Timeout: 86400
```

Description 填写审批说明，提醒审批人查看 Step 05A 的 Job Output。

#### 30.13.3 Approval A 后连接 Step 06

从 Approval A 节点点击 `+`：

```text
Node Type: Template
Job Template: DB_RU_RUN_GRID 或 DB_RU_RUN_ROOT
Edge Type: On Success
```

PROMPT：

```yaml
step_id: "06"
step_name: "save_grid_symlink"
```

Limit：

```text
db_nodes
```

#### 30.13.4 Approval A 失败分支

可选配置：

```text
Approval A
  On Failure -> Step 99 collect_failure_logs
```

或者不配置 Failure 分支，使 Workflow 停止。

---

### 30.14 Summary 节点与 set_stats 的关系

可以在 `run_ru_step.yml` 中使用 `ansible.builtin.set_stats` 将审批摘要路径、Gate 结果等信息输出到 AAP Workflow artifacts。

示例：

```yaml
- name: Publish RU step summary to workflow artifacts
  ansible.builtin.set_stats:
    data:
      last_step_id: "{{ step_id }}"
      last_step_rc: "{{ ru_step_result.rc }}"
      last_step_stdout: "{{ ru_step_result.stdout }}"
    per_host: false
```

对于 Summary 节点，可以输出：

```yaml
- name: Publish approval summary
  ansible.builtin.set_stats:
    data:
      approval_gate_result: "PASS"
      approval_report_path: "/u01/patch1930/ru_automation/reports/approval_A_summary.md"
    per_host: false
```

但生产环境不建议只依赖 AAP artifacts。建议同时保留服务器本地文件：

```text
/u01/patch1930/ru_automation/state/*.result.json
/u01/patch1930/ru_automation/reports/approval_*.md
/u01/patch1930/ru_automation/logs/*.log
```

这样即使 AAP 页面历史被清理，服务器侧仍有完整审计文件。

---

### 30.15 Approval 节点实施要求汇总

| 要求 | 说明 |
|---|---|
| Approval 前必须有 Summary / Gate 节点 | 不允许审批人只凭口头确认或手工翻日志判断 |
| Summary 节点必须自动检查硬性条件 | 条件不满足则 `exit 1`，不能进入 Approval |
| Approval Description 要写清楚审批依据 | 明确要求审批人查看哪个 Summary Job Output |
| Approval 后续主链路使用 On Success | 只有 Approve 才继续执行下一阶段 |
| Deny / Timeout 不继续主流程 | 可停止或进入 Step 99 日志收集 |
| Step 25/26 清理前必须审批 | 不允许在未确认升级成功前清理 switch back 目录 |
| Summary 报告必须落盘 | 建议保存到 `reports/approval_*.md` |
| Step 结果必须结构化 | 建议使用 `state/step_*.result.json` |

---

### 30.16 开发任务补充

在 V2 原开发任务基础上，需要额外增加以下开发项：

| 编号 | 开发项 | 说明 |
|---|---|---|
| A1 | 增强 `ru_step_runner.sh` | 支持 `05A/10A/14A/18A/19A/24A` 这 6 个 Summary Step |
| A2 | 开发 `05A_approval_A_summary.sh` | 汇总 precheck 和 backup |
| A3 | 开发 `10A_approval_B_summary.sh` | 汇总升级前状态 |
| A4 | 开发 `14A_approval_C_summary.sh` | 汇总节点二升级结果 |
| A5 | 开发 `18A_approval_D_summary.sh` | 汇总节点一升级和两节点 binary 状态 |
| A6 | 开发 `19A_approval_E_summary.sh` | 汇总 datapatch 前置条件 |
| A7 | 开发 `24A_approval_F_summary.sh` | 汇总 datapatch 后和清理前条件 |
| A8 | 修改 Workflow Visualizer 配置 | 在 6 个 Approval 前插入对应 Summary 节点 |
| A9 | 增加 Summary 报告目录 | `/u01/patch1930/ru_automation/reports` |
| A10 | 增加审批验证用例 | 测试 Summary PASS、Summary FAIL、Approval Approve、Approval Deny、Approval Timeout |

---

### 30.17 最终实施建议

生产环境推荐采用如下控制方式：

```text
自动执行 Step
  -> 自动生成 Summary / Gate 结论
  -> 硬性条件满足才进入 Approval
  -> 人工查看摘要并 Approve
  -> 继续执行下一阶段
```

不要采用：

```text
自动执行 Step
  -> 直接进入 Approval
  -> 审批人手工翻日志判断
```

最终要求是：

```text
每个 Approval 都有明确证据；
每个证据都可以追溯到 Step result、日志和检查脚本；
每个高风险动作都必须在自动检查通过且人工 Approve 后才执行。
```

---

## 31. 附录：AWX 验证适配与 AAP 回迁注意事项（新增）

> 本章节为 **【AWX验证补充】**，用于说明如何把本 V2 Approval 补充版方案先放到 AWX 上进行开发验证，并明确哪些地方需要临时调整、哪些地方只是新增验证要求，以及后续迁移回 AAP/Automation Controller 时要重点复核什么。  
> 原 V2 主体方案仍以 AAP 生产运行为目标，本章节不改变生产目标，只补充 AWX 验证阶段的适配要求。

### 31.1 标识规则

本文档中本章节使用以下标识：

| 标识 | 含义 |
|---|---|
| **【AWX验证修改】** | AWX 验证阶段建议对原 AAP 设计做临时调整，迁移回 AAP 时需要恢复或复核。 |
| **【AWX验证补充】** | 原 AAP 设计不需要变更，但为了在 AWX 上验证更清晰，新增测试项、变量、流程或检查项。 |
| **【AAP回迁注意】** | 从 AWX 迁移到 AAP 时必须重新确认的事项。 |

### 31.2 总体判断

**可以先在 AWX 上完整验证本方案中的 Project、Inventory、Credential、Job Template、Workflow Job Template、Workflow Visualizer、Prompt on Launch、Approval、Summary/Gate 节点和 27 个 step 的串联逻辑。**

AWX 是 Automation Controller 的 upstream 项目，AWX 官方文档中包含 Projects、Inventories、Credentials、Job Templates、Workflow Job Templates 等能力；Workflow Visualizer 支持 Template、Project Sync、Inventory Sync、Approval 等节点，也支持在节点级别通过 Prompt 修改启用了 Prompt on Launch 的参数。  
参考：

- AWX Workflow Job Templates：`https://docs.ansible.com/projects/awx/en/24.6.1/userguide/workflow_templates.html`
- AWX Job Templates：`https://docs.ansible.com/projects/awx/en/24.6.1/userguide/job_templates.html`
- AAP Workflow Job Templates：`https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.4/html/automation_controller_user_guide/controller-workflow-job-templates`
- AAP Job Templates：`https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.4/html/automation_controller_user_guide/controller-job-templates`

但需要明确：

```text
AWX = 开发验证平台
AAP = 生产运行平台
```

AWX 上验证通过，只能说明：

```text
流程逻辑、脚本框架、step_id 传递、Workflow 编排、Approval 操作、Summary/Gate 检查机制基本可行。
```

不能直接等同于：

```text
AAP 生产环境已经满足上线条件。
```

迁移到 AAP 前必须重新验证版本、Execution Environment、Credential、RBAC、审批权限、Project Sync、Workflow 节点配置、日志保存策略和生产 RAC 访问权限。

---

### 31.3 AWX 验证阶段修改/补充总览

| 编号 | 类型 | 涉及内容 | 原 AAP 设计 | AWX 验证阶段调整或补充 | AAP 回迁注意 |
|---:|---|---|---|---|---|
| 1 | 【AWX验证补充】 | 平台定位 | 原设计默认以 AAP 生产运行为目标。 | 明确 AWX 只作为开发/验证平台，不作为生产等价替代。 | AAP 上仍需重新做 UAT 验证。 |
| 2 | 【AWX验证补充】 | 版本基线 | 原设计未强制记录 AWX/AAP 版本差异。 | 增加 AWX Version、Ansible Core、EE Image、Collections、Python 版本记录。 | 迁移 AAP 时必须记录并对比 Controller/EE/Collections 版本。 |
| 3 | 【AWX验证修改】 | Project | 原设计：`DB_RU_Automation_Project` 指向正式 Git 仓库/分支。 | AWX 中建议使用测试分支，例如 `dev/awx-test` 或 `feature/ru-runbook-awx`。 | AAP 中切回正式仓库和正式 release 分支。 |
| 4 | 【AWX验证修改】 | Inventory | 原设计：`DB_RU_Inventory` 包含真实 RAC 节点 `node1/node2/db_nodes`。 | AWX 初期建议使用 `DB_RU_AWX_TEST_Inventory`，先接 mock/test 主机，再接 UAT RAC。 | AAP 中使用正式生产或 UAT Inventory，不直接复用 AWX 测试 Inventory。 |
| 5 | 【AWX验证修改】 | Credential | 原设计：root/grid/oracle 三类 Machine Credential。 | AWX 中可使用测试账号或 mock 主机账号，但仍保留 root/grid/oracle 三类 Credential 结构。 | AAP 中 Credential 必须重新创建，不导出 AWX 密钥。 |
| 6 | 【AWX验证补充】 | Credential Prompt | 原设计要求不要在脚本中使用交互式 `su - root`。 | AWX 中也必须验证 Credential 不依赖运行时输入密码，否则 Workflow 节点可能无法稳定选择或执行。 | AAP 中同样禁止依赖交互式密码输入。 |
| 7 | 【AWX验证修改】 | Execution Environment | 原设计面向 AAP EE。 | AWX 测试时增加 `DB_RU_AWX_EE`，尽量与 AAP 目标 EE 保持一致。 | AAP 上必须重新验证 EE 内 ansible-core、shell、python、collections 是否一致。 |
| 8 | 【AWX验证修改】 | Job Template 命名 | 原设计：`DB_RU_RUN_ROOT/GRID/ORACLE/CHECK`。 | AWX 中建议创建 `DB_RU_AWX_RUN_ROOT/GRID/ORACLE/CHECK`，避免和后续 AAP 命名混淆。 | AAP 中恢复正式命名，或保持统一命名但切换 Organization/Inventory。 |
| 9 | 【AWX验证补充】 | Job Template Prompt | 原设计要求 Variables 和 Limit 启用 Prompt on Launch。 | AWX 中必须专项验证每个 Workflow Node 是否能传入不同 `step_id` 和不同 `Limit`。 | AAP 中必须逐节点复核 Prompt 值是否正确迁移。 |
| 10 | 【AWX验证修改】 | Workflow 名称 | 原设计：`DB_RU_19_30_Rolling_Upgrade`。 | AWX 建议创建 `DB_RU_AWX_19_30_Rolling_Upgrade_TEST`。 | AAP 中创建正式 Workflow 名称，并禁止并发执行。 |
| 11 | 【AWX验证补充】 | Workflow 构建顺序 | 原设计直接给出 27 step + Summary + Approval 的完整流程。 | AWX 中建议分阶段验证：Smoke → Full Mock → Check-only → UAT Real。 | AAP 中不建议直接从 AWX Smoke 版本迁移，必须迁移 Full 版本。 |
| 12 | 【AWX验证补充】 | Mock Mode | 原设计 step 直接执行真实命令。 | AWX 初期新增 `ru_run_mode=mock/check/real`，避免一开始执行破坏性命令。 | AAP 生产中默认 `real`，并禁止用户随意切换危险模式。 |
| 13 | 【AWX验证补充】 | Approval | 原设计：Approval 前增加 Summary/Gate 节点。 | AWX 中必须验证 Approve、Deny、Timeout、无权限用户审批失败四类场景。 | AAP 中重新配置审批权限和审批人角色。 |
| 14 | 【AWX验证补充】 | Summary/Gate | 原设计建议 Step 05A/10A/14A/18A/19A/24A。 | AWX 中先用 mock result.json 验证 Summary 逻辑，再接真实检查。 | AAP 中 Summary 输出必须满足变更审计和生产复核要求。 |
| 15 | 【AWX验证补充】 | set_stats / artifacts | 原设计建议文件状态为主，set_stats 可选。 | AWX 中验证 artifacts 是否能传给下游节点，但不能只依赖 artifacts。 | AAP 中也以 `state/*.json` 和 `reports/*.md` 为主。 |
| 16 | 【AWX验证补充】 | 失败分支 | 原设计 Step 99 可选。 | AWX 中必须验证至少 3 类失败：precheck fail、Summary fail、Approval deny。 | AAP 生产中建议保留 Step 99 日志收集。 |
| 17 | 【AWX验证补充】 | 配置即代码 | 原设计可先 UI 手工配置，后续再代码化。 | AWX 验证后建议导出对象清单或用 `awx.awx` collection 固化。 | AAP 中推荐使用受支持的 controller/infra 配置方式或 UI 重建，不做数据库级迁移。 |

---

### 31.4 AWX 验证阶段建议增加的全局变量

【AWX验证补充】为了避免 AWX 测试阶段误执行真实升级命令，建议在 Job Template / Workflow Survey / Extra Vars 中增加以下变量：

```yaml
platform_mode: "awx_test"        # awx_test / aap_uat / aap_prod
ru_run_mode: "mock"              # mock / check / real
change_id: "AWX-TEST-CHG0001"
ru_version: "19.30"
allow_destructive_step: false     # 是否允许执行 rm -rf、stop instance、switch home、datapatch 等高风险步骤
approval_report_required: true
```

变量含义：

| 变量 | 说明 | AWX 测试建议 | AAP 生产建议 |
|---|---|---|---|
| `platform_mode` | 当前运行平台标识 | `awx_test` | `aap_prod` 或 `aap_uat` |
| `ru_run_mode` | 执行模式 | 初期 `mock`，中期 `check`，最终 UAT 才 `real` | 默认 `real` |
| `allow_destructive_step` | 是否允许破坏性命令 | 默认 `false` | 高风险步骤前由 Summary + Approval 控制 |
| `approval_report_required` | 是否要求审批报告存在 | `true` | `true` |

---

### 31.5 `run_ru_step.yml` 的 AWX 验证修改

#### 原 AAP 设计

原 V2 设计中的极薄 Ansible Wrapper 主要逻辑如下：

```yaml
- name: Run RU step runner
  ansible.builtin.shell: |
    set -o pipefail
    {{ ru_base_dir }}/ru_step_runner.sh {{ step_id }}
  args:
    executable: /bin/bash
  register: ru_step_result
  changed_when: true
  failed_when: ru_step_result.rc != 0
```

#### 【AWX验证修改】建议调整为兼容 mock/check/real 模式

AWX 测试阶段建议把运行模式也传给 step runner：

```yaml
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

  tasks:
    - name: Validate required variable step_id
      ansible.builtin.assert:
        that:
          - step_id is defined
          - step_id | length > 0
        fail_msg: "step_id is required. Example: step_id=04"

    - name: Show runtime parameters
      ansible.builtin.debug:
        msg:
          - "platform_mode={{ platform_mode }}"
          - "ru_run_mode={{ ru_run_mode }}"
          - "step_id={{ step_id }}"
          - "allow_destructive_step={{ allow_destructive_step }}"
          - "inventory_hostname={{ inventory_hostname }}"

    - name: Run RU step runner
      ansible.builtin.shell: |
        set -o pipefail
        {{ ru_base_dir }}/ru_step_runner.sh {{ step_id }} \
          --mode {{ ru_run_mode }} \
          --platform {{ platform_mode }} \
          --allow-destructive {{ allow_destructive_step | bool | ternary('true','false') }}
      args:
        executable: /bin/bash
      register: ru_step_result
      changed_when: true
      failed_when: ru_step_result.rc != 0

    - name: Show RU step output
      ansible.builtin.debug:
        var: ru_step_result.stdout_lines

    - name: Publish workflow stats
      ansible.builtin.set_stats:
        data:
          last_step_id: "{{ step_id }}"
          last_step_rc: "{{ ru_step_result.rc }}"
          last_step_mode: "{{ ru_run_mode }}"
          last_step_platform: "{{ platform_mode }}"
        per_host: false
```

#### AAP 回迁注意

【AAP回迁注意】迁移到 AAP 生产时可以保留上述变量设计，但需要：

```text
1. platform_mode 固定为 aap_prod；
2. ru_run_mode 固定为 real；
3. allow_destructive_step 不允许普通用户随意修改；
4. 高风险步骤仍然必须经过 Summary/Gate + Approval；
5. 不允许通过 Survey 让非管理员把 mock/check 改成 real。
```

---

### 31.6 `ru_step_runner.sh` 的 AWX 验证修改

#### 原 AAP 设计

原 V2 设计中，step runner 根据 `step_id` 映射到 27 个 step 脚本，并执行真实命令。

#### 【AWX验证修改】增加运行模式控制

建议 AWX 验证阶段将 `ru_step_runner.sh` 增强为支持三种模式：

| 模式 | 用途 | 行为 |
|---|---|---|
| `mock` | 初期流程验证 | 不执行真实 Oracle/RAC 命令，只生成日志、result.json 和 done 文件。 |
| `check` | 非破坏性检查 | 允许执行 `hostname/date/whoami/crsctl status/srvctl status/sqlplus select` 等只读命令。 |
| `real` | UAT 真实验证 | 执行真实 RU 升级步骤。 |

示例框架：

```bash
#!/bin/bash
set -euo pipefail

STEP_ID="${1:-}"
shift || true

MODE="mock"
PLATFORM="awx_test"
ALLOW_DESTRUCTIVE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --allow-destructive) ALLOW_DESTRUCTIVE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 10 ;;
  esac
done

BASE_DIR="/u01/patch1930/ru_automation"
LOG_DIR="${BASE_DIR}/logs"
STATE_DIR="${BASE_DIR}/state"
STEP_DIR="${BASE_DIR}/steps"
mkdir -p "${LOG_DIR}" "${STATE_DIR}"

LOG_FILE="${LOG_DIR}/step_${STEP_ID}_$(date +%Y%m%d_%H%M%S).log"
RESULT_JSON="${STATE_DIR}/step_${STEP_ID}.result.json"
DONE_FILE="${STATE_DIR}/step_${STEP_ID}.done"
FAILED_FILE="${STATE_DIR}/step_${STEP_ID}.failed"

write_result() {
  local status="$1"
  local rc="$2"
  cat > "${RESULT_JSON}" <<JSON
{
  "step_id": "${STEP_ID}",
  "status": "${status}",
  "return_code": ${rc},
  "mode": "${MODE}",
  "platform": "${PLATFORM}",
  "host": "$(hostname)",
  "log_file": "${LOG_FILE}",
  "time": "$(date '+%Y-%m-%d %H:%M:%S')"
}
JSON
}

if [[ -z "${STEP_ID}" ]]; then
  echo "ERROR: step_id is required"
  exit 10
fi

if [[ "${MODE}" == "mock" ]]; then
  echo "MOCK MODE: simulate step ${STEP_ID}" | tee -a "${LOG_FILE}"
  write_result "PASS" 0
  touch "${DONE_FILE}"
  rm -f "${FAILED_FILE}"
  exit 0
fi

# 防止 AWX 初期误执行高风险步骤
case "${STEP_ID}" in
  03|11|12|15|16|20|25|26)
    if [[ "${MODE}" != "real" || "${ALLOW_DESTRUCTIVE}" != "true" ]]; then
      echo "ERROR: step ${STEP_ID} is destructive and requires mode=real and allow_destructive=true" | tee -a "${LOG_FILE}"
      write_result "FAIL" 20
      touch "${FAILED_FILE}"
      exit 20
    fi
    ;;
esac

# check/real 模式下再映射真实 step 脚本
case "${STEP_ID}" in
  01) STEP_SCRIPT="${STEP_DIR}/01_create_dir.sh" ;;
  02) STEP_SCRIPT="${STEP_DIR}/02_unzip_ru_script.sh" ;;
  03) STEP_SCRIPT="${STEP_DIR}/03_clean_old_image.sh" ;;
  04) STEP_SCRIPT="${STEP_DIR}/04_precheck.sh" ;;
  05) STEP_SCRIPT="${STEP_DIR}/05_backup_home.sh" ;;
  05A) STEP_SCRIPT="${STEP_DIR}/05A_approval_A_summary.sh" ;;
  10A) STEP_SCRIPT="${STEP_DIR}/10A_approval_B_summary.sh" ;;
  14A) STEP_SCRIPT="${STEP_DIR}/14A_approval_C_summary.sh" ;;
  18A) STEP_SCRIPT="${STEP_DIR}/18A_approval_D_summary.sh" ;;
  19A) STEP_SCRIPT="${STEP_DIR}/19A_approval_E_summary.sh" ;;
  24A) STEP_SCRIPT="${STEP_DIR}/24A_approval_F_summary.sh" ;;
  99) STEP_SCRIPT="${STEP_DIR}/99_collect_failure_logs.sh" ;;
  *)
    echo "ERROR: unknown or unmapped step_id=${STEP_ID}" | tee -a "${LOG_FILE}"
    write_result "FAIL" 11
    exit 11
    ;;
esac

if [[ ! -x "${STEP_SCRIPT}" ]]; then
  echo "ERROR: step script not executable: ${STEP_SCRIPT}" | tee -a "${LOG_FILE}"
  write_result "FAIL" 12
  exit 12
fi

set +e
bash "${STEP_SCRIPT}" 2>&1 | tee -a "${LOG_FILE}"
RC=${PIPESTATUS[0]}
set -e

if [[ "${RC}" -eq 0 ]]; then
  write_result "PASS" 0
  touch "${DONE_FILE}"
  rm -f "${FAILED_FILE}"
  exit 0
else
  write_result "FAIL" "${RC}"
  touch "${FAILED_FILE}"
  exit "${RC}"
fi
```

#### AAP 回迁注意

【AAP回迁注意】迁移到 AAP 后，可以继续保留 `mock/check/real` 机制，但必须通过权限和 Survey 控制，避免生产用户误将高风险步骤开放给非授权人员。

---

### 31.7 AWX Project 适配

#### 原 AAP 设计

原设计：

```text
Project Name: DB_RU_Automation_Project
SCM Type: Git
SCM URL: 正式 Git 仓库
SCM Branch: main 或 release/19.30
```

#### 【AWX验证修改】

AWX 中建议：

```text
Project Name: DB_RU_AWX_Automation_Project
SCM Type: Git
SCM URL: 测试 Git 仓库或正式仓库测试分支
SCM Branch: dev/awx-test 或 feature/ru-runbook-awx
```

目录结构保持和 AAP 设计一致：

```text
playbooks/run_ru_step.yml
scripts/ru_step_runner.sh
scripts/steps/*.sh
scripts/checks/*.sh
inventory/db_ru_inventory.ini
```

#### AAP 回迁注意

【AAP回迁注意】回迁 AAP 时需要确认：

```text
1. Git URL 切换为正式仓库；
2. Branch 切换为 release 分支；
3. Project Sync Credential 重新配置；
4. Project Sync 日志无报错；
5. AAP 能识别同一个 playbook 路径。
```

---

### 31.8 AWX Inventory 适配

#### 原 AAP 设计

原设计：

```ini
[db_nodes]
cnzhjxd001dbadm01
cnzhjxd001dbadm02

[node1]
cnzhjxd001dbadm01

[node2]
cnzhjxd001dbadm02
```

#### 【AWX验证修改】

AWX 验证建议分两套 Inventory：

```text
DB_RU_AWX_MOCK_Inventory     # mock 主机或普通 Linux 测试主机
DB_RU_AWX_UAT_Inventory      # UAT RAC 主机
```

Mock Inventory 示例：

```ini
[db_nodes]
awx-test-node01
awx-test-node02

[node1]
awx-test-node01

[node2]
awx-test-node02
```

UAT Inventory 示例仍保持 RAC 结构：

```ini
[db_nodes]
cnzhjxd001dbadm01
cnzhjxd001dbadm02

[node1]
cnzhjxd001dbadm01

[node2]
cnzhjxd001dbadm02
```

#### AAP 回迁注意

【AAP回迁注意】回迁 AAP 时必须重新确认：

```text
1. node1/node2 是否与真实 RAC 节点对应；
2. Step 11/12 只在 node2；
3. Step 15/16 只在 node1；
4. Step 22/23/25/26 是否需要 db_nodes 全节点执行；
5. Limit Prompt 在 Workflow Node 里是否正确传递。
```

---

### 31.9 AWX Credential 适配

#### 原 AAP 设计

原设计保留三类 Credential：

```text
DB_RU_root_credential
DB_RU_grid_credential
DB_RU_oracle_credential
```

#### 【AWX验证修改】

AWX 中建议命名为：

```text
DB_RU_AWX_root_credential
DB_RU_AWX_grid_credential
DB_RU_AWX_oracle_credential
```

验证顺序：

```text
1. 先验证普通 SSH 登录；
2. 再验证 become/sudo；
3. 再验证 grid/oracle 用户环境变量；
4. 最后验证 srvctl/crsctl/sqlplus 是否可以执行。
```

必须避免：

```text
1. 在脚本中写 su - root；
2. 在脚本中写明文密码；
3. Workflow 运行时要求临时输入 SSH 密码；
4. AWX Credential 密钥导出后导入 AAP。
```

AWX Workflow 文档说明，如果 workflow 节点使用的 credential 需要运行时输入密码，该 credential 不适合在 workflow 节点创建时选择，因为节点创建时必须具备启动所需信息。

#### AAP 回迁注意

【AAP回迁注意】AAP 上必须重新创建 Credential，建议使用企业正式 SSH Key、sudoers、Vault 或 Secret Manager 机制，不能从 AWX 导出明文密钥。

---

### 31.10 AWX Job Template 适配

#### 原 AAP 设计

原设计 3~4 个通用 Job Template：

```text
DB_RU_RUN_ROOT
DB_RU_RUN_GRID
DB_RU_RUN_ORACLE
DB_RU_RUN_CHECK
```

#### 【AWX验证修改】

AWX 中建议创建对应测试版本：

```text
DB_RU_AWX_RUN_ROOT
DB_RU_AWX_RUN_GRID
DB_RU_AWX_RUN_ORACLE
DB_RU_AWX_RUN_CHECK
```

每个 Job Template 配置：

| 字段 | AWX 配置 |
|---|---|
| Project | `DB_RU_AWX_Automation_Project` |
| Inventory | `DB_RU_AWX_MOCK_Inventory` 或 `DB_RU_AWX_UAT_Inventory` |
| Playbook | `playbooks/run_ru_step.yml` |
| Credential | 对应 root/grid/oracle/check credential |
| Variables | 勾选 Prompt on Launch |
| Limit | 勾选 Prompt on Launch |
| Execution Environment | `DB_RU_AWX_EE` |

Extra Vars 示例：

```yaml
platform_mode: "awx_test"
ru_run_mode: "mock"
allow_destructive_step: false
change_id: "AWX-TEST-CHG0001"
ru_version: "19.30"
```

#### AAP 回迁注意

【AAP回迁注意】AAP 中可以恢复正式名称，也可以保留同一命名体系，但要重新确认：

```text
1. Project 是否指向正式 release 分支；
2. Inventory 是否切换为 AAP 正式 Inventory；
3. Credential 是否为 AAP 正式 Credential；
4. Execution Environment 是否为 AAP 认证/正式 EE；
5. Variables 和 Limit 的 Prompt on Launch 是否仍然启用。
```

---

### 31.11 AWX Workflow 适配

#### 原 AAP 设计

原设计是完整流程：

```text
27 个执行 Step
+ 6 个 Summary/Gate Step
+ 6 个 Approval Step
```

#### 【AWX验证补充】分阶段构建 Workflow

AWX 中不建议一开始就直接搭完整 39 个节点，而是分四阶段：

##### 阶段 1：Smoke Workflow

目标：验证 AWX 对象和 Approval 基础能力。

```text
Step 01 mock
-> Step 02 mock
-> Step 05A mock approval summary
-> Approval A
-> Step 06 mock
```

验证点：

```text
1. Project Sync 成功；
2. JT 可以执行；
3. step_id 可以传入；
4. Workflow 到 Approval A 会暂停；
5. Approve 后能继续；
6. Deny 后能停止或走失败分支。
```

##### 阶段 2：Full Mock Workflow

目标：验证完整拓扑。

```text
Step 01 -> ... -> Step 27
中间包含 Step 05A/10A/14A/18A/19A/24A
中间包含 Approval A/B/C/D/E/F
全部使用 ru_run_mode=mock
```

验证点：

```text
1. 27 个 step 的拓扑顺序正确；
2. 6 个 Summary 节点位置正确；
3. 6 个 Approval 节点位置正确；
4. 每个 Workflow Node 的 step_id 正确；
5. 每个 Workflow Node 的 Limit 正确；
6. On Success 连接正确；
7. On Failure 连接到 Step 99 或停止。
```

##### 阶段 3：Check-only Workflow

目标：验证非破坏性命令。

```text
ru_run_mode=check
allow_destructive_step=false
```

允许执行：

```text
hostname/date/whoami
crsctl status resource -t
srvctl status database/instance/service
sqlplus 只读查询
检查文件是否存在
检查目录是否存在
扫描日志
```

不允许执行：

```text
rm -rf
srvctl stop/start
switch home
datapatch
清理 switch_back 目录
```

##### 阶段 4：UAT Real Workflow

目标：在 UAT RAC 上跑完整真实 RU 流程。

```text
ru_run_mode=real
allow_destructive_step=true
```

前提：

```text
1. 已完成 Smoke / Full Mock / Check-only；
2. UAT RAC 可回退；
3. 变更窗口已确认；
4. 所有 Approval Summary 输出正确；
5. Step 99 失败日志收集可用。
```

#### AAP 回迁注意

【AAP回迁注意】迁移到 AAP 时，不迁移 Smoke Workflow。只迁移经过 Full Mock + Check-only + UAT Real 验证后的完整 Workflow 设计。

---

### 31.12 AWX Approval 验证适配

#### 原 AAP 设计

原设计包含：

```text
Step 05A -> Approval A
Step 10A -> Approval B
Step 14A -> Approval C
Step 18A -> Approval D
Step 19A -> Approval E
Step 24A -> Approval F
```

每个 Approval 前由 Summary/Gate 节点生成审批依据。

#### 【AWX验证补充】Approval 测试用例

AWX 中每个 Approval 至少测试以下场景：

| 测试场景 | 期望结果 |
|---|---|
| Summary PASS + Approve | 进入下一个 Step。 |
| Summary PASS + Deny | Workflow 停止或进入 Step 99。 |
| Summary FAIL | 不进入 Approval，Workflow 停止或进入 Step 99。 |
| Approval Timeout | Workflow 被标记失败或走 On Failure。 |
| 无审批权限用户登录 | 不能 Approve。 |
| 审批人只看 Job Output | 能根据 Summary 内容做出判断。 |

Approval A 的 AWX 验证示例：

```text
Step 04 mock precheck PASS
-> Step 05 mock backup PASS
-> Step 05A 生成 approval_A_summary.md
-> Approval A 暂停
-> 审批人查看 Step 05A Job Output
-> Approve
-> Step 06 继续执行
```

Step 05A Job Output 必须包含：

```text
1. Step 04 precheck = PASS
2. Step 05 backup = PASS
3. backup 目录存在 = YES
4. 日志 ERROR/FAILED/FATAL = 0
5. Gate decision = PASS
```

#### AAP 回迁注意

【AAP回迁注意】AAP 中需要重新配置审批权限，尤其确认：

```text
1. 谁能 Launch Workflow；
2. 谁能 Approve；
3. 审批人是否能看到 Summary Job Output；
4. 审批人是否不能修改 Project/JT/Workflow；
5. 拒绝审批后是否按设计停止或收集日志。
```

---

### 31.13 AWX Summary/Gate 验证适配

#### 原 AAP 设计

原设计要求每个 Approval 前都有 Summary/Gate 节点，且 Summary 节点读取：

```text
state/*.result.json
logs/*.log
reports/*.md
```

#### 【AWX验证补充】

AWX 初期可以先构造 mock result.json 验证 Summary 脚本逻辑。

示例：

```json
{
  "step_id": "04",
  "step_name": "precheck",
  "status": "PASS",
  "return_code": 0,
  "mode": "mock",
  "platform": "awx_test",
  "host": "awx-test-node01"
}
```

Summary/Gate 节点必须满足：

```text
1. 硬性条件失败时 exit 1；
2. 硬性条件通过时 exit 0；
3. 输出审批摘要到 AAP/AWX Job Output；
4. 输出 report 文件到 reports/approval_*.md；
5. 不要求审批人到服务器上手工查日志。
```

#### AAP 回迁注意

【AAP回迁注意】AAP 生产中必须确认 reports 目录纳入日志留存策略，至少保留到变更审计周期结束。

---

### 31.14 AWX 失败分支验证

#### 原 AAP 设计

原设计建议增加：

```text
Step 99 collect_failure_logs
```

用于失败后收集日志，不建议第一版做自动回滚。

#### 【AWX验证补充】

AWX 中必须构造失败场景验证 Step 99：

| 失败场景 | 构造方式 | 期望结果 |
|---|---|---|
| Step 04 precheck fail | mock 返回非 0 | 进入 Step 99 或停止。 |
| Step 05A Summary fail | 删除 step_05.result.json | 不进入 Approval A。 |
| Approval A deny | 人工点击 Deny | 进入 On Failure 或停止。 |
| Step 12 destructive blocked | `ru_run_mode=check` 执行 Step 12 | 返回 rc=20，阻止执行。 |
| Step 20 datapatch blocked | `allow_destructive_step=false` | 返回 rc=20，阻止执行。 |

#### AAP 回迁注意

【AAP回迁注意】生产中 Step 99 应至少收集：

```text
1. 当前 step 日志；
2. state/*.json；
3. reports/*.md；
4. crsctl/srvctl 状态；
5. alert log 关键片段；
6. datapatch 日志路径；
7. 当前 Workflow Job ID / Change ID。
```

---

### 31.15 AWX Execution Environment 验证

#### 原 AAP 设计

原设计默认在 AAP 中配置生产可用 Execution Environment。

#### 【AWX验证补充】

AWX 中建议使用尽量贴近 AAP 的 EE：

```text
DB_RU_AWX_EE
```

需要记录：

```text
AWX Version:
Ansible Core Version:
Execution Environment Image:
Python Version:
awx.awx Collection Version:
ansible.builtin Module Availability:
Shell/Perl/JQ Availability:
```

最低验证命令：

```bash
ansible --version
python3 --version
which bash
which perl
which jq || true
ansible-galaxy collection list | grep -E 'awx.awx|ansible.posix|community.general'
```

#### AAP 回迁注意

【AAP回迁注意】AAP 上要使用正式 EE，并重新验证：

```text
1. ansible-core 版本；
2. 需要的 collection；
3. 目标主机 SSH 行为；
4. stdout 日志显示是否一致；
5. set_stats/artifacts 传递是否一致。
```

---

### 31.16 AWX 对象迁移策略

#### 原 AAP 设计

原设计允许先通过 UI 手工创建 AAP 对象，后续再配置即代码化。

#### 【AWX验证补充】

AWX 验证完成后，建议输出一份对象清单：

```text
1. Project 清单
2. Inventory 清单
3. Credential 名称清单，不含密钥
4. Job Template 清单
5. Workflow Node 清单
6. 每个 Node 的 step_id / limit / JT / edge type
7. Approval 节点清单
8. Survey 和 Extra Vars 清单
```

可以选择两种迁移方式：

```text
方式一：AAP UI 中按清单重建
方式二：用配置即代码方式重建
```

如使用配置即代码：

```text
AWX 验证阶段可以使用 awx.awx collection；
AAP 生产阶段建议使用 Red Hat 支持的 controller/infra 配置方式或企业批准的配置即代码方式。
```

AWX 的 `awx.awx.workflow_job_template` 和 `awx.awx.workflow_job_template_node` 模块可以用于创建 Workflow 和 Workflow Node。  
参考：

- `https://docs.ansible.com/projects/ansible/latest/collections/awx/awx/workflow_job_template_module.html`
- `https://docs.ansible.com/projects/ansible/latest/collections/awx/awx/workflow_job_template_node_module.html`

#### AAP 回迁注意

【AAP回迁注意】不建议进行以下操作：

```text
1. 不建议从 AWX 数据库直接迁移到 AAP；
2. 不建议导出 AWX Credential 明文；
3. 不建议把 AWX 测试 Workflow 原样作为生产 Workflow；
4. 不建议跳过 AAP UAT 复测。
```

---

### 31.17 AWX 验证清单

| 验证项 | 是否必须 | 通过标准 |
|---|---:|---|
| Project Sync | 必须 | Git 拉取成功，能识别 `playbooks/run_ru_step.yml`。 |
| Inventory 分组 | 必须 | `node1/node2/db_nodes` 正确。 |
| Credential | 必须 | root/grid/oracle 三类用户能按预期执行。 |
| JT Prompt Variables | 必须 | 每个节点可传不同 `step_id`。 |
| JT Prompt Limit | 必须 | 每个节点可限制到 `node1/node2/db_nodes`。 |
| Smoke Workflow | 必须 | Approval A 可暂停、批准、拒绝。 |
| Full Mock Workflow | 必须 | 27 step + 6 Summary + 6 Approval 全部跑通。 |
| Check-only Workflow | 必须 | 只读检查正常，高风险步骤被阻止。 |
| UAT Real Workflow | 必须 | 测试 RAC 上完整升级成功。 |
| Summary/Gate | 必须 | 输出清晰审批摘要，失败时中断。 |
| Approval 权限 | 必须 | 只有授权用户能 Approve。 |
| Step 99 | 建议 | 能收集失败日志。 |
| Notifications | 可选 | 可通知变更群组或审批人。 |
| AAP UAT 复测 | 必须 | 迁移到 AAP 后完整复现。 |

---

### 31.18 AAP 回迁检查清单

AWX 验证完成后，迁移到 AAP 前必须完成以下检查：

| 检查项 | 要求 |
|---|---|
| AWX 测试报告 | 已完成 Smoke、Full Mock、Check-only、UAT Real 记录。 |
| AAP 版本记录 | 记录 AAP/Controller/Ansible Core/EE/Collections 版本。 |
| Git 分支 | 从 `dev/awx-test` 切换到正式 release 分支。 |
| Project | AAP Project Sync 成功。 |
| Inventory | 生产或 UAT RAC 节点分组正确。 |
| Credential | AAP 重新创建，不复用 AWX 密钥。 |
| Job Template | 3~4 个通用 JT 已创建，Prompt on Launch 已启用。 |
| Workflow | 27 Step + 6 Summary + 6 Approval 已重建。 |
| Approval 权限 | 审批人权限已测试。 |
| Execution Environment | 与 AWX 测试 EE 差异已确认。 |
| 并发控制 | 同一 RAC 不允许同时运行两个 RU Workflow。 |
| 失败分支 | Step 99 或人工接管流程已验证。 |
| 清理前审批 | Approval F 必须保留，不允许跳过。 |
| 高风险变量 | `allow_destructive_step` 不能被普通用户随意修改。 |
| AAP UAT | AAP 上至少完整跑一轮测试 RAC。 |

---

### 31.19 最终建议

针对 AWX 验证，本方案建议采用以下推进方式：

```text
1. 在 AWX 中创建测试 Project、Inventory、Credential、JT、Workflow；
2. 使用 ru_run_mode=mock 跑 Smoke Workflow；
3. 使用 ru_run_mode=mock 跑 Full Mock Workflow；
4. 使用 ru_run_mode=check 跑只读检查；
5. 在 UAT RAC 上使用 ru_run_mode=real 跑完整 27 step；
6. 输出 AWX 验证报告和对象清单；
7. 在 AAP 中按清单重建正式对象；
8. 在 AAP UAT 中复测完整流程；
9. 通过变更审批后再进入生产。
```

核心原则保持不变：

```text
AWX 负责验证流程和脚本可行性；
AAP 负责生产运行、权限控制、审计和正式变更执行。
```

