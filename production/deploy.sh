#!/bin/bash


# Load environment variables
export $(cat .env | grep -v '^#' | xargs)

# Step 1: Create the shared network
echo "Creating shared overlay network..."
./create-network.sh

# Step 2: Deploy database stack
echo "Deploying database stack..."
docker stack deploy --with-registry-auth -c database.yml database

# Wait for database to be ready
echo "Waiting for database services to be ready..."
sleep 30

# Step 3: Deploy backend stack
echo "Deploying backend stack..."
docker stack deploy --with-registry-auth -c backend.yml backend

# Step 4: Deploy frontend stack (if exists)
if [ -f frontend.yml ]; then
    echo "Deploying frontend stack..."
    docker stack deploy --with-registry-auth -c frontend.yml frontend
fi

# Step 5: Deploy proxy stack (if exists)
if [ -f proxy.yml ]; then
    echo "Deploying proxy stack..."
    docker stack deploy --with-registry-auth -c proxy.yml proxy
fi

echo "Deployment complete!"
echo ""
echo "Check status with:"
echo "  docker stack ls"
echo "  docker service ls"
echo "  docker network ls | grep koompi"