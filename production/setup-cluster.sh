#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/server.json"
SSH_KEY=""
USE_GLUSTERFS=false
SERVERS=()
IS_MANAGER=false
SWARM_TOKEN=""
MANAGER_IP=""

# Docker images to pre-pull - based on actual services
DOCKER_IMAGES=(
    # Database services
    "mongo:7.0"
    "redis:7-alpine"
    "mariadb:11"
    
    # Proxy and registry
    "jc21/nginx-proxy-manager:latest"
    "registry:2"
    
    # KoompiCloud services
    "image.koompi.org/library/koompi-cloud/secrets-service:latest"
    "image.koompi.org/library/koompi-cloud/repository-service:latest"
    "image.koompi.org/library/koompi-cloud/deployment-service:latest"
    "image.koompi.org/library/koompi-cloud/service-manager:latest"
    "image.koompi.org/library/koompi-cloud/auth-service:latest"
    "image.koompi.org/library/koompi-cloud/project-service:latest"
    "image.koompi.org/library/koompi-cloud/domain-service:latest"
    "image.koompi.org/library/koompi-cloud/database-service:latest"
    "image.koompi.org/library/koompi-cloud/notification-service:latest"
    "image.koompi.org/library/koompi-cloud/registry-service:latest"
    "image.koompi.org/library/koompi-cloud/stack-service:latest"
    "image.koompi.org/library/koompi-cloud/capsule-service:latest"
    "image.koompi.org/library/koompi-cloud/template-service:latest"
    "image.koompi.org/library/koompi-cloud/build-service:latest"
    "image.koompi.org/library/koompi-cloud/metrics-service:latest"
    "image.koompi.org/library/koompi-cloud/metrics-worker:latest"
    "image.koompi.org/library/koompi-cloud/monitor-service:latest"
    "image.koompi.org/library/koompi-cloud/monitor-worker:latest"
    "image.koompi.org/library/koompi-cloud/license-service:latest"
    "image.koompi.org/library/koompi-cloud/gateway:latest"
    "image.koompi.org/library/koompi-cloud/capsule-runtime:latest"
    
    # Frontend services
    "image.koompi.org/library/koompi-cloud/dynamic-serve:latest"
    "image.koompi.org/library/koompi-cloud/frontend:latest"
)

# Helper functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

