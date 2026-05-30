variable "suffix" { type = string }
variable "alert_email" { type = string }
variable "common_tags" {
  type    = map(string)
  default = {}
}
