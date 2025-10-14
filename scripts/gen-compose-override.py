#!/usr/bin/env python3
import os, re, sys
from pathlib import Path
import textwrap

ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = ROOT / '.env'
OUT_FILE = ROOT / 'docker-compose.override.yml'
SERVICE = 'gluster-solo'

def load_env(path: Path):
    env = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if not line.strip() or line.strip().startswith('#'):
                continue
            if '=' in line:
                k, v = line.split('=', 1)
                env[k.strip()] = v.strip()
    return env

def find_host_bricks(env):
    # Prefer HOST_BRICK_PATHS (comma-separated), else HOST_BRICK{N}
    raw = env.get('HOST_BRICK_PATHS', '').strip()
    hosts = []
    if raw:
        for part in raw.split(','):
            p = part.strip()
            if p:
                hosts.append(p)
    else:
        # Scan HOST_BRICK1..HOST_BRICKN in numeric order
        for k in sorted(env.keys(), key=lambda s: (not s.startswith('HOST_BRICK'), s)):
            if not k.startswith('HOST_BRICK'):
                continue
            m = re.fullmatch(r'HOST_BRICK(\d+)', k)
            if not m:
                continue
            v = env[k].strip()
            if v:
                hosts.append(v)
    return hosts

def main():
    env = load_env(ENV_FILE)
    host_paths = find_host_bricks(env)
    if not host_paths:
        print('ERROR: Keine HOST_BRICK*-Variablen gefunden. Setze entweder HOST_BRICK1..N oder HOST_BRICK_PATHS=pfad1,pfad2,...', file=sys.stderr)
        sys.exit(2)

    # Build volumes YAML lines and BRICK_PATHS=/bricks/brick1,... for the container
    vol_lines = []
    brick_paths = []
    for i, host in enumerate(host_paths, start=1):
        env_name = f'HOST_BRICK{i}'
        lhs = f'${{{env_name}:?set {env_name} in .env}}'
        tgt = f'/bricks/brick{i}'
        vol_lines.append(f'      - {lhs}:{tgt}:rw')
        brick_paths.append(tgt)

    # Add state/logs volumes last
    vol_lines.append('      - ./data/glusterd:/var/lib/glusterd')
    vol_lines.append('      - ./data/logs:/var/log/glusterfs')

    yml = textwrap.dedent(f'''
    services:
      {SERVICE}:
        volumes:
''') + '\n'.join(vol_lines) + '\n'

    OUT_FILE.write_text(yml, encoding='utf-8')

    # Update .env BRICK_PATHS for the entrypoint (container-side paths)
    lines = []
    seen = False
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            if line.startswith('BRICK_PATHS='):
                lines.append('BRICK_PATHS=' + ','.join(brick_paths))
                seen = True
            else:
                lines.append(line)
    if not seen:
        lines.append('BRICK_PATHS=' + ','.join(brick_paths))
    ENV_FILE.write_text('\n'.join(lines) + '\n', encoding='utf-8')

    print(f'geschrieben: {OUT_FILE}')
    print('BRICK_PATHS=' + ','.join(brick_paths))

if __name__ == '__main__':
    main()
