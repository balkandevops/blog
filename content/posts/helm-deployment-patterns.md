---
title: "Three ways to deploy Helm charts on Kubernetes, and when each one breaks"
date: 2026-06-29
tags: ["helm", "kubernetes", "argocd", "gitops", "terraform", "devops"]
description: "Most teams deploy Helm charts the way they did on day one and never revisit it. Here are the three patterns I've run in production, and where each one breaks."
---

Most teams deploy Helm charts the way they did on day one, and never revisit it until it hurts. The pipeline that ran `helm upgrade --install` against a staging cluster two years ago is still the thing shipping production today, and nobody questions it because it works. Right up until it doesn't.

The part nobody frames clearly is that Helm itself is just templating. It takes values and a chart and renders Kubernetes manifests. That rendering step is identical no matter what you do. The real question is how the rendered output lands on the cluster and how it stays there. There are three answers I have run in production, and each one is correct in a specific place and a liability everywhere else.

Two of these push once and walk away. Only ArgoCD has a loop, and that loop is the entire difference.

## Pattern one: helm upgrade --install from CI

This is where everyone starts. Your pipeline authenticates to the cluster and runs one command.

```yaml
- name: Deploy
  run: |
    helm upgrade --install myapp ./charts/myapp \
      --namespace prod \
      --values values.prod.yaml \
      --wait --timeout 5m
```

It feels fine because it is fine, at first. One command, one mental model, instant feedback in the pipeline log. Helm tracks the release state for you as a Secret in the cluster (`sh.helm.release.v1.myapp.v1`, incrementing the revision on every upgrade), so rollbacks are technically possible. New engineers understand it in thirty seconds. For a single service on a single cluster, there is nothing wrong with it.

It falls apart quietly, and always in the same four places.

You have no visibility into what is actually running. To answer "what is deployed in prod right now" you have to query the cluster with `helm list` and `helm get values`. There is no observable source of truth. The pipeline run from three weeks ago is your only record, and that record tells you what you tried to deploy, not what is live now.

Drift goes undetected. Someone runs `kubectl scale` during an incident, or patches a deployment by hand to unblock something, and the cluster now diverges from your repo. Nothing notices. The next deploy may or may not clobber that change depending on which fields Helm touches, and you find out in production.

Rollbacks are manual and they lie to you. `helm rollback myapp 4` works, but you have to know the revision number, and it rolls back to Helm's stored state, not to your git history. If your values came from the repo and the repo moved on, you now have a release that matches neither.

A pipeline failure mid-deploy leaves you in an unknown state. If the runner times out or dies during the upgrade, the release sits in `pending-upgrade`. The next deploy fails with "another operation (install/upgrade/rollback) is in progress" and now someone has to manually roll back or delete the pending release Secret before anything ships again. `--atomic` and `--cleanup-on-fail` soften this, but they do not remove it, and they introduce their own surprises when a long upgrade rolls itself back on a timeout.

There is also the credentials problem. Your CI runner holds broad cluster access so it can deploy. That is a large surface sitting in a system that runs arbitrary code from pull requests.

None of this means the pattern is wrong. It means it is a local and debugging tool that got promoted into a production delivery mechanism it was never meant to be.

## Pattern two: the Terraform Helm provider

This is the infrastructure engineer's instinct. Everything is infrastructure, infrastructure is code, so the Helm release becomes a `helm_release` resource and lives in the same Terraform that built the cluster.

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

For bootstrapping a cluster, this is genuinely the right call. The same `terraform apply` that provisions the AKS cluster and its node pools can lay down the foundational layer: cert-manager, your ingress controller, External Secrets Operator, and ArgoCD itself. You get ordering and dependency awareness through `depends_on`, you get one coherent definition of "a working cluster from nothing," and you get it versioned next to the infrastructure it depends on. Day zero is exactly what this pattern is good at.

It falls apart the moment you point it at application workloads.

