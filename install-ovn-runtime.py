#!/usr/bin/env python3
"""Install a verified native OVN build before the first cloud bootstrap."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify(root, files):
    for entry in files:
        path = root / entry["path"]
        if entry["type"] == "symlink":
            if not path.is_symlink() or os.readlink(path) != entry["target"]:
                raise RuntimeError(f"Incorrect symlink: {path}")
        elif path.is_symlink() or digest(path) != entry["sha256"]:
            raise RuntimeError(f"Incorrect file: {path}")
        if entry["type"] == "file" and path.stat().st_mode & 0o777 != entry["mode"]:
            raise RuntimeError(f"Incorrect permissions: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("archive_sha256")
    parser.add_argument("manifest_sha256")
    parser.add_argument("commit")
    args = parser.parse_args()
    if digest(args.archive) != args.archive_sha256:
        raise RuntimeError("Archive checksum mismatch")
    if digest(args.manifest) != args.manifest_sha256:
        raise RuntimeError("Manifest checksum mismatch")
    manifest = json.loads(args.manifest.read_text())
    if manifest["commit"] != args.commit:
        raise RuntimeError("Unexpected OVN source commit")
    if manifest["archive"]["sha256"] != args.archive_sha256:
        raise RuntimeError("Archive does not match build provenance")
    if "--with-dbdir=/var/lib/ovn" not in manifest["configure_args"]:
        raise RuntimeError("OVN must use /var/lib/ovn from first start")
    files = manifest["files"]
    names = {entry["path"] for entry in files}
    if len(names) != len(files):
        raise RuntimeError("Duplicate manifest paths")
    for name in names:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or not name.startswith("usr/"):
            raise RuntimeError(f"Unsafe install path: {name}")
    if names & {"usr/sbin/ovsdb-server", "usr/sbin/ovs-vswitchd"}:
        raise RuntimeError("Generic OVS programs must remain archive-managed")
    record = Path("/root/ovn-source") / args.commit
    stamp = record / "installed.json"
    if stamp.exists():
        verify(Path("/"), files)
        print(json.dumps({"commit": args.commit, "already_installed": True}))
        return
    for service in ("ovn-northd", "ovn-controller", "ovn-ovsdb-server-nb", "ovn-ovsdb-server-sb"):
        result = subprocess.run(["systemctl", "is-active", service], capture_output=True, text=True)
        if result.stdout.strip() in ("active", "activating"):
            raise RuntimeError(f"OVN already started before source installation: {service}")
    for name in ("ovnnb_db.db", "ovnsb_db.db"):
        if (Path("/var/lib/ovn") / name).exists() or (Path("/etc/ovn") / name).exists():
            raise RuntimeError(f"Existing OVN DB before source installation: {name}")
    record.mkdir(parents=True, mode=0o700, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ovn-source-", dir="/root") as temporary:
        root = Path(temporary)
        with tarfile.open(args.archive) as archive:
            members = archive.getmembers()
            if {x.name for x in members if not x.isdir()} != names:
                raise RuntimeError("Archive and manifest paths differ")
            archive.extractall(root, filter="data")
        verify(root, files)
        for entry in files:
            source = root / entry["path"]
            target = Path("/") / entry["path"]
            diversion = subprocess.check_output(["dpkg-divert", "--truename", str(target)], text=True).strip()
            saved = str(target) + ".uca-before-ovn-source"
            if diversion not in (str(target), saved):
                raise RuntimeError(f"Unrelated diversion: {target}")
            if diversion == str(target) and (target.exists() or target.is_symlink()):
                subprocess.run(["dpkg-divert", "--local", "--rename", "--divert", saved, "--add", str(target)], check=True)
            target.parent.mkdir(parents=True, exist_ok=True)
            new = target.with_name(target.name + ".ovn-source-new")
            new.unlink(missing_ok=True)
            if entry["type"] == "symlink":
                new.symlink_to(entry["target"])
            else:
                shutil.copy2(source, new)
            os.replace(new, target)
    verify(Path("/"), files)
    for service in ("ovn-northd", "ovn-ovsdb-server-nb", "ovn-ovsdb-server-sb"):
        directory = Path("/etc/systemd/system") / (service + ".service.d")
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "ovn-source.conf").write_text("[Service]\nEnvironment=OVN_DBDIR=/var/lib/ovn\n")
    # The Ubuntu services manage NB/SB independently of northd.
    stop = Path("/etc/systemd/system/ovn-northd.service.d/ovn-source.conf")
    with stop.open("a") as stream:
        stream.write("ExecStop=\nExecStop=/usr/share/ovn/scripts/ovn-ctl stop_northd --ovn-manage-ovsdb=no --no-monitor\n")
    shutil.copy2(args.manifest, record / "manifest.json")
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    stamp.write_text(json.dumps({"commit": args.commit, "archive_sha256": args.archive_sha256, "installed_before_bootstrap": True, "installed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat()}, indent=2))
    print(json.dumps({"commit": args.commit, "files": len(files), "installed_before_bootstrap": True}))


if __name__ == "__main__":
    main()
