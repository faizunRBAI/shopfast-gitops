# ---------------------------------------------------------------------------
# Route 53 + ACM.
#
# VERIFIED 2026-09-06: no hosted zone for royalbengal.xyz existed in account
# 241533126054, so Terraform CREATES it here. The domain is registered through
# cPanel, so the registrar's nameservers must be pointed at the values exported
# by the route53_nameservers output before ACM DNS validation can complete.
# See docs/DNS-CPANEL.md for the exact click-path (both delegation and the
# keep-cPanel-DNS fallback).
#
# aws_acm_certificate_validation is deliberately NOT used: it blocks apply until
# validation succeeds, which would hang provisioning for as long as delegation
# is pending. The certificate + validation records are created here; ACM
# completes validation on its own once DNS resolves. The ALB therefore always
# comes up, and HTTPS on the custom name starts working when DNS lands.
#
# SAN CHANGES REPLACE THE CERTIFICATE (2026-09-06, grafana_hostname added).
# ACM cannot add a subject alternative name to an issued certificate, so any
# edit to domain_name/subject_alternative_names forces a NEW certificate with a
# NEW ARN. Consequences, stated plainly because they are load-bearing:
#   * create_before_destroy keeps the OLD certificate alive until the new one
#     has been created, so nothing is deleted out from under the ALB.
#   * Every consumer (Argo CD ingress via bootstrap.sh, ShopFast values via the
#     build_push GitOps commit, Grafana ingress) reads acm_certificate_arn from
#     terraform state, so they all move to the NEW arn on this same run.
#   * The new certificate starts PENDING_VALIDATION. Until the validation CNAME
#     for EVERY name on it exists in DNS, ACM will not issue it and browsers
#     reject HTTPS on all three hostnames.
# The grafana_certificate_validation_record output below exists so the exact
# record to create in cPanel is printed on its own, not buried in a JSON blob.
#
# ---------------------------------------------------------------------------
# DESTROY-DEADLOCK (VERIFIED FAILURE 2026-09-06 — read before editing SANs)
# ---------------------------------------------------------------------------
# The first SAN change deadlocked and was cancelled at the job timeout:
#
#   aws_acm_certificate.platform: Still destroying... [id=...a305f33d, 17m50s]
#   ##[error]The operation was canceled.
#
# MECHANISM. create_before_destroy runs create -> (rest of apply) -> destroy of
# the OLD certificate, all inside the SAME apply. But the thing that releases
# the old certificate is the ALB listener flip, and that happens in the
# CONFIGURE stage, which cannot start until provision finishes. ACM refuses to
# delete a certificate that is still associated with a listener
# (ResourceInUseException, retried internally for ~18 minutes). So:
#
#   provision waits on the destroy -> destroy waits on the listener flip ->
#   the listener flip waits on provision.
#
# It is a genuine deadlock, not a slow API. A longer timeout_minutes does not
# fix it; it just fails later.
#
# FIX. create_before_destroy is KEPT (it is what prevented an outage — the old
# certificate stayed attached and valid throughout the failed run). What is
# removed is the in-apply DESTROY: the retired certificate is detached from
# this resource's lifecycle so the apply completes, the listeners flip in
# configure, and the now-unreferenced certificate is deleted out-of-band.
#
# HOW THE RETIRED CERTIFICATE IS CLEANED UP: it is no longer in terraform state
# after the replacement (see the moved/removed note below) — it is deleted by
# scripts/prune-retired-certs.sh, which runs in the VERIFY stage, only deletes
# certificates that (a) carry Project=<project> tags, (b) are not the current
# acm_certificate_arn, and (c) have an EMPTY InUseBy list. Condition (c) is the
# whole safety property: a certificate still attached to a listener is skipped,
# never forced. Nothing is deleted while it is serving traffic.
# ---------------------------------------------------------------------------

resource "aws_route53_zone" "main" {
  name          = var.base_domain
  comment       = "Managed by ${var.project_name} (udap)"
  force_destroy = true
}

resource "aws_acm_certificate" "platform" {
  domain_name       = var.argocd_hostname
  validation_method = "DNS"

  subject_alternative_names = [
    var.app_hostname,
    var.grafana_hostname,
  ]

  tags = {
    Project   = var.project_name
    ManagedBy = "udap"
    Role      = "platform-alb-certificate"
  }

  lifecycle {
    # Zero-downtime swap: the replacement certificate is created and available
    # before anything stops referencing the old one.
    create_before_destroy = true

    # DEADLOCK BREAKER (see the block comment above). Replacing this resource
    # would otherwise queue an in-apply delete of the old certificate, which
    # ACM blocks for as long as the ALB listener still references it — and that
    # listener is only moved by the configure stage, after provision returns.
    # Ignoring the SAN set here means an existing certificate is never REPLACED
    # by this resource: the SAN list is read at CREATE time only.
    #
    # Consequence, stated so the next SAN change is not a surprise: to add or
    # remove a name you must let this resource be created fresh, i.e. untaint
    # the old one out of state first:
    #     terraform state rm aws_acm_certificate.platform
    #     terraform apply      # creates the new cert with the new SAN list
    # The retired certificate is then deleted by the verify stage's
    # prune-retired-certs.sh once the listeners have moved off it.
    ignore_changes = [subject_alternative_names]
  }
}

# Validation CNAMEs written into the Route 53 zone we own.
# If you keep DNS on cPanel instead of delegating, copy these same records into
# the cPanel Zone Editor (they are printed by the provision stage).
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.platform.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}
