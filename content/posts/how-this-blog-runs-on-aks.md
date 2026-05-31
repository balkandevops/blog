---
title: "How this blog runs: Ghost on AKS, GitOps all the way down"
date: 2026-05-31
tags: ["kubernetes", "aks", "argocd", "gitops", "traefik", "terragrunt", "infrastructure"]
description: "A blog is a solved problem — you click deploy on a managed host and you're done. I did the opposite. Here's the whole stack, why each piece is there, and the parts I'd do differently."
---

A blog is a solved problem. You sign up for a managed host, pick a theme, and you're writing in ten minutes. I did almost none of that. This thing runs on a Kubernetes cluster I provision myself, deployed by a controller that reconciles from Git, with certificates and DNS and secrets all wired up by operators I had to install first.

Was that the sane choice for *a blog*? No. But the blog was never the point — it's the smallest real workload I could put on a platform I actually wanted to build and operate. Everything you're reading right now is the proof that the platform works. So this is the tour: every layer, why it exists, and where I'd cut a corner if I did it again.

## the shape of it

From the bottom up, the stack is:

- **Azure + AKS** — one managed Kubernetes cluster, single node, `westeurope`
- **Terragrunt** — provisions the cluster, network, Key Vault, and state backend
- **ArgoCD** — the thing that actually deploys everything on top, from Git
- **Traefik** — ingress and TLS termination
- **cert-manager** — issues the Let's Encrypt certificate
- **external-dns** — writes the DNS records to Cloudflare so I don't have to
- **External Secrets Operator** — pulls secrets out of Azure Key Vault into the cluster
- **CloudNativePG** — Postgres operator, ready for when the blog outgrows SQLite
- **Ghost** — the blog itself, one container and a volume

Two repos drive the whole thing. One holds the Terragrunt — the cloud infrastructure underneath Kubernetes. The other holds the Kubernetes manifests — everything ArgoCD syncs onto the cluster. That split matters and I'll come back to why.

## layer one: the cluster, via Terragrunt

The cluster is a single `Standard_B4s_v2` node in `westeurope`. One node. This is a personal blog, not a bank — I am not paying for a control plane's worth of redundancy to serve a few hundred kilobytes of text.

Terragrunt provisions it. People ask why Terragrunt and not plain Terraform, and the honest answer is: state backend boilerplate and DRY. The remote state lives in an Azure Storage account, in its own resource group, kept deliberately separate from everything Terragrunt manages — because the one thing you never want is your state file living inside the blast radius of the thing it describes.

What Terraform owns here: the AKS cluster, the VNet and subnet it sits in, and an Azure Key Vault. What it deliberately does **not** own: anything *inside* the cluster. No Helm releases driven from Terraform, no `kubernetes_manifest` resources. The moment you let Terraform manage in-cluster objects, you've got two controllers fighting over the same resources, and `terraform plan` starts lying to you. So Terraform stops at the cluster boundary. Everything above the kubelet is ArgoCD's job.

That boundary — Terraform below, GitOps above — is the single most important design decision in the whole setup.

## layer two: ArgoCD and the app-of-apps

Once the cluster exists, ArgoCD takes over. It runs *on* the cluster and continuously reconciles the live state against a Git repo. I push a YAML change, ArgoCD notices within a couple of minutes, and the cluster converges. I almost never run `kubectl apply` against this thing in anger.

The structure is the **app-of-apps** pattern. There's one root Application. It doesn't deploy workloads directly — it deploys *other* Applications, grouped by concern:

- **platform-infra** — cert-manager, the ClusterIssuer, external-dns, Traefik. The plumbing.
- **platform-apps** — the CloudNativePG operator, a Postgres cluster, and the blog. The actual workloads.
- **platform-monitoring** — the observability bits.

Why bother with the layer of indirection? Two reasons. First, ordering: the platform-infra apps have to be healthy *before* the workloads come up, because the blog's ingress is meaningless until Traefik and cert-manager exist. Second, onboarding a new service is a pull request that adds one small Application manifest — not a sprawl of `kubectl` commands that live only in shell history.

## layer three: getting traffic in

**Traefik** is the ingress controller — the front door, the one thing with a public IP, terminating TLS and routing to the right service. I use Traefik's own `IngressRoute` CRD rather than a vanilla `Ingress`. The rule is plain: match `www.balkandevops.com`, send it to the blog service, terminate TLS with the cert in a named secret.

**cert-manager** fills that secret. It talks to Let's Encrypt over ACME, proves I control the domain, drops a signed certificate into the cluster as a Kubernetes Secret, then renews it before it expires — forever, without me thinking about it.

**external-dns** closes the loop. It watches the cluster for hostnames that need to exist and writes the matching records straight into Cloudflare. When I declared `www.balkandevops.com` on the IngressRoute, I didn't open the Cloudflare dashboard — external-dns saw the hostname and created the A record pointing at Traefik's IP.

Three controllers, one outcome: a request to `https://www.balkandevops.com` lands on the blog with a valid cert and I touched none of it by hand after first setup.

## layer four: secrets and state

**Secrets** come from Azure Key Vault, brokered by the **External Secrets Operator**. The pattern: the real secret lives in Key Vault, the cluster holds only an `ExternalSecret` — a manifest that says "go fetch value X from the vault and materialise it as a Kubernetes Secret." No secrets in the repo, no secrets in shell history.

**State** — the actual blog data — is the honest soft spot. The blog currently runs on **SQLite**, on a single 5Gi persistent volume. CloudNativePG is installed and a Postgres cluster is sitting right there ready, but the blog isn't pointed at it yet. SQLite is fine at this scale, but it's a single file on a single volume, so the backup story is "the volume" and the HA story is "there is none." Migrating to CNPG Postgres is the obvious next move.

## the part where I'm honest

The cert issuer is **Let's Encrypt staging**, not production. Staging has generous rate limits and untrusted roots — perfect while you're rebuilding the ingress ten times a day. Flipping to production is a one-line change I'll make when I stop touching the networking.

It's a **single node**. Node goes down, blog goes down. Acceptable here; not a pattern I'd ship for anything with real users.

None of these are accidents — they're deliberate "good enough for now" calls. The difference between a homelab that teaches you something and one that eats your weekends is knowing *which* corners you cut and *why*.

## so why do it this way

Because every piece here is something I'd otherwise only touch under pressure, on someone else's cluster, during an outage. cert-manager renewals, ArgoCD drift, an ESO sync that silently fails, a Traefik route that 404s for no obvious reason — I would much rather meet all of those for the first time on a blog nobody will miss for an hour than on production with people watching.

The blog is the excuse. The platform is the point.

The repos are public: [github.com/balkandevops](https://github.com/balkandevops). Pull them apart, steal what's useful, and if you spot where I cut a corner I didn't admit to — [come tell me](https://linkedin.com/in/ivan-gjakovikj).

---

*Running something similar, or mid-migration onto Kubernetes? [GitHub](https://github.com/lcko9) / [LinkedIn](https://linkedin.com/in/ivan-gjakovikj).*
