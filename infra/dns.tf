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

  lifecycle {
    create_before_destroy = true
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
