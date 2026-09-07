# Docker Compose → AWS EKS: Complete Migration Plan

## Why Migrate?

| Problem with Docker Compose | EKS Solution |
|---|---|
| Single host — one VM down = full outage | Multi-node cluster with auto-healing pods |
| Manual scaling (`docker-compose scale`) | HPA scales pods in seconds based on CPU/memory/custom metrics |
| No rolling deployments — redeploy = downtime | Rolling updates, canary, blue/green out of the box |
| No self-healing — crashed container stays down | kubelet restarts failed containers; k8s reschedules evicted pods |
| Secrets in `.env` files on disk | AWS Secrets Manager + ESO / k8s Secrets encrypted at rest |
| No multi-AZ redundancy | EKS worker nodes spread across 3 AZs |
| No built-in observability | Prometheus + Grafana + Loki full stack |
| CI/CD is manual (`ssh` + `docker-compose up`) | GitOps pipeline: push → build → deploy, zero downtime |
| No resource governance | Requests/limits, LimitRange, ResourceQuota per namespace |
| Networking is flat Docker bridge | NetworkPolicy for micro-segmentation |

---

## Migration Phases

```
Phase 1  ─ Containerise & validate images (1 week)
Phase 2  ─ Infrastructure as Code — VPC + EKS + RDS + ECR (1 week)
Phase 3  ─ Kubernetes manifests + Helm chart (3 days)
Phase 4  ─ CI/CD pipeline (2 days)
Phase 5  ─ Monitoring stack (2 days)
Phase 6  ─ Cutover (DNS switch, drain old host) (1 day)
Phase 7  ─ Decommission docker-compose host (1 week after cutover)
```

---

## Application Stack (what we are migrating)

```
┌─────────────────────────────────────┐
│         Internet / Users            │
└────────────────┬────────────────────┘
                 │ HTTPS
        ┌────────▼────────┐
        │  ALB Ingress    │  (AWS Load Balancer Controller)
        └────────┬────────┘
                 │
        ┌────────▼────────┐
        │   Nginx / API   │  Node.js Express  (3 replicas)
        └──┬──────────────┘
           │          │
   ┌───────▼──┐  ┌────▼────┐
   │ PostgreSQL│  │  Redis  │
   │  (RDS)   │  │(ElastiC)|
   └──────────┘  └─────────┘
```

---

## Execution Checklist

### Pre-flight
- [ ] AWS CLI configured (`aws configure`)
- [ ] `kubectl` installed
- [ ] `eksctl` installed
- [ ] `helm` v3 installed
- [ ] `terraform` >= 1.5 installed
- [ ] Docker Desktop running
- [ ] GitHub repo + Actions enabled
- [ ] Domain in Route 53

### Phase 1 — Images
- [ ] Build & test each service image locally
- [ ] Push to ECR
- [ ] Verify images run with `docker run`

### Phase 2 — Infrastructure
- [ ] `terraform apply` in `terraform/environments/prod`
- [ ] EKS cluster healthy (`kubectl get nodes`)
- [ ] RDS endpoint noted
- [ ] ElastiCache endpoint noted

### Phase 3 — Manifests
- [ ] Namespaces created
- [ ] Secrets loaded (via `kubectl create secret` or ESO)
- [ ] `kubectl apply -k kubernetes/overlays/prod`
- [ ] All pods `Running`

### Phase 4 — CI/CD
- [ ] GitHub secrets set (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `ECR_REGISTRY`)
- [ ] Push a commit → pipeline green → pods updated

### Phase 5 — Monitoring
- [ ] Prometheus scraping all targets
- [ ] Grafana dashboards imported
- [ ] Loki receiving logs
- [ ] Alertmanager rules firing on test alert

### Phase 6 — Cutover
- [ ] Load test on EKS (k6 / locust)
- [ ] Update Route 53 A/CNAME → ALB DNS
- [ ] Monitor error rate for 30 min
- [ ] Rollback plan ready (switch DNS back)

---

## Rollback Strategy

```
1. DNS TTL already lowered to 60s before cutover
2. git revert → pipeline redeploys old tag
3. kubectl rollout undo deployment/api
4. If cluster broken → point DNS back to old docker-compose host
```
