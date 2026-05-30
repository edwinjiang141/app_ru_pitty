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
