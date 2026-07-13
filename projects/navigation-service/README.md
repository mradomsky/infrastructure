# navigation-service

Terraform stack for the navigation-service — a Java Spring Boot application backed by a SQLite
database stored on an AWS EFS persistent volume.

## Architecture

```
ECS Fargate task
  └─ /data  (EFS volume via access point)
       └─ nav.db  (SQLite file)
```

EFS persists across task restarts and redeployments. The ECS service runs inside the VPC; inbound
access is controlled by the task security group (`ingress_cidr_blocks` / `ingress_security_group_ids`).

## Module

This stack consumes `modules/ecs-service-with-efs`. The module manages:

| Resource | Notes |
| --- | --- |
| EFS file system + access point | Encrypted at rest, NFS over TLS |
| EFS mount targets | One per subnet — covers all AZs in the VPC |
| ECS cluster + task definition | Fargate, `awsvpc` networking |
| ECS service | Rolling deploys; Terraform ignores image changes (app CI owns those) |
| IAM roles | Execution role (ECR pull + CloudWatch logs) and task role (app-level permissions) |
| Security groups | Task SG + EFS SG (NFS only from task SG) |
| CloudWatch log group | `/ecs/<project>-<service>-<env>`, 30-day retention |

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `environment` | — | `dev` or `prod` |
| `container_image` | — | Full ECR image URI including tag |
| `container_port` | `8080` | Spring Boot server port |
| `cpu` | `512` | Fargate CPU units |
| `memory` | `1024` | Fargate memory (MiB) |
| `desired_count` | `1` | Running task replicas (`0` = stopped) |
| `sqlite_db_filename` | `nav.db` | Filename inside `/data` |
| `vpc_id` | `""` | Leave empty to use the default VPC |
| `subnet_ids` | `[]` | Leave empty to use all subnets in the VPC |
| `assign_public_ip` | `true` | Required with public subnets + no NAT gateway |
| `ingress_cidr_blocks` | `[]` | CIDRs allowed to reach the container port |

## Apply

`*.tfvars` are gitignored (keep secrets out). Copy the example files and customise:

```bash
cd projects/navigation-service
cp dev.tfvars.example dev.tfvars      # gitignored — edit locally
cp prod.tfvars.example prod.tfvars

terraform init
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars

# prod
terraform plan -var-file=prod.tfvars
terraform apply -var-file=prod.tfvars
```

## Navigation-service runtime config

Terraform injects these environment variables into the container:

| Env var | Value | Purpose |
| --- | --- | --- |
| `SQLITE_DB_PATH` | `/data/<sqlite_db_filename>` | Full path to the SQLite file — wire to `spring.datasource.url=jdbc:sqlite:${SQLITE_DB_PATH}` |
| `SPRING_PROFILES_ACTIVE` | environment name | Activates the matching Spring profile |
| `SERVER_PORT` | `container_port` | Matches the ECS port mapping |

Minimal `application.properties` / `application.yml` wiring:

```yaml
spring:
  datasource:
    url: jdbc:sqlite:${SQLITE_DB_PATH:/data/nav.db}
    driver-class-name: org.sqlite.JDBC
  jpa:
    database-platform: org.hibernate.community.dialect.SQLiteDialect
```

The default value (`/data/nav.db`) is used when the env var is absent — useful for local runs.

## Local dev parity

Local does not use Terraform. Run the service with a named Docker volume for SQLite parity:

```bash
docker run --rm \
  -p 8080:8080 \
  -v nav-data:/data \
  -e SQLITE_DB_PATH=/data/nav.db \
  -e SPRING_PROFILES_ACTIVE=local \
  <image>
```

Or via Docker Compose:

```yaml
services:
  navigation-service:
    image: <image>
    ports:
      - "8080:8080"
    volumes:
      - nav-data:/data
    environment:
      SQLITE_DB_PATH: /data/nav.db
      SPRING_PROFILES_ACTIVE: local

volumes:
  nav-data:
```

The named volume survives container restarts, matching EFS persistence behaviour on AWS.

## Code deploy contract

Same pattern as the rest of the repo — Terraform manages infrastructure, app CI manages code:

| Concern | Owner |
| --- | --- |
| ECS service, IAM, EFS, env vars, CPU/memory | this repo (`projects/navigation-service/`) |
| Container image (tag updates) | app repo CI via `aws ecs update-service --force-new-deployment` |

The task definition has `ignore_changes = [container_definitions]` so Terraform never rolls back an image deployed by CI.

## CI

Add this stack to `.github/workflows/plan.yml` matrix once the ECR repository exists:

```yaml
matrix:
  stack: [projects/radomskyi-com, projects/navigation-service]
```
