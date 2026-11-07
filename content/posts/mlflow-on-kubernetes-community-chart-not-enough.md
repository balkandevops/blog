---
title: "MLflow on Kubernetes: why the community chart is not enough"
date: 2026-06-18
tags: ["mlflow", "kubernetes", "aks", "helm", "argocd", "external-secrets", "platform-engineering", "mlops"]
draft: false
summary: "The community MLflow chart is great for a demo and useless for production. It knows nothing about your Key Vault, your Workload Identity, your Traefik ingress, or your certs. Here is the layered Helm pattern I run instead, where the open source chart stays untouched and your cloud specifics live in a thin layer on top. Plus the one missing package that breaks Workload Identity on day one."
---

**TL;DR**

- Keep the community chart untouched and add your own thin infra chart next to it.
- ArgoCD deploys both from one Application with multiple sources.
- The `burakince/mlflow` image has no `azure-identity`, so Workload Identity fails on the first upload. An init container fixes it without forking.

The first time MLflow tried to upload a model on our AKS cluster, the pod fell over:

```
ModuleNotFoundError: No module named 'azure.identity'
```

I'll get to the fix at the end. First, the setup that got me there, because the setup is the reason the fix was a few lines instead of a fork.

## The chart doesn't know your cloud

The community-charts/mlflow chart handles the Pod and the Service. It connects to PostgreSQL and Azure Blob Storage. That part is great.

But it doesn't know about your Key Vault. It doesn't know you want secrets from External Secrets Operator, that you run Traefik instead of a standard Ingress, that pods authenticate with Workload Identity, or that cert-manager issues your certs.

Those aren't flaws. The chart is cloud agnostic on purpose. Your production environment isn't.

## Layers, not forks

Don't fork the chart. Layer your own on top.

**Layer 1: the community chart.** `community-charts/mlflow:1.8.1`. Just MLflow, pointed at a Postgres database and a blob store. You never touch it.

**Layer 2: your infra chart.** Lives at `deploy/mlflow/infra/` and creates five things:

- Namespace: `mlflow`
- ServiceAccount `mlflow`, annotated with `azure.workload.identity/client-id`
- ExternalSecret that pulls the database password from Key Vault
- Certificate from cert-manager for `mlflow.mycompany.com`
- IngressRoute so Traefik routes HTTPS to MLflow

**Layer 3: ArgoCD.** One Application with three sources:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mlflow
  namespace: argocd
spec:
  sources:
    - repoURL: https://your-git-repo/_git/your-repo
      targetRevision: main
      ref: values

    - repoURL: https://your-git-repo/_git/your-repo
      targetRevision: main
      path: deploy/mlflow/infra
      helm:
        releaseName: mlflow-infra
        valueFiles:
          - $values/deploy/mlflow/values.yaml

    - repoURL: https://community-charts.github.io/helm-charts
      chart: mlflow
      targetRevision: "1.8.1"
      helm:
        releaseName: mlflow
        valueFiles:
          - $values/deploy/mlflow/values.yaml

  destination:
    server: https://kubernetes.default.svc
    namespace: mlflow
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

![How ArgoCD assembles the three sources into a running MLflow on the cluster](/img/mlflow-arch/ML%20Flow%20Argocd.png)

What you get: you stay on the community chart's upgrade path (bump `targetRevision`, test, done), you maintain no fork, and a move from Azure to AWS or from Traefik to nginx only touches your infra chart.

## The five templates

![The custom infra chart layered on top of the community chart, and the five resources it creates](/img/mlflow-arch/Layering%20Custom%20Infra%20chart.png)

**1. Namespace**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mlflow
```

**2. ServiceAccount with Workload Identity**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mlflow
  namespace: mlflow
  annotations:
    azure.workload.identity/client-id: "{{ .Values.managedIdentity.clientId }}"
```

The annotation tells Azure which managed identity the pod uses, the one you granted access to Key Vault and Blob Storage. No API keys.

Two things here cost me an afternoon of auth silently doing nothing.

First, the annotation is only half of it. The pod itself needs the label `azure.workload.identity/use: "true"` or the webhook never injects a token. With the community chart you set it through `extraPodLabels`:

