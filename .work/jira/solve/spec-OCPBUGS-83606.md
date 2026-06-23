# Implementation Spec: OCPBUGS-83606

## Problem Summary
EgressIP is not removed from the network interface when ovnkube-controller fails, causing a duplicated IP in the network. When the new ovnkube-controller starts, it should remove the stale egressIP from the network interface.

## Root Cause Analysis

The issue is in the `repairNode()` function in `go-controller/pkg/node/controllers/egressip/egressip.go` (line 890).

Currently, the function:
1. Gets EgressIP addresses from the node annotation (`existingAddrsFromAnnot`)
2. Iterates through all network links and their addresses
3. **Only tracks addresses that exist in the annotation** (line 924):
   ```go
   if existingAddrsFromAnnot.Has(address.IP.String()) {
       assignedAddr.Insert(addrLink{address.IPNet.String(), address.LinkIndex})
       assignedAddrStrToAddrs[addressStr] = address
   }
   ```
4. Compares tracked addresses against expected addresses and removes stale ones

**The Problem**: If ovnkube-controller crashes/restarts before updating the node annotation, the stale EgressIP won't be in the annotation. Therefore, it won't be tracked in `assignedAddr`, won't be compared against `expectedAddrs`, and **won't be removed**.

## Proposed Solution

Modify the `repairNode()` function to detect and remove stale EgressIP addresses that match known EgressIP assignments but shouldn't be on this node. The approach:

1. Build a map of all EgressIP addresses from all EgressIP objects in the cluster
2. During link address scanning, check each address against this map
3. If an address matches an EgressIP that is:
   - Assigned to a **different** node, OR
   - Not assigned at all, OR  
   - In the annotation but not in any current EgressIP status

   Then mark it as stale for removal

This ensures that even if the annotation isn't updated before a crash, we'll still detect and remove incorrectly assigned EgressIPs.

## Implementation Steps

### Step 1: Modify `repairNode()` function

**File**: `go-controller/pkg/node/controllers/egressip/egressip.go`

**Changes**:

1. Before the link scanning loop, build a map of all EgressIP addresses and their assigned nodes:
   ```go
   // Build map of all known EgressIP addresses -> node assignments
   allEgressIPsMap := make(map[string]string) // egressIP -> assigned node name (empty if unassigned)
   for _, egressIP := range egressIPs {
       for _, status := range egressIP.Status.Items {
           allEgressIPsMap[status.EgressIP] = status.Node
       }
       // Also track spec IPs that aren't in status (unassigned)
       for _, specIP := range egressIP.Spec.EgressIPs {
           if _, exists := allEgressIPsMap[specIP]; !exists {
               allEgressIPsMap[specIP] = "" // unassigned
           }
       }
   }
   ```

2. Modify the address scanning logic to also check for stale EgressIPs:
   ```go
   for _, address := range addresses {
       addressIP := address.IP.String()
       
       // Original logic: track addresses in annotation
       if existingAddrsFromAnnot.Has(addressIP) {
           addressStr := address.IPNet.String()
           assignedAddr.Insert(addrLink{addressStr, address.LinkIndex})
           assignedAddrStrToAddrs[addressStr] = address
       } else if assignedNode, isEgressIP := allEgressIPsMap[addressIP]; isEgressIP {
           // This address matches a known EgressIP but isn't in our annotation
           // Check if it's assigned to a different node or unassigned
           if assignedNode != c.nodeName {
               // This is a stale EgressIP - track it for removal
               addressStr := address.IPNet.String()
               assignedAddr.Insert(addrLink{addressStr, address.LinkIndex})
               assignedAddrStrToAddrs[addressStr] = address
               klog.Warningf("Found stale EgressIP %s on link %s (assigned to node %q but this is node %q)",
                   addressIP, linkName, assignedNode, c.nodeName)
           }
       }
   }
   ```

### Step 2: Add Unit Test

**File**: `go-controller/pkg/node/controllers/egressip/egressip_test.go`

Add a test case that simulates:
1. An EgressIP being assigned to a node
2. ovnkube-controller crashing before updating the annotation
3. ovnkube-controller restarting
4. Verification that the stale EgressIP is removed

### Step 3: Manual Testing

Test the fix by:
1. Configuring an EgressIP
2. Killing the ovnkube-controller process before it updates the node annotation
3. Verifying the EgressIP remains on the old node
4. Starting ovnkube-controller
5. Verifying the stale EgressIP is removed from the old node

## Testing Strategy

### Unit Tests
- Test `repairNode()` with stale EgressIPs in annotation
- Test `repairNode()` with stale EgressIPs NOT in annotation  
- Test `repairNode()` with EgressIPs assigned to different nodes
- Test `repairNode()` with unassigned EgressIPs in spec

### Integration Tests
Use the existing e2e test framework in `test/e2e/egressip.go` to add a test that simulates controller restart scenarios.

### Manual Verification
1. Create EgressIP object
2. Kill ovnkube-controller container
3. Verify EgressIP remains on network interface
4. Restart ovnkube-controller
5. Verify stale EgressIP is removed

## Risk Assessment

**Low Risk**:
- The fix is localized to the `repairNode()` startup function
- It only adds additional detection of stale EgressIPs
- Existing annotation-based cleanup logic remains unchanged
- The fix is defensive: it only removes IPs that match known EgressIP assignments but are on the wrong node

## Rollback Plan

If issues arise, the change can be reverted by:
1. Reverting the commit
2. Redeploying ovnkube-node
3. The existing annotation-based cleanup will continue to work for most cases

## Success Criteria

1. Stale EgressIPs are removed on ovnkube-controller restart
2. No duplicate IPs exist in the network after failover
3. All unit tests pass
4. Existing EgressIP functionality is not affected
