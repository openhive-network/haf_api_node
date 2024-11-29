import os
import subprocess

def get_git_revision(repo_path):
    try:
        repo_url = subprocess.check_output(
            ["git", "-C", repo_path, "config", "--get", "remote.origin.url"],
            stderr=subprocess.STDOUT
        ).strip().decode('utf-8')
        
        git_hash = subprocess.check_output(
            ["git", "-C", repo_path, "rev-parse", "HEAD"],
            stderr=subprocess.STDOUT
        ).strip().decode('utf-8')[:8]  # Use only the first 8 characters of the hash
        
        commit_date = subprocess.check_output(
            ["git", "-C", repo_path, "show", "-s", "--format=%ci", git_hash],
            stderr=subprocess.STDOUT
        ).strip().decode('utf-8')
        
        commit_description = subprocess.check_output(
            ["git", "-C", repo_path, "show", "-s", "--format=%s", git_hash],
            stderr=subprocess.STDOUT
        ).strip().decode('utf-8')
        
        return repo_url, git_hash, commit_date, commit_description
    except subprocess.CalledProcessError:
        return None, None, None, None

def update_env_file(env_file_path, repo_name, git_hash, commit_date, commit_description):
    updated = False
    with open(env_file_path, "r") as file:
        lines = file.readlines()
    
    with open(env_file_path, "w") as file:
        for line in lines:
            if line.startswith(f"{repo_name.upper()}_VERSION="):
                file.write(f"{repo_name.upper()}_VERSION={git_hash}  # {commit_date} - {commit_description}\n")
                updated = True
                print(f"Updated {repo_name.upper()}_VERSION to {git_hash} in .env file")
            else:
                file.write(line)
    
    if not updated:
        with open(env_file_path, "a") as file:
            file.write(f"{repo_name.upper()}_VERSION={git_hash}  # {commit_date} - {commit_description}\n")
            print(f"Added {repo_name.upper()}_VERSION={git_hash} to .env file")

def main(directory):
    env_file_path = None
    for item in os.listdir(directory):
        item_path = os.path.join(directory, item)
        if os.path.isdir(item_path) and item == "haf_api_node":
            env_file_path = os.path.join(item_path, ".env")
            break

    if not env_file_path or not os.path.exists(env_file_path):
        print("Error: .env file not found in haf_api_node repo.")
        return

    with open("repo_versions.txt", "w") as output_file:
        for item in os.listdir(directory):
            item_path = os.path.join(directory, item)
            if os.path.isdir(item_path) and ".git" in os.listdir(item_path):
                repo_url, git_hash, commit_date, commit_description = get_git_revision(item_path)
                if repo_url and git_hash and commit_date and commit_description:
                    output_file.write(f"{repo_url}, {git_hash}, {commit_date}, {commit_description}\n")
                    print(f"Found repo: {repo_url} at {item_path}")
                    repo_name = os.path.basename(item_path)
                    if repo_name != "hive":
                        update_env_file(env_file_path, repo_name, git_hash, commit_date, commit_description)

if __name__ == "__main__":
    import sys
    if len(sys.argv) != 2:
        print("Usage: python use_develop_env.py <directory>")
        print("This script updates the .env file in the haf_api_node repository with the short git hashes of other repositories in the specified directory.")
    else:
        main(sys.argv[1])
