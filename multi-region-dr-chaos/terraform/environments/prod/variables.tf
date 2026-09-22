variable "primary_region" {
  description = "Primary AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "Secondary DR AWS Region"
  type        = string
  default     = "us-west-2"
}

variable "hosted_zone_id" {
  description = "Route 53 Public Hosted Zone ID"
  type        = string
  default     = "Z10123456ABCDEF9999"
}
