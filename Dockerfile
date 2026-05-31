# Receives pre-built Hugo output from the CI step (./public)
FROM caddy:2-alpine
COPY public/ /srv
EXPOSE 80
