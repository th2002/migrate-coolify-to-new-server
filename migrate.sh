#!/bin/bash

# This script will backup your Coolify instance and move everything to a new server,
# including Docker volumes, Coolify database, and SSH keys.

# Configuration - Modify as needed
sshKeyPath="/root/.ssh/key" # Key to the destination server
destinationHost="server_ip"
sshPort=22 # SSH port for the destination server

# -- Shouldn't need to modify anything below --
backupSourceDir="/data/coolify/"
backupFileName="coolify_backup.tar.gz"

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run the script as root"
    exit 1
fi

# Check if the source directory exists
if [ ! -d "$backupSourceDir" ]; then
    echo "❌ Source directory $backupSourceDir does not exist"
    exit 1
fi
echo "✅ Source directory exists"

# Check if the SSH key file exists
if [ ! -f "$sshKeyPath" ]; then
    echo "❌ SSH key file $sshKeyPath does not exist"
    exit 1
fi
echo "✅ SSH key file exists"

# Check if Docker is installed and running
if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker is not installed"
    exit 1
fi

if ! systemctl is-active --quiet docker; then
    echo "❌ Docker is not running"
    exit 1
fi
echo "✅ Docker is installed and running"

# Check if we can SSH to the destination server
if ! ssh -p "$sshPort" -i "$sshKeyPath" -o "StrictHostKeyChecking no" -o "ConnectTimeout=5" root@"$destinationHost" "exit"; then
    echo "❌ SSH connection to $destinationHost failed"
    exit 1
fi
echo "✅ SSH connection successful"

# Get the names of all running Docker containers
containerNames=$(docker ps --format '{{.Names}}')

# Initialize an array to hold the volume paths
volumePaths=()

# Loop over the container names and get their volumes
for containerName in $containerNames; do
    volumeNames=$(docker inspect --format '{{range .Mounts}}{{.Name}} {{end}}' "$containerName")
    for volumeName in $volumeNames; do
        if [ -n "$volumeName" ]; then
            volumePaths+=("/var/lib/docker/volumes/$volumeName/_data")
        fi
    done
done

# Calculate and print the total size of the volumes and the source directory
totalSize=$(du -csh "${volumePaths[@]}" 2>/dev/null | grep total | awk '{print $1}')
echo "✅ Total size of volumes to migrate: ${totalSize:-0}"

backupSourceDirSize=$(du -csh "$backupSourceDir" 2>/dev/null | grep total | awk '{print $1}')
echo "✅ Size of the source directory: ${backupSourceDirSize:-0}"

# Check if the backup file already exists and create it if it does not
if [ ! -f "$backupFileName" ]; then
    echo "🚸 Backup file does not exist, creating..."

    # Optionally stop Docker before creating the backup
    echo "🚸 It's recommended to stop all Docker containers before creating the backup. Do you want to stop Docker? (y/n)"
    read -rp "Answer: " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        systemctl stop docker && systemctl stop docker.socket
        echo "✅ Docker stopped"
    else
        echo "🚸 Docker not stopped, continuing with the backup"
    fi

    # Create the backup tarball with progress feedback
    tar --exclude='*.sock' -Pczf "$backupFileName" -C / "$backupSourceDir" "$HOME/.ssh/authorized_keys" "${volumePaths[@]}" --checkpoint=.1000
    if [ $? -ne 0 ]; then
        echo "❌ Backup file creation failed"
        exit 1
    fi
    echo "✅ Backup file created"
else
    echo "🚸 Backup file already exists, skipping creation"
fi

# Define the remote commands to be executed
remoteCommands="
    if systemctl is-active --quiet docker; then
        if ! systemctl stop docker; then
            echo '❌ Docker stop failed';
            exit 1;
        fi
        echo '✅ Docker stopped';
    else
        echo 'ℹ️ Docker is not a service, skipping stop command';
    fi

    cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys_backup;
    if ! tar -Pxzf - -C /; then
        echo '❌ Backup file extraction failed';
        exit 1;
    fi
    echo '✅ Backup file extracted';

    cat ~/.ssh/authorized_keys_backup ~/.ssh/authorized_keys | sort | uniq > ~/.ssh/authorized_keys_temp;
    mv ~/.ssh/authorized_keys_temp ~/.ssh/authorized_keys;
    chmod 600 ~/.ssh/authorized_keys;
    echo '✅ Authorized keys merged';

    if ! curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash; then
        echo '❌ Coolify installation failed';
        exit 1;
    fi
    echo '✅ Coolify installed';
"

# SSH to the destination server, execute the remote commands
if ! ssh -p "$sshPort" -i "$sshKeyPath" -o "StrictHostKeyChecking no" root@"$destinationHost" "$remoteCommands" <"$backupFileName"; then
    echo "❌ Remote commands execution or Docker restart failed"
    exit 1
fi
echo "✅ Remote commands executed successfully"

# Clean up - Ask the user for confirmation before removing the local backup file
echo "Do you want to remove the local backup file? (y/n)"
read -rp "Answer: " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
    if ! rm -f "$backupFileName"; then
        echo "❌ Failed to remove local backup file"
        exit 1
    fi
    echo "✅ Local backup file removed"
else
    echo "🚸 Local backup file not removed"
fi
