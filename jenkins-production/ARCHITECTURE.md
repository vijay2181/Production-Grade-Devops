# Jenkins Production Architecture

> **Project 5** | Builds on: all previous projects
> Stack: Jenkins on Kubernetes · JCasC · Shared Library · Kaniko · Trivy · Cosign · ArgoCD promotion · IRSA · EFS · S3

---

## Why Jenkins (and Not GitHub Actions / GitLab CI)?

This is the first question every reviewer asks. Answer it honestly.

```
GitHub Actions:
  ✅ Zero infrastructure to manage
  ✅ Excellent for OSS and cloud-native greenfield
  ❌ Limited audit trail for enterprise compliance (SOC2, PCI)
  ❌ No fine-grained role-based pipeline access control
  ❌ Shared runners = shared blast radius
  ❌ Cannot run fully air-gapped (regulated industries)
  ❌ No support for complex multi-stage approval workflows
  ❌ Secrets management is per-repo, not centralised

Jenkins:
  ✅ Used in 60-70% of large enterprises (banks, telecoms, insurance)
  ✅ Full audit log: who triggered, who approved, what changed
  ✅ Centralised credential management with Vault / Secrets Manager
  ✅ Runs fully air-gapped (no internet required)
  ✅ Fine-grained RBAC per project, per pipeline, per environment
  ✅ Shared Libraries — one team owns pipeline logic, all teams consume it
  ✅ Supports complex approval gates, parallel execution, input steps
  ✅ Plugins for every enterprise tool: JIRA, ServiceNow, Artifactory, Nexus
  ❌ Infrastructure overhead — you operate it
  ❌ Groovy DSL learning curve
  ❌ Plugin compatibility management
```

**The rule of thumb:**
- Startup / cloud-native / small team → GitHub Actions
- Enterprise / regulated / large org / air-gapped → Jenkins

This project is the enterprise Jenkins pattern — the one you find in Fortune 500 companies.

---

## The Problem With "Standard" Jenkins

Most Jenkins setups fail in one of these ways:

```
Problem 1 — The Snowflake Server
  Jenkins installed on a VM in 2018.
  Config changed by clicking in the UI.
  Nobody knows what plugins are installed or why.
  Disaster recovery: "restore from the VM snapshot and pray."
  → Solved by: JCasC + Kubernetes + Git as source of truth

Problem 2 — Idle Agent VMs
  5 permanent agent VMs running 24/7.
  Each costs $200/month = $1200/month idle most of the time.
  Can't scale when 50 jobs queue simultaneously.
  → Solved by: Kubernetes agents — spin up on demand, die after job

Problem 3 — Credentials in Plain Text
  AWS_ACCESS_KEY stored in Jenkins credential store.
  Rotated never. Audited never.
  Anyone with Jenkins admin access can read them.
  → Solved by: IRSA (no static keys) + Secrets Manager integration

Problem 4 — Copy-Paste Jenkinsfiles
  50 microservices, 50 slightly different Jenkinsfiles.
  One security fix = 50 PRs.
  → Solved by: Shared Library — one change propagates to all pipelines

Problem 5 — No Reproducibility
  Jenkins broke after a plugin auto-updated.
  Cannot reproduce the exact build environment from 6 months ago.
  → Solved by: Pinned plugin versions + JCasC + immutable agent images

Problem 6 — No HA
  Jenkins controller on a single VM.
  VM goes down = all CI/CD stops.
  → Solved by: StatefulSet on Kubernetes + EFS (survives pod restarts)
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        EKS Cluster                                   │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  jenkins namespace                                           │    │
│  │                                                              │    │
│  │  ┌─────────────────────────┐                                │    │
│  │  │  Jenkins Controller     │  ← StatefulSet (1 replica)     │    │
│  │  │  (JCasC configured)     │    EFS-backed PVC              │    │
│  │  │                         │    Config loaded from Git      │    │
│  │  │  Port 8080 (UI)         │                                │    │
│  │  │  Port 50000 (agent)     │                                │    │
│  │  └──────────┬──────────────┘                                │    │
│  │             │ spawns                                         │    │
│  │             ▼                                                │    │
│  │  ┌─────────────────────────┐                                │    │
│  │  │  Jenkins Agent Pods     │  ← Ephemeral (born, run, die) │    │
│  │  │  (one per pipeline run) │    IRSA ServiceAccount         │    │
│  │  │                         │    No static AWS keys          │    │
│  │  │  Containers:            │                                │    │
│  │  │  - jnlp (agent)         │                                │    │
│  │  │  - build (node/java/go) │                                │    │
│  │  │  - kaniko (image build) │                                │    │
│  │  │  - trivy (scan)         │                                │    │
│  │  └─────────────────────────┘                                │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  External access                                             │    │
│  │  ALB Ingress → jenkins.company.com (TLS, OIDC auth)         │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘

External integrations:
  GitHub       → Webhooks trigger pipelines
  ECR          → Docker image registry (IRSA auth)
  S3           → Build artifacts + Jenkins home backup
  Secrets Mgr  → Credentials injected at runtime
  ArgoCD       → Pipelines trigger ArgoCD sync for deployment
  Slack        → Build notifications
  Grafana      → Jenkins metrics (job duration, queue depth, agent count)
```

