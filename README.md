# ~/.hermes/profiles/infra1/ansible/ — Cross-project deploy orchestrator

★ **Use this tree for any deploy to any project on any server.** The
playbooks are project-agnostic in shape; project-specific vars live
in `group_vars/<project>.yml`. Same pattern will apply when lgs and
rpkg land.

## Layout

```
~/.hermes/profiles/infra1/ansible/
├── ansible.cfg              # defaults: inventory, ssh args, log path
├── inventory.yml            # all hosts (group: project_env)
├── group_vars/
│   └── pitaas.yml           # project vars: FE bundles, BE sites, services, paths
├── playbooks/
│   ├── deploy-fe.yml        # FE: build locally + rsync 3 Vite bundles
│   └── deploy-be.yml        # BE: backup + rsync + restart + migrate
└── README.md                # this file
```

## Canonical invocations

★ **All deploys go through `~/bin/deploy` (PATH: `~/.hermes/profiles/infra1/bin`)**:

```bash
# 1. ALWAYS --check first (★ lazydog durable preference; never deploy without --check)
deploy pitaas pitaas-dev-1 fe --check --diff

# 2. Live deploy
deploy pitaas pitaas-dev-1 fe

# Multi-project (when lgs/rpkg land)
deploy lgs lgs-dev-1 fe --check

# Multi-server (when pitaas-staging-1 lands)
deploy pitaas pitaas-staging-1 fe --check

# All hosts (dry-run)
deploy --all fe --check
```

## What each playbook does

### `deploy-fe.yml` (FE static bundles)

1. **[local]** Verify pnpm, node, the FE repo exists
2. **[local]** Check if `apps/*/dist/index.html` exist (skip build if so)
3. **[local]** `pnpm install` + `pnpm build` (skipped if dist/ exists, or in --check)
4. **[remote]** Ensure `/var/www/pitaas/{customer,admin,auditor}-app/` exist
5. **[rsync]** Each `apps/*/dist/` → remote dest (with --checksum, --exclude)
6. **[remote]** Smoke test: find files on disk (skipped in --check)
7. **[local]** Append audit line to today's journal (skipped in --check)

### `deploy-be.yml` (BE docker + migrations)

1. **[local]** Verify the BE repo exists
2. **[remote]** Verify SSH connectivity
3. **[remote]** Verify the remote BE path exists
4. **[remote]** Pre-deploy backup (warns-and-skips if `/opt/pitaas/scripts/backup-all-sites.sh` is missing)
5. **[rsync]** BE repo → `/opt/pitaas/pitaas_v3/` (excludes .git, node_modules, etc.)
6. **[remote]** `docker compose up -d --build` for `be_services_to_restart` (configurator, traefik, mariadb, redis NOT touched)
7. **[remote]** Per-site `bench --site <site> migrate`
8. **[remote]** Per-site `bench execute frappe.ping` (smoke test)
9. **[local]** Audit log (skipped in --check)

## What you MUST do before relying on BE deploys in prod

★ **Install `/opt/pitaas/scripts/backup-all-sites.sh` on pitaas-dev-1** (Q6 in `obsidian/memory/infra1/pitaas-architecture-INDEX.md`).

Without it, the pre-deploy backup step warns-and-skips. That's fine for dev but not for prod.

## Pitfalls (★ learned the hard way, captured here)

See `obsidian/memory/infra1/work/journal/2026-10-11.md` §11:00Z for the full list. The 5 most relevant:

1. **FQCN module names**: `ansible.builtin.lineinfile`, not `line`. `ansible.builtin.stat`, not `stat`. `ansible.posix.synchronize`, not `synchronize`.
2. **`ansible_ssh_common_args` is a string, not a list of strings** (YAML literal scalar).
3. **`subelements` filter**: `item.0` is the parent dict, `item.1` is the sub-element; `item.stat.exists` doesn't apply.
4. **`ansible_date_time` requires `gather_facts: true`**. Use `lookup('pipe', 'date ...')` for timestamps when facts are off.
5. **`failed_when` returns the actual value of the expression; if you write it as a raw string, it returns the string** (not a bool). Use Jinja `var not in other_var`, not raw strings.

## When to upgrade to self-hosted GitHub Actions runner (Tier 2)

★ Trigger: when > 5 deploys/week OR > 1 PR source (agent + human dev) OR any paying customer.

The runner install is one-time on pitaas-dev-1:
```bash
sudo useradd -m -s /bin/bash gh-runner
sudo mkdir -p /opt/gh-runner && sudo chown gh-runner:gh-runner /opt/gh-runner
# (download + config + svc.sh install — see obsidian/memory/infra1/pitaas-ci-cd-bundles.md)
```

Until then, **manual Ansible via `deploy` is the canonical path**. Lazydog runs `deploy <project> <server-id> <fe|be>` after each PR merge to `main`.
