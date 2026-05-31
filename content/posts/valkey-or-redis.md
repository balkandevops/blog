---
title: "Valkey or Redis: how I'd actually choose"
date: 2026-05-31
tags: ["valkey", "redis", "kubernetes", "infrastructure", "open-source"]
description: "Everyone wrote a take about the fork. Nobody wrote the part where you still have to deploy one on Monday. Here's the actual decision, no drama."
---

Short version, because you've got a cluster to babysit: run Valkey. The exception is if you need vector search living in the same box as your cache — then look hard at Redis 8 and read the license before you commit. That's the post. Everything under here is me showing my work.

I run Valkey in prod. It's the cache and rate-limit store in front of an LLM gateway, and the ingestion queue for a tracing stack, on AKS. So this isn't a hot take about open-source ethics from someone who's never had to `kubectl rollout restart` the thing at 1am. The ethics argument is over and you still have to ship something — this is about that part.

## the bit everyone's mental model is wrong about

Fast history, because the version people repeat is already stale.

Redis was BSD from 2009. Permissive, boring, the good kind of boring. Then on March 20, 2024 Redis Ltd. pulled it off BSD onto a dual source-available license — RSALv2 + SSPLv1 ([#13157](https://github.com/redis/redis/pull/13157) if you want to read the actual commit). "Source-available" gets waved around like it means open source. It doesn't. The terms exist to stop cloud providers from reselling managed Redis without paying. That was the entire move.

The cloud providers did not take it lying down. Inside about two weeks the Linux Foundation stood up Valkey — forked from 7.2.4, the last BSD release — with AWS, Google, Oracle, Ericsson and Snap behind it. You don't hit that timeline by accident. Those companies had the lawyers and the fork warmed up before the announcement landed.

Then the part nobody updates their mental model for: on May 1, 2025 Redis added AGPLv3 — a real OSI-approved license — back as an option ([#13997](https://github.com/redis/redis/pull/13997)). So if you're still telling people "Redis went closed," you're a year behind. It went closed, then partway back open. It's a tri-license now (RSALv2 / SSPL / AGPL), antirez is back at the company, and Redis 8 pulled the old Stack modules — JSON, time series, the probabilistic stuff, vector sets — into core.

So retire the "open vs closed" framing. The real fork in the road is AGPL copyleft run by one company versus BSD run by a foundation. That's the choice you're actually making.

## does the license even matter to you? probably not

Here's what nobody says after all that drama: if you `helm install` it and never touch the source, AGPL vs BSD is academic. You will never feel it.

It bites in specific spots. If you're reselling it as a service, the source-available terms are pointed straight at your head — by design. If your legal team has a flat no-AGPL policy (lots do), Redis technically hands you SSPL or RSALv2 instead, except those aren't open source either, so you've fixed an AGPL problem by taking on a source-available one — BSD just makes the whole conversation evaporate. And if you've ever been burned by a single-vendor relicense — gestures at everything above — a foundation with five competitors watching each other is much harder to pull the rug out from under.

If none of that is you, it's a tiebreaker and you're overthinking it.

## the numbers, and the asterisk nobody prints

Both engines bolted on I/O multithreading and the benchmarks look great. Valkey 8.0: roughly 1.19M requests/sec on a 16-core Graviton box, about 230% over 7.2's 360K, latency down around 70%. 8.1 added a Swiss-table-style hashtable that claws back 20–30 bytes per key and moved TLS negotiation onto the I/O threads, which sent the new-connection accept rate way up.

Now the asterisk the headlines skip: it's *I/O* threading. Command execution — the part doing the real work — is still single-threaded, in both, on purpose, because that single thread is what makes your operations atomic. The extra cores help you accept connections and move bytes. They do not run one `GET` across eight cores.

So: connection- or network-bound, you'll feel the threading, it's real. Bound by the cost of the work itself, the cores buy you less than the slide deck implies. Most of what I run isn't near that RPS wall anyway — the 8.1 memory savings have mattered more day to day, because those land on the bill while the throughput ceiling never shows up.

## where they're drifting apart

Still ~90% command-compatible, so code mostly just moves across. But "mostly" is load-bearing and the gap widens every release, so you can't pick on "eh, they're the same thing" anymore. They're not, quite.

Redis 8's real pitch is vectors. With Stack in core it has the cleaner story if you want caching *and* vector similarity search in one engine. If that's your use case, it's the better-integrated product, license stuff aside.

Valkey's bets are GLIDE (the newer client library), experimental RDMA, and the steady memory-and-perf grind. Boring, fast, open, drop-in — which is, funnily enough, exactly what everyone wanted Redis to stay.

## the thing that actually decides it

Your managed provider probably already chose for you, and you should mostly let it.

ElastiCache has defaulted new clusters to Valkey since 2024; Memorystore supports it. On AWS, Valkey is the path of least resistance and running anything else is the thing you'd have to justify in review. That one default shifted more market share than every licensing blog post combined, this one included.

The exception is mine: Azure. The managed cache there is still Redis-based. So on AKS I just run Valkey on the cluster myself — open license, full control, drop-in, and it costs me exactly one more workload of a type I already run a pile of. When your provider hasn't picked Valkey for you, self-hosting it is the easy yes.

## so, the call

Self-hosting a plain cache, queue, or rate-limiter? Valkey — BSD, foundation-backed, active, drop-in, zero licensing homework for a workload that gains nothing from it. That's my setup and it wasn't close. On AWS or GCP managed, same answer, because it's already the default and fighting the default is wasted effort. The one real reason to walk into Redis 8 is wanting vectors and cache in the same engine — and if you do, go in eyes open and loop in whoever owns compliance, because that's where the cost actually lives. No-copyleft legal team, or just tired of single-vendor surprises? Valkey, and don't think about it twice.

The fork was a whole drama. The decision isn't. Run Valkey unless something specific drags you toward Redis — and if that something exists, you already know exactly what it is.

---

*Running one, or stuck mid-migration? Come yell at me — [GitHub](https://github.com/lcko9) / [LinkedIn](https://linkedin.com/in/ivan-gjakovikj).*