---

## Jenkins on Kubernetes — How It Works

### Controller (StatefulSet)

```
Why StatefulSet, not Deployment?
  - Stable Pod name: jenkins-0 (predictable hostname)
  - Ordered startup/shutdown (important for config loading)
  - PVC stays attached across restarts (job history preserved)

Storage:
  - Jenkins home: EFS (Elastic File System)
  - Why EFS and not EBS?
    EBS: bound to one AZ — if controller restarts in another AZ, can't attach
    EFS: multi-AZ, available everywhere in the region
    Trade-off: EFS is slower than EBS for random I/O
    Acceptable: Jenkins home is mostly config files and build logs, not DB writes
```

### Agents (Kubernetes Cloud Plugin)

```
Lifecycle of one pipeline run:

1. Developer pushes to GitHub
2. GitHub webhook fires → Jenkins controller
3. Controller schedules a job
4. Kubernetes Cloud plugin calls k8s API: create Pod
5. Pod starts with containers: jnlp + build + kaniko + trivy
6. jnlp container connects back to controller on port 50000
7. Pipeline runs inside the Pod
8. Pod is deleted when pipeline completes (success or failure)

Benefits:
  - No persistent agents to patch/maintain
  - Each build gets a clean environment
  - Scales automatically — no queue if nodes have capacity
  - Karpenter provisions new nodes if Pod can't be scheduled
  - Costs zero when idle (no agent Pods running)
```

---

## Jenkins Configuration as Code (JCasC)

```
What is JCasC?
  The Jenkins Configuration as Code plugin reads a YAML file at startup
  and configures ALL of Jenkins from it:
  - Admin password (from env var, not hardcoded)
  - GitHub OAuth credentials
  - Kubernetes cloud config
  - Agent pod templates
  - Global tools (JDK, Maven, NodeJS versions)
  - Security matrix (who can do what)
  - Shared Library registration

Why it matters:
  - Destroy Jenkins, redeploy, apply JCasC → identical Jenkins in 3 minutes
  - All changes in Git — auditable, reviewable, reversible
  - Zero manual UI configuration
  - Zero "I don't know how this was set up" problems
```

---

## Shared Library Architecture

```
Problem: 50 microservices, 50 Jenkinsfiles
If every team writes their own Jenkinsfile:
  - Security scan logic: 50 copies
  - ECR push logic: 50 copies
  - Slack notification: 50 copies
  - One security fix = 50 PRs

Solution: Shared Library
  Shared Library is a Git repository of Groovy functions.
  Registered in JCasC once.
  Every Jenkinsfile imports it with: @Library('company-pipeline-lib')

  Platform team owns: jenkins-shared-library repo
    vars/buildImage.groovy    ← buildImage(...)
    vars/runTests.groovy      ← runTests(...)
    vars/deployToEKS.groovy   ← deployToEKS(...)
    vars/securityScan.groovy  ← securityScan(...)
    vars/notifySlack.groovy   ← notifySlack(...)

  Application team Jenkinsfile (30 lines):
    @Library('company-pipeline-lib') _
    pipeline {
      stages {
        stage('Build')  { steps { buildImage(...) } }
        stage('Test')   { steps { runTests(...) } }
        stage('Scan')   { steps { securityScan(...) } }
        stage('Deploy') { steps { deployToEKS(...) } }
      }
    }

  Platform team fixes a security scan bug → one commit → all 50 pipelines updated
```

---

## Credential Management — No Static Keys

```
The wrong way (unfortunately common):
  AWS_ACCESS_KEY_ID=AKIAXXXXXXXX stored in Jenkins credentials
  Rotated never. Leaked in build logs accidentally. Never audited.

The right way (this project):

  Pattern 1 — IRSA for AWS (no keys at all)
    Jenkins agent Pod has a ServiceAccount annotated with IAM role ARN
    Pod gets short-lived token from AWS STS (auto-rotated every 15 min)
    No key to leak, no key to rotate, no key to store

  Pattern 2 — Secrets Manager for everything else
    GitHub token, Slack webhook, SonarQube token
    Stored in AWS Secrets Manager
    Jenkins reads them at pipeline runtime via AWS CLI / aws-secrets-manager plugin
    Never stored on Jenkins disk

  Pattern 3 — Kubernetes Secrets for in-cluster creds
    Sealed Secrets (from Project 4) for cluster-internal credentials
    Jenkins agent mounts them as env vars via pod template

  Audit trail:
    Every credential access logged in CloudTrail (Secrets Manager)
    Every credential use logged in Jenkins audit log
    No engineer needs to know the actual secret value
```

