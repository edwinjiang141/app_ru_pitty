# DB RU step scripts

These scripts are executed by `ru_step_runner.sh` on the target RAC/DB hosts.

Mapping rule:

```text
Workflow Node Extra Vars step_id: "01"
  -> run_ru_step.yml
  -> ru_step_runner.sh --step-id "01"
  -> automation/steps/step_01.sh on the target host
```

Approval nodes do not execute a shell script. Summary/Gate nodes do, for example
`step_id: "05A"` maps to `step_05A.sh` when that summary script is deployed.

The scripts support three modes through `RUN_MODE`:

- `mock`: no real DB/RAC change, safe for AWX workflow wiring tests.
- `check`: non-destructive checks only.
- `real`: executes the site-specific command variables and fails if required
  variables are missing.

Destructive steps require `ALLOW_DESTRUCTIVE_STEP=true` in real mode.



## `run_ru_step.yml`, `ru_step_runner.sh`, and `ru_common.sh`

They are cooperative layers, not replacements for each other:

1. `playbooks/run_ru_step.yml` runs inside AWX Execution Environment and uses
   Ansible SSH to reach the external DB/RAC target host.
2. `/u01/patch1930/ru_automation/bin/ru_step_runner.sh` runs on the target host.
   It reads optional `conf/ru_env.conf`, applies non-empty AWX arguments, exports
   the final environment, maps `STEP_ID` to `steps/step_<id>.sh`, and records the
   per-step result.
3. `automation/lib/ru_common.sh` is sourced by each `step_*.sh`. It provides
   common logging, failure handling, mode validation, destructive-step checks,
   file/path checks, and Perl `ru_script` invocation helpers.

Therefore `ru_common.sh` does not replace `ru_step_runner.sh`; the runner chooses
which step to execute, and `ru_common.sh` standardizes how that selected step
behaves.

## Environment variables and `ru_env.example.conf`

`automation/conf/ru_env.example.conf` is only a sample/template. In the
production workflow, copy it to the AWX Manual Project as `conf/ru_env.conf`,
edit it on the AWX/k3s side before each RU change window, and run
`DB_RU_AWX_APPLY_ENV_CONF` to distribute it to target hosts.
production workflow, copy it to the target host as
`/u01/patch1930/ru_automation/conf/ru_env.conf` and edit it before each RU
change window.

Recommended AWX usage:

1. Keep fixed workflow-node values in AWX Workflow Node Extra Vars:
   `step_id`, `step_name`, `ru_run_mode`, `allow_destructive_step`, and
   `approval_report_required`. These identify the node and should not change for
   every RU change.
2. Keep change-specific values in the AWX Project `conf/ru_env.conf`: `CHANGE_ID`,
   backup paths, RU versioned paths, package paths, Oracle/Grid links, and site
   command variables. The apply job installs that file onto the target hosts, so
   operators can edit it before the change without modifying AWX Job Template
   definitions or logging into target hosts.
2. Keep change-specific values in target-host `ru_env.conf`: `CHANGE_ID`, backup
   paths, RU versioned paths, package paths, Oracle/Grid links, and site command
   variables. Operators can edit this file before the change without modifying
   AWX Job Template definitions.
3. `ru_step_runner.sh` sources `ru_env.conf` first, then applies non-empty AWX
   CLI arguments from `run_ru_step.yml`. Therefore AWX fixed node values override
   accidental values in `ru_env.conf`, while empty optional AWX values do not wipe
   out change-specific values from the file.
## Environment variables and `ru_env.example.conf`

`automation/conf/ru_env.example.conf` is only a sample/template. It is useful
when many step variables are stable across runs, but it is not mandatory.

Recommended AWX test usage:

1. Put per-run values such as `step_id`, `ru_run_mode`, `change_id`, and
   `allow_destructive_step` in AWX Workflow/Job Template Extra Vars.
2. Put stable target-host values in either AWX Extra Vars or an edited target
   file named `/u01/patch1930/ru_automation/conf/ru_env.conf`.
3. If using the target-host `ru_env.conf`, source it in `ru_step_runner.sh`
   before the selected `step_*.sh` is executed.
4. Never store passwords in `ru_env.conf`; AWX Machine Credentials should carry
   SSH/sudo authentication.

A typical target-host usage pattern is:

```bash
cp automation/conf/ru_env.example.conf /root/db_ru_awx_test/project/conf/ru_env.conf
vi /root/db_ru_awx_test/project/conf/ru_env.conf
# Then run AWX Job Template DB_RU_AWX_APPLY_ENV_CONF to install it as:
# /u01/patch1930/ru_automation/conf/ru_env.conf on every selected target host.
```


## Applying `ru_env.conf` through AWX

Before each RU change, operators should edit `conf/ru_env.conf` on the AWX/k3s
side and run the AWX Job Template that uses `playbooks/apply_ru_env_conf.yml`.
That job copies the file to every selected target host as
`/u01/patch1930/ru_automation/conf/ru_env.conf` and validates it with
`bash -n`.

Recommended workflow order:

1. `DB_RU_AWX_APPLY_ENV_CONF` (`playbooks/apply_ru_env_conf.yml`) runs on all
   DB/RAC target hosts.
2. Step 00/01 and the rest of the DB RU workflow run through
   `playbooks/run_ru_step.yml` and `bin/ru_step_runner.sh`.

This keeps operators from logging into target hosts directly while still
allowing each change window to use a freshly reviewed env file.

cp automation/conf/ru_env.example.conf /u01/patch1930/ru_automation/conf/ru_env.conf
vi /u01/patch1930/ru_automation/conf/ru_env.conf
# ru_step_runner.sh: source /u01/patch1930/ru_automation/conf/ru_env.conf before running a step
```

## ru_script directory

`ru_play.txt` references Perl-based RU helper scripts. In this project they are
expected on each target host under:

```text
/u01/patch1930/ru_automation/packages/ru_script
```

The directory should contain files such as `Comments.pm`, `ru_patch_number.ini`,
`upgrade_ru_with_gold_image`, and `upgrade_ru_with_opatch`. Step 02 stages and
validates this directory; node home-switch steps can call these scripts through
`perl` when an explicit site command variable is not supplied.
