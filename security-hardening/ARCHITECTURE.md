# Kubernetes Security Hardening — Production Grade

> **Project 4** | Builds on: Projects 1 + 2 + 3
> Stack: Falco · OPA Gatekeeper · Kyverno · Trivy Operator · Sealed Secrets · Pod Security Admission · IRSA · CIS Benchmark

---

## Why Security?

### The Reality

```
Most Kubernetes clusters are deployed insecure by default.
The default settings allow:
  - Containers running as root
  - Privileged containers (full host access)
  - Any image from any registry (including malicious ones)
  - Pods reading secrets they don't own
  - Containers writing to their filesystem
  - No network segmentation between pods
  - Static AWS credentials in environment variables
  - Developers deploying to production without approval

None of these are blocked out of the box.
```

### What Happens Without Security Hardening

| Attack Vector | Impact | Real Example |
|---|---|---|
| Container running as root | Escape to host node — full cluster compromise | Tesla cryptomining attack 2018 |
| Latest image tag | Pull malicious image update automatically | Countless supply chain attacks |
| No resource limits | One pod consumes all node CPU/memory — DoS | Happens in every unguarded cluster |
| Static AWS creds in env vars | Leaked → attacker gets full AWS account access | Capital One breach pattern |
| No NetworkPolicy | Compromised pod lateral-moves to DB | Standard attack chain |
| kubectl exec allowed | Developer accidentally deletes production data | Happens regularly |
| No secret encryption | Secrets readable by anyone with Git access | Common misconfiguration |

### The Cost of NOT Doing This

```
Security incident:          $millions (breach notification, legal, downtime)
Compliance failure (SOC2):  Lost enterprise customers
CKS exam:                   Failing without this knowledge
Job interviews:             "How do you secure a Kubernetes cluster?"
```

### Why This Stack Specifically

```
Falco          → DETECT  threats at runtime (cryptominers, shell in container)
OPA Gatekeeper → PREVENT bad configs at admission time (policy as code)
Kyverno        → ENFORCE and AUTO-FIX resource configs (mutation + validation)
Trivy Operator → SCAN running images for CVEs continuously
Sealed Secrets → ENCRYPT secrets so they are safe in Git
Pod Security   → ENFORCE security profiles at namespace level
IRSA           → ELIMINATE static AWS credentials completely
NetworkPolicy  → ISOLATE pods (zero-trust networking)
```

---

## Threat Model

```
Attack Surface              Mitigation
──────────────────────────────────────────────────────────────────
Malicious container image   Trivy Operator scans + blocks CVEs
                            OPA: deny images not from ECR

Container escape to host    Pod Security: restricted profile
                            seccomp RuntimeDefault
                            No privileged containers (OPA)
                            No hostPID/hostNetwork (OPA)

Lateral movement            NetworkPolicy: zero-trust between pods
                            mTLS (Istio — Project 5)

Secret theft                Sealed Secrets: encrypted in Git
                            IRSA: no static credentials
                            External Secrets Operator (Project 1)

Privilege escalation        RBAC: least privilege
                            No allowPrivilegeEscalation (Kyverno)
                            readOnlyRootFilesystem (Kyverno)

Supply chain attack         OPA: only ECR images allowed
                            Trivy: scan on every deploy (CI)
                            Cosign: image signing (bonus)

Runtime attack              Falco: detects shell spawn, file write,
                            network connection, syscall anomalies

Misconfiguration            OPA + Kyverno: block bad YAML at deploy
                            CIS Benchmark: continuous compliance check
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                  PREVENTION LAYER                                │
│                                                                  │
│  Developer submits manifest → Kubernetes API Server             │
│                                     │                           │
│                          ┌──────────▼──────────┐               │
│                          │  Admission Webhooks  │               │
│                          │                      │               │
│                          │  OPA Gatekeeper      │               │
│                          │  (validate — deny    │               │
│                          │   bad configs)       │               │
│                          │                      │               │
│                          │  Kyverno             │               │
│                          │  (mutate — auto-fix  │               │
│                          │   + validate)        │               │
│                          │                      │               │
│                          │  Pod Security        │               │
│                          │  Admission           │               │
│                          └──────────┬───────────┘               │
│                                     │ allowed                   │
│                                     ▼                           │
│                              Pod starts                         │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                  DETECTION LAYER                                 │
│                                                                  │
│  Pod running → Falco (eBPF) watches every syscall               │
│                │                                                 │
│                ├── shell spawned in container → ALERT           │
│                ├── unexpected outbound connection → ALERT       │
│                ├── /etc/passwd read → ALERT                     │
│                ├── cryptominer process detected → ALERT         │
│                └── write to /etc or /bin → ALERT                │
│                                                                  │
│  All images → Trivy Operator scans every 24h                    │
│               → CRITICAL CVE found → alert + ticket             │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                  SECRETS LAYER                                   │
│                                                                  │
│  Git repo → Sealed Secrets (encrypted, safe to commit)          │
│  AWS API  → IRSA (pod identity, no static keys)                 │
│  Secrets Manager → External Secrets Operator (auto-sync)        │
└──────────────────────────────────────────────────────────────────┘
```

