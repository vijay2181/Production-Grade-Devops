# Jenkins Production — What We Got Right and What's Next

> A self-audit of every production pattern in this project.
> Use this to explain the setup in interviews or code reviews.

---

## The Standard

Production Jenkins is not about installing Jenkins.
It is about every decision that makes it safe, reproducible,
auditable, and operable by a team — not just the person who built it.

Eight patterns separate production Jenkins from tutorial Jenkins.
This project implements all eight correctly.

---

## Pattern 1 — No Docker Socket ✅

**The wrong way (what most tutorials show):**

```yaml
volumeMounts:
  - mountPath: /var/run/docker.sock
    name: docker-sock
```

Mounting the Docker socket gives the container full root access to the
host node. Every container on that node is now compromised. Every
security tool — Falco, Kyverno, Pod Security Admission — flags this
immediately. It is the #1 thing security auditors find in Jenkins setups.

**What we do instead:**

Kaniko builds Docker images inside a container with no socket,
no privileged mode, and no host filesystem access.

```yaml
containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:v1.21.0-debug
    # No privileged: true
    # No hostPath volumes
    # No /var/run/docker.sock
```

File: `jcasc/jenkins.yaml` → pod templates → kaniko container

---

## Pattern 2 — No Static AWS Keys ✅

**The wrong way:**

```yaml
env:
  - name: AWS_ACCESS_KEY_ID
    value: AKIAXXXXXXXXXXXXXXXX   # rotated never, leaked often
  - name: AWS_SECRET_ACCESS_KEY
    value: abc123...
```

Static keys stored in Jenkins never get rotated. They leak in build
logs when an engineer accidentally prints them. They persist after the
engineer who created them leaves the company.

**What we do instead:**

IRSA (IAM Roles for Service Accounts). The agent pod ServiceAccount
is annotated with an IAM role ARN. AWS STS issues a 15-minute token
automatically. Nothing to store, nothing to rotate, nothing to leak.

```yaml
# kubernetes/agents/serviceaccount.yaml
annotations:
  eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/jenkins-agent-irsa"
```

Verify it works:
```bash
kubectl exec -it <agent-pod> -n jenkins -- aws sts get-caller-identity
# Returns the IRSA role — no access key in env vars
```

File: `kubernetes/agents/serviceaccount.yaml`, `terraform/environments/prod/main.tf`

---

## Pattern 3 — Ephemeral Agents ✅

**The wrong way:**

```
5 permanent VMs running 24/7
Cost: $1,200/month
Utilisation: 20% (builds only happen during business hours)
Waste: $960/month

When 50 developers push at 9am:
  Builds queue behind 5 agent slots
  Engineers wait 20 minutes
  Trust in CI erodes
```

**What we do instead:**

Kubernetes pod agents. Zero pods when no builds run. N pods when N
builds are queued. Karpenter provisions new nodes automatically.
Pod dies when the job ends — clean environment for every build.

```yaml
# jcasc/jenkins.yaml → clouds → kubernetes
containerCap: 50          # max concurrent agent pods
idleMinutes: 0            # kill pod immediately when job ends
```

File: `jcasc/jenkins.yaml` → pod templates

---

## Pattern 4 — Jenkins Config Is Code ✅

**The wrong way:**

```
Jenkins installed on a VM in 2018.
Configuration changed by clicking in the UI.
Stored in config.xml on the VM's disk.
The engineer who "knows Jenkins" left in 2021.

Disaster recovery:
  "restore the VM snapshot and pray"
  Last tested: never
  Recovery time: 2-4 hours
  Result: unknown state
```

**What we do instead:**

JCasC (Jenkins Configuration as Code). The entire Jenkins
configuration — auth, clouds, agents, credentials, libraries,
notifications — lives in `jcasc/jenkins.yaml` in Git.

```
Destroy Jenkins completely.
Redeploy the StatefulSet.
ConfigMap loads jcasc/jenkins.yaml at startup.
Recovery time: 60-90 seconds.
Configuration: identical to before.
Every change: a Git commit with a reviewer.
```

File: `jcasc/jenkins.yaml`, `jcasc/credentials.yaml`

---

## Pattern 5 — Pipelines Never Run kubectl ✅

**The wrong way:**

```groovy
stage('Deploy') {
  steps {
    sh 'kubectl apply -f manifests/'
    // Bypasses ArgoCD entirely
    // ArgoCD sees drift and reverts the change
    // Cluster state no longer matches Git
    // GitOps contract broken
  }
}
```

**What we do instead:**

`deployToEKS.groovy` in the Shared Library:

```
Step 1: Clone GitOps repo
Step 2: kustomize edit set image myapp=ECR/myapp:SHA
Step 3: git commit + push
Step 4: POST /api/v1/applications/myapp-prod/sync  (ArgoCD API)
Step 5: Poll until health.status == Healthy AND sync.status == Synced
```

Jenkins builds and pushes the image.
ArgoCD owns the cluster state. Always.
No kubeconfig stored in Jenkins.
No kubectl in agent pods.

File: `pipelines/shared-library/vars/deployToEKS.groovy`

---

## Pattern 6 — Plugins Are Pinned ✅

**The wrong way:**

```dockerfile
FROM jenkins/jenkins:lts-jdk17
# Plugins auto-update to whatever is latest
# Plugin X breaks on a Friday afternoon
# Nobody knows which version was running before
# Rollback: not possible
```

