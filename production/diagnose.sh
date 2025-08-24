#!/bin/bash

echo "=== Docker Swarm Diagnostics ==="
echo ""

# Check swarm status
echo "1. Swarm Node Status:"
docker node ls
echo ""

# Check network
echo "2. Overlay Network Status:"
docker network ls | grep koompi
echo ""

# Check failed services
echo "3. Failed Service Details (showing first 5):"
for service in $(docker service ls --format "{{.Name}}" | head -5); do
    echo "Service: $service"
    docker service ps $service --no-trunc --format "table {{.Name}}\t{{.CurrentState}}\t{{.Error}}" | head -3
    echo "---"
done
echo ""

# Check resource usage
echo "4. System Resources:"
docker system df
echo ""
echo "Memory Usage:"
free -h
echo ""

# Check recent service logs
echo "5. Recent Error Logs (last service):"
last_service=$(docker service ls --format "{{.Name}}" | head -1)
docker service logs $last_service --tail 20 2>&1 | grep -E "error|Error|ERROR|failed|Failed|FAILED" || echo "No errors in recent logs"
echo ""

# Check if images are accessible
echo "6. Registry Connectivity:"
docker pull image.koompi.org/library/koompi-cloud/gateway:latest 2>&1 | head -5
echo ""

echo "=== Diagnostic Complete ==="