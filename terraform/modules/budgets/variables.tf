variable "suffix" {
  type = string
}

variable "account_id" {
  type = string
}

variable "environment" {
  type = string
}

variable "alert_email" {
  type = string
}

variable "limit_usd" {
  type    = string
  default = "50"
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