```yaml
extraPodLabels:
  azure.workload.identity/use: "true"
```

Second, watch who owns the ServiceAccount. The community chart defaults to `serviceAccount.create: true`. If your infra chart also creates one named `mlflow`, two owners fight over the same object and ArgoCD fights itself over the annotation. One line fixes it:

```yaml
serviceAccount:
  create: false
  name: mlflow
```

I also keep the `clientId` out of the chart. The base `values.yaml` has `managedIdentity.clientId: ""` and ArgoCD merges the real value in from `deploy/environments/dev/config.yaml` at render time. The UUID never lives in the committed chart.

**3. ExternalSecret**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: mlflow-db-secret
  namespace: mlflow
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-keyvault-store-apps
    kind: ClusterSecretStore
  target:
    name: mlflow-db-secret
    creationPolicy: Owner
    template:
      type: kubernetes.io/basic-auth
      data:
        username: mlflow
        password: "{{ .password }}"
  data:
    - secretKey: password
      remoteRef:
        key: postgres-mlflow-password
```

External Secrets Operator pulls `postgres-mlflow-password` from Key Vault every hour and keeps the Kubernetes Secret in sync. The community chart reads the database credentials from it.

**4. Certificate**

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: mlflow-tls-secret
  namespace: mlflow
spec:
  secretName: mlflow-tls-secret
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - mlflow.mycompany.com
```

**5. IngressRoute**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: mlflow-secure
  namespace: mlflow
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`mlflow.mycompany.com`)
      middlewares:
        - name: traefik-security-headers
          namespace: traefik-shared
      services:
        - name: mlflow
          port: 80
  tls:
    secretName: mlflow-tls-secret
```

That's the whole custom layer. Five small templates, all declarative, all in git.

## No storage key anywhere

With Workload Identity the community chart never sees an Azure key. The pod authenticates to Blob Storage with its own identity. The only secret left in the cluster is the Postgres password, and External Secrets pulls that from Key Vault, so no human ever types it into a file.

That's the plan. Here's where it broke.

## What broke: the missing package

Back to the error from the top. Passwordless auth on Azure goes through `DefaultAzureCredential`, which lives in the `azure-identity` package. The `burakince/mlflow` image bundles `azure-storage-blob` (the half that talks to blob storage) but not `azure-identity` (the half that gets you a token without a key). It ships `boto3` and `google-cloud-storage` too, so the other clouds are covered. The author reasonably assumed you'd hand MLflow a connection string. I wanted no string at all. This is still true on the current image, so you'll hit it too.

Two obvious fixes, both bad. Fork the image and add one line, and I own an image fork forever. Or build my own image on top, and now I babysit a pipeline for one missing package. Both break the point of this post.

So I patched it from my own layer. An init container pip installs `azure-identity` into a shared volume before MLflow starts, and `PYTHONPATH` points the main container at it:

```yaml
extraVolumes:
  - name: extra-pip-packages
    emptyDir: {}

extraVolumeMounts:
  - name: extra-pip-packages
    mountPath: /extra-packages

initContainers:
  - name: install-azure-identity
    image: burakince/mlflow:3.7.0
    command: ["pip", "install", "--target=/extra-packages", "azure-identity"]
    volumeMounts:
      - name: extra-pip-packages
        mountPath: /extra-packages

extraEnvVars:
  PYTHONPATH: /extra-packages
```

No fork, no custom image, no upstream change. Just a values override in my own chart.

The tradeoff: every pod start reaches out to PyPI, so you need egress and startup is slower than a baked image. If that bothers you, a custom image is the cleaner long term answer. For getting Workload Identity working without owning a fork, this is the whole change.

## Beyond MLflow

This isn't MLflow specific. Any community chart (Langfuse, PostgreSQL, Redis) plus your cloud gets the same treatment: an infra chart for your secrets backend, ingress controller, certificate issuer, and pod identity. The upstream chart stays clean, and ArgoCD ties it together.

*Running MLflow on Kubernetes? Hit me up on [GitHub](https://github.com/Icko9) or [LinkedIn](https://www.linkedin.com/in/ivan-gjakovikj-233a95236).*