---

## Security Layers — What Each Tool Does

### Layer 1: Prevention at Admission (OPA Gatekeeper)
Runs as a ValidatingWebhook. **Blocks** the request before the pod starts.
```
Deny if:  image uses :latest tag
Deny if:  privileged: true
Deny if:  hostPID: true or hostNetwork: true
Deny if:  no resource requests/limits set
Deny if:  image not from approved registry (ECR only)
Deny if:  runAsRoot: true or runAsUser: 0
```

### Layer 2: Auto-fix + Prevention (Kyverno)
Runs as both MutatingWebhook + ValidatingWebhook.
**Mutates** (auto-fixes) resources, then validates.
```
Auto-add: readOnlyRootFilesystem: true
Auto-add: allowPrivilegeEscalation: false
Auto-add: capabilities.drop: [ALL]
Auto-add: required labels (app, team, environment)
Validate: all Deployments have a matching PodDisruptionBudget
Validate: all pods have liveness + readiness probes
```

### Layer 3: Runtime Detection (Falco)
Uses eBPF to watch **every syscall** on every node.
Fires alerts when behaviour deviates from known good patterns.
```
Alert: shell spawned inside container (kubectl exec, reverse shell)
Alert: unexpected write to /etc, /bin, /usr
Alert: process other than node started in myapp containers
Alert: outbound connection to non-whitelisted IP
Alert: /etc/shadow or /etc/passwd read
Alert: container privilege escalation attempt
```

### Layer 4: Continuous CVE Scanning (Trivy Operator)
Scans every running image in the cluster every 24 hours.
Results stored as Kubernetes CRDs — queryable with kubectl.
```
kubectl get vulnerabilityreports -n myapp
kubectl get configauditreports -n myapp
kubectl get exposedsecretreports -n myapp
```

### Layer 5: Secrets (Sealed Secrets + IRSA)
```
Sealed Secrets:
  kubeseal encrypts with cluster public key
  Only the cluster controller can decrypt
  Encrypted YAML is safe to commit to Git

IRSA (IAM Roles for Service Accounts):
  Pod gets an AWS IAM role via projected ServiceAccount token
  No AWS_ACCESS_KEY_ID in environment variables
  Token rotates automatically every hour
  Role scoped to minimum permissions needed
```

### Layer 6: Pod Security Admission
Kubernetes built-in (no extra tools needed).
Enforces security profiles at namespace level.
```
myapp namespace:    enforce=restricted  (strictest)
monitoring:         enforce=baseline
kube-system:        enforce=privileged  (system components need it)
```

---

## CKS Exam Coverage

This project covers ~80% of the CKS (Certified Kubernetes Security Specialist) exam:

```
CKS Domain                          Coverage
────────────────────────────────────────────────────────
Cluster Setup (10%)                 ✅ CIS Benchmark, API server hardening
Cluster Hardening (15%)             ✅ RBAC, ServiceAccount, API restrictions
System Hardening (15%)              ✅ AppArmor, Seccomp, reduce attack surface
Minimise Microservice Attack Surface(20%) ✅ NetworkPolicy, Pod Security, OPA
Supply Chain Security (20%)         ✅ Trivy, image signing, OPA registry rules
Monitoring/Logging/Runtime (20%)    ✅ Falco, audit logs, behavioural analysis
```

---

## Folder Structure

