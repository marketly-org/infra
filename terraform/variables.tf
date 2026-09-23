variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "marketly"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus"
}

variable "node_count" {
  description = "Number of AKS worker nodes"
  type        = number
  default     = 3
}

variable "node_vm_size" {
  description = "VM size for AKS nodes"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "postgres_admin_password" {
  description = "Admin password for PostgreSQL. If empty, a random password is generated."
  type        = string
  default     = ""
  sensitive   = true
}

variable "llm_api_key" {
  description = "LLM API key for Sentinel"
  type        = string
  sensitive   = true
}

variable "llm_provider" {
  description = "LLM provider (zai, openai, anthropic, gemini)"
  type        = string
  default     = "zai"
}

variable "llm_base_url" {
  description = "LLM API base URL (empty = provider default)"
  type        = string
  default     = ""
}

variable "llm_fast_model" {
  description = "Fast/cheap model name"
  type        = string
  default     = "glm-4-flash"
}

variable "llm_frontier_model" {
  description = "Frontier/high-quality model name"
  type        = string
  default     = "glm-4.5"
}

variable "github_token" {
  description = "GitHub PAT for Sentinel (repo + PR + GHCR scopes)"
  type        = string
  sensitive   = true
}

variable "stripe_api_key" {
  description = "Stripe API key (test mode). Empty = simulated."
  type        = string
  default     = ""
  sensitive   = true
}

variable "sentinel_api_token" {
  description = "Bearer token for Sentinel admin API"
  type        = string
  default     = "marketly-sentinel-token"
  sensitive   = true
}
