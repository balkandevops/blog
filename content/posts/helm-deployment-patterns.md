---
title: "Three ways to deploy Helm charts on Kubernetes, and when each one breaks"
date: 2026-06-29
tags: ["helm", "kubernetes", "argocd", "gitops", "terraform", "devops"]
description: "Most teams deploy Helm charts the way they did on day one and never revisit it. Here are the three patterns I've run in production, and where each one breaks."
cover:
  image: "img/helm-deployment-structure/argocd-gitops-k8s.png"
  alt: "ArgoCD GitOps Kubernetes flow"
  relative: false
  hiddenInList: true
---

**TL;DR**

- Helm only renders manifests. The real question is how they land on the cluster and stay there.
- CI `helm upgrade` and the Terraform provider push once and walk away. Only ArgoCD has a loop that catches drift.
- Terraform builds the cluster and its foundations, ArgoCD ships the apps, raw `helm` stays for debugging.

Most teams deploy Helm charts the way they did on day one, and never revisit it until it hurts. The pipeline that ran `helm upgrade --install` against staging two years ago is still shipping production today. Nobody questions it because it works. Right up until it doesn't.

Helm itself is just templating. It takes values and a chart and renders manifests. That part is identical whatever you do. What matters is how the output lands on the cluster and how it stays there. I've run three answers in production. Each one is correct in a specific place and a liability everywhere else.

## Pattern one: helm upgrade --install from CI

This is where everyone starts. The pipeline authenticates to the cluster and runs one command.

```yaml
- name: Deploy
  run: |
    helm upgrade --install myapp ./charts/myapp \
      --namespace prod \
      --values values.prod.yaml \
      --wait --timeout 5m
```

One command, one mental model, instant feedback in the log. Helm stores release state as a Secret in the cluster (`sh.helm.release.v1.myapp.v1`, revision bumped on every upgrade), so rollbacks are technically possible. For a single service on a single cluster, there is nothing wrong with this.

It breaks in the same four places:

- **No visibility.** To answer "what is deployed in prod right now" you run `helm list` and `helm get values` against the cluster. The pipeline run from three weeks ago tells you what you tried to deploy, not what is live.
- **Silent drift.** Someone runs `kubectl scale` during an incident and the cluster now differs from your repo. Nothing notices. The next deploy may or may not clobber it, and you find out in production.
- **Rollbacks that lie.** `helm rollback myapp 4` goes to Helm's stored state, not your git history. If the repo moved on, you now have a release that matches neither.
- **Half finished deploys.** If the runner dies mid upgrade, the release sits in `pending-upgrade` and the next deploy fails with "another operation (install/upgrade/rollback) is in progress". Someone deletes the pending release Secret by hand. `--atomic` and `--cleanup-on-fail` soften this but bring their own surprises, like a long upgrade rolling itself back on a timeout.

On top of that, your CI runner holds broad cluster access while running code from pull requests.

None of this makes the pattern wrong. It's a local and debugging tool that got promoted into a delivery mechanism.

## Pattern two: the Terraform Helm provider

This is the infrastructure engineer's instinct. Everything is infrastructure, so the release becomes a `helm_release` next to the cluster.

```hcl
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.5"
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }
}
```

For bootstrapping, this is the right call. The same `terraform apply` that builds the AKS cluster and node pools can lay down cert-manager, ingress, External Secrets Operator, and ArgoCD itself. You get ordering through `depends_on` and one definition of "a working cluster from nothing". Day zero is what this pattern is good at.

Point it at application workloads and it bites:

- **State becomes a liability.** The provider's idea of the release drifts the moment anything touches it outside Terraform. You get perpetual plan diffs on values that didn't change, and sometimes it wants to recreate a release that's running fine. Debugging why `terraform plan` wants to destroy your running app is a bad afternoon.
- **Too slow for app cadence.** Five deploys a day means five state locks and five full apply runs holding everyone else's changes hostage.
- **No reconciliation.** Terraform only acts when you run apply. Between applies, drift is invisible and uncorrected. Fine for infrastructure that changes monthly, wrong for workloads that change hourly.
- **Wrong coupling.** App developers now need Terraform access to ship code, and a bad app deploy shares a state file with your infrastructure.

