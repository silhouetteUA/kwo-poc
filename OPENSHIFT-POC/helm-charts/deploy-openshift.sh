#!/bin/bash
# OpenShift WebLogic SOA/OSB Domain Deployment Script
# This script helps deploy the WebLogic domain to OpenShift using helmfile

set -e

# Configuration
HELMFILE_PATH="${HELMFILE_PATH:-.}"
VALUES_FILE="${VALUES_FILE:-values-openshift.yaml}"
ENVIRONMENT="${ENVIRONMENT:-default}"
OPERATION="${OPERATION:-sync}"
TIMEOUT="${TIMEOUT:-3600}"
DOMAIN_NAMESPACE="${DOMAIN_NAMESPACE:-soans}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-opns}"
VERBOSE="${VERBOSE:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check for required tools
    for tool in oc helm helmfile kubectl; do
        if ! command -v $tool &> /dev/null; then
            print_error "$tool is not installed"
            exit 1
        fi
        print_success "$tool is installed"
    done
    
    # Check if connected to cluster
    if ! oc cluster-info &> /dev/null; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    print_success "Connected to OpenShift cluster"
    
    # Check for values file
    if [ ! -f "$VALUES_FILE" ]; then
        print_error "Values file not found: $VALUES_FILE"
        exit 1
    fi
    print_success "Values file found: $VALUES_FILE"
    
    # Check for helmfile
    if [ ! -f "$HELMFILE_PATH/helmfile-openshift.yaml.gotmpl" ]; then
        print_error "Helmfile not found: $HELMFILE_PATH/helmfile-openshift.yaml.gotmpl"
        exit 1
    fi
    print_success "Helmfile found"
}

verify_openshift_storage() {
    print_header "Verifying OpenShift Storage"
    
    # Check for OCS StorageClass
    if oc get storageclass ocs-storagecluster-ceph-rbd &> /dev/null; then
        print_success "OCS StorageClass (ocs-storagecluster-ceph-rbd) found"
    else
        print_warning "OCS StorageClass not found. Available storage classes:"
        oc get storageclass --no-headers | awk '{print "  - " $1}'
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

create_namespaces() {
    print_header "Creating Namespaces"
    
    # Create domain namespace
    if oc get namespace $DOMAIN_NAMESPACE &> /dev/null; then
        print_success "Domain namespace ($DOMAIN_NAMESPACE) already exists"
    else
        oc create namespace $DOMAIN_NAMESPACE
        print_success "Domain namespace ($DOMAIN_NAMESPACE) created"
    fi
    
    # Create operator namespace
    if oc get namespace $OPERATOR_NAMESPACE &> /dev/null; then
        print_success "Operator namespace ($OPERATOR_NAMESPACE) already exists"
    else
        oc create namespace $OPERATOR_NAMESPACE
        print_success "Operator namespace ($OPERATOR_NAMESPACE) created"
    fi
    
    # Label domain namespace for WebLogic operator
    oc label namespace $DOMAIN_NAMESPACE weblogic-operator=enabled --overwrite
    print_success "Domain namespace labeled for WebLogic operator"
}

deploy_with_helmfile() {
    print_header "Deploying with Helmfile"
    
    cd "$HELMFILE_PATH"
    
    echo "Helmfile Command:"
    echo "  helmfile -f helmfile-openshift.yaml.gotmpl --values $VALUES_FILE -e $ENVIRONMENT $OPERATION"
    echo ""
    
    if [ "$VERBOSE" = "true" ]; then
        helmfile -f helmfile-openshift.yaml.gotmpl \
                 --values "$VALUES_FILE" \
                 -e "$ENVIRONMENT" \
                 --no-color=false \
                 $OPERATION
    else
        helmfile -f helmfile-openshift.yaml.gotmpl \
                 --values "$VALUES_FILE" \
                 -e "$ENVIRONMENT" \
                 $OPERATION
    fi
    
    if [ $? -eq 0 ]; then
        print_success "Helmfile operation completed successfully"
    else
        print_error "Helmfile operation failed"
        exit 1
    fi
}

wait_for_domain() {
    print_header "Waiting for Domain Deployment"
    
    print_warning "Waiting up to $TIMEOUT seconds for domain to be ready..."
    
    timeout $TIMEOUT bash -c "
        while [ \$(oc get domain soainfra -n $DOMAIN_NAMESPACE -o jsonpath='{.status.conditions[?(@.type==\"Completed\")].status}' 2>/dev/null) != 'True' ]; do
            echo '  Waiting for domain to be Completed...'
            sleep 10
        done
    " || {
        print_warning "Timeout waiting for domain. Domain may still be initializing."
        print_warning "Check status with: oc describe domain soainfra -n $DOMAIN_NAMESPACE"
    }
}

