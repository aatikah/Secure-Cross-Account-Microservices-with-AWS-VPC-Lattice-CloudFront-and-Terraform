output "account_a_id" {
  value = local.account_a_id
}

output "service_network_id" {
  value = aws_vpclattice_service_network.main.id
}

output "orders_service_dns" {
  value = one(aws_vpclattice_service.orders.dns_entry).domain_name
}

output "products_service_dns" {
  value = one(aws_vpclattice_service.products.dns_entry).domain_name
}

output "ram_share_arn" {
  value = aws_ram_resource_share.lattice.arn
}

output "orders_instance_id" {
  value = aws_instance.orders.id
}

output "products_instance_id" {
  value = aws_instance.products.id
}

output "next_steps" {
  value = <<-EOT

  ══════════════════════════════════════════════════════════════
  Account A deployed. Before running Account B:
  ══════════════════════════════════════════════════════════════

  1. Accept RAM share in Account B console:
     AWS RAM → Shared with me → Resource share invitations → Accept

  2. Fill in account-b/terraform.tfvars:
     account_a_id         = "${local.account_a_id}"
     service_network_id   = "${aws_vpclattice_service_network.main.id}"
     orders_service_dns   = "${one(aws_vpclattice_service.orders.dns_entry).domain_name}"
     products_service_dns = "${one(aws_vpclattice_service.products.dns_entry).domain_name}"

  3. cd ../account-b && terraform init && terraform apply
  ══════════════════════════════════════════════════════════════
  EOT
}
