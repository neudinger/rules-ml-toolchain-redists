#!/usr/bin/env python3
"""Resolve Moore Threads MUSA APT package closures from a Packages file."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


DEP_RE = re.compile(r"^([A-Za-z0-9.+-]+)(?:\s+\(([^)]+)\))?$")
CONSTRAINT_RE = re.compile(r"^(=|>=|<=|<<|>>)\s*(\S+)$")


def parse_packages(path: Path) -> list[dict[str, str]]:
    stanzas: list[dict[str, str]] = []
    current: dict[str, str] = {}
    current_key: str | None = None

    for line in path.read_text().splitlines():
        if not line:
            if current:
                stanzas.append(current)
                current = {}
                current_key = None
            continue

        if line[0] in " \t":
            if current_key:
                current[current_key] += "\n" + line[1:]
            continue

        if ":" not in line:
            raise SystemExit(f"invalid Packages line: {line}")
        key, value = line.split(":", 1)
        current[key] = value.strip()
        current_key = key

    if current:
        stanzas.append(current)

    return stanzas


def package_index(stanzas: list[dict[str, str]]) -> dict[str, list[dict[str, str]]]:
    index: dict[str, list[dict[str, str]]] = {}
    for stanza in stanzas:
        name = stanza.get("Package")
        if not name:
            continue
        index.setdefault(name, []).append(stanza)
    return index


def parse_dep(dep: str) -> tuple[str, str | None, str | None] | None:
    match = DEP_RE.match(dep.strip())
    if not match:
        return None
    name = match.group(1)
    constraint = match.group(2)
    if not constraint:
        return name, None, None

    constraint_match = CONSTRAINT_RE.match(constraint)
    if not constraint_match:
        return name, None, None
    return name, constraint_match.group(1), constraint_match.group(2)


def choose_candidate(
    name: str,
    op: str | None,
    version: str | None,
    index: dict[str, list[dict[str, str]]],
) -> dict[str, str] | None:
    candidates = index.get(name, [])
    if not candidates:
        return None

    if op == "=" and version:
        for candidate in candidates:
            if candidate.get("Version") == version:
                return candidate
        raise SystemExit(f"package {name} has no exact version {version}")

    # Moore Threads publishes newest duplicate package stanzas first. Keep that
    # order so mccl-s5000 resolves to 2.11.4 before the older 2.3.0 entry.
    return candidates[0]


def dep_groups(depends: str) -> list[list[str]]:
    groups: list[list[str]] = []
    for group in depends.replace("\n", " ").split(","):
        alternatives = [alt.strip() for alt in group.split("|") if alt.strip()]
        if alternatives:
            groups.append(alternatives)
    return groups


def resolve(
    roots: list[str],
    index: dict[str, list[dict[str, str]]],
) -> list[dict[str, str]]:
    resolved: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    queue: list[tuple[str, bool]] = [(root, True) for root in roots]

    while queue:
        dep, required = queue.pop(0)
        parsed = parse_dep(dep)
        if not parsed:
            if required:
                raise SystemExit(f"invalid root package expression: {dep}")
            continue

        name, op, version = parsed
        candidate = choose_candidate(name, op, version, index)
        if candidate is None:
            if required:
                raise SystemExit(f"root package not found in MUSA APT index: {name}")
            continue

        key = (candidate["Package"], candidate["Version"])
        if key in seen:
            continue
        seen.add(key)
        resolved.append(candidate)

        for group in dep_groups(candidate.get("Depends", "")):
            selected = None
            for alternative in group:
                parsed_alternative = parse_dep(alternative)
                if not parsed_alternative:
                    continue
                alt_name, alt_op, alt_version = parsed_alternative
                if choose_candidate(alt_name, alt_op, alt_version, index) is not None:
                    selected = alternative
                    break
            if selected:
                queue.append((selected, False))

    return resolved


def root_packages(value: str) -> list[str]:
    packages = [p for p in re.split(r"[\s,]+", value.strip()) if p]
    if not packages:
        raise SystemExit("--root-packages must name at least one package")
    return packages


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--packages-file", required=True, type=Path)
    parser.add_argument("--root-packages", required=True)
    args = parser.parse_args()

    stanzas = parse_packages(args.packages_file)
    index = package_index(stanzas)
    resolved = resolve(root_packages(args.root_packages), index)

    for stanza in resolved:
        missing = [
            field
            for field in ["Package", "Version", "Filename", "SHA256", "Size"]
            if not stanza.get(field)
        ]
        if missing:
            raise SystemExit(
                f"package {stanza.get('Package', '<unknown>')} is missing fields: "
                + ", ".join(missing)
            )
        print(
            "\t".join(
                [
                    stanza["Package"],
                    stanza["Version"],
                    stanza["Filename"],
                    stanza["SHA256"],
                    stanza["Size"],
                ]
            )
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