display_access_information() {
    print_header "WebLogic Access Information"
    
    # Get routes
    echo ""
    echo "OpenShift Routes:"
    oc get routes -n $DOMAIN_NAMESPACE --no-headers | while read route rest; do
        url=$(oc get route $route -n $DOMAIN_NAMESPACE -o jsonpath='{.spec.host}{.spec.path}')
        echo "  - http://$url"
    done
    
    echo ""
    echo "WebLogic Console:"
    ADMIN_ROUTE=$(oc get route admin-console -n $DOMAIN_NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || echo "NOT_FOUND")
    if [ "$ADMIN_ROUTE" != "NOT_FOUND" ]; then
        echo "  - http://$ADMIN_ROUTE/console"
        echo "  - Username: weblogic"
        echo "  - Password: (from values file)"
    else
        print_warning "Admin console route not found. Verify routes with: oc get routes -n $DOMAIN_NAMESPACE"
    fi
    
    echo ""
    echo "Oracle Database Service:"
    echo "  - Host: oracle-db.$DOMAIN_NAMESPACE.svc.cluster.local"
    echo "  - Port: 1521"
    echo "  - SID: XE"
    echo "  - PDB: XEPDB1"
}

check_pvc_status() {
    print_header "Checking PVC Status"
    
    echo "PVCs in namespace '$DOMAIN_NAMESPACE':"
    oc get pvc -n $DOMAIN_NAMESPACE --no-headers || print_warning "No PVCs found"
    
    echo ""
    echo "Oracle-XE Pod Status:"
    oc get pods -l app=oracle-xe -n $DOMAIN_NAMESPACE || print_warning "Oracle-XE pod not found"
}

display_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -f, --helmfile PATH     Path to helmfile (default: current directory)
    -v, --values FILE       Values file to use (default: values-openshift.yaml)
    -e, --environment ENV   Helmfile environment (default: default)
    -o, --operation OP      Helmfile operation: sync, diff, destroy (default: sync)
    -d, --domain-ns NS      Domain namespace (default: soans)
    -op, --operator-ns NS   Operator namespace (default: opns)
    -t, --timeout SECS      Timeout for domain deployment (default: 3600)
    --verbose               Verbose output
    --no-wait               Don't wait for domain to be ready
    --check-only            Only check prerequisites and display info

EXAMPLES:
    # Standard deployment
    $0

    # Deploy with custom namespace
    $0 --domain-ns wls --operator-ns wls-op

    # Verify configuration without deploying
    $0 --check-only

    # Destroy deployment
    $0 --operation destroy

    # Verbose deployment with custom values
    $0 --values my-values.yaml --verbose

EOF
}

# Main execution
main() {
    local wait_for_domain=true
    local check_only=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                display_usage
                exit 0
                ;;
            -f|--helmfile)
                HELMFILE_PATH="$2"
                shift 2
                ;;
            -v|--values)
                VALUES_FILE="$2"
                shift 2
                ;;
            -e|--environment)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -o|--operation)
                OPERATION="$2"
                shift 2
                ;;
            -d|--domain-ns)
                DOMAIN_NAMESPACE="$2"
                shift 2
                ;;
            -op|--operator-ns)
                OPERATOR_NAMESPACE="$2"
                shift 2
                ;;
            -t|--timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --no-wait)
                wait_for_domain=false
                shift
                ;;
            --check-only)
                check_only=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                display_usage
                exit 1
                ;;
        esac
    done
    
    echo ""
    print_header "OpenShift WebLogic SOA/OSB Deployment"
    echo "Helmfile: $HELMFILE_PATH/helmfile-openshift.yaml.gotmpl"
    echo "Values: $VALUES_FILE"
    echo "Domain Namespace: $DOMAIN_NAMESPACE"
    echo "Operator Namespace: $OPERATOR_NAMESPACE"
    echo "Operation: $OPERATION"
    echo ""
    
    # Execute steps
    check_prerequisites
    verify_openshift_storage
    
    if [ "$check_only" = "true" ]; then
        print_header "Pre-flight Check Complete"
        print_success "All prerequisites met. Ready to deploy."
        exit 0
    fi
    
    create_namespaces
    check_pvc_status
    
    read -p "Proceed with deployment? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Deployment cancelled"
        exit 0
    fi
    
    deploy_with_helmfile
    
    if [ "$wait_for_domain" = "true" ] && [ "$OPERATION" = "sync" ]; then
        wait_for_domain
    fi
    
    if [ "$OPERATION" = "sync" ]; then
        display_access_information
    fi
    
    echo ""
    print_success "Deployment script completed"
}

# Run main
main "$@"
