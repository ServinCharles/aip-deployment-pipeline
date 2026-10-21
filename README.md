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

## Observability with Grafana Cloud

Logs, metrics, traces and dashboards for the platform, using the **Grafana Cloud free tier** (50 GB logs, 50 GB traces, 10,000 metric series, 14 days). Only a small agent runs in the cluster; storage and dashboards are in Grafana Cloud.

```
k3s: AIP pods ──logs, metrics──▶ Grafana Alloy (monitoring namespace) ──▶ Grafana Cloud: Loki, Prometheus, Tempo, Grafana
     Beyla (eBPF) ──HTTP metrics and traces──┘
```

| What you get | Where in Grafana Cloud | Dynatrace equivalent |
| --- | --- | --- |
| Pods, restarts, OOMKilled, CPU and memory | Observability > Kubernetes | Kubernetes app |
| Requests, errors and response time per service, service map | Observability > Application | Services, Smartscape |
| HTTP traces (web app to aip-api and aip-chat-api) | Drilldown > Traces | PurePath |
| Pod logs, searchable by field (the .NET services log JSON) | Drilldown > Logs | Log viewer |
| **AIP Platform Overview** dashboard (below) | Dashboards | Custom dashboard |

**Beyla** instruments the web app and services automatically with eBPF, with no code changes (the same idea as OneAgent). It doesn't follow a request through Kafka, so the audit service shows as its own trace; the dashboard links the two with the application ID from the logs.

### AIP Platform Overview dashboard

Dashboard as code: [`monitoring/dashboards/aip-platform-overview.json`](monitoring/dashboards/aip-platform-overview.json), generated by [`build-dashboard.py`](monitoring/dashboards/build-dashboard.py) (edit the script, run it, commit both). Choose the environment (sit-01 or sit-02) at the top.

| Section | Panels | Source |
| --- | --- | --- |
| Mortgage decisions | Decisions audited, by outcome and over time; duplicates ignored; dead-lettered; not saved or published | Audit service and aip-api logs |
| Chatbot | Questions, fallback rate, personal data blocked, questions by intent | aip-chat-api logs (intent only, never the customer's words) |
| Services | Requests per second, 5xx rate, p95 response time | Beyla |
| Kubernetes | Restarts, OOMKilled, memory by container | kube-state-metrics, cAdvisor |
| Logs | Warnings and errors; **logs for one application ID** (cross-log view across services) | Loki |

### Set up

1. Create a free account at grafana.com and a stack.
2. In the Grafana Cloud portal, open your stack's **Details** and note the URL and user (instance ID) for **Prometheus**, **Loki** and **OpenTelemetry**.
3. **Security > Access Policies**: create a policy with `metrics:write`, `logs:write` and `traces:write`, then a token for it.
4. Install (needs `kubectl` and `helm`; on macOS `brew install helm`):

```bash
export GRAFANA_CLOUD_PROMETHEUS_URL=https://prometheus-prod-XX-prod-REGION.grafana.net/api/prom/push
export GRAFANA_CLOUD_PROMETHEUS_USER=123456
export GRAFANA_CLOUD_LOKI_URL=https://logs-prod-XXX.grafana.net/loki/api/v1/push
export GRAFANA_CLOUD_LOKI_USER=654321
export GRAFANA_CLOUD_OTLP_URL=https://otlp-gateway-prod-REGION.grafana.net/otlp
export GRAFANA_CLOUD_OTLP_USER=111111
export GRAFANA_CLOUD_TOKEN=glc_...          # never commit it
./scripts/monitoring-setup.sh install       # namespace, secret, Helm chart; waits for the pods
```

5. Load the dashboard. In Grafana, **Administration > Users and access > Service accounts**: create one with the Editor role and a token, then:

```bash
export GRAFANA_URL=https://YOURSTACK.grafana.net
export GRAFANA_SA_TOKEN=glsa_...
./scripts/monitoring-setup.sh dashboard
```

Or import the JSON by hand: **Dashboards > New > Import**.

6. Redeploy aip-api, aip-audit-service and aip-chat-api (deploy pipeline or `scripts/deploy.sh`) so they pick up JSON logging.

Other commands: `preview` (render the Kubernetes objects without installing), `status`, `uninstall`.

| Setting | Why |
| --- | --- |
| Helm chart `grafana/k8s-monitoring` pinned to 4.5.3 | Repeatable installs ([values](monitoring/k8s-monitoring-values.yaml)) |
| Credentials in the Kubernetes secret `grafana-cloud`, created from environment variables | Nothing secret in git |
| Logs and Kubernetes metrics from the AIP namespaces only | Stays far inside the free tier |
| Small Alloy collectors, no Beyla cache pod, no node or cost exporters | One small local node |
| `Logging__Console__FormatterName=json` on the .NET services | One JSON object per log line, so `ApplicationId`, `Decision` and `Intent` can be queried |

Beyla needs privileged access to the node (eBPF). k3s allows it; if Beyla pods don't start, logs and Kubernetes dashboards still work.

## Cost and teardown

Left running, this costs roughly **$6 a day** (EKS control plane, two t3.medium nodes, NAT gateway, and a load balancer per environment). Create it for demos and remove it afterwards:

```bash
./scripts/teardown.sh
```

It deletes the sit-01 and sit-02 namespaces first (which removes their load balancers), then runs `terraform destroy`.
