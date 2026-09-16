# Why Jenkins on Kubernetes

> The question every reviewer asks. The honest answer.

---

## The Short Answer

Jenkins is in 44% of enterprise CI/CD pipelines (JetBrains Developer Survey 2023).
Most of them run it wrong — a single VM, manually configured, always-on agents, no audit trail.

This project shows how to run it right.

---

## Problem 1 — Traditional Jenkins Wastes Money

```
Standard setup at most companies:

  5 permanent agent VMs
  Each: 4 vCPU, 8GB RAM, ~$200/month
  Total: $1,200/month

  Actual utilisation: 20% of the day (builds happen during business hours)
  Actual cost of idle time: ~$960/month wasted

  And when 50 developers push at 9am on Monday?
  Builds queue. Engineers wait. Trust in CI erodes.
  The 5 agents can't scale to handle bursts.
```

**Kubernetes pods fix this completely:**

```
  0 pods when no builds are running     → zero cost
  50 pods when 50 builds are queued    → Karpenter provisions nodes
  0 pods again when builds finish      → nodes drain and terminate

  Cost: proportional to actual usage
  Parallelism: limited only by cluster capacity, not a fixed VM count
```

---

## Problem 2 — Traditional Jenkins is a Snowflake

```
The most common Jenkins setup in 2024:

  Jenkins installed on a VM in 2018.
  Configuration changed by clicking in the UI.
  Nobody knows what plugins are installed or why.
  One engineer who "knows Jenkins" left the company in 2021.
  
  Disaster recovery plan: "restore the VM snapshot and pray"
  Last tested: never

  What happens when it goes down:
    - All CI/CD stops
    - Engineers can't deploy
    - On-call scrambles
    - Recovery: 2-4 hours minimum
```

**JCasC (Jenkins Configuration as Code) fixes this:**

```
  Entire Jenkins configuration lives in a YAML file in Git.
  
  Destroy Jenkins completely.
  Redeploy the StatefulSet.
  ConfigMap loads the JCasC YAML at startup.
  
  Recovery time: 60-90 seconds.
  Configuration: identical to before.
  Audit trail: every change is a Git commit with a reviewer.
  
  The engineer who "knows Jenkins" can leave.
  The knowledge lives in the repo.
```

---

## Problem 3 — Traditional Jenkins Has No Security Model

```
How credentials work on most Jenkins setups:

  AWS_ACCESS_KEY_ID = AKIAXXXXXXXXXXXXXXXX
  Stored in: Jenkins Credentials store (encrypted on disk)
  Rotated: never
  Last audited: never
  Who can read it: anyone with Jenkins admin access
  
  GitHub token: personal token from an engineer's account
  That engineer left 8 months ago.
  Token still works.
  Nobody noticed.
```

**IRSA + Secrets Manager fixes this:**

```
  AWS access:
    Agent pod has a ServiceAccount annotated with an IAM role ARN.
    AWS STS issues a short-lived token (15 min TTL) automatically.
    No AWS_ACCESS_KEY_ID exists anywhere.
    Nothing to rotate. Nothing to leak. Nothing to audit.

  Everything else (GitHub token, Slack, SonarQube):
    Stored in AWS Secrets Manager.
    Accessed by IRSA at runtime — never stored on Jenkins disk.
    Every access logged in CloudTrail.
    Engineer doesn't need to know the actual value.
```

---

## Problem 4 — Traditional Jenkins Has Copy-Paste Pipelines

```
The org has 50 microservices.
Each has a Jenkinsfile written by the team that owns it.

Over 3 years:
  - 50 slightly different ways to build a Docker image
  - 30 different ways to push to ECR
  - 12 different Slack notification formats
  - 8 different ways to handle test failures

A security team mandates: "all pipelines must scan images with Trivy."
Result: 50 PRs.
Some teams do it wrong.
Nobody verifies all 50.
3 pipelines never get updated.

When the vulnerability is found: nobody knows which pipelines are compliant.
```

