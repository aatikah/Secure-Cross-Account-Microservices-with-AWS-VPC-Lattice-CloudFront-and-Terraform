# Cross-Account Microservices on AWS: VPC Lattice, CloudFront, and Terraform

![Preview](https://github.com/aatikah/Secure-Cross-Account-Microservices-with-AWS-VPC-Lattice-CloudFront-and-Terraform/blob/main/lattice-thumbnail.png)

---

## 📖 Detailed Walkthrough
For a comprehensive step-by-step guide, including screenshots and detailed explanations, check out the full tutorial on Medium:
[**Build Secure Cross-Account Microservices on AWS UsingVPC Lattice, CloudFront, and Terraform**](https://medium.com/p/de3b324fe517)

## What This Project Does

The project simulates a simple ecommerce platform split across two AWS accounts:

**Account A (Provider)** runs two backend microservices:
- `orders-service` — manages orders (create, list, update, cancel)
- `products-service` — manages products and stock levels

**Account B (Consumer)** runs a storefront app that calls both services through VPC Lattice. It sits behind an Application Load Balancer and CloudFront, so it's publicly accessible over HTTPS.

The two accounts never share a VPC. They communicate through a VPC Lattice service network that Account A creates and shares with Account B via AWS RAM (Resource Access Manager).

---

## Architecture Overview

```
Internet
   |
   v
CloudFront (Account B)
   |  HTTPS redirect
   v
ALB — public subnets (Account B)
   |  HTTP port 8080
   v
Consumer EC2 — private subnet (Account B)
   |  SigV4-signed HTTP via VPC Lattice DNS
   v
VPC Lattice Service Network (shared via RAM)
   |
   +---> orders-service  (Account A, private subnet)
   +---> products-service (Account A, private subnet)
```


**AWS services used:**

| Service | Purpose |
|---|---|
| VPC Lattice | Service-to-service networking across accounts |
| AWS RAM | Share the Lattice service network with Account B |
| EC2 (t3.micro) | Runs the Flask microservices |
| ALB | Load balancer in front of the consumer app |
| CloudFront | HTTPS termination and public entry point |
| IAM | SigV4 auth for Lattice calls |
| NAT Gateway | Outbound internet for private subnets |
| CloudWatch Logs | VPC Lattice access logs |
| SSM | Shell access to EC2 instances without SSH |
| S3 (remote state) | Terraform state for Account A |

---

## Prerequisites

Before you start, you need:

- Two AWS accounts (Account A and Account B) in the same AWS Organization
- AWS CLI configured with named profiles: `account-a` and `account-b`
- Terraform >= 1.5 installed
- An S3 bucket in Account A for Terraform remote state (update the bucket name in `account-a/main.tf`)
- The AWS Organization OU ARN for Account B (used for the RAM share)
- Both accounts must have the VPC Lattice service available in `us-east-1`

To check your CLI profiles are working:

```bash
aws sts get-caller-identity --profile account-a
aws sts get-caller-identity --profile account-b
```

---

## Project Structure

```
.
├── account-a/
│   ├── main.tf              # All Account A infrastructure
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars
│   └── userdata/
│       ├── orders-service.sh    # Bootstraps the orders Flask app
│       └── products-service.sh  # Bootstraps the products Flask app
└── account-b/
    ├── main.tf              # All Account B infrastructure
    ├── variables.tf
    ├── outputs.tf
    ├── terraform.tfvars
    └── userdata/
        └── consumer.sh.tpl  # Bootstraps the consumer app (uses templatefile)
```

Each account is a self-contained Terraform root module. Account B reads Account A's outputs via `terraform_remote_state` pointing at the S3 backend.


---

## Step-by-Step Deployment

### Step 1 — Configure Account A variables

Create and open `account-a/terraform.tfvars` and fill in your values:

```hcl
aws_region      = "us-east-1"
project         = "ecommerce"
account_b_id    = "YOUR_ACCOUNT_B_ID"
customer_ou_arn = "arn:aws:organizations::YOUR_ORG_ACCOUNT_ID:ou/o-XXXXX/ou-XXXX-XXXXXXXX"
instance_type   = "t2.micro"
```

You can find your OU ARN in the AWS Organizations console under the organizational structure.

### Step 2 — Deploy Account A

```bash
cd account-a
terraform init
terraform plan
terraform apply --auto-approve
```

This creates 41 resources. The apply takes about 3-4 minutes, mostly waiting on the NAT Gateway and VPC Lattice target group attachments.

When it finishes, Terraform prints a `next_steps` output that looks like this:

```
account_a_id         = "98455435**********"
service_network_id   = "sn-007ae7c29e96b7006"
orders_service_dns   = "ecommerce-orders-svc-049628b2528ebf445.7d67968.vpc-lattice-svcs.us-east-1.on.aws"
products_service_dns = "ecommerce-products-svc-0cee9928a8fd55558.7d67968.vpc-lattice-svcs.us-east-1.on.aws"
```


### Step 3 — Accept the RAM share in Account B

Account A shares the VPC Lattice service network with Account B's OU via AWS RAM. Before Account B can use it, someone needs to accept the invitation.

1. Log into the Account B AWS console
2. Go to **AWS RAM** → **Shared with me** → **Resource share invitations**
3. Accept the invitation named `ecommerce-lattice-share`

This step is manual and must happen before you run Account B's Terraform.

**However, if Account A and Account B are members of the same AWS Organization, and AWS RAM sharing with AWS Organizations is enabled, the invitation acceptance step is NOT required.**

### Step 4 — Deploy Account B

Account B's `terraform.tfvars` only needs the basic variables — it reads the service DNS names directly from Account A's remote state:

```hcl
aws_region    = "us-east-1"
project       = "ecommerce"
instance_type = "t2.micro"
```

```bash
cd ../account-b
terraform init
terraform plan
terraform apply --auto-approve
```

This creates the consumer VPC, EC2 instance, ALB, CloudFront distribution, and the VPC Lattice VPC association. CloudFront takes a few minutes to propagate.

When done, you'll see output like:

```
cloudfront_url = "https://d1234abcd.cloudfront.net"
public_endpoints = <<EOT
  Storefront : https://d1234abcd.cloudfront.net/storefront
  Products   : https://d1234abcd.cloudfront.net/api/products
  Orders     : https://d1234abcd.cloudfront.net/api/orders
  Health     : https://d1234abcd.cloudfront.net/health
  Diagnostic : https://d1234abcd.cloudfront.net/diagnostic
EOT
```

### Step 5 — Verify the deployment

Hit the health endpoint first:

```bash
curl https://YOUR_CLOUDFRONT_DOMAIN/health
```

Then check the diagnostic endpoint, which tests connectivity to both backend services:

```bash
curl https://YOUR_CLOUDFRONT_DOMAIN/diagnostic | python3 -m json.tool
```

A healthy response looks like:

```json
{
  "overall": "healthy",
  "services": {
    "orders": { "status": "ok" },
    "products": { "status": "ok" }
  }
}
```

If you want to test from inside the consumer EC2 (bypassing CloudFront and ALB), use SSM:

```bash
aws ssm start-session --target i-XXXXXXXXX --profile account-b --region us-east-1
```

Then from inside the instance:

```bash
curl -s http://localhost:8080/diagnostic | python3 -m json.tool
curl -s http://localhost:8080/storefront | python3 -m json.tool
curl -s "http://localhost:8080/api/products?active=true" | python3 -m json.tool
```


---

## Key Design Decisions

### VPC Lattice instead of VPC peering

VPC peering between accounts works, but it doesn't scale well. You end up managing route tables, overlapping CIDR concerns, and security groups across accounts. VPC Lattice abstracts all of that. Services get stable DNS names, traffic is load-balanced automatically, and auth is handled by IAM policies attached to the service network and individual services.


### SigV4 signing on every Lattice request

The service network and both services use `auth_type = "AWS_IAM"`. This means every HTTP request from the consumer to a backend service must be signed with SigV4. The consumer app handles this using `boto3` and `botocore`:

```python
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

aws_req = AWSRequest(method=method, url=full_url, data=body or b"")
SigV4Auth(credentials, "vpc-lattice-svcs", AWS_REGION).add_auth(aws_req)
```

The EC2 instance gets its credentials from the instance profile, so no keys are hardcoded anywhere.


### Userdata as base64-encoded scripts

The EC2 instances bootstrap themselves on first boot. The userdata scripts install Python, Flask, write the app code to disk, and register a systemd service. Using `user_data_base64 = base64encode(file(...))` is cleaner than inline heredocs in Terraform and keeps the scripts easy to edit independently.

The consumer script uses `templatefile()` instead of `file()` because it needs to inject the Lattice DNS names at deploy time:

```hcl
user_data_base64 = base64encode(templatefile("${path.module}/userdata/consumer.sh.tpl", {
  orders_dns   = data.terraform_remote_state.account_a.outputs.orders_service_dns
  products_dns = data.terraform_remote_state.account_a.outputs.products_service_dns
  aws_region   = var.aws_region
}))
```


---

## Cleanup

Destroy in reverse order:  Account B first, then Account A:

```bash
cd account-b
terraform destroy --auto-approve

cd ../account-a
terraform destroy --auto-approve
```

Account A's destroy will take a few minutes because the NAT Gateway and VPC Lattice associations have to be removed first.

Note: the S3 bucket for remote state is not managed by Terraform in this project, so it won't be deleted automatically. Clean it up manually if you no longer need it.

---

## Conclusion

This setup gives you a working cross-account microservices architecture with proper network isolation, IAM-based auth, and a public HTTPS endpoint — all managed with Terraform.

---

## 📖 Detailed Walkthrough
For a comprehensive step-by-step guide, including screenshots and detailed explanations, check out the full tutorial on Medium:
[**Build Secure Cross-Account Microservices on AWS UsingVPC Lattice, CloudFront, and Terraform**](https://medium.com/p/de3b324fe517)


## 📬 Connect With Me
- 💼 [LinkedIn](https://www.linkedin.com/in/abdulhakeem-sulaiman/)
- ☕ [Support me on BuyMeACoffee](https://buymeacoffee.com/aatikah)
- 🧪 [Explore More Projects on GitHub](https://github.com/aatikah)



