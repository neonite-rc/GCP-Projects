# ---------------------------------------------------------------------------
# Import blocks — resources Terraform adopts rather than creates.
#
# IMPORTANT: import blocks are ONLY allowed in the root module. A block
# inside a child module fails `terraform init` with:
#
#   "An import block was detected in \"module.primary\". Import blocks are
#    only allowed in the root module."
#
# Each entry below takes over a resource that GCP creates by itself, so
# Terraform manages it from then on. Without the import, the first apply
# fails with "already exists" — the rule is already there, Terraform
# just cannot own it yet.
#
# These are no-ops once the resource is in state.
# ---------------------------------------------------------------------------

# GCP creates `default-allow-ssh` with every CUSTOM-mode VPC, allowing
# tcp:22 from 0.0.0.0/0 to every instance. That defeats the
# admin-IP-only SSH rule, so the project takes it over and disables it.
# See modules/primary-site/main.tf.
import {
  # The rule lives in the global scope, so the import id is just its name.
  to = module.primary.google_compute_firewall.disable_default_ssh
  id = "default-allow-ssh"
}

# Same story, one port over: tcp:3389 from 0.0.0.0/0. Nothing on the
# Debian 12 VM listens on 3389, but the rule is a latent exposure and
# disabling SSH while leaving RDP open is the kind of half-finished
# hardening a review is designed to catch.
import {
  to = module.primary.google_compute_firewall.disable_default_rdp
  id = "default-allow-rdp"
}
