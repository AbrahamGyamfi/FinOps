variable "suffix" {
  description = "Random suffix to avoid name collisions"
  type        = string
}

variable "common_tags" {
  description = "Tags applied to every resource in this module"
  type        = map(string)
  default     = {}
}
