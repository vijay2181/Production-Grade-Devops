# Project 4 — Security Architecture Diagrams

---

## 1. Defence-in-Depth — All Security Layers

```mermaid
flowchart TD
    DEV["👩‍💻 Developer\ngit push / kubectl apply"]

    subgraph PREVENT["PREVENTION — Before Pod Starts"]
        GK["OPA Gatekeeper\nValidatingWebhook\nDeny: latest tag, privileged,\nno limits, non-ECR images"]
        KY["Kyverno\nMutate + Validate\nAuto-add: securityContext\nDeny: no probes, no PDB"]
        PSA["Pod Security Admission\nNamespace-level\nrestricted / baseline / privileged"]
        GK --> KY --> PSA
    end

    subgraph RUNTIME["DETECTION — While Pod Runs"]
        FALCO["Falco eBPF\nWatches every syscall\nShell spawn · crypto · file write\ntoken read · privilege escalation"]
        TRIVY["Trivy Operator\nScans images every 24h\nCritical CVE → alert + ticket"]
    end

    subgraph SECRETS["SECRETS — At Rest + In Transit"]
        SS["Sealed Secrets\nEncrypted in Git\nOnly cluster decrypts"]
        IRSA["IRSA\nNo static AWS credentials\nTemporary STS tokens\nRotate every 1 hour"]
        ESO["External Secrets Operator\nAWS Secrets Manager\nAuto-rotation"]
    end

    subgraph NET["NETWORK — Zero Trust"]
        NP["NetworkPolicy\nDefault deny all\nAllow only: ALB→API→RDS/Redis/OTel"]
    end

    DEV -->|"kubectl apply"| PREVENT
    PREVENT -->|"allowed"| POD["Pod Running"]
    POD --> RUNTIME
    POD --> SECRETS
    POD --> NET

    FALCO -->|"alert"| SLACK["Slack / PagerDuty"]
    TRIVY -->|"CVE found"| TICKET["GitHub Issue / Jira"]

    style PREVENT fill:#fff8f0,stroke:#f59e0b
    style RUNTIME fill:#fff0f0,stroke:#e53e3e
    style SECRETS fill:#f0fff4,stroke:#38a169
    style NET fill:#f0f4ff,stroke:#3b82d4
```

---

## 2. OPA Gatekeeper — Admission Flow

```mermaid
sequenceDiagram
    participant Dev as 👩‍💻 Developer
    participant API as Kubernetes API
    participant GK as OPA Gatekeeper
    participant K8S as etcd (cluster state)

    Dev->>API: kubectl apply deployment.yaml
    API->>GK: ValidatingAdmissionWebhook
    Note over GK: Evaluate all Constraints

    GK->>GK: Check: image uses :latest?
    GK->>GK: Check: privileged=true?
    GK->>GK: Check: no resource limits?
    GK->>GK: Check: non-ECR image?
    GK->>GK: Check: runAsUser=0?

    alt All checks PASS
        GK-->>API: ALLOW
        API->>K8S: Store object
        API-->>Dev: ✅ deployment.apps/api created
    else Any check FAILS
        GK-->>API: DENY + reason
        API-->>Dev: ❌ Error: Container uses :latest tag
    end
```

---

## 3. Falco Runtime Detection Flow

```mermaid
flowchart LR
    subgraph NODE["EKS Node"]
        KERNEL["Linux Kernel\nsyscalls"]
        EBPF["eBPF probe\n(Falco driver)"]
        FALCO_D["Falco daemon\nevaluates rules"]
        KERNEL -->|"every syscall"| EBPF --> FALCO_D
    end

    subgraph RULES["Rule Evaluation"]
        R1["Shell spawned?\nbash/sh in myapp container"]
        R2["Crypto miner?\nxmrig/minerd process"]
        R3["Token read?\n/serviceaccount/token"]
        R4["Privilege escalation?\nsetuid syscall"]
        FALCO_D --> R1 & R2 & R3 & R4
    end

    subgraph ALERT["Alerting"]
        SLACK2["#security-alerts\nSlack"]
        PD["PagerDuty\n(CRITICAL only)"]
        LOKI["Loki\n(all alerts logged)"]
    end

    R1 & R2 & R3 & R4 -->|"rule matched"| FALCOSIDEKICK["Falcosidekick\nrouter"]
    FALCOSIDEKICK --> SLACK2
    FALCOSIDEKICK --> PD
    FALCOSIDEKICK --> LOKI
```

---

## 4. Attack Chain vs Defence

