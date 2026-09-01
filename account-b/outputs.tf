output "cloudfront_url" {
  description = "Public HTTPS URL — share this with users"
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "alb_dns" {
  description = "ALB DNS — only reachable from CloudFront IPs"
  value       = aws_lb.public.dns_name
}

output "consumer_instance_id" {
  value = aws_instance.consumer.id
}

output "ssm_connect_command" {
  value = "aws ssm start-session --target ${aws_instance.consumer.id} --profile account-b --region ${var.aws_region}"
}

output "public_endpoints" {
  value = <<-EOT
    Storefront : https://${aws_cloudfront_distribution.main.domain_name}/storefront
    Products   : https://${aws_cloudfront_distribution.main.domain_name}/api/products
    Orders     : https://${aws_cloudfront_distribution.main.domain_name}/api/orders
    Health     : https://${aws_cloudfront_distribution.main.domain_name}/health
    Diagnostic : https://${aws_cloudfront_distribution.main.domain_name}/diagnostic
  EOT
}

output "internal_test_commands" {
  description = "Run these inside the consumer EC2 via SSM"
  value       = <<-EOT
    sudo systemctl status consumer
    curl -s http://localhost:8080/diagnostic | python3 -m json.tool
    curl -s http://localhost:8080/storefront | python3 -m json.tool
    curl -s "http://localhost:8080/api/products?active=true" | python3 -m json.tool
    curl -s http://localhost:8080/api/orders | python3 -m json.tool
    curl -s -X POST http://localhost:8080/api/orders \
      -H "Content-Type: application/json" \
      -d '{"customer_id":"cust-001","items":[{"product_id":"prod-A1","name":"Headphones","qty":1,"price":79.99}]}' \
      | python3 -m json.tool
  EOT
}
