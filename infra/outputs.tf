output "eks_cluster_name" {
  description = "EKS cluster name (consumed by configure/verify stages)."
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "eks_oidc_provider_arn" {
  description = "IAM OIDC provider ARN for IRSA."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "alb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller."
  value       = aws_iam_role.alb_controller.arn
}

output "ecr_repository_url" {
  description = "ECR repository URL for the ShopFast image."
  value       = aws_ecr_repository.shopfast.repository_url
}

output "ecr_repository_name" {
  description = "ECR repository name."
  value       = aws_ecr_repository.shopfast.name
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN used by the ALB ingress for HTTPS."
  value       = aws_acm_certificate.platform.arn
}

output "route53_zone_id" {
  description = "Route 53 hosted zone id for the base domain."
  value       = aws_route53_zone.main.zone_id
}

output "route53_nameservers" {
  description = "ACTION REQUIRED: set these four nameservers on the domain at your registrar (cPanel) so the public HTTPS hostnames resolve."
  value       = aws_route53_zone.main.name_servers
}

output "acm_validation_records" {
  description = "DNS validation records for the ACM certificate. Only needed if you keep DNS on cPanel instead of delegating to Route 53."
  value = [
    for dvo in aws_acm_certificate.platform.domain_validation_options : {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  ]
}

# Isolated so the provision stage can print the ONE record that is new on this
# change without the operator having to pick it out of the full JSON list.
# DNS stays on cPanel (no Route 53 delegation), so this record must be created
# by hand in the cPanel Zone Editor before ACM will issue the certificate.
output "grafana_certificate_validation_record" {
  description = "ACTION REQUIRED (cPanel Zone Editor): CNAME that validates the Grafana hostname on the platform certificate."
  value = one([
    for dvo in aws_acm_certificate.platform.domain_validation_options :
    {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
    if dvo.domain_name == var.grafana_hostname
  ])
}

output "vpc_id" {
  description = "Platform VPC id."
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet ids hosting the EKS node group."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet ids used by the internet-facing ALB."
  value       = aws_subnet.public[*].id
}

output "argocd_hostname" {
  description = "Public hostname for the Argo CD dashboard."
  value       = var.argocd_hostname
}

output "app_hostname" {
  description = "Public hostname for the ShopFast application."
  value       = var.app_hostname
}

output "grafana_hostname" {
  description = "Public hostname for the Grafana dashboard."
  value       = var.grafana_hostname
}
