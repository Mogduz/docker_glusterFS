# Fixes applied to docker_glusterFS

## compose.solo-2bricks-replica.yml
- Removed duplicate `restart` key by normalizing YAML (kept `restart: unless-stopped`).
- YAML formatting normalized.

## compose.solo-2bricks-replica.steady.yml
- Removed duplicate `restart` key by normalizing YAML (kept `restart: unless-stopped`).
- YAML formatting normalized.

## compose.server.variantB.yml
- Fixed indentation under `healthcheck:` (normalized `test:` indentation).
- Removed duplicate `healthcheck` block (kept the parameterized one using `${HC_*}` variables).
- Removed duplicate `environment` block (kept the parameterized one using `${...}` variables).
- Resolved duplicate `ports` blocks (kept the more complete set, including `24008` and the `49152–49251` range).
- Removed duplicate `extra_hosts` block (kept a single one).
- Revalidated: file now parses and contains no duplicate keys.

## Project-wide validation
- Parsed all YAML files with a duplicate-key check: **no remaining YAML syntax or duplicate-key errors** detected.
