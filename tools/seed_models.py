#!/usr/bin/env python3
"""Descarga modelos desde registry.ollama.ai forzando IPv4 y los instala en Ollama.

Motivo: en esta Mac IPv6 no tiene ruta, y el cliente de descarga de Ollama
fija la primera IP resuelta (AAAA) -> "network is unreachable".
Este script usa curl -4 (IPv4) y escribe blobs + manifiesto en OLLAMA_MODELS.

Uso:  python3 seed_models.py qwen2.5:1.5b qwen3:1.7b ...
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys

REG = "https://registry.ollama.ai/v2"
MODELS_DIR = os.path.expanduser(os.path.join(os.environ.get("OLLAMA_MODELS", ""), "") or "~/.ollama/models")
BLOBS = os.path.join(MODELS_DIR, "blobs")
MANIFESTS = os.path.join(MODELS_DIR, "manifests", "registry.ollama.ai", "library")
ACCEPT = "application/vnd.docker.distribution.manifest.v2+json"


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, **kw)


def curl(url, out=None, timeout=3600):
    cmd = ["curl", "-4", "-sL", "--fail", "--max-time", str(timeout)]
    if out:
        cmd += ["-o", out]
    cmd.append(url)
    return sh(cmd)


def get_manifest(repo, ref):
    p = sh(["curl", "-4", "-s", "--fail", "--max-time", "30", "-H", f"Accept: {ACCEPT}",
            f"{REG}/{repo}/manifests/{ref}"])
    if p.returncode != 0:
        raise SystemExit(f"[{repo}:{ref}] manifiesto no disponible: {p.stderr.decode()[:200]}")
    return p.stdout


def human(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} TB"


def seed_blob(digest, repo, size):
    hexd = digest.split(":", 1)[1]
    dest = os.path.join(BLOBS, f"sha256-{hexd}")
    if os.path.exists(dest):
        if os.path.getsize(dest) == size and sha256_file(dest) == hexd:
            print(f"  ✓ blob {hexd[:12]} ya presente ({human(size)})")
            return
        os.remove(dest)
    tmp = dest + ".dl"
    print(f"  ↓ descargando {hexd[:12]} ({human(size)})…", flush=True)
    r = curl(f"{REG}/{repo}/blobs/{digest}", out=tmp)
    if r.returncode != 0 or not os.path.exists(tmp):
        raise SystemExit(f"[{repo}] fallo descarga {digest}: {r.stderr.decode()[:200]}")
    got = sha256_file(tmp)
    if got != hexd:
        os.remove(tmp)
        raise SystemExit(f"[{repo}] hash incorrecto para {digest} (obtenido {got[:16]})")
    os.replace(tmp, dest)
    print(f"  ✓ blob {hexd[:12]} verificado")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def seed_model(spec):
    if ":" in spec:
        name, tag = spec.rsplit(":", 1)
    else:
        name, tag = spec, "latest"
    repo = f"library/{name}"
    print(f"\n== {name}:{tag}", flush=True)
    raw = get_manifest(repo, tag)
    mf = json.loads(raw)
    layers = [mf.get("config", {})] + list(mf.get("layers", []))
    total = sum(l.get("size", 0) for l in layers)
    print(f"  {len(layers)} bloques, {human(total)}")
    for l in layers:
        if l.get("digest"):
            seed_blob(l["digest"], repo, l.get("size", 0))
    outdir = os.path.join(MANIFESTS, name)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, tag), "wb") as f:
        f.write(raw)
    print(f"  ✓ {name}:{tag} instalado")


def main():
    os.makedirs(BLOBS, exist_ok=True)
    specs = sys.argv[1:]
    if not specs:
        raise SystemExit(__doc__)
    for s in specs:
        seed_model(s)
    p = sh(["ollama", "list"])
    print("\n" + p.stdout.decode())


if __name__ == "__main__":
    main()
