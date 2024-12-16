#!/usr/bin/env python3

# This helper script can be run after editing the main .yaml files in the top-level
# haf_api_node directory.  It will detect when new services have been added or removed,
# and it will update the corresponding yaml files in this directory by adding or removing
# services.  Newly-detected services will be added with a default config, edit by hand
# if you want to add rotation.
#
# You'll need to edit compose.yml yourself if you've added/removed new yaml files
#
# Run this script from the top-level haf_api_node directory (..)

import os
import yaml
import sys

def load_yaml(file_path):
    """Load YAML content from a file."""
    if not os.path.exists(file_path):
        return {}
    with open(file_path, 'r') as f:
        try:
            return yaml.safe_load(f) or {}
        except yaml.YAMLError as exc:
            print(f"Error parsing YAML file {file_path}: {exc}")
            sys.exit(1)

def save_yaml(data, file_path):
    """Save YAML content to a file."""
    with open(file_path, 'w') as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)

def ensure_log_rotation_directory(log_rotation_dir):
    """Ensure the log_rotation directory exists."""
    if not os.path.exists(log_rotation_dir):
        os.makedirs(log_rotation_dir)
        print(f"Created directory: {log_rotation_dir}")

def get_top_level_yaml_files(top_level_dir, exclude_files=None):
    """Get all .yaml files in the top-level directory, excluding specified files."""
    if exclude_files is None:
        exclude_files = []
    yaml_files = []
    for file in os.listdir(top_level_dir):
        if (
            file.endswith('.yaml') or file.endswith('.yml')
        ) and os.path.isfile(os.path.join(top_level_dir, file)) and file not in exclude_files:
            yaml_files.append(file)
    return yaml_files

def sync_log_rotation(top_level_dir, log_rotation_dir, exclude_files=None):
    """Synchronize log rotation configurations with top-level Docker Compose files."""
    if exclude_files is None:
        exclude_files = []
    ensure_log_rotation_directory(log_rotation_dir)
    yaml_files = get_top_level_yaml_files(top_level_dir, exclude_files)

    for yaml_file in yaml_files:
        top_yaml_path = os.path.join(top_level_dir, yaml_file)
        top_yaml = load_yaml(top_yaml_path)
        services = top_yaml.get('services', {}).keys()

        log_rotation_file = os.path.splitext(yaml_file)[0] + '.log_rotation.yaml'
        log_rotation_path = os.path.join(log_rotation_dir, log_rotation_file)

        log_yaml = load_yaml(log_rotation_path)
        log_services = log_yaml.get('services', {})

        # Remove services that no longer exist
        removed_services = set(log_services.keys()) - set(services)
        if removed_services:
            for svc in removed_services:
                del log_services[svc]
            print(f"Removed services from {log_rotation_file}: {', '.join(removed_services)}")

        # Add new services with default logging config
        added_services = set(services) - set(log_services.keys())
        if added_services:
            for svc in added_services:
                log_services[svc] = {
                    'logging': {
                        'driver': 'local'
                    }
                }
            print(f"Added services to {log_rotation_file}: {', '.join(added_services)}")

        # Update the log_yaml structure
        log_yaml['services'] = log_services

        # Save the updated log rotation file
        save_yaml(log_yaml, log_rotation_path)
        print(f"Updated log rotation file: {log_rotation_file}")

def main():
    """Main function to execute the synchronization."""
    top_level_dir = os.getcwd()  # Current working directory
    log_rotation_dir = os.path.join(top_level_dir, 'log_rotation')
    exclude_files = ['compose.yml', 'compose.yaml', '.gitlab-ci.yaml', '.gitlab-ci.yml']  # Add any other files to exclude if necessary

    sync_log_rotation(top_level_dir, log_rotation_dir, exclude_files)

if __name__ == "__main__":
    main()
