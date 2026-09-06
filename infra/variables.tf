variable "project_name" {
  description = "Branch-scoped project name used as the prefix for every AWS resource."
  type        = string
}

variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated platform VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS control plane version. Must be within EKS standard support."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "Instance type for the EKS managed node group."
  type        = string
  default     = "t3.large"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 3
}

variable "node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 5
}

variable "base_domain" {
  description = "Apex domain for the public hosted zone (e.g. royalbengal.xyz)."
  type        = string
  default     = "royalbengal.xyz"
}

variable "argocd_hostname" {
  description = "Public hostname for the Argo CD dashboard."
  type        = string
  default     = "argocd.shopfast.royalbengal.xyz"
}

variable "app_hostname" {
  description = "Public hostname for the ShopFast application."
  type        = string
  default     = "shopfast.royalbengal.xyz"
}