confirm() {
    local prompt="$1"
    local response
    while true; do
        read -p "$prompt [y/n]: " response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# Check if Docker is installed
check_docker() {
    print_info "Checking Docker installation..."
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed!"
        if confirm "Would you like to install Docker?"; then
            install_docker
        else
            print_error "Docker is required. Exiting."
            exit 1
        fi
    else
        print_success "Docker is installed: $(docker --version)"
    fi
}

# Install Docker
install_docker() {
    print_info "Installing Docker..."
    
    # Detect OS
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if [ -f /etc/debian_version ]; then
            # Debian/Ubuntu
            sudo apt-get update
            sudo apt-get install -y \
                ca-certificates \
                curl \
                gnupg \
                lsb-release
            
            # Add Docker's official GPG key
            sudo mkdir -m 0755 -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            
            # Set up the repository
            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Install Docker Engine
            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            
        elif [ -f /etc/redhat-release ]; then
            # RHEL/CentOS/Fedora
            sudo yum install -y yum-utils
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        else
            print_error "Unsupported Linux distribution"
            exit 1
        fi
        
        # Start and enable Docker
        sudo systemctl start docker
        sudo systemctl enable docker
        
        # Add current user to docker group
        sudo usermod -aG docker $USER
        
        print_success "Docker installed successfully"
        print_warning "You may need to log out and back in for group changes to take effect"
    else
        print_error "Automatic Docker installation not supported for this OS"
        print_info "Please install Docker manually: https://docs.docker.com/get-docker/"
        exit 1
    fi
}

# Check Docker Swarm status
check_swarm() {
    print_info "Checking Docker Swarm status..."
    
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        print_success "Docker Swarm is already initialized"
        
        # Check if this is a manager node
        if docker node ls &>/dev/null; then
            IS_MANAGER=true
            print_info "This is a Swarm manager node"
        else
            print_info "This is a Swarm worker node"
        fi
        return 0
    else
        print_warning "Docker Swarm is not initialized"
        return 1
    fi
}

# Initialize Docker Swarm
init_swarm() {
    print_info "Initializing Docker Swarm..."
    
    # Get the default IP address
    DEFAULT_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
    
    read -p "Enter the IP address for Swarm manager (default: $DEFAULT_IP): " MANAGER_IP
    MANAGER_IP=${MANAGER_IP:-$DEFAULT_IP}
    
    if docker swarm init --advertise-addr "$MANAGER_IP"; then
        print_success "Docker Swarm initialized successfully"
        IS_MANAGER=true
        
        # Get join tokens
        SWARM_TOKEN=$(docker swarm join-token worker -q)
        print_info "Worker join token: $SWARM_TOKEN"
        
        # Save tokens to file
        echo "MANAGER_IP=$MANAGER_IP" > "${SCRIPT_DIR}/swarm-tokens.txt"
        echo "WORKER_TOKEN=$SWARM_TOKEN" >> "${SCRIPT_DIR}/swarm-tokens.txt"
        echo "MANAGER_TOKEN=$(docker swarm join-token manager -q)" >> "${SCRIPT_DIR}/swarm-tokens.txt"
        
        print_success "Swarm tokens saved to swarm-tokens.txt"
    else
        print_error "Failed to initialize Docker Swarm"
        exit 1
    fi
}

# Load server configuration
load_server_config() {
    print_info "Checking for server configuration..."
    
    if [ -f "$CONFIG_FILE" ]; then
        print_success "Found server configuration: $CONFIG_FILE"
        # Parse JSON configuration (requires jq)
        if command -v jq &> /dev/null; then
            mapfile -t SERVERS < <(jq -r '.servers[].host' "$CONFIG_FILE" 2>/dev/null || true)
            SSH_KEY=$(jq -r '.ssh_key // ""' "$CONFIG_FILE" 2>/dev/null || true)
        else
            print_warning "jq is not installed. Cannot parse server.json automatically."
        fi
    else
        print_info "No server configuration file found"
    fi
}

# Configure servers
configure_servers() {
    print_info "Server configuration setup..."
    
    # Ask about number of servers
    read -p "How many servers do you have? (1 for single server): " SERVER_COUNT
    
    if [[ "$SERVER_COUNT" =~ ^[0-9]+$ ]] && [ "$SERVER_COUNT" -ge 1 ]; then
        if [ "$SERVER_COUNT" -eq 1 ]; then
            print_info "Single server setup selected"
            
            if confirm "Do you plan to add more servers later for redundancy?"; then
                print_info "Configuring for future multi-server expansion..."
                USE_GLUSTERFS=true
            elif confirm "Would you like to set up GlusterFS anyway (for future expansion)?"; then
                USE_GLUSTERFS=true
            fi
        else
            print_info "Multi-server setup selected ($SERVER_COUNT servers)"
            
            # Collect server information
            for ((i=1; i<=SERVER_COUNT; i++)); do
                read -p "Enter IP/hostname for server $i: " SERVER_IP
                SERVERS+=("$SERVER_IP")
            done
            
            if confirm "Would you like to set up GlusterFS for distributed storage?"; then
                USE_GLUSTERFS=true
            fi
        fi
    else
        print_error "Invalid server count"
        exit 1
    fi
    
    # Ask about SSH key
    if [ ${#SERVERS[@]} -gt 0 ]; then
        if confirm "Do you have an SSH key for passwordless authentication?"; then
            read -p "Enter path to SSH private key: " SSH_KEY_PATH
            if [ -f "$SSH_KEY_PATH" ]; then
                SSH_KEY="$SSH_KEY_PATH"
                print_success "SSH key configured: $SSH_KEY"
            else
                print_error "SSH key file not found: $SSH_KEY_PATH"
            fi
        fi
    fi
    
    # Save configuration
    save_server_config
}

# Save server configuration
save_server_config() {
    print_info "Saving server configuration..."
    
    cat > "$CONFIG_FILE" <<EOF
{
  "servers": [
EOF
    
    if [ ${#SERVERS[@]} -gt 0 ]; then
        for i in "${!SERVERS[@]}"; do
            if [ $i -gt 0 ]; then
                echo "," >> "$CONFIG_FILE"
            fi
            cat >> "$CONFIG_FILE" <<EOF
    {
      "host": "${SERVERS[$i]}",
      "role": $([ $i -eq 0 ] && echo '"manager"' || echo '"worker"')
    }
EOF
        done
    else
        cat >> "$CONFIG_FILE" <<EOF
    {
      "host": "localhost",
      "role": "manager"
    }
EOF
    fi
    
    cat >> "$CONFIG_FILE" <<EOF
  ],
  "ssh_key": "$SSH_KEY",
  "use_glusterfs": $( [ "$USE_GLUSTERFS" = true ] && echo "true" || echo "false" )
}
EOF
    
    print_success "Configuration saved to $CONFIG_FILE"
}

# Setup GlusterFS
setup_glusterfs() {
    print_info "Setting up GlusterFS..."
    
    # Check if GlusterFS is installed
    if ! command -v gluster &> /dev/null; then
        print_warning "GlusterFS is not installed"
        
        if confirm "Would you like to install GlusterFS?"; then
            install_glusterfs
        else
            print_warning "Skipping GlusterFS setup"
            return
        fi
    fi
    
    # Configure GlusterFS volumes
    print_info "Configuring GlusterFS volumes..."
    
    # Create directories for GlusterFS
    sudo mkdir -p /gluster/brick1/volume1
    
    if [ ${#SERVERS[@]} -gt 1 ]; then
        # Multi-server GlusterFS setup
        print_info "Setting up GlusterFS cluster with ${#SERVERS[@]} servers..."
        
        # Start glusterd service
        sudo systemctl start glusterd
        sudo systemctl enable glusterd
        
        # Peer probe other servers
        for server in "${SERVERS[@]:1}"; do
            print_info "Adding peer: $server"
            sudo gluster peer probe "$server"
        done
        
        # Create replicated volume
        VOLUME_CREATE_CMD="sudo gluster volume create koompi-volume replica ${#SERVERS[@]}"
        for server in "${SERVERS[@]}"; do
            VOLUME_CREATE_CMD="$VOLUME_CREATE_CMD $server:/gluster/brick1/volume1"
        done
        
        eval "$VOLUME_CREATE_CMD"
        sudo gluster volume start koompi-volume
        
        # Mount the volume
        sudo mkdir -p /mnt/gluster
        sudo mount -t glusterfs localhost:/koompi-volume /mnt/gluster
        
        # Add to fstab for persistent mount
        echo "localhost:/koompi-volume /mnt/gluster glusterfs defaults,_netdev 0 0" | sudo tee -a /etc/fstab
        
    else
        # Single server GlusterFS setup
        print_info "Setting up GlusterFS for single server (future expansion ready)..."
        
        sudo systemctl start glusterd
        sudo systemctl enable glusterd
        
        # Create a single brick volume
        sudo gluster volume create koompi-volume localhost:/gluster/brick1/volume1 force
        sudo gluster volume start koompi-volume
        
        # Mount the volume
        sudo mkdir -p /mnt/gluster
        sudo mount -t glusterfs localhost:/koompi-volume /mnt/gluster
        
        # Add to fstab
        echo "localhost:/koompi-volume /mnt/gluster glusterfs defaults,_netdev 0 0" | sudo tee -a /etc/fstab
    fi
    
    print_success "GlusterFS setup completed"
}

# Install GlusterFS
install_glusterfs() {
    print_info "Installing GlusterFS..."
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/debian_version ]; then
            # Debian/Ubuntu
            sudo apt-get update
            sudo apt-get install -y glusterfs-server glusterfs-client
        elif [ -f /etc/redhat-release ]; then
            # RHEL/CentOS/Fedora
            sudo yum install -y centos-release-gluster
            sudo yum install -y glusterfs-server glusterfs-client
        else
            print_error "Unsupported Linux distribution for GlusterFS"
            return 1
        fi
        
        sudo systemctl start glusterd
        sudo systemctl enable glusterd
        
        print_success "GlusterFS installed successfully"
    else
        print_error "GlusterFS installation not supported for this OS"
        return 1
    fi
}

# Pre-pull Docker images
pre_pull_images() {
    print_info "Pre-pulling Docker images..."
    
    local total=${#DOCKER_IMAGES[@]}
    local current=0
    
    for image in "${DOCKER_IMAGES[@]}"; do
        current=$((current + 1))
        print_info "[$current/$total] Pulling $image..."
        
        if docker pull "$image"; then
            print_success "Successfully pulled $image"
        else
            print_warning "Failed to pull $image (will retry during deployment)"
        fi
    done
    
    print_success "Image pre-pulling completed"
}

# Setup remote servers
setup_remote_servers() {
    if [ ${#SERVERS[@]} -eq 0 ]; then
        return
    fi
    
    print_info "Setting up remote servers..."
    
    for server in "${SERVERS[@]}"; do
        print_info "Configuring server: $server"
        
        # Prepare SSH command
        SSH_CMD="ssh"
        if [ -n "$SSH_KEY" ]; then
            SSH_CMD="$SSH_CMD -i $SSH_KEY"
        fi
        
        # Copy setup script to remote server
        print_info "Copying setup script to $server..."
        scp_cmd="scp"
        if [ -n "$SSH_KEY" ]; then
            scp_cmd="$scp_cmd -i $SSH_KEY"
        fi
        
        $scp_cmd "$0" "$server:/tmp/setup-cluster.sh"
        
        # Execute setup on remote server
        print_info "Running setup on $server..."
        $SSH_CMD "$server" "bash /tmp/setup-cluster.sh --remote --manager-ip $MANAGER_IP --token $SWARM_TOKEN"
    done
    
    print_success "Remote server setup completed"
}

# Join Swarm cluster (for remote execution)
join_swarm() {
    local manager_ip="$1"
    local token="$2"
    
    print_info "Joining Swarm cluster..."
    
    if docker swarm join --token "$token" "$manager_ip:2377"; then
        print_success "Successfully joined Swarm cluster"
    else
        print_error "Failed to join Swarm cluster"
        exit 1
    fi
}

# Create Docker networks
create_networks() {
    print_info "Creating Docker overlay networks..."
    
    if docker network create \
        --driver overlay \
        --attachable \
        --scope swarm \
        koompi-cloud-shared \
        2>/dev/null; then
        print_success "Created network: koompi-cloud-shared"
    else
        print_info "Network koompi-cloud-shared already exists"
    fi
    
    print_success "Docker networks ready"
}

# Create .env file with default values
create_env_file() {
    print_info "Checking environment configuration..."
    
    ENV_FILE="${SCRIPT_DIR}/.env"
    
    if [ -f "$ENV_FILE" ]; then
        print_info "Found existing .env file"
        if confirm "Would you like to update the .env file?"; then
            backup_file="${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$ENV_FILE" "$backup_file"
            print_info "Backed up existing .env to $backup_file"
        else
            return
        fi
    fi
    
    print_info "Creating environment configuration..."
    
    # Get storage path
    read -p "Enter storage path for persistent data (default: /opt/koompi-cloud): " STORAGE_PATH
    STORAGE_PATH=${STORAGE_PATH:-/opt/koompi-cloud}
    
    # Get absolute path
    read -p "Enter absolute path for containers (default: /opt/koompi-cloud): " ABSOLUTE_PATH
    ABSOLUTE_PATH=${ABSOLUTE_PATH:-/opt/koompi-cloud}
    
    # MongoDB configuration
    read -p "Enter MongoDB root username (default: admin): " MONGO_ROOT_USERNAME
    MONGO_ROOT_USERNAME=${MONGO_ROOT_USERNAME:-admin}
    
    read -sp "Enter MongoDB root password (default: changeme): " MONGO_ROOT_PASSWORD
    echo
    MONGO_ROOT_PASSWORD=${MONGO_ROOT_PASSWORD:-changeme}
    
    # Generate MongoDB URI
    MONGO_URI="mongodb://${MONGO_ROOT_USERNAME}:${MONGO_ROOT_PASSWORD}@mongodb:27017/kontainer?authSource=admin"
    
    # Redis configuration
    read -sp "Enter Redis password (leave empty for no password): " REDIS_PASSWORD
    echo
    
    if [ -n "$REDIS_PASSWORD" ]; then
        REDIS_URL="redis://:${REDIS_PASSWORD}@redis:6379"
    else
        REDIS_URL="redis://redis:6379"
    fi
    
    # NPM configuration
    read -p "Enter Nginx Proxy Manager email (default: admin@example.com): " NPM_EMAIL
    NPM_EMAIL=${NPM_EMAIL:-admin@example.com}
    
    read -sp "Enter Nginx Proxy Manager password (default: changeme): " NPM_PASSWORD
    echo
    NPM_PASSWORD=${NPM_PASSWORD:-changeme}
    
    # Registry configuration
    read -p "Enter Docker registry URL (default: image.koompi.org): " REGISTRY_URL
    REGISTRY_URL=${REGISTRY_URL:-image.koompi.org}
    
    # JWT and encryption keys
    JWT_SECRET=$(openssl rand -hex 32)
    ENCRYPTION_KEY=$(openssl rand -hex 32)
    
    # Docker group ID
    DOCKER_GROUP_ID=$(getent group docker | cut -d: -f3 || echo "998")
    
    # Write .env file
    cat > "$ENV_FILE" <<EOF
# KoompiCloud Environment Configuration
# Generated on $(date)

# Storage paths
STORAGE_PATH=${STORAGE_PATH}
ABSOLUTE_PATH=${ABSOLUTE_PATH}

# MongoDB
MONGO_ROOT_USERNAME=${MONGO_ROOT_USERNAME}
MONGO_ROOT_PASSWORD=${MONGO_ROOT_PASSWORD}
MONGO_DATABASE=kontainer
MONGO_URI=${MONGO_URI}

# Redis
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_URL=${REDIS_URL}

# Nginx Proxy Manager
NPM_EMAIL=${NPM_EMAIL}
NPM_PASSWORD=${NPM_PASSWORD}
NPM_URL=http://nginx-proxy-manager:81/api
NPM_DB_USER=npm
NPM_DB_PASSWORD=$(openssl rand -base64 12)
NPM_DB_NAME=npm
NPM_MYSQL_ROOT_PASSWORD=$(openssl rand -base64 12)

# Registry
REGISTRY_URL=${REGISTRY_URL}
REGISTRY_USERNAME=
REGISTRY_PASSWORD=

# Security
JWT_SECRET=${JWT_SECRET}
ENCRYPTION_KEY=${ENCRYPTION_KEY}

# Docker
DOCKER_GROUP_ID=${DOCKER_GROUP_ID}

# Telegram Bot (optional)
TELEGRAM_BOT_TOKEN=

# License (optional)
SUBSCRIPTION_ID=
PORTAL_URL=https://koompi.cloud
PORTAL_API_KEY=
KOOMPI_VERSION=2.0.0

# Registration
ALLOW_REGISTRATION=first_user_only
EOF
    
    chmod 600 "$ENV_FILE"
    print_success "Environment configuration saved to $ENV_FILE"
}

# Main deployment function
deploy_stacks() {
    print_info "Starting stack deployment..."
    
    # Check for .env file
    if [ ! -f "${SCRIPT_DIR}/.env" ]; then
        print_error ".env file not found. Please run setup first."
        create_env_file
    fi
    
    # Source .env file
    source "${SCRIPT_DIR}/.env"
    
    # Create storage directories
    print_info "Creating storage directories..."
    sudo mkdir -p "${STORAGE_PATH}"/{mongodb-data,mongodb-config,redis-data,npm-data,npm-letsencrypt,npm-mysql,build-service,templates-dokploy,koompi-uploads,database-backups}
    
    # Deploy stacks in order
    STACKS=("database" "proxy" "registry" "backend" "frontend")
    
    for stack in "${STACKS[@]}"; do
        compose_file="${SCRIPT_DIR}/${stack}.yml"
        
        if [ -f "$compose_file" ]; then
            print_info "Deploying stack: $stack"
            
            # Export environment variables for docker stack deploy
            export $(grep -v '^#' "${SCRIPT_DIR}/.env" | xargs)
            
            if docker stack deploy -c "$compose_file" "$stack"; then
                print_success "Stack $stack deployed"
                
                # Wait for essential services
                if [ "$stack" == "database" ]; then
                    print_info "Waiting for database services to be ready..."
                    sleep 30
                elif [ "$stack" == "proxy" ]; then
                    print_info "Waiting for proxy services to be ready..."
                    sleep 20
                fi
            else
                print_warning "Failed to deploy stack $stack"
            fi
        else
            print_warning "Stack file not found: $compose_file"
        fi
    done
    
    print_success "All stacks deployed"
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --remote)
                # This is a remote execution
                shift
                ;;
            --manager-ip)
                MANAGER_IP="$2"
                shift 2
                ;;
            --token)
                SWARM_TOKEN="$2"
                shift 2
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --ssh-key)
                SSH_KEY="$2"
                shift 2
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Show help message
show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

KoompiCloud Cluster Setup Script

Options:
    --config FILE       Path to server configuration file (default: server.json)
    --ssh-key FILE      Path to SSH private key for remote servers
    --remote            Internal flag for remote execution
    --manager-ip IP     Swarm manager IP address (for remote nodes)
    --token TOKEN       Swarm join token (for remote nodes)
    --help              Show this help message

Examples:
    # Interactive setup
    $0

    # Setup with existing configuration
    $0 --config servers.json --ssh-key ~/.ssh/id_rsa

EOF
}

# Main execution
main() {
    print_info "KoompiCloud Cluster Setup Script"
    print_info "================================"
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Check if this is a remote execution
    if [ -n "$MANAGER_IP" ] && [ -n "$SWARM_TOKEN" ]; then
        # Remote node setup
        check_docker
        join_swarm "$MANAGER_IP" "$SWARM_TOKEN"
        pre_pull_images
        exit 0
    fi
    
    # Main setup flow
    check_docker
    
    # Check or initialize Swarm
    if ! check_swarm; then
        if confirm "Would you like to initialize Docker Swarm?"; then
            init_swarm
        else
            print_error "Docker Swarm is required for cluster setup"
            exit 1
        fi
    fi
    
    # Load or configure servers
    load_server_config
    
    if [ ${#SERVERS[@]} -eq 0 ] && [ ! -f "$CONFIG_FILE" ]; then
        configure_servers
    fi
    
    # Setup GlusterFS if requested
    if [ "$USE_GLUSTERFS" = true ] || { [ -f "$CONFIG_FILE" ] && grep -q '"use_glusterfs": true' "$CONFIG_FILE"; }; then
        setup_glusterfs
    fi
    
    # Create or update .env file
    if [ ! -f "${SCRIPT_DIR}/.env" ]; then
        create_env_file
    else
        if confirm "Would you like to review/update environment configuration?"; then
            create_env_file
        fi
    fi
    
    # Pre-pull images
    if confirm "Would you like to pre-pull Docker images?"; then
        pre_pull_images
    fi
    
    # Setup remote servers if configured
    if [ ${#SERVERS[@]} -gt 0 ]; then
        if confirm "Would you like to setup remote servers now?"; then
            setup_remote_servers
        fi
    fi
    
    # Create networks
    if [ "$IS_MANAGER" = true ]; then
        create_networks
    fi
    
    # Deploy stacks
    if [ "$IS_MANAGER" = true ]; then
        if confirm "Would you like to deploy the stacks now?"; then
            deploy_stacks
        fi
    fi
    
    print_success "Cluster setup completed!"
    
    # Show status
    if [ "$IS_MANAGER" = true ]; then
        print_info "Cluster status:"
        docker node ls
        
        print_info "Deployed services:"
        docker service ls
        
        print_info ""
        print_info "Access points:"
        print_info "- Gateway API: http://$(hostname -I | awk '{print $1}'):8083"
        print_info "- Nginx Proxy Manager: http://$(hostname -I | awk '{print $1}'):81"
        print_info "- Docker Registry: http://$(hostname -I | awk '{print $1}'):5000"
    fi
}

# Run main function
main "$@"