# Resource group
resource "azurerm_resource_group" "main" {
  name     = "${var.name_prefix}-rg"
  location = var.location
}

# AKS cluster
resource "azurerm_kubernetes_cluster" "main" {
  name                = "${var.name_prefix}-aks"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "${var.name_prefix}"

  default_node_pool {
    name                = "default"
    node_count          = var.node_count
    vm_size             = var.node_vm_size
    os_disk_size_gb     = 50
    os_disk_type        = "Managed"
    enable_auto_scaling = false
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
    service_cidr      = "10.1.0.0/16"
    dns_service_ip    = "10.1.0.10"
  }

  role_based_access_control_enabled = true

  tags = {
    Environment = "test"
    Project     = "marketly"
  }
}

# Public IP for ingress
resource "azurerm_public_ip" "ingress" {
  name                = "${var.name_prefix}-ingress-ip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = var.name_prefix
}

# PostgreSQL Flexible Server
resource "azurerm_postgresql_flexible_server" "main" {
  name                   = "${var.name_prefix}-pg"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  version                = "16"
  administrator_login    = "marketly_admin"
  administrator_password = coalesce(var.postgres_admin_password, random_password.postgres.result)
  storage_mb             = 32768
  sku_name               = "B1ms"
  zone                   = "1"

  authentication {
    password_auth_enabled = true
  }

  lifecycle {
    ignore_changes = [zone]
  }
}

# PostgreSQL databases — one per service
locals {
  db_names = [
    "checkout",
    "payments",
    "inventory",
    "users",
    "shipping",
    "search",
    "recommendation",
    "workers",
  ]
}

resource "azurerm_postgresql_flexible_server_database" "main" {
  for_each  = toset(local.db_names)
  name      = each.value
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Firewall rule: allow Azure services (AKS) to connect
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Redis Cache
resource "azurerm_redis_cache" "main" {
  name                = "${var.name_prefix}-redis"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  capacity            = 1
  family              = "C"
  sku_name            = "Standard"
  minimum_tls_version = "1.2"
  redis_configuration {
    enable_non_ssl_port = false
  }
}

# Random password for Postgres if not provided
resource "random_password" "postgres" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Key Vault for secrets
resource "azurerm_key_vault" "main" {
  name                       = "${var.name_prefix}kv"
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
}

data "azurerm_client_config" "current" {}

# Store secrets in Key Vault
resource "azurerm_key_vault_secret" "llm_api_key" {
  name         = "llm-api-key"
  value        = var.llm_api_key
  key_vault_id = azurerm_key_vault.main.id
}

resource "azurerm_key_vault_secret" "github_token" {
  name         = "github-token"
  value        = var.github_token
  key_vault_id = azurerm_key_vault.main.id
}

resource "azurerm_key_vault_secret" "stripe_api_key" {
  name         = "stripe-api-key"
  value        = coalesce(var.stripe_api_key, "sk_test_disabled")
  key_vault_id = azurerm_key_vault.main.id
}

resource "azurerm_key_vault_secret" "postgres_password" {
  name         = "postgres-password"
  value        = coalesce(var.postgres_admin_password, random_password.postgres.result)
  key_vault_id = azurerm_key_vault.main.id
}
