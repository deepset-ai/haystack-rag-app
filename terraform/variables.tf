variable "aws_region" {
  type        = string
  description = "AWS region to deploy resources"
  default     = "eu-west-1"
}

variable "environment" {
  type        = string
  description = "Deployment environment (e.g. dev, staging, prod)"
}
