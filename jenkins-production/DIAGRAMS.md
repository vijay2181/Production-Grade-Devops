# Jenkins Production — Diagrams

> All diagrams use Mermaid — render natively in GitHub, GitLab, and Notion.

---

## Diagram 1 — Overall Architecture

```mermaid
graph TB
    subgraph Internet
        DEV[Developer]
        GH[GitHub]
    end

    subgraph AWS["AWS — EKS Cluster"]
        subgraph JNS["jenkins namespace"]
            CTRL["Jenkins Controller\n(StatefulSet)"]
            AGENT1["Agent Pod\n(job run 1)"]
            AGENT2["Agent Pod\n(job run 2)"]
            AGENTН["Agent Pod\n(job run N)"]
        end

        subgraph STORAGE["Storage"]
            EFS["EFS\n(Jenkins home)\nmulti-AZ"]
            S3["S3\n(artifacts + backup)"]
        end

        subgraph AUTH["IAM / IRSA"]
            CTRL_ROLE["Controller IAM Role\n(S3 + Secrets Manager)"]
            AGENT_ROLE["Agent IAM Role\n(ECR + S3 + SM)"]
        end

        ECR["ECR\n(Docker registry)"]
        SM["Secrets Manager\n(credentials)"]
        ALB["Internal ALB\n(TLS termination)"]
    end

    subgraph GITOPS["GitOps (ArgoCD — Project 2)"]
        GITOPS_REPO["GitOps Repo\n(kustomization.yaml)"]
        ARGOCD["ArgoCD"]
        CLUSTER["EKS Prod\n(myapp running)"]
    end

    DEV -- "git push" --> GH
    GH -- "webhook" --> ALB
    ALB --> CTRL
    CTRL -- "spawn pod" --> AGENT1
    CTRL -- "spawn pod" --> AGENT2
    CTRL -- "spawn pod" --> AGENTН
    CTRL --- EFS
    CTRL_ROLE --> SM
    CTRL_ROLE --> S3
    AGENT1 -- "ECR push" --> ECR
    AGENT1 -- "update image tag" --> GITOPS_REPO
    AGENT1 -- "trigger sync" --> ARGOCD
    AGENT_ROLE --> ECR
    AGENT_ROLE --> SM
    AGENT_ROLE --> S3
    GITOPS_REPO --> ARGOCD
    ARGOCD --> CLUSTER
```

---

## Diagram 2 — Agent Pod Lifecycle

```mermaid
sequenceDiagram
    participant GH as GitHub
    participant JC as Jenkins Controller
    participant K8S as Kubernetes API
    participant POD as Agent Pod
    participant KANIKO as Kaniko Container
    participant ECR as ECR

    GH->>JC: Webhook (push event)
    JC->>JC: Queue build job

    JC->>K8S: Create Pod (spec from JCasC template)
    K8S->>POD: Start pod (jnlp + build + kaniko + trivy)

    POD->>JC: JNLP connect on port 50000
    JC->>POD: Execute pipeline stages

    Note over POD: Stage: Unit tests
    Note over POD: Stage: Lint + SAST
    Note over POD: Stage: Build (in build container)

    POD->>KANIKO: Build Docker image
    KANIKO->>ECR: Push image (no Docker socket)

    Note over POD: Stage: Trivy scan
    Note over POD: Stage: Sign (cosign)
    Note over POD: Stage: Deploy (update GitOps repo)

    JC->>POD: Pipeline complete
    JC->>K8S: Delete Pod
    K8S->>POD: Terminate all containers

    Note over JC: Build result stored in EFS
    Note over K8S: Zero idle cost when no builds running
```

---

## Diagram 3 — Full CI/CD Pipeline Flow

```mermaid
flowchart TD
    PUSH["git push"] --> WEBHOOK["GitHub Webhook"]
    WEBHOOK --> CHECKOUT["Stage: Checkout"]

    CHECKOUT --> PARALLEL{"PARALLEL"}
    PARALLEL --> TESTS["Unit Tests\n(Jest + JUnit)"]
    PARALLEL --> LINT["Lint\n(ESLint)"]
    PARALLEL --> SAST["SAST\n(Semgrep)"]

    TESTS --> BUILD["Stage: Build Image\n(Kaniko — no Docker socket)"]
    LINT --> BUILD
    SAST --> BUILD

    BUILD --> SCAN["Stage: Image Scan\n(Trivy)"]
    SCAN -->|CRITICAL CVEs| FAIL1["❌ FAIL\nNotify Slack"]
    SCAN -->|Clean| SIGN["Stage: Sign Image\n(Cosign)"]

    SIGN --> PUSH_ECR["Stage: Push to ECR\n(IRSA auth — no keys)"]
    PUSH_ECR --> DEPLOY_DEV["Stage: Deploy → dev\n(update GitOps + ArgoCD sync)"]
    DEPLOY_DEV --> INT_TESTS["Stage: Integration Tests\n(against dev endpoint)"]

    INT_TESTS -->|main branch| DEPLOY_STG["Stage: Deploy → staging"]
    INT_TESTS -->|feature branch| END1["✅ Done\n(feature branch)"]

    DEPLOY_STG --> SMOKE["Stage: Smoke Tests\n(p95 < 500ms gate)"]
    SMOKE -->|fail| FAIL2["❌ FAIL\nNotify Slack"]
    SMOKE -->|pass| APPROVAL{"Manual Approval\n(24h timeout)"}

    APPROVAL -->|approved| DEPLOY_PROD["Stage: Deploy → prod\n(ArgoCD canary rollout)"]
    APPROVAL -->|timeout / rejected| CANCEL["Build cancelled"]

    DEPLOY_PROD --> TAG["Tag image as :stable\nin ECR"]
    TAG --> NOTIFY["✅ Notify Slack\n#deployments"]

    style FAIL1 fill:#ff4444,color:#fff
    style FAIL2 fill:#ff4444,color:#fff
    style NOTIFY fill:#22bb33,color:#fff
    style END1 fill:#22bb33,color:#fff
```