**Shared Library fixes this:**

```
  Platform team owns one repo: jenkins-shared-library
  It contains:
    buildImage()    — one correct way to build with Kaniko
    runTests()      — one correct way to run and report tests
    securityScan()  — Trivy scan with CRITICAL gate
    signImage()     — Cosign image signing
    deployToEKS()   — ArgoCD GitOps deployment
    notifySlack()   — consistent notification format

  Every service Jenkinsfile is ~30 lines:
    @Library('company-pipeline-lib') _
    pipeline {
      stages {
        stage('Build')  { steps { buildImage(...) } }
        stage('Test')   { steps { runTests(...) } }
        stage('Scan')   { steps { securityScan(...) } }
        stage('Deploy') { steps { deployToEKS(...) } }
      }
    }

  Security mandate: add Trivy? One commit in the library.
  All 50 pipelines get it. Automatically. Next build.
```

---

## Why Not Just Use GitHub Actions?

This is the right question. Here is the honest answer.

```
GitHub Actions is the correct choice for:
  ✅ New projects, greenfield, cloud-native
  ✅ Open source projects
  ✅ Small to mid-size engineering teams
  ✅ Teams without compliance audit requirements
  ✅ When you want zero infrastructure to manage

Jenkins on Kubernetes is what you find in:
  ✅ Banks, insurance companies, telecoms
  ✅ Air-gapped environments (no internet access — regulated industries)
  ✅ SOC2 / PCI-DSS / HIPAA environments
       → Jenkins audit trail: every action, every approval, every config change
       → GitHub Actions: limited audit logging, stored externally
  ✅ Orgs with 50+ services and a centralised Platform team
       → Shared Library: platform owns the pipeline, teams just call functions
       → GitHub Actions: each repo manages its own workflows
  ✅ Complex multi-stage approval workflows
       → Jenkins input step: blocks pipeline, records who approved, logs identity
       → GitHub Actions: environment protection rules are simpler but less flexible
  ✅ When you need to run builds on your own hardware or private network
       → Self-hosted runners exist but are operationally heavier than Jenkins agents
```

**The market reality:**

GitHub Actions is at 56% adoption and growing.
Jenkins is at 44% adoption and declining slowly.

But "declining slowly" in a 44% market share means hundreds of thousands of production Jenkins instances will still be running in 2027. The enterprise doesn't move fast.

**If you only know GitHub Actions:**
You can work at a startup or a mid-size cloud-native company.

**If you also know Jenkins at production depth:**
You can walk into any large enterprise on day one and understand
what's running, what's broken, and how to fix it.
That is a different job level.

---

## Why This Specific Stack

```
Jenkins StatefulSet      — stable pod name, PVC survives restarts
EFS (not EBS)            — multi-AZ, Jenkins home available on any node
JCasC                    — zero manual UI config, entire state in Git
Kubernetes agents        — ephemeral pods, zero idle cost, clean per-build env
Kaniko (not Docker)      — no Docker socket, no privileged containers
IRSA (not access keys)   — short-lived tokens, nothing to rotate or leak
Shared Library           — platform team owns the pipeline contract
Pinned plugins           — reproducible, no surprise breakage on Fridays
ArgoCD integration       — Jenkins builds, ArgoCD deploys (GitOps contract)
Trivy + Cosign           — every image scanned and signed before deploy
```

Every choice solves a specific real problem.
None of it is complexity for its own sake.

---

## What This Project Proves

```
Anyone can install Jenkins.
This project shows you understand:

  → Why the standard Jenkins setup fails at scale
  → How to make it reproducible, recoverable, and auditable
  → How to remove every static credential from the system
  → How to scale build capacity without scaling cost linearly
  → How to own the pipeline contract for an entire organisation
  → How to integrate CI into a GitOps workflow without breaking it

That is what Platform Engineering and Senior DevOps roles require.
```
