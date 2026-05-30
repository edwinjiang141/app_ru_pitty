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
