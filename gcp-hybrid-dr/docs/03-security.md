# Security: Hybrid Cloud Disaster Recovery

## Security Architecture

### 1. IAM — Least Privilege, Write-Only Backup

| Principal | Role | Scope | Justification |
|-----------|------|-------|---------------|
| Primary VM SA | `roles/storage.objectCreator` | backup bucket (bucket-level) | Write-only: can create new backups, cannot list/read/delete existing ones |
| Freshness function SA | `roles/storage.objectViewer` | backup bucket (bucket-level) | Read-only: lists backups to check age |
| Restore-drill function SA | `roles/storage.objectViewer` | backup bucket (bucket-level) | Read-only: downloads and verifies the newest backup |
| DNS failover function SA | `projects/<project>/roles/drFailoverDnsAdmin` (custom) | project-level, record sets only | Read/write record sets + submit changes. Cannot create/delete zones, cannot touch IAM, cannot leave the project |
| GCS service agent | `roles/cloudkms.cryptoKeyEncrypterDecrypter` | backup + replica KMS keys | Server-side encryption/decryption (NOT the uploader) |
| STS service agent | `roles/storage.objectViewer` + `roles/storage.legacyBucketReader` | backup bucket | Reads objects for cross-region replication |
| STS service agent | `roles/storage.legacyBucketWriter` | replica bucket | Writes replicated objects |
| Monitoring notification agent | `roles/pubsub.publisher` | failover topic | Publishes alert payloads to the failover function |

**No project-level IAM bindings** for any *runtime* service account other
than the DNS failover function, which needs a project-scoped custom role
because zone-level Cloud DNS IAM does not work reliably (see
[docs/05-troubleshooting.md](05-troubleshooting.md) Issue 3).

### 2. Why the Custom DNS Role Exists

`roles/dns.resourceRecordsAdmin` — the obvious choice — **does not exist
on GCP**. The IAM API returns 404 for it, and Cloud DNS's `setIamPolicy`
accepts the binding and then silently stores an empty policy. The result
is a function that looks correctly permissioned and can do nothing at
all.

`roles/dns.admin` does work, but it also grants zone create/delete and
IAM policy mutation — a far larger blast radius than a failover function
needs.

So the project defines a custom role with exactly the permissions the
function uses:

```
dns.resourceRecordSets.{create,delete,get,list,update}
dns.changes.{create,get,list}
dns.managedZones.{get,list}
```

Verified by impersonating the service account: it can list record sets
and submit a change, and nothing else.

### 3. Backup Integrity Chain

| Step | Mechanism | What It Protects |
|------|-----------|-----------------|
| SQLite online backup | Consistent snapshot without stopping app | No corruption from concurrent writes |
| PRAGMA integrity_check | Verifies snapshot BEFORE shipping | Corrupt backup discovered at backup time, not during disaster |
| gzip -9 | Compression | Cost optimization (smaller backup = less storage) |
| sha256sum manifest | Checksum of compressed artifact | Detects tampering or corruption in transit |
| JSON API upload + `x-goog-hash: crc32c` | CRC32C validated upload | Detects network corruption during upload |
| Post-restore integrity_check | Verifies restored backup | Full chain: backup → ship → restore → verify |

### 4. Why the Upload Is Not `gcloud storage cp`

`gcloud storage cp` reads the destination object before writing it, to
decide whether to overwrite. The primary VM's SA is write-only by
design, so that read is denied and the upload fails with HTTP 403.

Granting the read would mean the compromised-primary scenario could read
(and potentially tamper with) its own recovery path — the single
property the whole design rests on.

The backup therefore uploads through the Cloud Storage JSON API's
`uploadType=media` endpoint, which creates the object without reading
the destination. `x-goog-hash: crc32c=...` preserves the in-transit
integrity check, so GCS still rejects a corrupted upload with HTTP 400.

**The write-only guarantee holds end to end: upload → replicate →
restore → verify, and the primary VM can do none of the read steps.**

### 5. Network Security

- **SSH: admin-IP-only** — firewall rule allows TCP 22 only from
  `admin_ip_cidr`
