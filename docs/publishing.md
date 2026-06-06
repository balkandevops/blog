# Publishing a post

You need: a GitHub account with write access to this repo. No cluster access required.

## Create the file

Add a new `.md` file under `content/posts/`:

```
content/posts/your-post-slug.md
```

The filename becomes the URL: `www.balkandevops.com/posts/your-post-slug/`

## Frontmatter

Every post must start with this block:

```yaml
---
title: "Your Post Title"
date: 2026-06-06
tags: ["kubernetes", "aks", "whatever-fits"]
description: "One sentence shown in the post list and in search results."
---
```

Then write the rest in standard Markdown.

## Publish

Push to `main`. That's it.

GitHub Actions will:
1. Build the site with Hugo
2. Package it into a Docker image and push to GHCR
3. Bump the image tag in the apps repo

ArgoCD picks up the tag change and rolls out the new pod. The post is live in roughly 2 minutes.

## Optional frontmatter fields

```yaml
draft: true          # hides the post from the listing until removed
cover:
  image: "img/cover.png"   # place the file in static/img/
  alt: "description of image"
weight: 1            # pin a post to the top of the list
```

## Rules

- Use lowercase, hyphen-separated filenames (`my-post.md`, not `MyPost.md`)
- `date` must be set or the post won't appear in the listing
- No affiliate links, no sponsored content
