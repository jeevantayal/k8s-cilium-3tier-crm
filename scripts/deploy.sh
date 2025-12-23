#!/bin/bash

# ============================================================================
# Kubernetes Cilium CRM Deployment Script
# ============================================================================
# This script:
# 1. Creates a kind cluster
# 2. Installs Cilium CNI
# 3. Deploys the 3-tier CRM application
# 4. Applies CiliumNetworkPolicy security policies
# 5. Verifies functionality
# 6. Provides cleanup option
# ============================================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="cilium-crm-cluster"
MANIFESTS_DIR="$(dirname "$0")/../manifests"

# Functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    print_info "Checking prerequisites..."
    
    local missing_tools=()
    
    if ! command -v kind &> /dev/null; then
        missing_tools+=("kind")
    fi
    
    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi
    
    if ! command -v helm &> /dev/null; then
        missing_tools+=("helm")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        print_info "Please install:"
        for tool in "${missing_tools[@]}"; do
            case $tool in
                kind)
                    echo "  - kind: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
                    ;;
                kubectl)
                    echo "  - kubectl: https://kubernetes.io/docs/tasks/tools/"
                    ;;
                helm)
                    echo "  - helm: https://helm.sh/docs/intro/install/"
                    ;;
            esac
        done
        exit 1
    fi
    
    print_success "All prerequisites met"
}

create_cluster() {
    print_info "Creating kind cluster: $CLUSTER_NAME"
    
    # Check if cluster already exists
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        print_warning "Cluster $CLUSTER_NAME already exists"
        read -p "Delete and recreate? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kind delete cluster --name "$CLUSTER_NAME"
        else
            print_info "Using existing cluster"
            return
        fi
    fi
    
    # Create kind cluster configuration
    cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
nodes:
- role: control-plane
- role: worker
- role: worker
EOF
    
    print_success "Cluster created successfully"
    print_info "Loading application image into kind..."
    kind load docker-image crm-app:1.0 --name "$CLUSTER_NAME"
}

install_cilium() {
    print_info "Installing Cilium CNI..."
    
    # Add Cilium Helm repo
    helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
    helm repo update
    
    # Install Cilium
    helm install cilium cilium/cilium \
        --version 1.14.5 \
        --namespace kube-system \
        --set ipam.mode=kubernetes \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true \
        --wait
    
    print_info "Waiting for Cilium to be ready..."
    kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s
    
    print_success "Cilium installed successfully"
}

deploy_application() {
    print_info "Deploying CRM application..."
    
    # Apply manifests in order
    kubectl apply -f "$MANIFESTS_DIR/namespace.yaml"
    
    print_info "Waiting for namespace to be ready..."
    sleep 2
    
    # Deploy DB tier
    print_info "Deploying database tier..."
    kubectl apply -f "$MANIFESTS_DIR/db/"
    
    # Wait for DB to be ready
    print_info "Waiting for database pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=crm-db -n crm-app --timeout=300s || true
    
    # Initialize database
    print_info "Initializing database..."
    kubectl apply -f "$MANIFESTS_DIR/db/init-db-job.yaml"
    sleep 5
    kubectl wait --for=condition=complete job/postgres-init -n crm-app --timeout=120s || true
    
    # Deploy App tier
    print_info "Deploying application tier..."
    kubectl apply -f "$MANIFESTS_DIR/app/"
    
    # Wait for App to be ready
    print_info "Waiting for application pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=crm-app -n crm-app --timeout=300s || true
    
    # Deploy Web tier
    print_info "Deploying web tier..."
    kubectl apply -f "$MANIFESTS_DIR/web/"
    
    # Wait for Web to be ready
    print_info "Waiting for web pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=crm-web -n crm-app --timeout=300s || true
    
    print_success "Application deployed successfully"
}

apply_security_policies() {
    print_info "Applying CiliumNetworkPolicy security policies..."
    
    kubectl apply -f "$MANIFESTS_DIR/security/cilium-network-policies.yaml"
    
    print_success "Security policies applied successfully"
}

verify_deployment() {
    print_info "Verifying deployment..."
    
    echo ""
    print_info "=== Cluster Status ==="
    kubectl get nodes
    
    echo ""
    print_info "=== Pod Status ==="
    kubectl get pods -n crm-app -o wide
    
    echo ""
    print_info "=== Service Status ==="
    kubectl get svc -n crm-app
    
    echo ""
    print_info "=== CiliumNetworkPolicy Status ==="
    kubectl get cnp -n crm-app
    
    echo ""
    print_info "=== Testing Connectivity ==="
    
    # Get a web pod name
    WEB_POD=$(kubectl get pod -n crm-app -l app=crm-web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$WEB_POD" ]; then
        print_info "Testing web pod health endpoint..."
        kubectl exec -n crm-app "$WEB_POD" -- wget -qO- http://localhost/ || print_warning "Web health check failed"
        
        print_info "Testing app service connectivity from web pod..."
        kubectl exec -n crm-app "$WEB_POD" -- wget -qO- http://crm-app-service.crm-app.svc.cluster.local:5000/health || print_warning "App connectivity test failed"
    fi
    
    # Get LoadBalancer IP (if available)
    LB_IP=$(kubectl get svc crm-web-service -n crm-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -z "$LB_IP" ]; then
        LB_IP=$(kubectl get svc crm-web-service -n crm-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    fi
    
    if [ -n "$LB_IP" ]; then
        print_success "LoadBalancer IP: $LB_IP"
        print_info "You can access the application at: http://$LB_IP"
    else
        print_warning "LoadBalancer IP not yet assigned. For kind, you may need to use port-forward:"
        print_info "  kubectl port-forward -n crm-app svc/crm-web-service 8080:80"
        print_info "  Then access at: http://localhost:8080"
    fi
    
    echo ""
    print_success "Verification complete"
}

cleanup() {
    print_warning "This will delete the entire cluster and all resources"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deleting cluster: $CLUSTER_NAME"
        kind delete cluster --name "$CLUSTER_NAME"
        print_success "Cleanup complete"
    else
        print_info "Cleanup cancelled"
    fi
}

show_help() {
    cat <<EOF
Usage: $0 [COMMAND]

Commands:
    deploy      Create cluster, install Cilium, deploy app, and apply policies (default)
    verify      Verify the deployment status
    cleanup     Delete the cluster and all resources
    help        Show this help message

Examples:
    $0              # Deploy everything
    $0 deploy       # Same as above
    $0 verify       # Check deployment status
    $0 cleanup      # Remove everything
EOF
}

# Main script logic
main() {
    case "${1:-deploy}" in
        deploy)
            check_prerequisites
            create_cluster
            install_cilium
            deploy_application
            apply_security_policies
            verify_deployment
            echo ""
            print_success "=== Deployment Complete ==="
            print_info "Next steps:"
            print_info "1. Run '$0 verify' to check status"
            print_info "2. Access the application using the LoadBalancer IP or port-forward"
            print_info "3. Run '$0 cleanup' when done"
            ;;
        verify)
            verify_deployment
            ;;
        cleanup)
            cleanup
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"

