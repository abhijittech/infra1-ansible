---
name: traefik-cors-middleware
description: Use when adding/editing Traefik middlewares in pitaas-v3 file-provider (cors, security, rate-limit, retry). Critical gotchas on naming, file-provider refresh, and upstream-stripping behaviors.
category: devops
---

# Traefik Middleware on pitaas-v3 — Rules + Gotchas

Canonical reference for adding/editing Traefik middlewares in the pitaas-v3 stack. Captures the file-provider-specific behaviors that burned us in 2026-10-12 CORS regression.

## When to load
- Adding a new Traefik middleware (CORS, rate limit, retry, etc.) in pitaas-v3
- Diagnosing "middleware does not exist" errors after a refresh
- Diagnosing CORS preflight failures in pitaas-v3 (Allow-Origin missing from response)
- Editing `playbooks/traefik-file-provider.yml.j2`

## Stack reference (pitaas-v3 specific)
- Traefik v3.7.14 in container `pitaas_v3-traefik-1`
- Host port bindings: `443/tcp → 8000`, `80/tcp → 8080` (vendor NAT maps public 443 to host 8000)
- File provider at `/etc/traefik/file-provider/file-provider.yml` inside container
- Source template: `~/.hermes/profiles/infra1/ansible/playbooks/traefik-file-provider.yml.j2`
- Rendered via `deploy pitaas pitaas-dev-1 refresh` (ansible playbook `refresh-nginx.yml`)
- Single source of truth for allowed origins: `nginx_cors_allowed_origins` in `group_vars/pitaas.yml`

## Rule 1: file-provider middlewares must NOT include '@file' suffix
Traefik auto-appends the provider suffix based on where the middleware is defined. Defining `cors-headers@file:` in the file-provider config and referencing it as `cors-headers@file` from a router causes `middleware "cors-headers@file" does not exist` errors. The Traefik parser sees the explicit `@file` as a name conflict.

**Correct**:
```yaml
# middlewares section
middlewares:
  cors-headers:        # ← NO @file suffix
    headers:
      accessControlAllowOriginList: [...]

# router section
routers:
  apex-https:
    middlewares:
      - cors-headers   # ← NO @file suffix; Traefik auto-resolves to cors-headers@file
```

**Wrong** (causes silent failure):
```yaml
middlewares:
  cors-headers@file:   # ← do NOT include
    headers: ...

routers:
  apex-https:
    middlewares:
      - cors-headers@file   # ← do NOT include
```

## Rule 2: CORS headers should be set at the Traefik layer, not relied on from upstream
Traefik v3's response forwarding strips specific headers from upstream responses in some scenarios (OPTIONS preflight especially). nginx's `add_header` directives in fe-bundles.conf come through (they're FE nginx's own response headers), but Frappe's `set_cors_headers` middleware (which adds `Allow-Origin`, `Vary`, `Allow-Credentials`, `Allow-Max-Age` per-request) gets dropped.

**Fix**: add a dedicated Traefik `headers` middleware with `accessControlAllowOriginList`, `accessControlAllowCredentials`, `accessControlAllowMethods`, `accessControlAllowHeaders`, `accessControlMaxAge`. Wire it into all HTTPS routers BEFORE `security-headers@file`.

## Rule 3: Middlewares execute in order specified in the router
When wiring multiple middlewares, order matters. CORS should run BEFORE security headers (otherwise security headers might add headers that conflict with CORS, or the response rewriting happens after CORS is evaluated).

```yaml
middlewares:
  - cors-headers       # ← first
  - security-headers   # ← second
```

## Rule 4: accessControlAllowOriginList must be a YAML list, not a single string
```yaml
# CORRECT
accessControlAllowOriginList:
  - 'https://apex.pitaas.rtcnexora.com'
  - 'https://dev.pitaas.rtcnexora.com'

# WRONG (Traefik treats string as a single-element list but rejects special chars)
accessControlAllowOriginList: 'https://apex.pitaas.rtcnexora.com,https://dev.pitaas.rtcnexora.com'
```

## Rule 5: accessControlAllowCredentials + non-wildcard origin are required
The CORS spec forbids `Access-Control-Allow-Origin: *` when `Access-Control-Allow-Credentials: true`. Traefik handles this correctly when you use `accessControlAllowOriginList` (specific origins) + `accessControlAllowCredentials: true`. Do NOT use `accessControlAllowOrigin: '*'` with `accessControlAllowCredentials: true`.

