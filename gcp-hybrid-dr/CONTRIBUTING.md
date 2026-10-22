# Contributing

This project is a student portfolio demonstration of hybrid cloud
disaster recovery on Google Cloud. Contributions are welcome, especially
documentation improvements, test coverage, and cost optimisations.

## How to contribute

1. Fork the repository and create a feature branch:
   ```bash
   git checkout -b feat/your-feature-name
   ```
2. Make changes with clear commit messages.
3. Run local checks (all of these are what CI runs):
   ```bash
   terraform fmt -check -recursive
   terraform validate
   shellcheck src/scripts/*.sh
   ruff check src/ tests/
   pytest tests/ -v
   ```
4. Open a Pull Request against `main`. Describe what changed and why.

## Code standards

- Terraform: `terraform fmt` enforced by CI. `terraform plan` on a
  freshly applied project must report **no changes** — a plan that
  always shows a diff is a plan nobody can trust.
- Shell scripts: `set -euo pipefail`, ShellCheck clean.
- Python: ruff clean. Every Cloud Function logs a single-line JSON
  object to stdout — the alert policies match on
  `jsonPayload.message`, so the message text is a contract.
- No secrets in code. Use `terraform/terraform.tfvars.example` as a
  template; `terraform.tfvars` is gitignored.

## Things that have bitten this project

Read `docs/05-troubleshooting.md` before changing the infrastructure —
every entry is a problem that was actually hit. The ones worth knowing
up front:

- **`gcloud storage cp` reads the destination before writing it.** Under
  the write-only `objectCreator` binding the upload fails with a 403.
  The backup uploads through the JSON API's `uploadType=media` instead,
  which creates without reading. Do not "fix" that by granting the
  read — it would break the security model the whole project rests on.
- **`roles/dns.resourceRecordsAdmin` does not exist on GCP.** The IAM
  API 404s it and Cloud DNS silently stores an empty policy. The
  project uses a custom `drFailoverDnsAdmin` role instead.
- **Rotating a KMS key does not retire the old version.** It stays
  ENABLED and stays billed, forever. The monthly
  `key-version-retirement` function exists to fix that.
- **A key version is retired by SUPERSESSION time, not create time.**
  Destroying a version still encrypting live backups makes them
  permanently unreadable.

## Reporting issues

Open an issue with:

- Expected vs actual behaviour
- Terraform plan output or logs
- GCP project and VM state

## License

This project is released under CC0 1.0 Universal. See LICENSE.