```
kubernetes-security/
├── ARCHITECTURE.md              ← this file
├── README.md                    ← e2e execution steps
├── TESTING-GUIDE.md             ← 10-phase security test guide
├── DIAGRAMS.md                  ← Mermaid diagrams
│
├── falco/
│   ├── install.yaml             ← Falco Helm values (eBPF mode)
│   ├── rules/
│   │   ├── custom-rules.yaml    ← myapp-specific detection rules
│   │   └── macros.yaml          ← reusable rule macros
│   └── alerts/
│       └── falcosidekick.yaml   ← route alerts to Slack/PagerDuty
│
├── gatekeeper/
│   ├── install.yaml             ← OPA Gatekeeper Helm values
│   ├── templates/               ← ConstraintTemplates (policy definitions)
│   │   ├── require-labels.yaml
│   │   ├── deny-latest-tag.yaml
│   │   ├── deny-privileged.yaml
│   │   ├── require-resources.yaml
│   │   ├── allowed-registries.yaml
│   │   └── deny-root-user.yaml
│   └── constraints/             ← Constraints (policy instances)
│       ├── require-labels.yaml
│       ├── deny-latest-tag.yaml
│       ├── deny-privileged.yaml
│       ├── require-resources.yaml
│       ├── allowed-registries.yaml
│       └── deny-root-user.yaml
│
├── kyverno/
│   └── policies/
│       ├── add-security-context.yaml   ← mutate: auto-add securityContext
│       ├── require-probes.yaml         ← validate: liveness + readiness
│       ├── require-pdb.yaml            ← validate: PDB exists per Deployment
│       ├── restrict-image-tag.yaml     ← validate: no latest tag
│       └── add-labels.yaml             ← mutate: auto-add required labels
│
├── trivy/
│   ├── install.yaml             ← Trivy Operator Helm values
│   └── reports/
│       └── vulnerability-dashboard.json ← Grafana dashboard
│
├── sealed-secrets/
│   ├── install.yaml             ← Sealed Secrets controller Helm values
│   ├── example-secret.yaml      ← example SealedSecret CRD
│   └── seal.sh                  ← script to encrypt a secret
│
├── pod-security/
│   └── namespace-labels.yaml    ← Pod Security Admission labels per namespace
│
├── rbac/
│   ├── developer-role.yaml      ← read-only dev access
│   ├── deployer-role.yaml       ← deploy to staging only
│   └── readonly-clusterrole.yaml
│
├── network-policies/
│   └── zero-trust.yaml          ← default-deny + allow only required flows
│
├── irsa/
│   ├── terraform.tf             ← IRSA role + policy for myapp service account
│   └── serviceaccount.yaml      ← annotated ServiceAccount
│
├── scripts/
│   ├── install-security-stack.sh ← install everything in order
│   ├── audit.sh                  ← run kube-bench CIS benchmark
│   ├── scan-images.sh            ← trivy scan all running images
│   └── test-policies.sh          ← test OPA + Kyverno policies
│
└── dashboards/
    └── security-dashboard.json   ← Grafana: CVEs, policy violations, Falco alerts
```

## Real Attack Chains — How Clusters Get Compromised

### Attack Chain 1: Supply Chain → Cryptominer (most common)

```
Step 1: Developer uses image: node:latest
        ↓
Step 2: Attacker poisons node:latest on Docker Hub
        (or typosquats: n0de:latest)
        ↓
Step 3: Next deploy pulls poisoned image
        ↓
Step 4: Container starts — spawns hidden crypto process
        ↓
Step 5: Pod uses 100% CPU → Cluster Autoscaler spins up 20 nodes
        ↓
Step 6: AWS bill: $50,000 in one weekend

PREVENTION:
  OPA blocks :latest tags → can't deploy
  OPA blocks non-ECR images → only your own images
  Trivy scans in CI → malicious image caught before push
  Falco detects crypto process spawning → alert in seconds
```

### Attack Chain 2: Escaped Container → Full Cloud Account Access

```
Step 1: App has a code vulnerability (RCE via Log4Shell, Struts, etc.)
        ↓
Step 2: Attacker executes code inside container
        ↓
Step 3: Container runs as root → easy filesystem access
        ↓
Step 4: /var/run/secrets/kubernetes.io/serviceaccount/token readable
        ↓
Step 5: Token has cluster-admin role (default in many clusters)
        ↓
Step 6: kubectl --token=... get secrets --all-namespaces
        → reads all DB passwords, API keys, AWS credentials
        ↓
Step 7: AWS credentials found → full cloud account access
        → S3 buckets read, RDS accessed, EC2 instances launched
        ↓
Step 8: Data exfiltration / ransomware

PREVENTION:
  Pod Security restricted: no root, no privilege escalation
  RBAC: service account has NO cluster-wide permissions
  IRSA: no static credentials — only temporary STS tokens
  readOnlyRootFilesystem: can't write exploit tools to disk
  NetworkPolicy: container can't reach Kubernetes API
  Falco: alerts on token file read + unexpected API calls
```

### Attack Chain 3: Exposed Dashboard → Lateral Movement

