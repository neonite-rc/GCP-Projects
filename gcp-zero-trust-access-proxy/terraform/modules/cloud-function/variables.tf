variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "name" {
  description = "Function name (also used for the storage object prefix and service account)"
  type        = string
}

variable "source_dir" {
  description = "Directory containing the function source"
  type        = string
}

variable "entry_point" {
  description = "Python entry point function"
  type        = string
}

variable "runtime" {
  description = "Function runtime"
  type        = string
}

variable "bucket_name" {
  description = "Existing storage bucket that holds the deployed zips"
  type        = string
}

variable "region" {
  description = "Deployment region"
  type        = string
}

variable "env_vars" {
  description = "Environment variables for the function"
  type        = map(string)
  default     = {}
}

variable "iam_roles" {
  description = "Project-level IAM roles to grant the function's service account"
  type        = list(string)
  default     = []
}

variable "public" {
  description = "Allow unauthenticated invocations (auth must be inside the function)"
  type        = bool
  default     = false
}

variable "memory" {
  description = "Memory limit (e.g. 256Mi)"
  type        = string
  default     = "256Mi"
}

variable "timeout_seconds" {
  description = "Function timeout in seconds"
  type        = number
  default     = 60
}

variable "cpu" {
  description = "CPU allocation (e.g. 0.1667)"
  type        = string
  default     = "0.1667"
}
