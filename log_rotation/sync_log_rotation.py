#!/usr/bin/env python3

"""Verify (and optionally fix) that every service in the main compose stack has a
corresponding log rotation override, and that compose.log_rotation.yml includes
all log rotation files.

Usage:
    # Check mode (default) — reports drift, exits non-zero if any found
    python3 log_rotation/sync_log_rotation.py --check

    # Fix mode — creates/updates files to eliminate drift
    python3 log_rotation/sync_log_rotation.py --fix

Run from the top-level haf_api_node directory.
"""

import os
import re
import sys
import argparse

import yaml


# Files that should never be processed for log rotation
EXCLUDE_FILES = frozenset([
    'compose.yml',
    'compose.yaml',
    'compose.override.yml',
    'compose.override.yaml',
    'docker-compose.yml',
    'docker-compose.yaml',
    'docker-compose.override.yml',
    'docker-compose.override.yaml',
    '.gitlab-ci.yaml',
    '.gitlab-ci.yml',
])

LOG_ROTATION_DIR = 'log_rotation'
LOG_ROTATION_MANIFEST = os.path.join(LOG_ROTATION_DIR, 'compose.log_rotation.yml')
COMPOSE_FILE = 'compose.yml'

# Regex to extract the default value from ${VAR:-default} patterns
VAR_DEFAULT_RE = re.compile(r'\$\{[^:}]+:-([^}]+)\}')


def expand_variable_defaults(s):
    """Replace ${VAR:-default} with just 'default'."""
    return VAR_DEFAULT_RE.sub(r'\1', s)


def load_yaml(file_path):
    """Load YAML content from a file."""
    if not os.path.exists(file_path):
        return None
    with open(file_path, 'r') as f:
        try:
            return yaml.safe_load(f) or {}
        except yaml.YAMLError as exc:
            print(f"Error parsing YAML file {file_path}: {exc}", file=sys.stderr)
            sys.exit(1)


def get_included_compose_files():
    """Parse compose.yml to get the list of included files (expanding variable defaults)."""
    data = load_yaml(COMPOSE_FILE)
    if data is None:
        print(f"Error: {COMPOSE_FILE} not found", file=sys.stderr)
        sys.exit(1)

    includes = data.get('include', [])
    files = []
    for entry in includes:
        # includes can be strings or dicts with 'path' key
        if isinstance(entry, str):
            path = entry
        elif isinstance(entry, dict):
            path = entry.get('path', '')
        else:
            continue
        expanded = expand_variable_defaults(path)
        files.append((path, expanded))
    return files


def get_log_rotation_filename(compose_filename):
    """Derive the log rotation filename from a compose filename.

    e.g. 'haf_base.yaml' -> 'log_rotation/haf_base.log_rotation.yaml'
         '${JSONRPC_API_SERVER_NAME:-drone}.yaml' -> 'log_rotation/${JSONRPC_API_SERVER_NAME:-drone}.log_rotation.yaml'
    """
    base, ext = os.path.splitext(compose_filename)
    return os.path.join(LOG_ROTATION_DIR, f"{base}.log_rotation.yaml")


def get_manifest_includes():
    """Parse compose.log_rotation.yml and return the set of included file paths."""
    data = load_yaml(LOG_ROTATION_MANIFEST)
    if data is None:
        return set()
    includes = data.get('include', [])
    paths = set()
    for entry in includes:
        if isinstance(entry, str):
            paths.add(entry)
        elif isinstance(entry, dict):
            paths.add(entry.get('path', ''))
    return paths


def get_services_from_file(file_path):
    """Get all service names from a compose yaml file."""
    data = load_yaml(file_path)
    if data is None:
        return []
    return list(data.get('services', {}).keys())


def is_valid_log_rotation_entry(service_config):
    """Check if a service config in a log rotation file is a valid logging override.

    A valid entry has a 'logging' key. Entries that define their own image/command/etc
    are standalone services, not overrides.
    """
    if not isinstance(service_config, dict):
        return False
    return 'logging' in service_config