---

## Pipeline Security Model

```
Groovy Sandbox:
  All Jenkinsfile code runs inside a Groovy sandbox by default.
  Dangerous methods (System.exec, file write outside workspace) are blocked.
  Must be explicitly approved by Jenkins admin.
  Prevents malicious Jenkinsfiles from escaping the agent.

Script Approval:
  Non-sandboxed scripts require admin approval before running.
  Approval stored in Jenkins config (JCasC-manageable).
  Prevents unauthorized code execution.

Agent ↔ Controller separation:
  Pipeline code runs on agents, NOT on the controller.
  Controller is the brain, agents are the hands.
  Even if an agent is compromised, the controller is not directly affected.
  NetworkPolicy: agents can only talk to controller on port 50000.

Kaniko instead of Docker socket:
  Building Docker images without mounting the Docker socket.
  Docker socket mount = container escape vector (full host access).
  Kaniko builds images inside a container with no privileged access.
  Runs as non-root. No host filesystem access.
```

---

## Plugin Strategy

```
Pinned versions (plugins.txt):
  Every plugin listed with an exact version.
  Committed to Git.
  Docker image built with: jenkins-plugin-cli --plugin-file plugins.txt

Why pinning matters:
  Jenkins has 1800+ plugins.
  Auto-updates break pipelines regularly.
  Pinning = reproducible Jenkins.
  Upgrade process:
    1. Update version in plugins.txt
    2. Build new Jenkins image
    3. Deploy to staging Jenkins first
    4. Run test pipelines
    5. Promote to production

Core plugins in this stack:
  kubernetes          — agent pod orchestration
  configuration-as-code — JCasC
  job-dsl             — seed job pattern
  workflow-aggregator — Pipeline support
  git                 — Git SCM
  github              — GitHub webhooks + OAuth
  amazon-ecr          — ECR authentication
  aws-credentials     — AWS credential binding
  pipeline-aws        — AWS Pipeline steps
  blueocean           — Modern pipeline UI
  audit-trail         — Audit logging
  role-strategy       — RBAC
  credentials-binding — Secret injection into env vars
  slack               — Slack notifications
  sonar               — SonarQube integration
  docker-workflow     — Docker pipeline steps
  timestamper         — Timestamps in build logs
  build-timeout       — Kill stuck builds
  throttle-concurrents — Rate limit concurrent jobs
```

---

## HA and Disaster Recovery

```
Single controller limitation:
  Jenkins does not support active-active HA (CloudBees does, OSS doesn't).
  Single controller = single point of failure.

Mitigation strategy (production OSS Jenkins):

  1. Kubernetes restarts the controller if it crashes (self-healing)
     - StatefulSet ensures it comes back as jenkins-0
     - EFS PVC reattaches — all job history preserved
     - Typical recovery time: 60-90 seconds

  2. Nightly backup to S3
     - Jenkins home directory (config, job history, credentials)
     - Restore tested in DR drill quarterly
     - Recovery time from backup: ~10 minutes

  3. JCasC reconstruction
     - If everything is lost: redeploy controller, apply JCasC
     - All jobs recreated from seed job (Job DSL)
     - Recovery time from scratch: ~5 minutes
     - Only loss: build history (acceptable — build again)

  4. Plugin image is immutable
     - jenkins-controller:1.2.3 image contains exact plugins
     - Can recreate any historical Jenkins version

CloudBees (commercial) provides:
  - Active-Active HA with no downtime
  - Hibernation (controller sleeps when idle)
  - Operations Center for multi-controller management
  If OSS HA is a hard requirement, evaluate CloudBees.
```

---

## Integration with Previous Projects

```
Project 1 (aws-eks-migration):
  - Jenkins deploys to the EKS cluster from Project 1
  - Uses the same ECR registry
  - Uses the same RDS and ElastiCache endpoints
  - Jenkins IRSA role can describe EKS cluster

Project 2 (argocd-multicluster):
  - Jenkins does NOT run kubectl — it calls ArgoCD API
  - Pipeline: build image → push to ECR → update image tag in Git → ArgoCD syncs
  - Keeps GitOps contract: cluster state always matches Git
  - ArgoCD handles rollout, Jenkins handles build + image push only

Project 3 (observability):
  - Jenkins controller exposes Prometheus metrics (/prometheus endpoint)
  - Metrics: job_duration_seconds, executor_count, queue_length, build_result
  - Grafana dashboard for Jenkins health
  - Alerts: queue depth > 10 for 5 min (agents not scaling), build failure rate > 20%

Project 4 (kubernetes-security):
  - Jenkins agent Pods subject to Kyverno policies (must have resource limits)
  - Agent Pods subject to Pod Security Admission (restricted profile)
  - Sealed Secrets used for in-cluster Jenkins credentials
  - Falco monitors Jenkins namespace for suspicious activity
  - Trivy scan runs inside the pipeline as a stage (image scanning)
  - Cosign signs images inside the pipeline — Kyverno verifies at deploy time
```

