# SLURM Manager (Modular)

This project provides a robust, modular Bash-based SLURM resource manager for controller host operations.

It supports:
- `add`: add host entries and assign to partitions
- `remove` / `delete`: remove host entries and partition membership
- `move`: move hosts from one controller to another
- automatic backup, controlled apply-to-source, restart, and rollback on restart failure

## Project Layout

- `main.sh` - main orchestrator with CLI/help
- `config/slurm_manager.conf` - reusable config for path/controller setup
- `lib/common.sh` - shared logging/config/runtime utilities
- `scripts/op_add.sh` - add operation module
- `scripts/op_remove.sh` - remove operation module
- `scripts/op_move.sh` - move operation module
- `scripts/copy_to_source.sh` - copy changed files to true source directories
- `scripts/revert_on_failure.sh` - rollback module for failed restart
- `scripts/restart_controllers.sh` - restart module with post-restart validation

## Requirements

- Bash 4+
- Linux host with `systemctl` (restart/rollback steps)
- Read/write access to:
  - `SLURM_BASE_DIR` (example: `/etc/slurm1`, `/etc/slurm2`)
  - backup directory configured in `BACKUP_BASE_DIR`
- Optional tools:
  - `md5sum` or `md5` (checksum compare; script auto-falls back)

## Configuration

Edit `config/slurm_manager.conf`:

- `SLURM_BASE_DIR` - live source base (for example `/etc`)
- `CONTROLLER_PREFIX` - default `slurm`
- `MAX_CONTROLLERS` - how many controller dirs to manage
- `DEFAULT_INPUT_FILE` - default input filename
- `BACKUP_BASE_DIR` / `LOG_DIR` - run artifacts
- `RESTART_STABILIZE_SECONDS` - post-restart health wait
- `ENABLE_ANSIBLE_SYNC` and `ANSIBLE_TARGET_BASE` - optional sync
- `AUTO_APPROVE` - optional no-prompt apply

## Usage

```bash
./main.sh <operation> [options]
```

Operations:
- `add`
- `remove` (`delete` is alias)
- `move`

Options:
- `--input-file <path>`
- `--config <path>`
- `--yes`
- `--dry-run`
- `-h, --help`

### Examples

```bash
./main.sh add --input-file input_add.txt
./main.sh remove --input-file input_remove.txt
./main.sh move --input-file input_move.txt
./main.sh add --config ./config/slurm_manager.conf --yes
```

## Input File Formats

### add/remove

```text
<controller> <partition_names|all> <full NodeName/NodeAddr host config line>
```

Example:

```text
slurm1 compute NodeName=node-101 NodeAddr=10.0.0.101 Gres=gpu:2 State=UNKNOWN
slurm2 all NodeName=node-202 NodeAddr=10.0.0.202 State=UNKNOWN
```

### move

```text
NodeName=<hostname> NodeAddr=<ip> <source_controller> <target_controller>
```

Example:

```text
NodeName=node-101 NodeAddr=10.0.0.101 slurm1 slurm3
```

## Safety Behavior

1. Creates dual backup for every run:
   - original snapshot
   - working copy for edits
2. Runs operation logic on working copy only
3. Asks confirmation before touching source (unless `--yes` or `AUTO_APPROVE=true`)
4. Copies only changed files to source
5. Restarts only controllers that changed
6. On restart failure, restores controller from original backup


