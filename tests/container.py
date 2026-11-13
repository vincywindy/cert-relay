"""Run actual TLS/entrypoint/lifecycle checks with Docker or Windows WSLC (stdlib only)."""

import argparse
import json
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", nargs="?", default="cert-relay:test")
    parser.add_argument("--runtime", default="docker")
    args = parser.parse_args()
    volume = "cert-sync-test-" + uuid.uuid4().hex[:12]
    container = None

    def run(*command, check=True):
        result = subprocess.run(
            [args.runtime, *command], capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=90,
        )
        if check and result.returncode:
            raise RuntimeError(f"{command[0]} failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
        return result.stdout.strip()

    def helper(script):
        return run("run", "--rm", "--entrypoint", "sh", "-v", f"{volume}:/fixture", args.image, "-ec", script)

    def prepare():
        helper("""
            mkdir -p /fixture/source /fixture/state /fixture/dynamic
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
              -keyout /fixture/source/new.key -out /fixture/source/new.pem \
              -subj /CN=one.example.test -days 2 >/dev/null 2>&1
            mv /fixture/source/new.key /fixture/source/one.key
            mv /fixture/source/new.pem /fixture/source/one.pem
        """)

    def state():
        info = json.loads(run("inspect", container))
        return (info[0] if isinstance(info, list) else info)["State"]

    def start(mode, interval=1):
        nonlocal container
        options = [
            "run", "-d", "-v", f"{volume}:/fixture",
            "-e", 'SYNC_PAIRS=[{"name":"one","cert":"/fixture/source/one.pem","key":"/fixture/source/one.key"}]',
            "-e", "SYNC_STATE_DIR=/fixture/state",
            "-e", "SYNC_DYNAMIC_FILE=/fixture/dynamic/cert-sync.yml",
            "-e", f"SYNC_INTERVAL_SECS={interval}", "-e", "SYNC_MIN_AGE_SECS=0",
        ]
        if mode == "env":
            options += [
                "-e", "TRAEFIK_ENTRYPOINTS_WEBSECURE_ADDRESS=:8443",
                "-e", "TRAEFIK_PROVIDERS_FILE_DIRECTORY=/fixture/dynamic",
                "-e", "TRAEFIK_PROVIDERS_FILE_WATCH=true", args.image,
            ]
        elif mode == "file":
            options += [args.image, "traefik", "--configFile=/fixture/traefik.yml"]
        else:
            options += [
                args.image, "--entrypoints.websecure.address=:8443",
                "--providers.file.directory=/fixture/dynamic", "--providers.file.watch=true",
            ]
        container = run(*options)

    def serial():
        return run("exec", container, "sh", "-c", """
            openssl s_client -connect 127.0.0.1:8443 -servername one.example.test </dev/null 2>/dev/null |
              openssl x509 -noout -serial 2>/dev/null
        """, check=False)

    def await_serial(expected):
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            if serial() == expected:
                return
            time.sleep(1)
        raise AssertionError("Expected certificate did not become active over a real TLS connection")

    def expected_serial():
        return helper("openssl x509 -in /fixture/source/one.pem -noout -serial")

    try:
        assert "3.7.18" in run("run", "--rm", args.image, "version")
        run("run", "--rm", args.image, "--help")
        run("run", "--rm", "-e", "SENTINEL=spaces and = signs", args.image,
            "sh", "-c", 'test "$SENTINEL" = "spaces and = signs"')
        assert "3.7.18" in run("run", "--rm", "-e", "SYNC_ENABLED=false", args.image, "version")
        print("PASS: official diagnostic/arbitrary commands and environment passthrough", flush=True)
        run("volume", "create", volume)
        prepare()
        helper("""cat > /fixture/dynamic/routes.yml <<'YAML'
http:
  routers:
    test:
      rule: Host(`one.example.test`)
      entryPoints: [websecure]
      tls: {}
      service: test
  services:
    test:
      loadBalancer:
        servers:
          - url: http://127.0.0.1:9
YAML
""")
        routes_before = helper("sha256sum /fixture/dynamic/routes.yml")
        helper("""cat > /fixture/traefik.yml <<'YAML'
entryPoints:
  websecure:
    address: ':8443'
providers:
  file:
    directory: /fixture/dynamic
    watch: true
YAML
""")
        for mode in ("cli", "env", "file"):
            start(mode)
            await_serial(expected_serial())
            started = state()["StartedAt"]
            prepare()
            await_serial(expected_serial())
            assert state()["StartedAt"] == started, "Container restarted during certificate renewal"
            assert helper("sha256sum /fixture/dynamic/routes.yml") == routes_before
            run("stop", "-t", "15", container)
            assert state()["ExitCode"] == 0, f"Ungraceful shutdown: {state()}"
            run("rm", container)
            container = None
            print(f"PASS: {mode} config, TLS hot reload without restart, unchanged routes, clean SIGTERM", flush=True)

        start("cli", interval=300)
        await_serial(expected_serial())
        run("exec", container, "sh", "-ec",
            'kill -KILL "$(pgrep -f "^/bin/sh /usr/local/bin/cert-sync --loop$")"')
        deadline = time.monotonic() + 20
        while state()["Running"] and time.monotonic() < deadline:
            time.sleep(1)
        if state()["Running"]:
            print(run("exec", container, "ps", "-o", "pid,ppid,stat,args", check=False), flush=True)
            print(json.dumps(state()), flush=True)
        assert not state()["Running"], "Dead synchronizer left the proxy running"
        assert state()["ExitCode"] != 0
        run("rm", container)
        container = None
        print("PASS: unexpected sync-worker death stops the container with failure", flush=True)
    finally:
        if container:
            print(run("logs", container, check=False))
            run("rm", "-f", container, check=False)
        run("volume", "rm", volume, check=False)


if __name__ == "__main__":
    main()
