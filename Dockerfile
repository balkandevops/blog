# Stage 1: build the Hugo site
FROM ghcr.io/hugomods/hugo:exts AS builder
WORKDIR /src
COPY . .
RUN hugo --minify --gc

# Stage 2: serve with Caddy (single binary, zero config, gzip built-in)
FROM caddy:2-alpine
COPY --from=builder /src/public /srv
EXPOSE 80
