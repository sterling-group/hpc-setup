# HPC Setup

*Author: Markus G. S. Weiss*  

Welcome to the **HPC Setup** repository! This comprehensive collection provides everything you need to configure and manage High‑Performance Computing (HPC) clusters, including:

- **Step-by-step guides** for cluster configuration and access
- **Automation scripts** for environment setup and backups
- **Job submission tools** for computational workflows

## Contents

### [Guides](guides/)
- [SSH Key Generation and Cluster Access Guide](guides/ssh-key-guide/README.md)
- [IQmol Setup Guide](guides/iqmol-guide/README.md)
- [Rclone Backup to Box Guide](guides/rclone-backup-guide/README.md)

### [Scripts](scripts/)
- `setup.sh` - HPC environment configuration script
- `environment` - Sterling Group environment setup
- `backup.sh` - Automated backup system for cluster data
- `crontab-backup` - Cron configuration for automated backups

### [Tools](tools/)
- [qorca](tools/qorca/) - ORCA job submission scripts
- [qqchem](tools/qqchem/) - Q-Chem job submission scripts

## Guides

### [SSH Key Generation and Cluster Access Guide](guides/ssh-key-guide/README.md)

Learn how to generate SSH keys, add your private key to an SSH agent, and copy your public key to the HPC cluster for secure, password‑less authentication.

### [IQmol Setup Guide](guides/iqmol-guide/README.md)

Follow this guide to configure IQmol to connect to the HPC cluster and submit computational jobs efficiently.

### [Rclone Backup to Box Guide](guides/rclone-backup-guide/README.md)

Configure and schedule automatic, incremental backups of your home directory to Box using rclone and cron. Includes offline authorization for SSO, directory setup, dry‑run testing, logs, snapshots, and maintenance tips.

## Scripts

Automation scripts for HPC environment setup and maintenance:

- **`setup.sh`** - Inserts shell configuration block that sources the Sterling Group environment file
- **`environment`** - Sterling Group environment configuration with conda management and cluster-specific settings
- **`backup.sh`** - Comprehensive backup solution with daily incremental backups, weekly snapshots, and log management
- **`crontab-backup`** - Ready-to-use cron configuration for automated backup scheduling

## Tools

External tools integrated as git submodules for job submission and workflow management:

- **[qorca](https://github.com/Markus-G-S-Weiss/qorca)** - ORCA quantum chemistry job submission scripts
- **[qqchem](https://github.com/Markus-G-S-Weiss/qqchem)** - General quantum chemistry job submission tools

## Quick Start

1. **Clone the repository** (with submodules):
   ```bash
   git clone --recursive https://github.com/sterling-group/hpc-setup.git
   ```

2. **Set up your environment**:
   ```bash
   cd hpc-setup
   ./scripts/setup.sh
   ```

3. **Configure backups** (optional):
   ```bash
   # Follow the rclone backup guide
   crontab scripts/crontab-backup
   ```

## Contributing

Contributions are welcome! Whether you want to:
- Improve existing guides or scripts
- Add new HPC tools or configurations
- Fix bugs or enhance documentation
- Suggest new features

Please feel free to submit a pull request or open an issue.

## License

This project is licensed under the [LICENSE](LICENSE) specified in this repository.

---