- **The GCP default SSH rule is disabled** — `default-allow-ssh` allows
  TCP 22 from `0.0.0.0/0` to every instance in a custom-mode VPC. It is
  imported into Terraform and set to `disabled = true`. Without this the
  "SSH is admin-IP-only" claim is false.
- **HTTP: public** — the primary IS the website; health checks arrive
  from Google ranges
- **No HTTPS on the primary** — no TLS certificate without a registered
  domain (documented)
- **Deny-all ingress** — explicit deny rule at lowest priority logs
  blocked attempts
- **OS Login disabled** — single provisioned key + `block-project-ssh-keys`
  = smaller trust surface

**Verified live:** the deny-all rule does fire and its events are
queryable by rule reference:

```
$ gcloud logging read 'jsonPayload.rule_details.reference:"dr-demo-primary-vpc-deny-all-ingress"' \
    --project gcp-hybrid-dr --limit=3
2026-10-21T19:26:28Z  network:dr-demo-primary-vpc/firewall:dr-demo-primary-vpc-deny-all-ingress
2026-10-21T19:26:27Z  network:dr-demo-primary-vpc/firewall:dr-demo-primary-vpc-deny-all-ingress
2026-10-21T19:26:25Z  network:dr-demo-primary-vpc/firewall:dr-demo-primary-vpc-deny-all-ingress
```

> **Known limitation, measured:** the log *sink* that exports those
> events to Cloud Storage does not deliver anything on this billing
> account. It is not a filter problem — the sink's filter was verified
> to match live entries, and a scratch sink with **no filter at all**,
> pointing at a freshly created bucket, also produced zero objects. The
> Cloud Logging → Cloud Storage export path is therefore not functional
> on this account.
>
> The firewall events are still generated, still retained in Cloud
> Logging (where the free tier covers them), and still queryable with
> the filter above — which is what the sink was for. The Terraform
> resource is kept because it is correct and works elsewhere; the
> *export* is what this account cannot do.

### 6. VM Hardening

- Password authentication: disabled
- Root login: disabled
- OS Login: disabled (project SSH keys blocked)
- Shielded VM: Secure Boot + vTPM + Integrity Monitoring
- Dedicated SA (no default Compute Engine Editor)
- `NoNewPrivileges=true` in systemd service
- `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`

### 7. CMEK Encryption

- **Two key rings** — one per region (KMS keys must be in the same
  location as the bucket)
- **90-day rotation** — `rotation_period = 7776000s`
- **GCS service agent** — performs server-side encryption (NOT the
  uploader)
- **Superseded key versions are retired automatically** — a monthly
  sweep destroys versions that are no longer primary and are older than
  the backup retention window. Without it, rotated versions are never
  disabled and stay billed forever (measured — see
  [06-measurements.md §11](06-measurements.md)). The retention window is
  a hard floor: destroying a key version makes the data it encrypted
  unreadable.
- **Keys never deleted** — KMS key rings/keys are immortal by GCP design

### 8. Failover Safety Rules

The failover function is the only component that can break DNS for
everyone. Three rules keep it from causing an outage of its own:

1. **No DR target → refuse to act.** The function logs
   `FAILOVER_TARGET_MISSING` and leaves the record alone. Pointing the
   only public record at nothing would turn a partial outage into a
   total one.
2. **Unhealthy standby → refuse to fail over.** The standby's `/health`
   endpoint is probed *before* the record is repointed. If it does not
   answer, the function logs `FAILOVER_ABORTED` and stays on the
   primary. Failing over into an unreachable standby is strictly worse
   than staying on a degraded primary.
3. **Wrong record type → refuse to act.** The record is a **CNAME**
   whose two targets are hostnames (`primary.<zone>` and
   `<standby>.a.run.app`). The type never changes, so there is no
   A↔CNAME conflict window in which the name has no usable record, and
   the target can never go stale — Google's Cloud Run front-end IPs
   rotate, so an A record pinned to last month's IPs is a broken record.

All three are covered by unit tests.

### 9. The threat model, and where it stops

The design answers one question: *can an actor destroy the backups?*
Different actors need different answers, so it is worth being precise
about which are actually covered.