**What we do instead:**

Every plugin pinned to an exact version in `plugins/plugins.txt`.
Baked into the Docker image at build time — not downloaded at runtime.

```
kubernetes:4029.v5712230ccb_f8
configuration-as-code:1810.v9b_c30a_249a_4c
workflow-aggregator:596.v8c21c963d92d
... (all 40+ plugins pinned)
```

Upgrade process:
```
1. Update version in plugins.txt
2. Build new image: jenkins-controller:NEW_VERSION
3. Deploy to staging Jenkins
4. Run test pipelines
5. If green: deploy to production
6. Keep old image tag for instant rollback
```

File: `plugins/plugins.txt`, `docker/Dockerfile`

---

## Pattern 7 — Security Context on Every Agent Pod ✅

**The wrong way:**

```yaml
containers:
  - name: build
    image: node:20
    # No securityContext
    # Runs as root (UID 0)
    # Full Linux capabilities
    # No seccomp profile
```

**What we do instead:**

Every agent pod template in JCasC has a full security context:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
containers:
  - securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
```

The jenkins namespace has PSA labels set to `restricted`.
Kyverno policies from Project 4 enforce resource limits.
Falco monitors the namespace for suspicious activity.

File: `jcasc/jenkins.yaml` → pod templates → yaml block,
      `kubernetes/namespace.yaml`

---

## Pattern 8 — Credentials Never Touch Jenkins Disk ✅

**The wrong way:**

```
Jenkins Credentials store:
  id: github-token
  secret: ghp_XXXXXXXXXXXXXXXXXX   (encrypted on disk)

Accessible to: anyone with Jenkins admin access
Rotated: when someone remembers
Audited: never
What happens when admin account is compromised: everything is exposed
```

**What we do instead:**

```
AWS access:
  IRSA — no credential object exists at all
  STS token issued automatically, expires in 15 minutes

Everything else (GitHub, Slack, SonarQube, ArgoCD, Cosign):
  Stored in AWS Secrets Manager under jenkins/* prefix
  Read by controller at startup via IRSA
  Injected as env vars into running pods
  Never written to /var/jenkins_home
  Every access logged in CloudTrail with timestamp + caller identity
```

File: `jcasc/credentials.yaml`, `terraform/environments/prod/main.tf`

---

## Honest Gaps — What's Not Here Yet

These are extensions, not mistakes in the current setup.
The foundation is correct. These make it more complete.

### Gap 1 — KinD in Pod (Helm chart isolation testing)

```
Current state:
  Helm chart is tested by deploying to dev cluster
  If the chart is broken, dev environment breaks

Missing:
  testInKinD() Shared Library function
  Spins up a KinD cluster inside the agent pod
  Deploys the Helm chart into it
  Runs integration tests against it
  Pod dies → cluster gone → zero cleanup
  The real dev cluster is never touched for testing

Why it matters:
  "Does my Helm chart actually install?" is answered
  before the pipeline touches any real environment
```

### Gap 2 — Build Cache Persistence

```
Current state:
  npm ci downloads all packages fresh on every build
  Typical Node.js build: 8-12 minutes
  Most of that time: downloading node_modules

Missing:
  PVC mounted into agent pods for npm/Maven/Go cache
  Build time on cache hit: 2-3 minutes
  Build time on cache miss: same as now

Why it matters:
  Developer feedback loop is directly tied to build speed
  A 10-minute build kills developer flow
  A 2-minute build feels instant
```

### Gap 3 — Golden Path Pipeline Template

```
Current state:
  pipelines/myapp/Jenkinsfile exists (fully working)
  New services have no template to start from

Missing:
  pipelines/templates/microservice.Jenkinsfile
  The document platform team points new teams to
  "Copy this, change APP_NAME and GITOPS_REPO, done"

Why it matters:
  This is what makes the Shared Library real in an org
  Without a template, teams write their own Jenkinsfiles
  With a template, adoption takes 5 minutes
```

### Gap 4 — Parallel Multi-Cluster Deploy

```
Current state:
  deploy to dev → staging → prod sequentially

Missing:
  deploy to dev-us-east-1 and dev-eu-west-1 in parallel
  (uses Project 2's multi-cluster ArgoCD setup)

Why it matters:
  Production runs in multiple regions
  Sequential deploys mean one region is always behind
  Parallel deploys cut total deployment time in half
```

---

## Summary

```
8 production patterns implemented correctly:

  ✅ No Docker socket (Kaniko)
  ✅ No static AWS keys (IRSA)
  ✅ Ephemeral agents (Kubernetes pods)
  ✅ Config as code (JCasC)
  ✅ No kubectl in pipelines (ArgoCD GitOps)
  ✅ Pinned plugins (reproducible image)
  ✅ Security context on every pod (non-root, no caps)
  ✅ Credentials never on Jenkins disk (Secrets Manager)

4 extensions to add next:

  [ ] KinD in pod (Helm chart isolation testing)
  [ ] Build cache PVC (faster builds)
  [ ] Golden path template (platform adoption)
  [ ] Parallel multi-cluster deploy (Project 2 integration)
```

This is what separates a Jenkins setup that works from one that
is safe to hand to a team of 50 engineers and walk away from.