```mermaid
flowchart TD
    A1["🔴 Attack: :latest image poisoned\non Docker Hub"]
    A2["🔴 Attack: Container escape\nvia root + RCE"]
    A3["🔴 Attack: Cryptominer\ndeployed in pod"]
    A4["🔴 Attack: kubectl exec\nreverse shell"]

    D1["✅ OPA: deny :latest\nBlocked at admission"]
    D2["✅ Pod Security restricted\nNo root, readOnlyFS\nIRSA: no static creds"]
    D3["✅ Falco: detects xmrig\nwithin seconds\nTrivy: CVE in image"]
    D4["✅ Falco: shell spawned\nalert fires immediately\nNetworkPolicy: no C2 egress"]

    A1 --> D1
    A2 --> D2
    A3 --> D3
    A4 --> D4

    style A1 fill:#fff0f0,stroke:#e53e3e
    style A2 fill:#fff0f0,stroke:#e53e3e
    style A3 fill:#fff0f0,stroke:#e53e3e
    style A4 fill:#fff0f0,stroke:#e53e3e
    style D1 fill:#f0fff4,stroke:#38a169
    style D2 fill:#f0fff4,stroke:#38a169
    style D3 fill:#f0fff4,stroke:#38a169
    style D4 fill:#f0fff4,stroke:#38a169
```

---

## 5. IRSA — How Pods Get AWS Credentials Without Static Keys

```mermaid
sequenceDiagram
    participant SA as ServiceAccount\n(myapp-api)
    participant POD as myapp Pod
    participant EKS as EKS OIDC\nProvider
    participant STS as AWS STS
    participant SM as Secrets Manager

    Note over SA: Annotated with IAM role ARN
    POD->>EKS: Request projected token\n(audience: sts.amazonaws.com)
    EKS-->>POD: JWT token (valid 1h)
    POD->>STS: AssumeRoleWithWebIdentity\n(JWT + role ARN)
    STS->>EKS: Verify JWT signature
    EKS-->>STS: Valid
    STS-->>POD: Temporary credentials\n(expire in 1h, auto-renewed)
    POD->>SM: GetSecretValue\n(using temp credentials)
    SM-->>POD: DB_PASSWORD value
    Note over POD: No AWS_ACCESS_KEY_ID\nNo AWS_SECRET_ACCESS_KEY\never stored anywhere
```

---

## 6. Sealed Secrets — GitOps-Safe Secret Management

```mermaid
flowchart LR
    subgraph DEV["Developer Workstation"]
        PLAIN["Plain Secret YAML\nDB_PASSWORD=s3cr3t"]
        KUBESEAL["kubeseal CLI\n(uses cluster public key)"]
        SEALED["SealedSecret YAML\nencrypted gibberish"]
        PLAIN --> KUBESEAL --> SEALED
    end

    subgraph GIT["Git Repository"]
        COMMIT["✅ Safe to commit\nEncrypted value only"]
        SEALED --> COMMIT
    end

    subgraph CLUSTER["Kubernetes Cluster"]
        CONTROLLER["Sealed Secrets Controller\n(holds private key)"]
        SECRET["kubernetes Secret\n(decrypted, in memory only)"]
        POD["App Pod\nreads DB_PASSWORD"]
        COMMIT --> CONTROLLER --> SECRET --> POD
    end

    ATTACKER["❌ Attacker reads Git\nSees encrypted gibberish\nUseless without cluster key"]
    COMMIT -.->|"reads"| ATTACKER
```

---

## 7. Zero-Trust NetworkPolicy

```mermaid
flowchart TD
    ALB["AWS ALB\n(internet)"]
    API["myapp-api pods\n:3000"]
    RDS["RDS PostgreSQL\n:5432"]
    REDIS["ElastiCache Redis\n:6379"]
    OTEL["OTel Collector\n:4317"]
    PROM["Prometheus\nmonitoring ns"]
    BLOCKED["❌ Everything else\nBlocked by default-deny"]

    ALB -->|"✅ allowed\nkube-system → :3000"| API
    API -->|"✅ allowed\negress :5432"| RDS
    API -->|"✅ allowed\negress :6379"| REDIS
    API -->|"✅ allowed\negress :4317"| OTEL
    PROM -->|"✅ allowed\nmonitoring ns → :3000"| API
    API -.->|"❌ BLOCKED\nno k8s API access"| BLOCKED
    API -.->|"❌ BLOCKED\nno cross-NS access"| BLOCKED

    style BLOCKED fill:#fff0f0,stroke:#e53e3e
    style API fill:#f0f4ff,stroke:#3b82d4
```
