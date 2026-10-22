variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "zone_name" {
  description = "Managed zone resource name"
  type        = string
}

variable "dns_name" {
  description = "FQDN for the zone, with trailing dot (e.g. dr-demo.example.com.)"
  type        = string
}

variable "primary_ip" {
  description = "Static IP of the primary VM (backs the primary A record)"
  type        = string
}

variable "public_record_name" {
  description = <<-EOT
    Public FQDN (with trailing dot) of the record the failover function
    rewrites. It MUST be below the zone apex: a CNAME cannot live at the
    apex (RFC 1912 §2.3.2), and Cloud DNS rejects it with
    "recordTypeDisallowedAtZoneApex". For a zone "dr-demo.example.com."
    the public name is "www.dr-demo.example.com.".
  EOT
  type        = string
  default     = "www.dr-demo.example.com."
}

variable "primary_target_name" {
  description = <<-EOT
    Hostname (with trailing dot) whose A record points at the primary VM
    — the "healthy" CNAME target. Keeping this a NAME (rather than
    putting the IP straight in the public record) means the failover
    function only ever swaps one CNAME value, and Terraform keeps
    ownership of the IP mapping.
  EOT
  type        = string
  default     = "primary.dr-demo.example.com."
}

variable "dr_target" {
  description = <<-EOT
    Hostname of the DR standby — the Cloud Run service's *.a.run.app name.
    The failover function points the public CNAME at this while an
    incident is open. Empty means no automatic flip target exists: the
    function logs FAILOVER_TARGET_MISSING on an incident instead of
    rewriting the record blindly.
  EOT
  type        = string
  default     = ""
}

variable "dr_health_url" {
  description = <<-EOT
    URL probed BEFORE the record is repointed at the standby. If the
    standby does not answer, the function refuses to fail over (and says
    so) — failing over into an unreachable standby is worse than staying
    on a degraded primary. Empty disables the probe.
  EOT
  type        = string
  default     = ""
}

variable "dns_failover_role_id" {
  description = <<-EOT
    Fully-qualified id of the custom project role that grants the failover
    function record-set write access, e.g.
    "projects/<project_id>/roles/drFailoverDnsAdmin".

    WHY A CUSTOM ROLE:
    - `roles/dns.resourceRecordsAdmin` does not exist on GCP; the IAM API
      404s it and Cloud DNS silently drops the binding.
    - Zone-level IAM does not work on this account (dns/v2 setIamPolicy
      returns HTTP 500; dns/v1 stores an empty policy).
    - `roles/dns.admin` works at project level but also grants zone
      create/delete and IAM mutation — too much blast radius.

    Create it once with:
      gcloud iam roles create drFailoverDnsAdmin --project=<project_id> \
        --title="DR DNS Failover Admin" \
        --permissions=dns.resourceRecordSets.create,dns.resourceRecordSets.delete,dns.resourceRecordSets.get,dns.resourceRecordSets.list,dns.resourceRecordSets.update,dns.changes.create,dns.changes.get,dns.changes.list,dns.managedZones.get,dns.managedZones.list
  EOT
  type        = string
  default     = ""
}

variable "record_ttl" {
  description = "TTL (seconds) of the records — the stale-cache window during a flip"
  type        = number
  default     = 300

  validation {
    condition     = var.record_ttl >= 60 && var.record_ttl <= 86400
    error_message = "record_ttl must be between 60 and 86400 seconds."
  }
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "region" {
  description = "Region for the failover Cloud Function and its source bucket"
  type        = string
}

variable "function_source_dir" {
  description = "Path to src/functions/dns-failover (zipped by archive_file)"
  type        = string
}

variable "labels" {
  description = "Labels applied to all labelable resources"
  type        = map(string)
}