Terraform state becomes a liability instead of an asset. State now tracks live cluster objects, and the Helm provider's idea of the release drifts from reality the instant anything touches that release outside Terraform. You get perpetual plan diffs on values that did not change, and occasionally the provider decides it needs to recreate a release that is running perfectly well. Debugging why `terraform plan` wants to destroy your running app is not how anyone wants to spend an afternoon.

The plan and apply cycle is too slow for application cadence. Deploying an app five times a day through Terraform means five state locks, five full evaluations, five apply runs that hold everyone else's changes hostage until they finish. Compared to a git push, it is heavy machinery for a frequent, low-risk action.

You lose continuous reconciliation, which is the deeper problem. Terraform only does anything when you run apply. It is a point-in-time tool, not a controller. Between applies, drift is invisible and uncorrected because there is no control loop watching the cluster. That is fine for infrastructure that changes monthly and wrong for workloads that change hourly.

And you have coupled the wrong things together. Application developers now need Terraform knowledge and state access to ship a code change, and a bad app deploy shares a blast radius and a state file with your infrastructure. The release cadence of your product is now bolted to your infrastructure tooling, and those two things want to move at completely different speeds.

Terraform for the cluster and its foundations: yes. Terraform for the apps that run on it: this is where it bites.

## Pattern three: ArgoCD

ArgoCD is not magic and treating it like a silver bullet is how people end up disappointed. What it actually is: a controller that runs in the cluster and continuously compares the desired state in git against the live state on the cluster. You describe an application as a CRD pointing at a repo path, and Argo does the converging.

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

Notice that Helm is still here. Argo renders the chart with `helm template` and applies the output. The templating tool did not change. What changed is everything around it, and it solves the exact problems the first two patterns have.

Drift detection is the default behavior, not an add-on. The control loop diffs constantly and shows you `OutOfSync` the moment the cluster stops matching git. Turn on `selfHeal` and it corrects that drift for you. The `kubectl scale` someone ran during an incident gets reverted automatically, or at minimum flagged loudly.

Git is the observable source of truth. Desired state is declarative, versioned, and reviewed through pull requests like any other change. "What is deployed in prod" is answered by reading the repo, not interrogating the cluster.

Visibility does not require kubectl. The UI and CLI show sync status, health, the full resource tree, and a live diff against git. You can hand that view to someone who does not know kubectl and they can still see whether prod is healthy.

Rollback is a git revert. Revert the commit and Argo syncs the cluster back. No revision numbers to memorize, no divergence between what Helm thinks and what git says, because git is the only thing that decides. The cluster always trends toward what is in the repo.

Where it costs you, and it does cost you: ArgoCD is one more thing to run, secure, and upgrade. Because it uses `helm template` rather than `helm install`, there is no Helm release Secret and Helm hooks are translated into Argo sync phases and waves, so charts that lean heavily on hooks or on `lookup` functions behave differently than they do under raw Helm. Secrets cannot sit in git, so you need External Secrets Operator or a sealed-secrets approach alongside it. And Argo cannot bootstrap itself, which is the chicken-and-egg that sends you right back to Terraform for the initial install. None of these are dealbreakers. They are the price, and it is worth knowing the price before you pay it.

## But how does a new image even get deployed

Here is the question everyone hits about a week after adopting ArgoCD, and it is worth answering directly because it is the first thing that confuses people. If the cluster only ever converges to git, how does a freshly built image tag get onto the cluster without a human editing a values file by hand every single deploy?

Argo does not watch your registry. It watches git. So the new tag has to reach git somehow, and there are three ways to make that happen.

The cleanest one, and the one I use, is to have CI write the tag back to git. The pipeline builds the image, pushes it to the registry, then patches the image tag in the app's values file and commits. Argo sees the commit and syncs. I tag images with the commit SHA rather than `latest` or a floating semver, because the SHA is immutable, traces straight back to the exact commit that produced it, and makes Argo's diff unmistakable since the tag string actually changes on every build.

