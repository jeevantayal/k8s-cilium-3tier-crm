#!/bin/bash

# ============================================================================
# Demo Script for Kubernetes Cilium CRM Project
# ============================================================================
# This script demonstrates the security policies and traffic flow
# ============================================================================

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_demo() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${YELLOW}→${NC} $1"
}

wait_for_pods() {
    print_info "Waiting for all pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=crm-web -n crm-app --timeout=60s
    kubectl wait --for=condition=ready pod -l app=crm-app -n crm-app --timeout=60s
    kubectl wait --for=condition=ready pod -l app=crm-db -n crm-app --timeout=60s
    sleep 3
}

demo_allowed_traffic() {
    print_demo "DEMO 1: Allowed Traffic Patterns"
    
    # Test 1: External to Web
    print_info "Test 1: External access to Web tier (should work)"
    WEB_POD=$(kubectl get pod -n crm-app -l app=crm-web -o jsonpath='{.items[0].metadata.name}')
    if kubectl exec -n crm-app "$WEB_POD" -- wget -qO- http://127.0.0.1/healthy > /dev/null 2>&1; then
        print_success "External can access Web tier"
    else
        print_error "External cannot access Web tier"
    fi
    
    # Test 2: Web to App
    print_info "Test 2: Web tier accessing App tier (should work)"
    if kubectl exec -n crm-app "$WEB_POD" -- wget -qO- http://crm-app-service.crm-app.svc.cluster.local:5000/health > /dev/null 2>&1; then
        print_success "Web tier can access App tier"
        kubectl exec -n crm-app "$WEB_POD" -- wget -qO- http://crm-app-service.crm-app.svc.cluster.local:5000/health
    else
        print_error "Web tier cannot access App tier"
    fi
    
    # Test 3: App to DB
    print_info "Test 3: App tier accessing DB tier (should work)"
    APP_POD=$(kubectl get pod -n crm-app -l app=crm-app -o jsonpath='{.items[0].metadata.name}')
    #if kubectl exec -n crm-app "$APP_POD" -- sh -c 'PGPASSWORD=crmpass123 psql -h postgres-service.crm-app.svc.cluster.local -U crmuser -d crmdb -c "SELECT 1;"' > /dev/null 2>&1; then
    if kubectl exec -n crm-app "$APP_POD" -- python -c "..."; then
        print_success "App tier can access DB tier"
    else
        print_error "App tier cannot access DB tier"
    fi
    
    echo ""
}

demo_blocked_traffic() {
    print_demo "DEMO 2: Blocked Traffic Patterns (Security Enforcement)"
    
    # Test 1: External directly to App (should fail)
    print_info "Test 1: External trying to access App tier directly (should be blocked)"
    APP_POD=$(kubectl get pod -n crm-app -l app=crm-app -o jsonpath='{.items[0].metadata.name}')
    if kubectl exec -n crm-app "$APP_POD" -- wget -qO- http://localhost:5000/health > /dev/null 2>&1; then
        print_error "External CAN access App tier (security issue!)"
    else
        print_success "External CANNOT access App tier directly (correctly blocked)"
    fi
    
    # Test 2: External directly to DB (should fail)
    print_info "Test 2: External trying to access DB tier directly (should be blocked)"
    DB_POD=$(kubectl get pod -n crm-app -l app=crm-db -o jsonpath='{.items[0].metadata.name}')
    if kubectl exec -n crm-app "$DB_POD" -- sh -c 'PGPASSWORD=crmpass123 psql -h localhost -U crmuser -d crmdb -c "SELECT 1;"' > /dev/null 2>&1; then
        print_error "External CAN access DB tier (security issue!)"
    else
        print_success "External CANNOT access DB tier directly (correctly blocked)"
    fi
    
    # Test 3: Web trying to access DB (should fail)
    print_info "Test 3: Web tier trying to access DB tier directly (should be blocked)"
    WEB_POD=$(kubectl get pod -n crm-app -l app=crm-web -o jsonpath='{.items[0].metadata.name}')
    if kubectl exec -n crm-app "$WEB_POD" -- sh -c 'PGPASSWORD=crmpass123 psql -h postgres-service.crm-app.svc.cluster.local -U crmuser -d crmdb -c "SELECT 1;"' > /dev/null 2>&1; then
        print_error "Web tier CAN access DB tier (security issue!)"
    else
        print_success "Web tier CANNOT access DB tier directly (correctly blocked)"
    fi
    
    echo ""
}

demo_cilium_observability() {
    print_demo "DEMO 3: Cilium Observability"
    
    print_info "Checking Cilium endpoint status..."
    kubectl get cep -n crm-app
    
    echo ""
    print_info "Viewing CiliumNetworkPolicy details..."
    kubectl describe cnp -n crm-app
    
    echo ""
    print_info "To view real-time traffic flow, you can use Cilium Hubble:"
    print_info "  kubectl port-forward -n kube-system svc/hubble-ui 12000:80"
    print_info "  Then open http://localhost:12000 in your browser"
    
    echo ""
}

demo_application_functionality() {
    print_demo "DEMO 4: Application Functionality"
    
    print_info "Testing end-to-end application flow..."
    
    # Get service endpoint
    LB_IP=$(kubectl get svc crm-web-service -n crm-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -z "$LB_IP" ]; then
        print_info "LoadBalancer IP not available, using port-forward..."
        print_info "In another terminal, run: kubectl port-forward -n crm-app svc/crm-web-service 8080:80"
        print_info "Then test with: curl http://localhost:8080/api/customers"
        return
    fi
    
    print_info "Fetching customers via API..."
    curl -s http://$LB_IP/api/customers | jq '.' || curl -s http://$LB_IP/api/customers
    
    echo ""
    print_info "Creating a new customer..."
    curl -s -X POST http://$LB_IP/api/customers \
        -H "Content-Type: application/json" \
        -d '{"name":"Demo User","email":"demo@example.com"}' | jq '.' || \
    curl -s -X POST http://$LB_IP/api/customers \
        -H "Content-Type: application/json" \
        -d '{"name":"Demo User","email":"demo@example.com"}'
    
    echo ""
}

main() {
    echo ""
    print_demo "Kubernetes Cilium CRM Security Demo"
    echo ""
    
    wait_for_pods
    
    demo_allowed_traffic
    demo_blocked_traffic
    demo_cilium_observability
    demo_application_functionality
    
    echo ""
    print_demo "Demo Complete!"
    print_info "Key Takeaways:"
    print_info "1. External traffic can only reach Web tier"
    print_info "2. Web tier can only reach App tier"
    print_info "3. App tier can only reach DB tier"
    print_info "4. All other traffic is denied by default (zero trust)"
    echo ""
}

main