Terraform for the cluster and its foundations: yes. For the apps on it: no.

## Pattern three: ArgoCD

![ArgoCD flow](/img/helm-deployment-structure/DiagramArgoCD.png)
*Source: freeCodeCamp.org*

ArgoCD is not magic. It's a controller in the cluster that continuously compares desired state in git against live state. You describe an app as a CRD pointing at a repo path, and Argo converges the cluster to it.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/myorg/deployments
    path: charts/myapp
    targetRevision: main
    helm:
      valueFiles:
        - values.prod.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: prod
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Helm is still here. Argo renders the chart with `helm template` and applies the output. What changed is everything around it:

- **Drift detection is the default.** It diffs constantly and shows `OutOfSync` the moment the cluster stops matching git. With `selfHeal` on, that incident `kubectl scale` gets reverted automatically.
- **Git is the source of truth.** "What is deployed in prod" is answered by reading the repo.
- **Visibility without kubectl.** The UI shows sync status, health, the resource tree, and a live diff. You can hand that to someone who has never touched kubectl.
- **Rollback is a git revert.** No revision numbers to remember, and no gap between what Helm thinks and what git says.

What it costs you: one more thing to run, secure, and upgrade. Because Argo uses `helm template` instead of `helm install`, there is no Helm release Secret, and hooks become Argo sync phases and waves. Charts that lean on hooks or `lookup` behave differently. Secrets can't sit in git, so you need External Secrets Operator or sealed secrets. And Argo can't bootstrap itself, which sends you back to Terraform for the first install.

## How does a new image get deployed?

The question everyone hits about a week after adopting ArgoCD. Argo watches git, not your registry. So how does a fresh image tag reach the cluster without someone editing a values file by hand?

What I use: CI writes the tag back to git. The pipeline builds the image, pushes it, then patches the tag in the app's values file and commits. Argo sees the commit and syncs. I tag with the commit SHA, never `latest`. The SHA is immutable, traces to the exact commit, and makes Argo's diff obvious because the string changes on every build.

Use `yq` for the patch instead of `sed`. It targets the exact path, so a stray `tag:` elsewhere or a shifted indent can't break it.

```bash
yq -i '.image.tag = "'"$GIT_SHA"'"' dev.yaml
git commit -am "deploy: ${GIT_SHA} [skip ci]"
git push
```

The `[skip ci]` matters when the pipeline commits back into a repo that can trigger it. Otherwise the tag bump kicks off another build and you have a loop.

The app owns one values file per environment, `dev.yaml` and `prod.yaml` next to the chart, each with its own Argo Application. That gives you a promotion gate for free. Auto bump `dev.yaml` for continuous deployment to dev, and keep `prod.yaml` a manual commit or pull request. As it grows, a shared `values.yaml` holds everything identical and the env files hold only what differs, like replica counts, limits, and ingress host. Then reading `prod.yaml` shows exactly what's supposed to be different.

Two alternatives exist. ArgoCD Image Updater watches the registry and, in git write-back mode, commits the tag for you. Its other mode patches the Application directly without touching git, which puts you right back in the drift problem. Same tool, two modes, only one is GitOps. Flux image automation does the git write-back too, which is pointless to add if you're already on Argo. Old operators like Keel patched the running deployment in place, which made sense before GitOps and is the wrong tool after it.

## How I split it

After running all three, it's a layering, not a ranking.

**Terraform owns the cluster and foundations.** Cluster, node pools, and the day zero addons: cert-manager, ingress, External Secrets Operator, ArgoCD itself. It changes rarely and needs Terraform's explicit ordering.

**ArgoCD owns the application workloads.** Anything that deploys often and wants drift correction and git rollback.

**Raw helm stays local.** `helm template` to see what a chart renders. `helm install` into a throwaway namespace to poke at a new chart. `helm get manifest` to see what Argo actually applied. Great for inspection, bad as a production delivery mechanism.

Helm renders the manifests. Terraform gets you a working cluster. ArgoCD keeps your apps converged to git. Stop asking one tool to do all three.
