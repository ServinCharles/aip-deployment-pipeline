# AIP Deployment Pipeline

Deploys the AIP (Agreement in Principle) microservices to Kubernetes on AWS EKS, and owns everything about **where and how they run**: the AWS infrastructure, the per-environment configuration, and the Jenkins deploy pipeline.

The app repos only build images. This repo promotes those exact images through the environments.

| Repo | Owns |
| --- | --- |
| [aip-mortgage-api](https://github.com/ServinCharles/aip-mortgage-api) | .NET API code, Dockerfile, **build** pipeline |
| [aip-webapp](https://github.com/ServinCharles/aip-webapp) | React code, Dockerfile, **build** pipeline |
| [aip-chat-api](https://github.com/ServinCharles/aip-chat-api) | Chatbot service, model validation artifacts, **build** pipeline |
| [aip-audit-service](https://github.com/ServinCharles/aip-audit-service) | Kafka consumer keeping the audit trail in MongoDB, **build** pipeline |
| **aip-deployment-pipeline** (this repo) | Terraform, Kubernetes manifests per environment, **deploy** pipeline |
| [Agentic-qa-demo](https://github.com/ServinCharles/Agentic-qa-demo) | Test framework, run by the deploy pipeline after every deploy |

```
 build pipeline (app repo)                     deploy pipeline (this repo)
 test → Sonar → Snyk → image scan → ECR  ──▶  approve (sit-02) → deploy → rollback on failure → smoke → Agentic-qa-demo tests
```

## Environments

Each environment has a frontend, a backend and a data namespace, matching the platform architecture:

| Environment | Frontend namespace | Backend namespace | Data namespace |
| --- | --- | --- | --- |
| sit-01 | `sit-01-dip` (aip-webapp) | `sit-01-api` (aip-api, aip-chat-api, aip-audit-service) | `sit-01-data` (MongoDB, Kafka) |
| sit-02 | `sit-02-dip` (aip-webapp) | `sit-02-api` (aip-api, aip-chat-api, aip-audit-service) | `sit-02-data` (MongoDB, Kafka) |

The frontend calls the API across namespaces through cluster DNS (`aip-api.<env>-api.svc.cluster.local`) and the chatbot at `aip-chat-api.<env>-api.svc.cluster.local`. The web app still works if the chatbot isn't deployed; the chat widget just says it's unavailable. Only the frontend is public, through an AWS load balancer.

### Events and data (MongoDB + Kafka)

```
aip-api ──save──▶ MongoDB (db aip, collection applications)
   │
   └──publish AipDecisionMade──▶ Kafka topic aip.decisions ──▶ aip-audit-service ──▶ MongoDB (db aip_audit, collection audit_events)
                                                    events it can't process ──▶ aip.decisions.dlq
```

- **Deploy order:** `aip-data` (MongoDB + Kafka) first, then aip-api, then aip-audit-service.
- **sit-01** has persistence switched on for aip-api (`PERSISTENCE_ENABLED=true`, applications kept 7 days). **sit-02** stays off until sit-01 is proven: copy the patch from `k8s/environments/sit-01/aip-api/kustomization.yaml` to switch it on.
- A NetworkPolicy only lets the environment's `-api` namespace reach `<env>-data`. MongoDB has no password in this demo setup, so the NetworkPolicy is its protection.
- Data is on persistent volumes, so it survives pod restarts. On EKS that needs the Amazon EBS CSI driver add-on.
- Memory: MongoDB and Kafka need about 1.5 GB between them. On colima, give the VM enough room: `colima stop && colima start --kubernetes --cpu 4 --memory 6`.

Look at the data:
```bash
kubectl -n sit-01-data exec mongodb-0 -- mongosh aip --quiet --eval 'db.applications.find().sort({createdAt:-1}).limit(3)'
kubectl -n sit-01-data exec mongodb-0 -- mongosh aip_audit --quiet --eval 'db.audit_events.countDocuments()'
kubectl -n sit-01-data exec kafka-0 -- /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group aip-audit
```
The last command shows each partition's **lag**: how many events aip-audit-service hasn't processed yet.

```
k8s/
  base/aip-api, base/aip-webapp, base/aip-chat-api, base/aip-audit-service  the services, shared by every environment
  base/mongodb, base/kafka                the data services
  environments/sit-01/<service>           namespace, replicas, API address for sit-01
  environments/sit-02/<service>           the same for sit-02
infra/terraform                           VPC, EKS cluster, ECR repositories
scripts/deploy.sh                         the deploy logic (Jenkins and manual deploys)
scripts/deploy-data.sh                    deploys MongoDB + Kafka to an environment and creates the topics
scripts/kubectl-docker.sh                 kubectl in a container, for Jenkins
scripts/teardown.sh                       removes everything from AWS
Jenkinsfile                               the AIP Deployment Pipeline
```

Adding an environment (e.g. `sit-03`) means copying a folder under `k8s/environments/` and adding it to the `ENVIRONMENT` choice in the Jenkinsfile.

## What a deploy does

`scripts/deploy.sh <service> <environment> <image>`:

1. Pins the image on top of the environment's config and applies it
2. Waits for the rollout. **If it fails, it rolls back to the previous version automatically**
3. Smoke-tests from inside the cluster: `/health` for the API; for the chatbot, its health check plus a real question it must recognise; for the web app, its health check plus a real AIP decision through the frontend, which proves the frontend can reach the API
4. If the smoke test fails, it rolls back too

CI proves all of this on every change, on a real Kubernetes cluster: it deploys both services to sit-01 and sit-02, then deploys a broken image and checks the previous version is still running.

## Jenkins: AIP Deployment Pipeline

```
Validate → Approve (sit-02 only) → Connect → Deploy → Post-deploy tests
```

| Parameter | Meaning |
| --- | --- |
| `SERVICE` | `aip-api`, `aip-webapp`, `aip-chat-api`, `aip-audit-service`, or `aip-data` (MongoDB + Kafka, no `IMAGE_TAG` needed) |
| `IMAGE_TAG` | the git short SHA the build pipeline tagged the image with, e.g. `3f2a1c9` |
| `ENVIRONMENT` | `sit-01`, or `sit-02` (asks for approval first) |
| `TARGET` | `eks` (AWS) or `local` (a cluster on the Jenkins machine) |
| `RUN_TESTS` | after deploying, run the Agentic-qa-demo job against the environment's URL (`api` suite for the API, `events` for the audit service, `smoke` for the rest; skipped for `aip-data`) |
| `LOCAL_URL` | `TARGET=local` only: the web app's URL on the Jenkins machine, default `http://localhost:8090` (a port-forward) |

- **Promotion gate**: on EKS, the image must already be in ECR, meaning it went through the build pipeline's tests and scans. Nothing is rebuilt here.
- Every tool runs in a container (AWS CLI, kubectl), so Jenkins only needs Docker.
- The cluster token is short-lived and deleted when the run ends.

### Setup

1. **New Item → Pipeline**, named `aip-deployment-pipeline`. You can set the display name to *AIP Deployment Pipeline* under *Advanced*; keep the job name itself free of spaces, because it becomes a folder path.
2. *Pipeline script from SCM* → Git → `https://github.com/ServinCharles/aip-deployment-pipeline.git`, branch `*/main`, script path `Jenkinsfile`.
3. Credentials:

| ID | Type | Used for |
| --- | --- | --- |
| `aws-credentials` | Username with password (access key ID / secret key) | `TARGET=eks`. The IAM user needs ECR read and EKS access (see below) |
| `kubeconfig-local` | Secret file | `TARGET=local`: your local kubeconfig (`~/.kube/config`) |

4. The build pipelines in the app repos can trigger this job automatically after a successful build (`TRIGGER_DEPLOY`), deploying the new image to sit-01.

**EKS access for Jenkins**: Terraform gives cluster-admin to whoever created the cluster. If Jenkins uses a different IAM user, grant it access:

```bash
aws eks create-access-entry --cluster-name aip-mortgage --principal-arn <jenkins-user-arn>
aws eks associate-access-policy --cluster-name aip-mortgage --principal-arn <jenkins-user-arn> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster
```

### Post-deploy tests on a local cluster

On colima the web app's load balancer address (e.g. `192.168.5.1`) only exists inside the VM, so Jenkins can't reach it. With `TARGET=local` the pipeline tests `LOCAL_URL` instead, which needs a port-forward running on the Jenkins machine:

1. In a **separate terminal**, start it and leave it open. This version reconnects by itself, because a port-forward is tied to one pod and stops whenever aip-webapp is redeployed:
   ```
   while true; do kubectl -n sit-01-dip port-forward svc/aip-webapp 8090:80; sleep 2; done
   ```
2. Check it: `curl http://localhost:8090/healthz` prints `ok`.
3. Run the deploy with `TARGET=local` and `RUN_TESTS` ticked.

If the port-forward isn't running, the pipeline skips the tests (the deploy stays green) and prints the command to start it.

## Create the AWS infrastructure

Prerequisites: AWS CLI v2 (logged in), Terraform 1.6+.

```bash
terraform -chdir=infra/terraform init
terraform -chdir=infra/terraform apply      # about 15 minutes, London region by default
```

This creates the VPC, the EKS cluster `aip-mortgage` and an ECR repository per service.

## Manual deploy

```bash
aws eks update-kubeconfig --region eu-west-2 --name aip-mortgage
./scripts/deploy-data.sh sit-01     # MongoDB + Kafka, first
./scripts/deploy.sh aip-api sit-01 <account>.dkr.ecr.eu-west-2.amazonaws.com/aip-api:<tag>
./scripts/deploy.sh aip-audit-service sit-01 <account>.dkr.ecr.eu-west-2.amazonaws.com/aip-audit-service:<tag>
./scripts/deploy.sh aip-webapp sit-01 <account>.dkr.ecr.eu-west-2.amazonaws.com/aip-webapp:<tag>
kubectl -n sit-01-dip get svc aip-webapp     # EXTERNAL-IP is the app's URL
```

On a local cluster, use the local image names instead, e.g. `aip-api:3f2a1c9`.

## Cost and teardown

Left running, this costs roughly **$6 a day** (EKS control plane, two t3.medium nodes, NAT gateway, and a load balancer per environment). Create it for demos and remove it afterwards:

```bash
./scripts/teardown.sh
```

It deletes the sit-01 and sit-02 namespaces first (which removes their load balancers), then runs `terraform destroy`.