```
Step 1: Kubernetes Dashboard deployed with no auth
        (default in many tutorials)
        ↓
Step 2: Dashboard accessible on public NodePort
        ↓
Step 3: Attacker finds it via Shodan/port scan
        ↓
Step 4: Dashboard running with service-account-token
        bound to cluster-admin role
        ↓
Step 5: Attacker deploys a privileged pod:
          privileged: true
          hostPID: true
          hostPath: /
        ↓
Step 6: chroot /host → attacker is now on the host node
        ↓
Step 7: Node has AWS instance role → full EC2 metadata access
        → attacker gets IAM credentials from 169.254.169.254

PREVENTION:
  OPA: deny privileged containers
  OPA: deny hostPID, hostPath mounts
  RBAC: dashboard service account is read-only
  NetworkPolicy: dashboard not accessible from outside
  Pod Security: restricted profile blocks hostPID/hostPath
```

### Attack Chain 4: Developer Mistake → Production Data Loss

```
Step 1: Developer has kubectl access to prod context
        (no RBAC separation between dev and prod)
        ↓
Step 2: Runs: kubectl delete namespace myapp
               (intended for dev cluster)
        ↓
Step 3: Production namespace deleted
        All pods terminated, PVCs deleted
        ↓
Step 4: RDS has deletion protection — data safe
        But recovery takes 2 hours

PREVENTION:
  RBAC: developers have read-only on prod
  Kyverno: deny delete on namespace with label env=prod
  ArgoCD RBAC (Project 2): only release-managers can sync prod
  Namespace annotation: kubectl.kubernetes.io/last-applied-configuration
```

---

## Defence-in-Depth Model

```
Every security layer assumes the previous one has failed.
If OPA fails → Kyverno catches it.
If Kyverno fails → Pod Security blocks it.
If Pod Security fails → Falco detects it at runtime.
If Falco misses it → Trivy finds the CVE.
If all prevention fails → IRSA limits blast radius (no AWS creds).
If IRSA is compromised → NetworkPolicy blocks lateral movement.

LAYER    TOOL              WHEN IT ACTS           FAIL MODE
──────────────────────────────────────────────────────────────────
1        OPA Gatekeeper    At admission (before    False negative:
                           pod starts)             bad policy written

2        Kyverno           At admission            False negative:
         (mutate+validate) (mutate first,          policy gap
                           then validate)

3        Pod Security      At admission            Namespace not
         Admission         (namespace level)       labelled correctly

4        Falco             At runtime              Rule not written
         (eBPF)            (every syscall)         for new attack

5        Trivy Operator    Every 24h               CVE not yet in DB
         (image scan)      (continuous)

6        IRSA              Always                  Role too permissive
         (no static creds) (token-based)

7        NetworkPolicy     At packet level         Policy gap
         (zero-trust)      (every connection)

8        Sealed Secrets    At rest (Git)           Controller compromised
         (encryption)
```

---

## Tool Decision Rationale — Why Not X?

### OPA Gatekeeper vs Kyverno — Why both?

```
OPA Gatekeeper:
  ✅ Rego policy language — very powerful, any complex logic
  ✅ Industry standard — used by Google, HashiCorp, Netflix
  ✅ Constraint Framework — separates policy definitions from instances
  ❌ Steep learning curve (Rego is not intuitive)
  ❌ Mutation support is limited
  ❌ Verbose — 50+ lines for a simple policy

Kyverno:
  ✅ YAML-native — same language as your manifests
  ✅ Mutation + Validation in one tool
  ✅ Auto-generates policies from existing resources
  ✅ ClusterPolicy + Policy (namespace-scoped)
  ❌ Less powerful than Rego for complex logic
  ❌ Smaller ecosystem than OPA

WHY BOTH:
  Use OPA for complex organisational policies (registry allowlists, label schemas)
  Use Kyverno for auto-mutation (add securityContext, add labels)
  They don't conflict — they complement each other
```

### Falco vs eBPF-only solutions

```
Falco:
  ✅ Purpose-built for Kubernetes security
  ✅ 200+ built-in rules covering common attacks
  ✅ eBPF mode (no kernel module needed on EKS)
  ✅ Falcosidekick: routes alerts to Slack/PagerDuty/Elasticsearch
  ✅ CNCF project — vendor neutral
  ❌ Rule writing requires expertise
  ❌ High false positive rate on custom rules

Alternatives:
  Datadog Security → expensive, vendor lock-in
  Aqua Security → expensive enterprise tool
  Sysdig → expensive, but best UI for Falco rules
  Tetragon (Cilium) → newer, more powerful but complex

WHY FALCO: Free, open source, purpose-built, CNCF standard.
```