The build step produces two things: an image in the registry and a one line commit in git. Git is the pivot. Everything left of it is imperative build tooling, everything right of it is Argo converging the cluster to what git now says.

The patch itself is worth doing properly. Editing the file with `sed` works right up until a stray `tag:` appears somewhere else or the indentation shifts. `yq` targets the exact path instead of pattern-matching text, so it survives refactors of the values file.

```bash
yq -i '.image.tag = "'"$GIT_SHA"'"' dev.yaml
git commit -am "deploy: ${GIT_SHA} [skip ci]"
git push
```

The `[skip ci]` matters when the pipeline commits back into a repo that can also trigger it, otherwise the tag-bump commit kicks off another build and you have a loop. If your build repo and your deployment repo are separate, that problem mostly disappears on its own.

The app owns its values, one file per environment, so `dev.yaml` and `prod.yaml` sit next to the chart and each has its own Argo Application pointing at it. That split quietly forces a useful property: each environment is a separate commit. Auto-bump `dev.yaml` and you get continuous deployment to dev. Leave `prod.yaml` as a manual commit or a pull request and you get a promotion gate for free, just because prod is a separate file someone has to touch. The thing to watch as this grows is the two files drifting into accidental divergence, which is what the shared-base-plus-overrides layout solves: a common `values.yaml` holding everything identical, and the env files holding only what genuinely differs, replica counts, resource limits, ingress host. Argo merges them in order, so reading `prod.yaml` shows you exactly the set of things that are supposed to be different and nothing else.

The other two ways exist and are worth knowing. ArgoCD Image Updater watches the registry the way an old-school operator would, and in its git write-back mode it commits the new tag for you so Argo syncs normally. It also has a mode that patches the Application directly without touching git, and that mode quietly puts you back in the drift problem this whole post argues against, cluster moves, git does not. Same tool, two modes, only one of them is actually GitOps. Flux image automation does the same git write-back from the Flux ecosystem, which is fine if you are on Flux and pointless to pull in if you are already on Argo.

For contrast, the imperative-era answer to this exact problem was an operator like Keel, which watched the registry and patched the running deployment in place the moment a new tag appeared. No git round-trip, no manifest change, just a live patch. It was the right tool when raw `helm` and CI was the delivery model, because there was no git source of truth to respect in the first place. The day you move to GitOps it becomes the wrong tool, for the obvious reason that patching the cluster directly reintroduces precisely the drift you adopted Argo to eliminate. That shift, from patch the cluster to write to git and let the controller converge, is the whole mental move GitOps asks of you, and image promotion is where it becomes concrete.

## How I actually split it

After running all three in anger, the division that holds up is not a ranking. It is a layering, and each layer plays to what the tool is good at.

Terraform owns the cluster and the foundational services. The cluster, the node pools, and the day-zero addons that have to exist before anything else can run: cert-manager, ingress, External Secrets Operator, and ArgoCD itself. This stuff changes rarely, benefits from being defined next to the infrastructure it sits on, and needs the explicit ordering Terraform gives you. One apply takes you from nothing to a cluster that is ready to receive workloads.

ArgoCD owns the application workloads. Everything that deploys frequently, benefits from continuous reconciliation, and wants drift correction and git-based rollback lives here. This is the layer your product ships through, and it is the layer where the first two patterns hurt the most.

Raw helm commands stay where they belong, which is local development and debugging. `helm template` to see exactly what a chart renders before it goes anywhere near a cluster. `helm install` into a throwaway namespace to poke at a new chart. `helm get manifest` to figure out what an Argo-managed release actually applied. These are inspection and experimentation tools, and they are excellent at that. They are just not a production delivery mechanism, and the trouble starts the day someone forgets that distinction.

The honest version of this whole post is short. Helm renders the manifests. Terraform gets you a working cluster. ArgoCD keeps your apps converged to git. Use each one for the job it is actually good at, and stop asking any single one of them to do all three.