---

## Diagram 4 — Credential Flow (No Static Keys)

```mermaid
flowchart LR
    subgraph K8S["Kubernetes"]
        AGENT_SA["Agent ServiceAccount\n(jenkins-agent)"]
        AGENT_POD["Agent Pod"]
    end

    subgraph AWS_IAM["AWS IAM"]
        OIDC["EKS OIDC\nProvider"]
        IAM_ROLE["jenkins-agent-irsa\nIAM Role"]
        STS["AWS STS"]
    end

    subgraph AWS_SERVICES["AWS Services"]
        ECR["ECR\n(docker push)"]
        SM["Secrets Manager\n(GitHub token, Slack, etc.)"]
        S3["S3\n(artifacts)"]
    end

    AGENT_SA -- "annotated with role ARN" --> IAM_ROLE
    AGENT_POD -- "token projection" --> OIDC
    OIDC -- "verify OIDC token" --> IAM_ROLE
    IAM_ROLE -- "AssumeRoleWithWebIdentity" --> STS
    STS -- "short-lived token\n(15 min TTL)" --> AGENT_POD
    AGENT_POD -- "auth with temp token" --> ECR
    AGENT_POD -- "auth with temp token" --> SM
    AGENT_POD -- "auth with temp token" --> S3

    style AGENT_POD fill:#3b82d4,color:#fff
    note1["No AWS_ACCESS_KEY_ID\nNo AWS_SECRET_ACCESS_KEY\nEver."]
```

---

## Diagram 5 — JCasC Configuration Loading

```mermaid
sequenceDiagram
    participant GIT as Git Repo
    participant CM as ConfigMap
    participant INIT as Init Container
    participant JC as Jenkins Controller
    participant CASC as JCasC Plugin

    GIT->>CM: CI pipeline updates ConfigMap\n(jcasc/jenkins.yaml)
    CM->>INIT: Init container copies YAML\nto /var/jenkins_home/casc_configs/
    INIT->>JC: Jenkins starts
    JC->>CASC: Loads CASC_JENKINS_CONFIG path
    CASC->>CASC: Parse jenkins.yaml + credentials.yaml
    CASC->>JC: Configure: auth, clouds, libraries,\ncredentials, tools, notifications
    JC->>JC: ✅ Jenkins fully configured\n(zero manual UI steps)

    Note over JC,CASC: To reload without restart:\nManage Jenkins → Configuration as Code → Reload
```

---

## Diagram 6 — Jenkins ↔ ArgoCD GitOps Contract

```mermaid
sequenceDiagram
    participant JC as Jenkins Pipeline
    participant GITOPS as GitOps Repo\n(kustomization.yaml)
    participant ARGO as ArgoCD
    participant CLUSTER as EKS Cluster

    Note over JC: Build + scan + sign complete

    JC->>GITOPS: git clone gitops repo
    JC->>GITOPS: kustomize edit set image\nmyapp=ECR/myapp:SHA
    JC->>GITOPS: git commit + push

    GITOPS->>ARGO: ArgoCD detects drift\n(polls every 3 min or webhook)

    JC->>ARGO: POST /api/v1/applications/myapp-prod/sync\n(optional — speeds up sync)

    ARGO->>CLUSTER: Apply manifests (kubectl apply)
    CLUSTER->>ARGO: Report health status

    loop Wait for Healthy
        JC->>ARGO: GET /api/v1/applications/myapp-prod
        ARGO->>JC: health.status + sync.status
    end

    ARGO->>JC: Healthy + Synced ✅

    Note over JC,CLUSTER: Cluster state ALWAYS reflects Git.\nJenkins never runs kubectl directly.\nNo kubeconfig stored in Jenkins.
```

---

## Diagram 7 — Disaster Recovery

```mermaid
flowchart TD
    INCIDENT["💥 Jenkins controller\nPod crash / node failure"]

    INCIDENT --> K8S_HEAL["Kubernetes detects failure\n(StatefulSet self-heals)"]
    K8S_HEAL --> RESCHEDULE["Pod rescheduled\n(jenkins-0 on new node)"]
    RESCHEDULE --> EFS_MOUNT["EFS remounts\n(multi-AZ — available on any node)"]
    EFS_MOUNT --> CASC_LOAD["JCasC reloads from ConfigMap\n(zero manual config)"]
    CASC_LOAD --> READY["Jenkins ready\n⏱ ~60-90 seconds"]

    TOTAL_LOSS["💥 Total loss\n(EFS corrupted / deleted)"]
    TOTAL_LOSS --> RESTORE_BACKUP["Restore from S3 backup\n(nightly — last 30 days)"]
    RESTORE_BACKUP --> REDEPLOY["Redeploy StatefulSet\n(new EFS)"]
    REDEPLOY --> CASC_LOAD2["JCasC reloads config"]
    CASC_LOAD2 --> READY2["Jenkins ready\n⏱ ~10 minutes"]

    style READY fill:#22bb33,color:#fff
    style READY2 fill:#22bb33,color:#fff
    style INCIDENT fill:#ff4444,color:#fff
    style TOTAL_LOSS fill:#ff4444,color:#fff
```