| Attacker | What they can do | Are the backups protected? | By what |
|----------|------------------|---------------------------|---------|
| **Ransomware on the primary VM** | Anything the VM's service account can do | ✅ **Yes** | The VM's SA has `roles/storage.objectCreator` — write-only. It cannot list, read, overwrite or delete. *Verified from inside the VM.* |
| **An accidental overwrite** | — | ✅ **Yes** | Object versioning: the prior generation is recoverable |
| **A regional outage** (us-east1) | — | ✅ **Yes** | Storage Transfer Service replicates to us-west1 continuously. *Verified byte-identical and independently restorable.* |
| **A stolen bucket export** | — | ✅ **Yes** | CMEK with 90-day rotation; the GCS service agent holds the key, not the uploader. The key never leaves KMS. |
| **A corrupt or truncated backup** | — | ✅ **Yes** | sha256 manifest + `PRAGMA integrity_check` + CRC32C validated on upload + a weekly restore drill |
| **A principal with `storage.admin` in the project** | Delete the bucket and its objects | ⚠️ **Partially** | The bucket-level **retention policy** blocks deletion of objects younger than the window, and `lock_backup_retention = true` makes that permanent against *everyone*. But a principal with enough IAM to remove the *retention policy* itself, or to delete the bucket wholesale, is still a threat. |
| **A principal who compromises the whole project** | Delete the bucket, the KMS key's policy, the backups | ❌ **No** | Both the backups and the key live in the same project. |

**The last row is the real gap, and it is the reason a cross-project
replica was designed.**

### 10. The cross-project replica — designed, not deployed

The fix for the last row is a second copy of the backups in a **second
GCP project**, under a different billing scope, ideally a different
owner. Then compromising one project does not destroy both copies.

**It was skipped, by decision, on budget grounds** — not because the
design was unknown. The whole 7-project portfolio shares one $300
trial credit, this project's entire footprint is **$0.53/month**, and a
second project would roughly double the fixed costs (a second KMS keyring
per region, a second Cloud DNS zone, a second bucket set) for a
*control* improvement rather than a *capability* one. Creating and
linking it is also an account-owner action with blast radius across the
whole portfolio.

The design is written down in [MISSING.md](../MISSING.md) — the bucket
shape, the second-project keyring, the cross-project IAM grants for the
Storage Transfer Service agent in both directions, and the second
Terraform state — so that it is a configuration change rather than a
rewrite if the budget ever allows it.

**What ships instead**, all of it verified live:

| Control | Stops | Cost |
|---------|-------|------|
| Write-only `objectCreator` on the VM's SA | Ransomware on the primary reading, overwriting or deleting backups | $0 |
| Bucket-level retention policy (+ optional permanent lock) | Deletion of recent backups by a project principal | $0 |
| Object versioning | Accidental overwrite | $0 |
| Cross-region replication (STS) | Regional outage | $0.05/mo |
| CMEK + 90-day rotation | A stolen bucket export | $0.12/mo |
| Weekly restore drill | A backup that exists but cannot be restored | $0.00 |

The honest summary: *the ransomware-on-the-box case is closed and
demonstrated; the project-compromise case is mitigated but not closed,
and the cross-project copy is the fix that was scoped out for budget
reasons.*

### 11. Production Requirements (Designed, Documented, Deployable)

| Feature | Production Implementation | Student Account Limitation |
|---------|--------------------------|----------------------------|
| **TLS certificate** | Cloud Managed SSL via domain mapping | Requires registered domain ($12/yr) |
| **Cloud Interconnect** | Private hybrid connectivity ($1,700/mo) | Budget: VM simulates on-prem |
| **Hourly backups** | Cloud Scheduler every hour for RPO < 1h | Nightly cron by default; `backup_cron` turns it on |
| **Cloud SQL** | Replace SQLite with managed Postgres | Budget: SQLite proves the DR pattern |
| **Warm standby** | Cloud Run min instances = 1 | Scale-to-zero ($0) for demo |
| **Backup retention locks** | Object retention policies | `lock_backup_retention` makes the window permanent — and makes `terraform destroy` wait for backups to age out |
| **Cross-project backups** | A second project with its own KMS keyring and a cross-project STS job | **Scoped out** — a second billable project does not fit the shared $300 trial budget. Designed and documented; not deployed. |
