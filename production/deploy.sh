#!/bin/bash

set -e  # Exit on error

# Load environment variables
export $(cat .env | grep -v '^#' | xargs)

# Step 1: Create the shared network
echo "Creating shared overlay network..."
./create-network.sh

# Wait for network to propagate across all nodes
echo "Waiting for network to propagate..."
sleep 5

# Verify network exists and is ready
if ! docker network ls | grep -q koompi-cloud-shared; then
    echo "ERROR: Network koompi-cloud-shared not found!"
    exit 1
fi

# Step 2: Deploy database stack with detach flag
echo "Deploying database stack..."
docker stack deploy --with-registry-auth --detach=false -c database.yml database

# Wait for database to be ready
echo "Waiting for database services to be ready..."
for i in {1..30}; do
    if docker service ls | grep -E "database_mongodb.*1/1" && docker service ls | grep -E "database_redis.*1/1"; then
        echo "Database services are ready!"
        break
    fi
    echo "Waiting for database services... ($i/30)"
    sleep 2
done

# Step 3: Deploy backend stack
echo "Deploying backend stack..."
docker stack deploy --with-registry-auth --detach=false -c backend.yml backend

# Wait a bit for backend services to start
echo "Waiting for backend services to initialize..."
sleep 10

# Step 4: Deploy frontend stack (if exists)
if [ -f frontend.yml ]; then
    echo "Deploying frontend stack..."
    docker stack deploy --with-registry-auth --detach=false -c frontend.yml frontend
fi

# Step 5: Deploy proxy stack (if exists)
if [ -f proxy.yml ]; then
    echo "Deploying proxy stack..."
    docker stack deploy --with-registry-auth --detach=false -c proxy.yml proxy
fi

# Step 6: Deploy registry stack (if exists)
if [ -f registry.yml ]; then
    echo "Deploying registry stack..."
    docker stack deploy --with-registry-auth --detach=false -c registry.yml registry
fi

echo "Deployment complete!"
echo ""
echo "Check status with:"
echo "  docker stack ls"
echo "  docker service ls"
echo "  docker network ls | grep koompi"