# DNS setup for `royalbengal.xyz` (cPanel)

**Verified fact:** on 2026-09-06 there was **no Route 53 hosted zone** for
`royalbengal.xyz` in AWS account `241533126054`. Terraform creates one. Until the
domain actually points at that zone (or you copy the records manually), the public
HTTPS hostnames cannot resolve and the ACM certificate stays `PENDING_VALIDATION`.

You have two options. **Option A is strongly recommended.**

---

## Option A — Delegate the domain to Route 53 (recommended)

AWS becomes the authoritative DNS for the domain. Terraform then manages the ACM
validation records and the ALB alias automatically, and certificate renewal is
hands-off forever.

### 1. Get the four nameservers

After the `provision` stage runs, open the GitHub Actions log and find the group
**"Route53 nameservers — set these at your registrar"**. It prints something like:

```json
[
  "ns-1234.awsdns-26.org",
  "ns-567.awsdns-07.net",
  "ns-890.awsdns-45.com",
  "ns-2101.awsdns-12.co.uk"
]
```

You can also read them any time with:

```bash
aws route53 list-hosted-zones-by-name --dns-name royalbengal.xyz \
  --query 'HostedZones[0].Id' --output text
# then
aws route53 get-hosted-zone --id <ZONE_ID> --query 'DelegationSet.NameServers'
```

### 2. Where to change them in cPanel

Nameservers are a **registrar** setting, not a zone setting. The exact location
depends on how the domain was bought.

**If the domain was registered through your hosting provider (most common):**

1. Log in to your hosting account's **client area / billing portal**
   (e.g. WHMCS — often `my.<provider>.com`, not cPanel itself).
2. Go to **Domains → My Domains**.
3. Click the domain `royalbengal.xyz` → **Manage Nameservers**
   (sometimes **Nameservers** in the left sidebar).
4. Select **Use custom nameservers**.
5. Replace all existing entries with the four AWS values from step 1.
6. Save.

**If cPanel itself shows a "Zone Editor" only:** cPanel's Zone Editor edits the
zone, not the delegation. Changing nameservers must happen in the registrar
portal above. If you cannot find it, use **Option B**.

### 3. Wait for propagation

Delegation typically takes 15–60 minutes (up to 48h worst case). Check with:

```bash
dig NS royalbengal.xyz +short
# should return the four ns-*.awsdns-* entries
```

Once delegation is live, ACM validates within a few minutes and
`https://argocd.shopfast.royalbengal.xyz` starts serving.

### 4. Important warning

Delegating moves **all** DNS for `royalbengal.xyz` to AWS. Any existing records
(website `A` record, `MX` mail records, `TXT`/SPF) **stop working** unless you
recreate them in the Route 53 zone. If the domain currently serves a website or
email from cPanel, either recreate those records in Route 53 first, or use
Option B.

---

## Option B — Keep DNS on cPanel (no delegation)

Use this if `royalbengal.xyz` already serves a live site or email from cPanel and
you do not want to move DNS.

You add two kinds of records **by hand** in **cPanel → Zone Editor**.

### B1. ACM validation records (issues the certificate)

The `provision` stage prints them; you can also read them with:

```bash
cd infrastructure
terraform output -json acm_validation_records
```

For each entry, in **cPanel → Zone Editor → Manage → Add Record**:

| Field | Value |
|---|---|
| Type | `CNAME` |
| Name | the `name` field (e.g. `_a1b2c3....argocd.shopfast`) |
| Record / Points to | the `value` field (e.g. `_x9y8z7....acm-validations.aws.`) |
| TTL | `300` |

> cPanel often appends the domain automatically. If the printed name is
> `_abc.argocd.shopfast.royalbengal.xyz.` enter only `_abc.argocd.shopfast`
> and let cPanel add the rest. Verify afterwards with
> `dig CNAME _abc.argocd.shopfast.royalbengal.xyz +short`.

ACM validates within minutes of these resolving.

### B2. Hostname records (routes traffic to the ALB)

Get the ALB hostname (printed by the `verify` stage, or):

```bash
kubectl -n argocd get ingress \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
# e.g. k8s-shopfast-abc123-456789.us-east-1.elb.amazonaws.com
```

Add two `CNAME` records in the Zone Editor:

| Type | Name | Points to | TTL |
|---|---|---|---|
| CNAME | `argocd.shopfast` | `<alb-hostname>` | 300 |
| CNAME | `shopfast` | `<alb-hostname>` | 300 |

That yields `argocd.shopfast.royalbengal.xyz` and `shopfast.royalbengal.xyz`.

### B3. Caveat you must accept

An ALB's DNS name is stable **while the ALB exists**, but AWS does not guarantee
it across recreation. If the ingress is deleted and recreated (e.g. a full
`destroy` + redeploy), the ALB hostname changes and you must update these CNAMEs
by hand. Option A does this automatically.

---

## Verifying it worked

```bash
# Delegation (Option A only)
dig NS royalbengal.xyz +short

# Hostname resolves
dig argocd.shopfast.royalbengal.xyz +short

# Certificate issued
aws acm list-certificates --region us-east-1 \
  --query "CertificateSummaryList[?DomainName=='argocd.shopfast.royalbengal.xyz']"

# Dashboard is live
curl -I https://argocd.shopfast.royalbengal.xyz
```

`ISSUED` on the certificate plus a `200` from curl means you are done.

---

## Reaching Argo CD before DNS is ready

You are never blocked. The ALB serves the dashboard on its own AWS hostname:

```bash
ALB=$(kubectl -n argocd get ingress \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

curl -k -H "Host: argocd.shopfast.royalbengal.xyz" "https://${ALB}/"
```

For browser access before delegation, add a local hosts entry:

```
<alb-ip>  argocd.shopfast.royalbengal.xyz
```

This is a **temporary convenience for your workstation only** — it is not the
final solution, and it is not `kubectl port-forward`. The permanent path is
Option A or Option B above.
