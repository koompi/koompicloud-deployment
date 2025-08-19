#!/bin/bash

# Create the shared overlay network if it doesn't exist
docker network create \
  --driver overlay \
  --attachable \
  --scope swarm \
  koompi-cloud-shared \
  2>/dev/null || echo "Network koompi-cloud-shared already exists"

echo "Shared overlay network 'koompi-cloud-shared' is ready"