### Sealed Secrets vs External Secrets Operator

```
Sealed Secrets:
  ✅ Encrypt once, commit to Git — pure GitOps
  ✅ No external dependency at runtime
  ✅ Simple mental model
  ❌ Rotation requires re-sealing + re-committing
  ❌ If cluster is destroyed, old sealed secrets unreadable
     (need to backup the controller key)

External Secrets Operator (already in Project 1):
  ✅ Source of truth is AWS Secrets Manager
  ✅ Automatic rotation (no manual steps)
  ✅ Audit trail in AWS CloudTrail
  ❌ Runtime dependency on Secrets Manager
  ❌ More complex setup

WHY BOTH:
  Use Sealed Secrets for non-rotating secrets (TLS certs, API keys)
  Use ESO for rotating secrets (DB passwords, tokens)
```

---

## Compliance Mapping

### SOC 2 Type II

```
SOC 2 Control          Kubernetes Implementation
──────────────────────────────────────────────────────────────
CC6.1 Logical access   RBAC, namespace isolation, IRSA
CC6.2 Authentication   OIDC + GitHub SSO (ArgoCD RBAC Project 2)
CC6.3 Authorisation    OPA Gatekeeper, Kyverno, Pod Security
CC6.6 Network control  NetworkPolicy zero-trust
CC6.8 Malware          Trivy CVE scanning, Falco runtime detection
CC7.1 Monitoring       Falco alerts, Prometheus, Grafana (Project 3)
CC7.2 Anomaly detect   Falco behavioural detection
CC8.1 Change mgmt      ArgoCD GitOps audit trail (Project 2)
```

### PCI DSS (Payment Card Industry)

```
PCI Requirement        Kubernetes Implementation
──────────────────────────────────────────────────────────────
Req 1: Firewall        NetworkPolicy zero-trust
Req 2: No defaults     OPA: deny default ServiceAccount
Req 6: Secure code     Trivy CVE scan in CI pipeline
Req 7: Need-to-know    RBAC least privilege
Req 8: Identity        IRSA, no shared credentials
Req 10: Logging        Falco + CloudWatch audit logs
Req 11: Testing        kube-bench CIS scan, Trivy
```

### CIS Kubernetes Benchmark

```
The CIS Benchmark has 100+ controls for Kubernetes.
kube-bench (script in this project) tests all of them automatically.

Key controls this project implements:
  1.1  API server: anonymous-auth=false
  1.2  RBAC: --authorization-mode includes RBAC
  2.1  etcd: encryption at rest enabled
  3.1  Controller manager: service account key rotation
  4.1  Worker nodes: kubelet authentication
  5.1  RBAC: no wildcard permissions
  5.2  Pod Security: restricted profile enforced
  5.3  NetworkPolicy: default-deny
  5.4  Secrets: not in environment variables (IRSA)
  5.7  Namespaces: proper isolation
```

---

## Security Posture Score

After implementing everything in this project:

```
BEFORE this project:
  CIS Benchmark score:     ~40% PASS
  RBAC hardening:          FAIL (default service accounts)
  Secret management:       FAIL (base64 in YAML)
  Runtime detection:       FAIL (none)
  Image scanning:          PARTIAL (only in CI)
  Network segmentation:    PARTIAL (basic NetworkPolicy)
  Pod security:            FAIL (running as root)

AFTER this project:
  CIS Benchmark score:     ~85% PASS
  RBAC hardening:          PASS
  Secret management:       PASS (Sealed Secrets + IRSA)
  Runtime detection:       PASS (Falco)
  Image scanning:          PASS (Trivy Operator 24h)
  Network segmentation:    PASS (zero-trust)
  Pod security:            PASS (restricted profile)
```

---

## Links to Projects 1, 2, 3

```
Project 1 (aws-eks-migration):
  + Replace base64 Secrets with SealedSecrets
  + Add IRSA to app ServiceAccount (no static AWS creds)
  + Add OPA policies to block bad Helm chart values
  + Trivy scan in GitHub Actions CI pipeline already exists — extend it

Project 2 (argocd-multicluster):
  + ArgoCD RBAC already done — extend with OPA project-level policies
  + Kyverno: add deny-delete policy on prod namespace
  + Falco rules: alert on ArgoCD sync from unexpected Git branch

Project 3 (observability):
  + Trivy vulnerability reports → Grafana security dashboard
  + Falco alerts → Loki (same log aggregation stack)
  + OPA violations → Prometheus metrics → alert on policy breach rate
```