---

## Build Pipeline — Full Flow

```
Trigger: git push to feature branch / PR / main

Stage 1: Checkout
  - Clone repo
  - Set build version: semver from git tag or commit SHA

Stage 2: [PARALLEL — all 3 run simultaneously]
  - Unit tests (Jest/JUnit/pytest — depends on language)
  - Lint (ESLint / golangci-lint / checkstyle)
  - SAST (Semgrep — static analysis, finds security bugs in code)

Stage 3: Build image
  - Kaniko builds Docker image (no Docker socket)
  - Multi-stage Dockerfile (minimal runtime image)
  - Image tagged: ECR_REGISTRY/myapp:git-SHA

Stage 4: Image security scan
  - Trivy scans the built image
  - CRITICAL vulnerabilities → pipeline FAILS (no deployment)
  - HIGH vulnerabilities → pipeline WARNS (logged, allowed)
  - Results stored as Jenkins artifact

Stage 5: Sign image
  - Cosign signs the image with a keyless signature (OIDC)
  - Signature stored in ECR alongside the image
  - Kyverno policy (Project 4) verifies signature at deploy time

Stage 6: Push to ECR
  - IRSA auth — no AWS keys needed
  - Push image:SHA and image:latest (latest only on main branch)

Stage 7: Deploy to dev
  - Update image tag in GitOps repo (kustomization.yaml)
  - ArgoCD auto-syncs within 3 minutes
  - Integration tests run against dev endpoint

Stage 8: Deploy to staging (main branch only)
  - ArgoCD sync triggered via API call
  - Smoke tests run against staging endpoint
  - Performance baseline check (p95 < 500ms)

Stage 9: Manual approval gate (prod only)
  - Jenkins input step: "Approve deployment to production?"
  - Timeout: 24 hours (then auto-cancel)
  - Approver logged in audit trail

Stage 10: Deploy to prod
  - ArgoCD sync triggered (canary rollout — from Project 2)
  - Rollout monitored by AnalysisTemplate (from Project 2)
  - Slack notification: success / failure / rollback

Total pipeline time (parallel stages): ~8-12 minutes
```

---

## Metrics and Alerting

```
Jenkins exposes Prometheus metrics at: http://jenkins:8080/prometheus

Key metrics to track:

  jenkins_builds_duration_milliseconds_summary
    → p50/p95/p99 build duration
    → Alert if p95 > 20 minutes

  jenkins_executor_count_value
    → How many executors (agents) are active
    → Alert if 0 for > 5 minutes during business hours

  jenkins_queue_size_value
    → How many jobs are waiting for an agent
    → Alert if > 10 for > 5 minutes (Karpenter not scaling fast enough)

  jenkins_builds_failed_build_count_total
    → Build failure rate
    → Alert if > 30% failure rate in 30 minutes

Grafana dashboard (included):
  - Build success / failure rate (last 7 days)
  - Average build duration per job
  - Agent utilisation (executors used vs available)
  - Queue depth over time
  - Slowest jobs (p95 build time)
```

---

## Security Posture

```
Attack surface reduction:
  ✅ Jenkins UI not publicly accessible (internal ALB or VPN only)
  ✅ No local Jenkins users (GitHub SSO / OIDC only)
  ✅ No static AWS keys (IRSA)
  ✅ Groovy sandbox enforced
  ✅ Agent ↔ Controller network isolation (NetworkPolicy)
  ✅ Kaniko (no Docker socket mount)
  ✅ Agent Pods run as non-root
  ✅ Agent Pods have resource limits (Kyverno enforced)
  ✅ Audit log enabled (who did what, when)
  ✅ Secrets never in Jenkinsfile or logs (credentialsBinding)
  ✅ Image signing (Cosign) — deployed images are verified
  ✅ Trivy scan gates deployment (CRITICAL CVEs block pipeline)

Residual risks (document honestly):
  ⚠️  Single controller = single point of failure (mitigated by Kubernetes + EFS)
  ⚠️  Groovy sandbox can be bypassed by script approval (admin must be careful)
  ⚠️  Plugin supply chain risk (mitigated by pinned versions + image scanning)
  ⚠️  Build logs may contain sensitive output if engineers print secrets
       → Mitigated by: credential masking plugin + log review in audit
```
