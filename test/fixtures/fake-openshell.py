#!/usr/bin/env python3
"""A stand-in for NVIDIA OpenShell's command line, for the sandbox tests.

It answers the calls harness-sandbox.el makes -- `status -o json`, the
`--help` of `sandbox create|exec|delete`, `sandbox create`, `sandbox exec`
and `sandbox delete` -- the way openshell 0.1.5 does, and checks what the
real gateway checks of them: the policy file against the documented schema,
the driver config's mounts against the Docker driver's rules, a sandbox's
name.  `sandbox exec` runs the command the way the supervisor runs it, as
`bash -c 'cd DIR && NAME=value ... quoted-argv'`, and where bwrap works it
does so in what the sandbox's mounts and policy describe, so that a test
sees what a command could reach: the image's /usr and /etc (the host's),
the mounts of the driver config, a private /tmp, no network unless the
policy has network rules.  It is no OpenShell: it takes every unknown
option as a failure, and enforces nothing the policy says beyond that.

Every call is appended to $FAKE_OPENSHELL_STATE/calls.log, as a JSON line.
What the stand-in does is set by these environment variables:

  FAKE_OPENSHELL_STATE      where it keeps its sandboxes and its log (required)
  FAKE_OPENSHELL_STATUS     what `status` says: connected (default),
                            disconnected, error, not_configured, auth-failed
  FAKE_OPENSHELL_OLD        non-empty: a program without --no-auto-providers
  FAKE_OPENSHELL_BIND_MOUNTS
                            `off': the gateway refuses bind mounts
  FAKE_OPENSHELL_CREATE_FAIL
                            non-empty: `sandbox create` fails with this text
  FAKE_OPENSHELL_DELETE_DELAY
                            seconds `sandbox delete` takes
  FAKE_OPENSHELL_NEED_CWD   seconds after it starts that it asks for its working
                            directory, which fails when that was removed
  FAKE_OPENSHELL_RUNTIME    `bwrap' (default where bwrap can start) or `none':
                            run the command unconfined, in its directory
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

STATE = os.environ.get("FAKE_OPENSHELL_STATE")
CONTROL_ROOTS = ["/opt/openshell", "/etc/openshell", "/etc/openshell-tls", "/run/openshell",
                 "/run/openshell-sidecar", "/run/netns", "/var/run/netns"]
HELP_FLAGS = {
    "create": ["--name", "--from", "--no-keep", "--driver-config-json", "--policy", "--no-tty",
               "--detach", "--no-auto-providers", "--label", "--env"],
    "exec": ["--name", "--workdir", "--timeout", "--no-tty", "--no-login-shell", "--env"],
    "delete": ["--all"],
}
MAX_ARG = 32 * 1024


def fail(message, status=1):
    sys.stderr.write("Error: %s\n" % message)
    sys.exit(status)


def log(record):
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "calls.log"), "a") as f:
        f.write(json.dumps(record) + "\n")


# ---------------------------------------------------------------- the policy

def unquote(text):
    """The string of a double-quoted YAML scalar, as the harness writes them."""
    text = text.strip()
    if not (len(text) >= 2 and text[0] == '"' and text[-1] == '"'):
        fail("policy: %r is not a quoted string" % text)
    return json.loads(re.sub(r"\\x([0-9A-Fa-f]{2})", r"\\u00\1", text))


def parse_policy(path):
    """Read the subset of YAML the harness writes, strictly, as a dict."""
    if not os.path.isfile(path):
        fail("sandbox policy source is not a regular file: %s" % path)
    policy = {}
    section = key = rule = endpoint = None
    for number, raw in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        line = raw.strip()
        where = "policy line %d" % number
        if indent == 0:
            name, _, value = line.partition(":")
            if name not in ("version", "filesystem_policy", "landlock", "process", "network_policies"):
                fail("%s: unknown field `%s'" % (where, name))
            if name in policy:
                fail("%s: duplicate key `%s'" % (where, name))
            section, key, rule = name, None, None
            policy[name] = int(value) if name == "version" else {}
        elif section == "filesystem_policy":
            if indent == 2:
                name, _, value = line.partition(":")
                if name == "include_workdir":
                    policy[section][name] = value.strip() == "true"
                elif name in ("read_only", "read_write"):
                    policy[section][name] = []
                    key = name
                else:
                    fail("%s: unknown field `%s'" % (where, name))
            elif indent == 4 and line.startswith("- ") and key:
                policy[section][key].append(unquote(line[2:]))
            else:
                fail("%s: cannot read `%s'" % (where, line))
        elif section in ("landlock", "process"):
            name, _, value = line.partition(":")
            allowed = {"landlock": ("compatibility",), "process": ("run_as_user", "run_as_group")}[section]
            if indent != 2 or name not in allowed:
                fail("%s: unknown field `%s'" % (where, name))
            policy[section][name] = unquote(value) if value.strip().startswith('"') else value.strip()
        elif section == "network_policies":
            if indent == 2:
                rule = line[:-1] if line.endswith(":") else fail("%s: a rule is NAME:" % where)
                if rule.startswith("_provider_"):
                    fail("%s: rule keys cannot start with _provider_" % where)
                policy[section][rule] = {"endpoints": [], "binaries": []}
                key = None
            elif indent == 4 and line in ("endpoints:", "binaries:"):
                key = line[:-1]
            elif indent == 6 and key == "endpoints" and line.startswith("- host:"):
                endpoint = {"host": unquote(line[len("- host:"):])}
                policy[section][rule]["endpoints"].append(endpoint)
            elif indent == 8 and key == "endpoints":
                name, _, value = line.partition(":")
                if name == "port":
                    endpoint["ports"] = [int(value)]
                elif name == "ports":
                    endpoint["ports"] = [int(p) for p in value.strip().strip("[]").split(",")]
                else:
                    fail("%s: unknown endpoint field `%s'" % (where, name))
            elif indent == 6 and key == "binaries" and line.startswith("- path:"):
                policy[section][rule]["binaries"].append(unquote(line[len("- path:"):]))
            else:
                fail("%s: cannot read `%s'" % (where, line))
        else:
            fail("%s: cannot read `%s'" % (where, line))
    validate_policy(policy)
    return policy


def validate_policy(policy):
    """The constraints of the policy schema reference."""
    if policy.get("version") != 1:
        fail("unsupported policy version %r; expected version 1" % policy.get("version"))
    fs = policy.get("filesystem_policy", {})
    paths = fs.get("read_only", []) + fs.get("read_write", [])
    if len(paths) > 256:
        fail("filesystem_policy lists %d paths; at most 256" % len(paths))
    for path in paths:
        if not path.startswith("/") or ".." in path.split("/") or len(path.encode()) > 4096:
            fail("filesystem path %r must be absolute, without .., at most 4096 bytes" % path)
    if "/" in fs.get("read_write", []):
        fail("filesystem_policy.read_write cannot contain /")
    both = set(fs.get("read_only", [])) & set(fs.get("read_write", []))
    if both:
        fail("filesystem path %s is listed both read-only and read-write" % sorted(both)[0])
    compat = policy.get("landlock", {}).get("compatibility")
    if compat not in (None, "best_effort", "hard_requirement"):
        fail("landlock.compatibility must be best_effort or hard_requirement, not %r" % compat)
    for field, value in policy.get("process", {}).items():
        if value != "sandbox" and not (value.isdigit() and 1 <= int(value) <= 4294967294):
            fail("process.%s must be `sandbox' or a numeric id from 1, not %r" % (field, value))
    for name, rule in policy.get("network_policies", {}).items():
        if not rule["endpoints"] or not rule["binaries"]:
            fail("network rule %s needs endpoints and binaries" % name)
        for endpoint in rule["endpoints"]:
            host = endpoint["host"]
            if "*" in host and len(host.split(".")) < 3:
                fail("a wildcard host must have at least three DNS labels: %s" % host)
            if not endpoint.get("ports") or not all(1 <= p <= 65535 for p in endpoint["ports"]):
                fail("endpoint %s needs port or ports" % host)


# ---------------------------------------------------------------- the mounts

def validate_target(target):
    if not target.startswith("/") or re.search(r"[\x00-\x1f]", target):
        fail("mount target %r must be an absolute container path" % target)
    parts = target.split("/")[1:]
    if any(p in (".", "..") for p in parts[:-1]) or "" in parts[:-1] or parts[-1] in (".", ".."):
        fail("mount target %r must be normalized without empty, '.', or '..' path segments" % target)
    normalized = target.rstrip("/")
    if not normalized:
        fail("mount target must not be the container root")
    for root in CONTROL_ROOTS:
        if normalized == root or normalized.startswith(root + "/") or root.startswith(normalized + "/"):
            fail("mount target '%s' conflicts with reserved OpenShell path '%s'" % (target, root))
    if normalized == "/sandbox" or "/sandbox".startswith(normalized + "/"):
        fail("mount target '%s' is reserved for the OpenShell workspace" % target)
    return normalized


def parse_driver_config(text):
    try:
        config = json.loads(text)
    except ValueError as e:
        fail("invalid --driver-config-json: %s" % e)
    if not isinstance(config, dict) or list(config) not in (["docker"], ["podman"], ["vm"], ["kubernetes"]):
        fail("--driver-config-json must be an object keyed by the driver's name")
    driver = list(config)[0]
    if driver != os.environ.get("FAKE_OPENSHELL_DRIVER", "docker"):
        return []  # not this gateway's block: forwarded to nobody
    block = config[driver]
    if set(block) - {"mounts"}:
        fail("invalid %s driver_config: unknown field" % driver)
    mounts, targets = [], set()
    for mount in block.get("mounts", []):
        kind = mount.get("type")
        known = {"bind": {"type", "source", "target", "read_only", "selinux_label"},
                 "tmpfs": {"type", "target", "options", "size_bytes", "mode"}}.get(kind)
        if known is None or set(mount) - known:
            fail("invalid %s driver_config: bad mount %s" % (driver, json.dumps(mount)))
        if kind == "bind":
            if os.environ.get("FAKE_OPENSHELL_BIND_MOUNTS") == "off":
                fail("docker bind mounts require enable_bind_mounts = true in [openshell.drivers.docker]")
            source = mount["source"]
            if not os.path.isabs(source) or source != source.strip():
                fail("bind source must be an absolute host path")
        target = validate_target(mount["target"])
        if target in targets:
            fail("duplicate docker driver_config mount target '%s'" % target)
        targets.add(target)
        mounts.append({"type": kind, "source": mount.get("source"), "target": target,
                       "read_only": mount.get("read_only", True), "mode": mount.get("mode")})
    return mounts


def check_policy_against_mounts(policy, mounts):
    """Landlock denies what the policy does not list: a mount it does not name is useless."""
    fs = policy.get("filesystem_policy", {})
    listed = {"ro": fs.get("read_only", []), "rw": fs.get("read_write", [])}
    for mount in mounts:
        want = "ro" if mount["type"] == "bind" and mount["read_only"] else "rw"
        if not any(mount["target"] == p or mount["target"].startswith(p.rstrip("/") + "/")
                   for p in listed[want] + (listed["rw"] if want == "ro" else [])):
            fail("the policy does not allow %s of %s" % ("reading" if want == "ro" else "writing", mount["target"]))
        if want == "rw" and not any(mount["target"] == p or mount["target"].startswith(p.rstrip("/") + "/")
                                    for p in listed["rw"]):
            fail("the policy does not allow writing %s" % mount["target"])


# ---------------------------------------------------------------- the calls

def shell_escape(value):
    if "\0" in value:
        fail("value contains null bytes")
    if value == "":
        return "''"
    if re.fullmatch(r"[A-Za-z0-9./_-]+", value):
        return value
    return "'" + value.replace("'", "'\"'\"'") + "'"


def sandbox_file(name):
    return os.path.join(STATE, "sandboxes", name + ".json")


def take_options(args, flags, with_value):
    """Split ARGS at the first `--' into options (a dict, a list for repeats) and the rest."""
    options, rest, i = {}, [], 0
    while i < len(args):
        arg = args[i]
        if arg == "--":
            rest = args[i + 1:]
            break
        if arg in with_value:
            if i + 1 >= len(args):
                fail("a value is required for '%s'" % arg)
            options.setdefault(arg, []).append(args[i + 1])
            i += 2
        elif arg in flags:
            options[arg] = [True]
            i += 1
        else:
            fail("unexpected argument '%s' found" % arg, 2)
    return options, rest


def cmd_status(args):
    status = os.environ.get("FAKE_OPENSHELL_STATUS", "connected")
    out = {"gateway": "fake", "server": "https://127.0.0.1:17670"}
    if status == "connected":
        out.update(status="connected", version="0.1.5",
                   authentication={"status": "authenticated", "provider": "mTLS transport"})
    elif status == "auth-failed":
        out.update(status="connected", version="0.1.5",
                   authentication={"status": "failed", "error": "token expired"})
    elif status == "not_configured":
        out = {"status": "not_configured"}
    else:
        out.update(status=status, error="connection refused",
                   authentication={"status": "unverified", "reason": "gateway unreachable"})
    print(json.dumps(out, indent=2))


def cmd_help(which):
    flags = list(HELP_FLAGS[which])
    if which == "create" and os.environ.get("FAKE_OPENSHELL_OLD"):
        flags.remove("--no-auto-providers")
    print("Usage: openshell sandbox %s [OPTIONS]\n\nFLAGS:" % which)
    for flag in flags:
        print("      %s" % flag)


def cmd_create(args):
    options, command = take_options(
        args, {"--detach", "--no-keep", "--no-tty", "--tty", "--no-auto-providers", "--auto-providers", "--keep"},
        {"--name", "--from", "--driver-config-json", "--policy", "--label", "--env", "--cpu", "--memory"})
    name = (options.get("--name") or [""])[0]
    if not re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", name) or len(name) > 63:
        fail("name %r is not a valid DNS-1123 label" % name)
    if os.path.exists(sandbox_file(name)):
        fail("sandbox %s already exists" % name)
    if os.environ.get("FAKE_OPENSHELL_CREATE_FAIL"):
        fail(os.environ["FAKE_OPENSHELL_CREATE_FAIL"])
    if not command or not command[0]:
        fail("spec.command[0] must not be empty")
    policy = parse_policy(options["--policy"][0]) if "--policy" in options else {}
    mounts = parse_driver_config(options["--driver-config-json"][0]) if "--driver-config-json" in options else []
    check_policy_against_mounts(policy, mounts)
    os.makedirs(os.path.join(STATE, "sandboxes"), exist_ok=True)
    with open(sandbox_file(name), "w") as f:
        json.dump({"name": name, "policy": policy, "mounts": mounts, "image": (options.get("--from") or [None])[0],
                   "command": command, "labels": options.get("--label", [])}, f)
    # What the real one prints around the command, and a script must not take for its output.
    print("Created sandbox: %s\n  00:00 Requesting compute...\n  00:01 Sandbox ready" % name)


def bwrap_runtime():
    return os.environ.get("FAKE_OPENSHELL_RUNTIME", "bwrap") == "bwrap" and shutil.which("bwrap")


def bwrap_command(box, shell):
    """The bwrap line that is the container: the image is the host's /usr and /etc."""
    cmd = [shutil.which("bwrap"), "--clearenv", "--setenv", "PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
           "--ro-bind", "/usr", "/usr", "--ro-bind", "/etc", "/etc"]
    for d in ("/lib", "/lib64", "/bin", "/sbin"):
        if os.path.islink(d):
            cmd += ["--symlink", os.readlink(d), d]
        elif os.path.isdir(d):
            cmd += ["--ro-bind", d, d]
    cmd += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"]
    # The runtime mounts shallow targets before the ones below them.
    for mount in sorted(box["mounts"], key=lambda m: m["target"].count("/")):
        if mount["type"] == "tmpfs":
            cmd += ["--perms", "%o" % (mount["mode"] or 0o755), "--tmpfs", mount["target"]]
        else:
            cmd += ["--ro-bind" if mount["read_only"] else "--bind", mount["source"], mount["target"]]
    policy = box["policy"]
    if not policy.get("network_policies"):
        cmd += ["--unshare-net"]
    return cmd + ["--unshare-pid", "--unshare-ipc", "--unshare-uts", "--die-with-parent", "--new-session"] + shell


def cmd_exec(args):
    options, command = take_options(
        args, {"--no-tty", "--tty", "--no-login-shell"}, {"--name", "-n", "--workdir", "--timeout", "--env"})
    name = (options.get("--name") or options.get("-n") or [""])[0]
    if not os.path.exists(sandbox_file(name)):
        fail("sandbox '%s' not found" % name)
    box = json.load(open(sandbox_file(name)))
    if len(command) > 1024 or any(len(c.encode()) > MAX_ARG for c in command):
        fail("command argument exceeds %d byte limit" % MAX_ARG)
    env = {}
    for pair in options.get("--env", []):
        key, _, value = pair.partition("=")
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key) or key.startswith("OPENSHELL_") or "\n" in value:
            fail("environment keys must match ^[A-Za-z_][A-Za-z0-9_]*$; got '%s'" % key)
        env[key] = value
    parts = ["%s=%s" % (k, shell_escape(v)) for k, v in sorted(env.items())] + [shell_escape(c) for c in command]
    line = " ".join(parts)
    workdir = (options.get("--workdir") or [""])[0]
    if workdir:
        line = "cd %s && %s" % (shell_escape(workdir), line)
    shell = ["bash", "-c", line]
    if bwrap_runtime():
        argv = bwrap_command(box, shell)
        cwd = None
    else:
        argv, cwd = shell, (workdir if workdir and os.path.isdir(workdir) else None)
    sys.stdout.flush()
    proc = subprocess.Popen(argv, cwd=cwd)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda s, _f: (proc.send_signal(s), None))
    status = proc.wait()
    sys.exit(128 - status if status < 0 else status)


def cmd_delete(args):
    time.sleep(float(os.environ.get("FAKE_OPENSHELL_DELETE_DELAY", "0")))
    for name in args:
        try:
            os.remove(sandbox_file(name))
        except OSError:
            pass


def main():
    if os.environ.get("FAKE_OPENSHELL_NEED_CWD"):
        # A program that needs its working directory a moment after it starts:
        # one the caller removed in between makes it fail, logging nothing.
        time.sleep(float(os.environ["FAKE_OPENSHELL_NEED_CWD"]))
        os.getcwd()
    if not STATE:
        fail("FAKE_OPENSHELL_STATE is not set")
    args = sys.argv[1:]
    log({"argv": args, "pid": os.getpid(), "gateway_env": os.environ.get("OPENSHELL_GATEWAY")})
    if args[:1] == ["--gateway"]:
        args = args[2:]
    if args[:1] == ["status"]:
        return cmd_status(args[1:])
    if args[:1] == ["sandbox"] and len(args) > 1 and args[1] in HELP_FLAGS:
        which, rest = args[1], args[2:]
        if rest == ["--help"]:
            return cmd_help(which)
        return {"create": cmd_create, "exec": cmd_exec, "delete": cmd_delete}[which](rest)
    fail("unrecognized subcommand %s" % " ".join(args), 2)


if __name__ == "__main__":
    main()
