---
title: "Taming Azure AI Foundry with LiteLLM: budgets and key rotation"
date: 2026-06-07
tags: ["litellm", "azure", "azure-ai-foundry", "llmops", "platform-engineering", "kubernetes"]
draft: false
summary: "Azure AI Foundry is amazing until you have to manage it for more than one team. Here is how LiteLLM became the gateway that fixed my key sprawl, capped everyone's spend, and turned key rotation from a fire drill into a thirty second job."
---

**TL;DR**

- Put LiteLLM in front of Foundry and hand out virtual keys, never the real ones.
- Every team key gets a hard budget, so a runaway agent stops at its own cap.
- A leaked key is a delete and a re-mint. The real Foundry credentials never move.

A guy on one of the teams burned $35 in two hours. He wired up an agent, left the retry logic looping, and walked away from his desk. No malice. Just a loop doing what loops do.

$35 is nothing until you multiply it by a weekend and a dozen teams with nobody watching the meter. That is why every team key has a budget now.

## Why raw Foundry keys don't scale

Foundry gives you a key per model deployment. Then one team wants a Mistral model, another wants an embedding model, a third wants something from the Phi family. Three endpoints, three keys, multiplied by every team in the org.

Soon you have raw keys living in `.env` files and pipeline secrets. Nobody knows who spends what. When one leaks, you rotate it and hope you didn't break four other workloads sharing the same deployment.

A raw key is all or nothing. You can't scope it, cap it, or kill it without collateral damage.

LiteLLM fixes that. It sits in front of Foundry as one OpenAI compatible endpoint. Teams talk to LiteLLM, and LiteLLM talks to Foundry for them.

## One gateway, every model

You list every deployment once in a config file, give it a friendly name, and point it at the right endpoint.

```yaml
model_list:
  # OpenAI family on Foundry uses the azure/ prefix
  - model_name: gpt-4o
    litellm_params:
      model: azure/gpt-4o-deployment
      api_base: https://my-foundry.openai.azure.com/
      api_key: os.environ/AZURE_API_KEY
      api_version: "2024-10-21"

  # Everything else in the Foundry catalog uses azure_ai/
  - model_name: phi-4
    litellm_params:
      model: azure_ai/phi-4-deployment
      api_base: https://my-foundry.services.ai.azure.com/
      api_key: os.environ/AZURE_AI_API_KEY

  # Embeddings, same idea
  - model_name: text-embedding-3-large
    litellm_params:
      model: azure/text-embedding-3-large-deployment
      api_base: https://my-foundry.openai.azure.com/
      api_key: os.environ/AZURE_API_KEY
```

The two prefixes trip people up. GPT and the embedding models go through `azure/`. The rest of the catalog (Phi, Mistral, Llama) goes through `azure_ai/`. Teams just ask for `gpt-4o` or `phi-4` by name and never care which family they hit.

## Virtual keys

Once everything routes through one place, I stop handing out the real Foundry keys. Every team gets a virtual key instead, and it comes with rules. Which models it can call. How much it can spend per month. How many requests and tokens per minute. And I can revoke it without touching anything else.

```bash
curl -X POST "https://litellm.mycompany.com/key/generate" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "team-search",
    "models": ["gpt-4o", "text-embedding-3-large"],
    "max_budget": 200,
    "budget_duration": "30d",
    "tpm_limit": 100000,
    "rpm_limit": 500
  }'
```

The real Foundry credentials now live in one place, the gateway. Here is what a key looks like in the LiteLLM UI: spend against budget, rate limits, and the exact models it can touch.

![A virtual key in the LiteLLM admin UI, showing its spend against budget, rate limits, and the list of allowed models](/img/litellm-virtual-key-overview.png)

## Budgets that actually stop the spend

LiteLLM tracks spend per key in Postgres on every call. When a key crosses its ceiling, the gateway stops serving it.

So the $35 loop would have hit its own team's cap, gotten a clear error back, and pinged me. Blast radius: one team, capped at a number I picked in advance.

Budgets nest too. Set one org wide cap, say $2,000 a month, then carve per team slices under it. Spend rolls up. One team can blow its own slice without putting the whole org over, and I can see exactly who spent what instead of staring at one giant Azure line item.

Things I learned the hard way:

- **Budgets reset on a duration, not a calendar month.** `budget_duration: "30d"` rolls thirty days from when you made the key. My numbers didn't match the Azure invoice until I figured that out.
- **Use soft limits too.** A `soft_budget` fires an alert without blocking anyone. Wire it to Slack or Teams at around 80 percent. I skipped this at first and a team hit a hard wall with zero warning.
- **The Postgres is not a throwaway sidecar.** It had a bad day once, and because every virtual key and all the spend tracking lives in it, budgets and auth went down with it. Back it up. Give it real resources.
- **Pin your image tag.** Never `latest`. LiteLLM ships fast, and this proxy sits in front of every team's AI access. Read the changelog, test the bump outside prod.

## Rotating keys without a fire drill

A key will leak eventually. A notification preview, a screenshot in a ticket, a log line nobody scrubbed.

With a raw Foundry key that's a project. New key in the portal, hunt down every place the old one lives, redeploy everything, and the leaked key stays live and billable the whole time.

With a virtual key, you delete it, mint a fresh one with the same scope, and hand it to the one team that owns it. The leaked key is dead the second you revoke it. The real Foundry credentials never moved, because that's not what leaked.

You don't have to wait for a leak either. Open a key's settings and turn on auto rotation.

![The key settings page in LiteLLM with auto rotation enabled on a seven day schedule and the next rotation date shown](/img/litellm-auto-rotation.png)

The one in the screenshot rolls every seven days and already knows its next rotation date. No cron job, no script, nobody remembering.

## No Foundry key at all

Since this runs on AKS, I took it one step further. LiteLLM authenticates to Foundry with a managed identity. The pod gets its own Azure identity, I grant it the right role on the Foundry resource, and the API key disappears from the config.

```yaml
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: azure/gpt-4o-deployment
      api_base: https://my-foundry.openai.azure.com/
      # no api_key at all, LiteLLM uses the pod's Azure identity
      api_version: "2024-10-21"
```

LiteLLM uses `DefaultAzureCredential` under the hood, so on AKS it picks up the workload identity automatically. I expected this to be fiddly. It wasn't.

Now there's no Foundry secret to leak. The only credentials humans ever handle are virtual keys, and those are scoped, capped, and killable in one call.

*Running one, or stuck mid migration? Come yell at me on [GitHub](https://github.com/Icko9) or [LinkedIn](https://www.linkedin.com/in/ivan-gjakovikj-233a95236).*
