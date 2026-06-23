# Implementation Plan: OCPBUGS-86018

## Issue Summary
When a Service of type LoadBalancer is updated to disable NodePort allocation (`allocateLoadBalancerNodePorts: false`), the corresponding NodePort listeners remain active on cluster nodes. This results in unintended network exposure even after the Service object no longer reflects the assigned NodePorts.

## Root Cause Analysis
The bug is in the `buildServiceLBConfigs` function in `go-controller/pkg/ovn/controller/services/lb_config.go`. 

Current behavior (lines 198-216):
```go
if svcPort.NodePort != 0 {
    nodePortLBConfig := lbConfig{
        protocol:             svcPort.Protocol,
        inport:               svcPort.NodePort,
        vips:                 []string{placeholderNodeIPs},
        clusterEndpoints:     clusterEndpoints,
        nodeEndpoints:        nodeEndpoints,
        externalTrafficLocal: externalTrafficLocal,
        internalTrafficLocal: false,
        hasNodePort:          true,
    }
    // ... adds to perNodeConfigs or templateConfigs
}
```

The problem: This code only checks `if svcPort.NodePort != 0`, but doesn't consider whether NodePort allocation is actually enabled for LoadBalancer services via `allocateLoadBalancerNodePorts`.

According to Kubernetes API semantics:
- When `allocateLoadBalancerNodePorts` is `false`, the service **should not** have NodePort listeners, even if the `nodePort` field contains a value (leftover from previous state)
- The field `allocateLoadBalancerNodePorts` controls whether NodePorts are actually allocated/active for LoadBalancer services

## Solution

### Step 1: Add Helper Function Check
Modify the condition in `buildServiceLBConfigs` to also check if NodePort allocation is enabled for LoadBalancer services using the existing helper function `util.LoadBalancerServiceHasNodePortAllocation(service)`.

### Step 2: Update the NodePort Creation Logic
The fix should be applied at line 198 of `lb_config.go`:

**Before:**
```go
if svcPort.NodePort != 0 {
```

**After:**
```go
// Only create NodePort load balancers if:
// 1. NodePort is explicitly set (svcPort.NodePort != 0), AND
// 2. For LoadBalancer services, allocateLoadBalancerNodePorts is not explicitly disabled
// 3. For NodePort services, always create NodePort LBs
shouldCreateNodePortLB := svcPort.NodePort != 0 &&
    (service.Spec.Type != corev1.ServiceTypeLoadBalancer || util.LoadBalancerServiceHasNodePortAllocation(service))

if shouldCreateNodePortLB {
```

This ensures that:
- For `ServiceTypeNodePort`: NodePort LBs are created whenever `NodePort != 0` (existing behavior preserved)
- For `ServiceTypeLoadBalancer`: NodePort LBs are created **only if** `NodePort != 0` AND `allocateLoadBalancerNodePorts != false`
- When `allocateLoadBalancerNodePorts: false` is set, no NodePort LB configs are generated
- Existing NodePort LBs will be cleaned up in the reconciliation loop because they won't be in the desired state

### Step 3: Add Test Coverage
Add test cases to `lb_config_test.go` to verify:
1. LoadBalancer service with `allocateLoadBalancerNodePorts: false` does not create NodePort LB configs
2. LoadBalancer service with `allocateLoadBalancerNodePorts: true` creates NodePort LB configs  
3. LoadBalancer service with `allocateLoadBalancerNodePorts: nil` (default) creates NodePort LB configs
4. NodePort service behavior is unchanged

### Step 4: Verify the Fix
The reconciliation loop in `syncService` (services_controller.go:378) will automatically:
1. Detect that the desired LBs (without NodePort) differ from existing LBs (with NodePort)
2. Call `EnsureLBs` to reconcile the state
3. Remove the stale NodePort LBs from OVN

## Files to Modify

1. **go-controller/pkg/ovn/controller/services/lb_config.go** (line ~198)
   - Update the NodePort LB creation condition

2. **go-controller/pkg/ovn/controller/services/lb_config_test.go**
   - Add test cases for the new behavior

## Testing Strategy

### Unit Tests
Add test cases to `lb_config_test.go`:
- `TestBuildServiceLBConfigs_LoadBalancerWithAllocateNodePortsFalse`
- `TestBuildServiceLBConfigs_LoadBalancerWithAllocateNodePortsTrue`
- `TestBuildServiceLBConfigs_LoadBalancerWithAllocateNodePortsNil`
- `TestBuildServiceLBConfigs_NodePortServiceUnchanged`

### Manual Verification (if possible)
1. Create a LoadBalancer service with NodePort
2. Verify NodePort listener exists on node
3. Update service with `allocateLoadBalancerNodePorts: false` and remove NodePort from spec
4. Verify NodePort listener is removed from node

## Expected Outcome
After this fix:
- When a LoadBalancer service has `allocateLoadBalancerNodePorts: false`, no NodePort LB configurations will be created
- The controller will properly clean up existing NodePort listeners when the field is changed from `true` to `false`
- NodePort services continue to work as before (unaffected)
- LoadBalancer services with `allocateLoadBalancerNodePorts: true` or `nil` continue to work as before

## Dependencies
- Existing helper function: `util.LoadBalancerServiceHasNodePortAllocation(service)` in `pkg/util/kube.go`
- No new dependencies required

## Risks
- **Low risk**: The change is localized to the LB config building logic
- The reconciliation loop will handle cleanup automatically
- Existing services without this field set will continue to work (backward compatible)