## Rule 6: After editing the file-provider, force a Traefik restart (file provider watch is unreliable)
`deploy pitaas pitaas-dev-1 refresh` writes the rendered file to `/etc/traefik/file-provider/file-provider.yml` and Traefik's `--providers.file.watch=true` should auto-reload. In practice, **Traefik v3.7 sometimes fails to pick up the new middleware definition** and continues to throw `middleware does not exist` errors. Workaround: `sudo -n docker restart pitaas_v3-traefik-1`. After restart, the new middleware is recognized.

Verify with: `sudo -n docker logs pitaas_v3-traefik-1 --tail 20 | grep -i middleware`

## Rule 7: Negative test (evil origin) is the only way to confirm allowlist enforcement
The `origin_check` behavior in Traefik silently drops Allow-Origin when the request's Origin doesn't match. From the browser's perspective, a missing Allow-Origin = automatic request rejection. Always test with:
- A legitimate origin (must echo Allow-Origin)
- A non-allowlisted origin like `https://evil.example.com` (must NOT echo Allow-Origin)

```bash
# legitimate
curl -sk -X OPTIONS -H "Origin: https://apex.pitaas.rtcnexora.com" -H "Host: apex.pitaas.rtcnexora.com" "https://103.117.50.250:8000/api/login" -i | grep -i allow

# evil
curl -sk -X OPTIONS -H "Origin: https://evil.example.com" -H "Host: apex.pitaas.rtcnexora.com" "https://103.117.50.250:8000/api/login" -i | grep -i allow
```

## Rule 8: pitaas-dev-server host port 443 is NOT bound; only 8000
This is a vendor-NAT quirk. HTTPS is on host 8000 (mapped from container 443). If the browser shows `ERR_CONNECTION_REFUSED` on `https://apex.pitaas.rtcnexora.com/login` (port 443), the vendor's external NAT (public 443 → host 8000) is missing or broken. Not an app/infra1/pitaas1 issue — vendor/network admin task. Workaround: append `:8000` to the URL.

## Diagnostic commands (one-liners)
```bash
# rendered config in container
sudo -n docker exec pitaas_v3-traefik-1 cat /etc/traefik/file-provider/file-provider.yml

# traefik logs
sudo -n docker logs pitaas_v3-traefik-1 --tail 30

# current middlewares in Traefik API
curl -sk -H "Host: traefik.pitaas.rtcnexora.com" "https://103.117.50.250:8000/api/http/middlewares"

# OPTIONS preflight through Traefik
curl -sk -X OPTIONS -H "Origin: https://apex.pitaas.rtcnexora.com" -H "Host: apex.pitaas.rtcnexora.com" "https://103.117.50.250:8000/api/login" -i

# actual login through Traefik
curl -sk -X POST -H "Origin: https://apex.pitaas.rtcnexora.com" -H "Host: apex.pitaas.rtcnexora.com" -H "Content-Type: application/json" -d '{"usr":"...","pwd":"..."}' "https://103.117.50.250:8000/api/login" -i
```

## Reference: full cors-headers middleware template
```yaml
cors-headers:
  headers:
    accessControlAllowOriginList:
{% for origin in nginx_cors_allowed_origins %}
      - '{{ origin }}'
{% endfor %}
    accessControlAllowCredentials: true
    accessControlAllowMethods:
      - GET
      - POST
      - OPTIONS
      - PUT
      - DELETE
    accessControlAllowHeaders:
      - Content-Type
      - Authorization
      - X-Frappe-CSRF-Token
    accessControlExposeHeaders:
      - Set-Cookie
    accessControlMaxAge: 86400
    addVaryHeader: true
```

## What NOT to do
- Don't add `@file` to middleware names in file-provider config
- Don't rely on upstream's `set_cors_headers` reaching the browser (Traefik may strip it)
- Don't use `accessControlAllowOrigin: '*'` with `accessControlAllowCredentials: true`
- Don't add the CORS middleware AFTER security-headers (CORS should evaluate first)
- Don't trust `deploy refresh` to auto-reload Traefik's middleware definitions — always verify with `docker logs`
- Don't claim CORS is fixed without running the negative test (evil origin)
