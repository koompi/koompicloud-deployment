#!/bin/bash

# Check if network already exists
if docker network ls | grep -q koompi-cloud-shared; then
    echo "Network koompi-cloud-shared already exists"
else
    # Create the shared overlay network
    echo "Creating overlay network koompi-cloud-shared..."
    docker network create \
      --driver overlay \
      --attachable \
      --scope swarm \
      koompi-cloud-shared
fi

# Verify network was created successfully
if docker network ls | grep -q koompi-cloud-shared; then
    echo "Shared overlay network 'koompi-cloud-shared' is ready"
else
    echo "ERROR: Failed to create network koompi-cloud-shared"
    exit 1
fi