def check_log_rotation_file(log_rotation_path, expected_services):
    """Check a log rotation file for issues. Returns list of problem descriptions."""
    problems = []
    data = load_yaml(log_rotation_path)

    if data is None:
        problems.append(f"  missing file: {log_rotation_path}")
        return problems

    lr_services = data.get('services', {})

    # Check for services that are overrides for non-existent main services
    for svc_name, svc_config in lr_services.items():
        if svc_name not in expected_services:
            problems.append(f"  {log_rotation_path}: service '{svc_name}' not in main compose file")
        elif not is_valid_log_rotation_entry(svc_config):
            problems.append(f"  {log_rotation_path}: service '{svc_name}' is not a valid logging override (missing 'logging' key)")

    # Check for main services missing from log rotation
    for svc in expected_services:
        if svc not in lr_services:
            problems.append(f"  {log_rotation_path}: missing override for service '{svc}'")

    return problems


def fix_log_rotation_file(log_rotation_path, expected_services):
    """Create or update a log rotation file to match expected services."""
    data = load_yaml(log_rotation_path)

    if data is None:
        data = {'services': {}}

    services = data.get('services', {})

    # Remove services not in main compose
    for svc in list(services.keys()):
        if svc not in expected_services:
            del services[svc]

    # Remove invalid entries (non-override services)
    for svc in list(services.keys()):
        if not is_valid_log_rotation_entry(services[svc]):
            del services[svc]

    # Add missing services
    for svc in expected_services:
        if svc not in services:
            services[svc] = {'logging': {'driver': 'local'}}

    data['services'] = services

    os.makedirs(os.path.dirname(log_rotation_path), exist_ok=True)
    with open(log_rotation_path, 'w') as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)


def fix_manifest(expected_includes):
    """Update compose.log_rotation.yml to include all expected files."""
    includes = sorted(expected_includes)
    with open(LOG_ROTATION_MANIFEST, 'w') as f:
        f.write("include:\n")
        for path in includes:
            f.write(f"  - {path}\n")


def main():
    parser = argparse.ArgumentParser(
        description='Verify or fix log rotation configuration drift')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--check', action='store_true', default=True,
                       help='Check for drift and report (default)')
    group.add_argument('--fix', action='store_true',
                       help='Automatically fix drift')
    args = parser.parse_args()

    # --fix implies not --check
    if args.fix:
        args.check = False

    if not os.path.exists(COMPOSE_FILE):
        print(f"Error: {COMPOSE_FILE} not found. Run this script from the top-level haf_api_node directory.",
              file=sys.stderr)
        sys.exit(1)

    included_files = get_included_compose_files()
    all_problems = []
    expected_manifest_includes = set()

    for original_path, expanded_path in included_files:
        # Skip files we shouldn't process
        basename = os.path.basename(expanded_path)
        if basename in EXCLUDE_FILES:
            continue

        # Skip files that don't exist (e.g. variable expansion yielded wrong default)
        if not os.path.exists(expanded_path):
            all_problems.append(f"  warning: {expanded_path} (from '{original_path}') does not exist")
            continue

        # Determine the log rotation file path (preserving variables in the name)
        lr_path = get_log_rotation_filename(original_path)
        lr_path_expanded = get_log_rotation_filename(expanded_path)

        # Get expected services from the main compose file
        services = get_services_from_file(expanded_path)
        if not services:
            continue

        # Track what should be in the manifest
        expected_manifest_includes.add(lr_path)

        if args.fix:
            fix_log_rotation_file(lr_path_expanded, services)
            print(f"Fixed: {lr_path_expanded}")
        else:
            problems = check_log_rotation_file(lr_path_expanded, services)
            all_problems.extend(problems)

    # Check/fix the manifest
    current_manifest = get_manifest_includes()
    if args.fix:
        fix_manifest(expected_manifest_includes)
        print(f"Fixed: {LOG_ROTATION_MANIFEST}")
    else:
        missing_from_manifest = expected_manifest_includes - current_manifest
        extra_in_manifest = current_manifest - expected_manifest_includes
        for path in sorted(missing_from_manifest):
            all_problems.append(f"  {LOG_ROTATION_MANIFEST}: missing include for '{path}'")
        for path in sorted(extra_in_manifest):
            all_problems.append(f"  {LOG_ROTATION_MANIFEST}: includes '{path}' which is not a main compose file")

    if all_problems:
        print("Log rotation drift detected:")
        for p in all_problems:
            print(p)
        print(f"\nRun with --fix to auto-repair, or fix manually.")
        sys.exit(1)
    elif not args.fix:
        print("No log rotation drift detected.")


if __name__ == "__main__":
    main()
