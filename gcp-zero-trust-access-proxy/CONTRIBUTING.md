# Contributing

This project is a student portfolio demonstration of Zero Trust Network Access on Google Cloud. Contributions are welcome, especially documentation improvements, test coverage, and cost optimizations.

## How to contribute

1. Fork the repository and create a feature branch:
   ```bash
   git checkout -b feat/your-feature-name
   ```
2. Make changes with clear commit messages.
3. Run local checks:
   ```bash
   terraform fmt -check
   terraform validate
   shellcheck src/scripts/*.sh
   ```
4. Open a Pull Request against `main`. Describe what changed and why.

## Code standards

- Terraform: `terraform fmt` enforced by CI.
- Shell scripts: `set -euo pipefail`, ShellCheck clean.
- No secrets in code. Use `terraform.tfvars.example` and `.env.example` as templates.
- `confidential/` and `keys/` are intentionally gitignored. Do not commit credentials.

## Reporting issues

Open an issue with:
- Expected vs actual behavior
- Terraform plan output or logs
- GCP region and VM state

## License

This project is released under CC0 1.0 Universal. See LICENSE.
