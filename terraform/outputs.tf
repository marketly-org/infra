output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "aks_cluster_fqdn" {
  value = azurerm_kubernetes_cluster.main.fqdn
}

output "postgres_server_fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}

output "postgres_admin_login" {
  value = azurerm_postgresql_flexible_server.main.administrator_login
}

output "redis_hostname" {
  value = azurerm_redis_cache.main.hostname
}

output "ingress_public_ip" {
  value = azurerm_public_ip.ingress.ip_address
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "kubeconfig_command" {
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name} --overwrite-existing"
  description = "Run this to configure kubectl to talk to the cluster"
}
