# Implementation Plan for OCPBUGS-86242

## Issue Summary
ARP flooding from VM traffic is not working due to OVS kernel datapath not properly programming flood ports for localnet networks. OVN and OVS userspace (ofproto) are correctly programmed, but the kernel datapath's forwarding database (FDB) does not flood ARP requests to the bond interface attached to the physical network bridge.

## Root Cause Analysis
The OVS kernel datapath uses a forwarding database (FDB) to determine where to flood packets. When a localnet bridge is set up and bridge-mappings are configured:
1. OVN correctly programs the logical topology (verified via ovn-trace)
2. OVS userspace correctly programs OpenFlow flows (verified via ofproto/trace)
3. **BUT** the kernel datapath's FDB does not get properly synchronized with the userspace configuration
4. Result: ARP requests are only flooded to the internal port, not to the physical bond interface

The workaround (reboot) works because it forces a fresh initialization where all components are synchronized.

**Manual Workaround (without reboot):**
```bash
ovs-appctl fdb/flush <bridge-name>
```

## Solution
Add FDB flush operation after bridge-mappings are set up for localnet networks. This forces the OVS kernel datapath to refresh its forwarding database and properly configure flooding to all ports including the physical interface.

## Implementation Steps

### Step 1: Add utility function to flush OVS FDB
**File**: `go-controller/pkg/util/ovs.go`

Add a new function `FlushOVSBridgeFDB` that uses ovs-appctl to flush the FDB for a given bridge:

```go
// FlushOVSBridgeFDB flushes the forwarding database for the specified OVS bridge
// This is necessary to ensure the kernel datapath is synchronized with userspace flows
func FlushOVSBridgeFDB(bridge string) error {
	stdout, stderr, err := RunOvsVswitchdAppCtl("fdb/flush", bridge)
	if err != nil {
		return fmt.Errorf("failed to flush FDB for bridge %s, stdout: %q, stderr: %q, error: %v",
			bridge, stdout, stderr, err)
	}
	klog.V(5).Infof("Flushed FDB for bridge %s", bridge)
	return nil
}
```

### Step 2: Call FDB flush after bridge-mappings setup
**File**: `go-controller/pkg/node/bridgeconfig/bridgeconfig.go`

In the `bridgedGatewayNodeSetup` function (around line 220), after setting the ovn-bridge-mappings, flush the bridge FDB to ensure kernel datapath synchronization:

```go
func bridgedGatewayNodeSetup(nodeName, bridgeName, physicalNetworkName string) (string, error) {
	// ... existing code for setting bridge-mappings ...
	
	_, stderr, err = util.RunOVSVsctl("set", "Open_vSwitch", ".",
		fmt.Sprintf("external_ids:ovn-bridge-mappings=%s", mapString))
	if err != nil {
		return "", fmt.Errorf("failed to set ovn-bridge-mappings for ovs bridge %s"+
			", stderr:%s (%v)", bridgeName, stderr, err)
	}

	// Flush the bridge FDB to ensure kernel datapath is synchronized with userspace flows.
	// This is critical for localnet networks where ARP flooding must reach the physical interface.
	// Without this, the kernel datapath may not properly flood to all ports, causing ARP failures.
	// See: https://issues.redhat.com/browse/OCPBUGS-86242
	if err := util.FlushOVSBridgeFDB(bridgeName); err != nil {
		// Log the error but don't fail the setup - this is a best-effort optimization
		klog.Warningf("Failed to flush FDB for bridge %s: %v", bridgeName, err)
	}

	ifaceID := bridgeName + "_" + nodeName
	return ifaceID, nil
}
```

### Step 3: Add unit test
**File**: `go-controller/pkg/util/ovs_test.go` (create if doesn't exist)

Add unit tests for the new `FlushOVSBridgeFDB` function to ensure it handles success and error cases properly.

```go
func TestFlushOVSBridgeFDB(t *testing.T) {
	tests := []struct {
		name        string
		bridge      string
		mockOutput  string
		mockError   error
		expectError bool
	}{
		{
			name:        "successful flush",
			bridge:      "br-ex",
			mockOutput:  "",
			mockError:   nil,
			expectError: false,
		},
		{
			name:        "flush fails",
			bridge:      "br-ex",
			mockOutput:  "",
			mockError:   fmt.Errorf("bridge not found"),
			expectError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Setup mock runner
			// ... test implementation ...
		})
	}
}
```

### Step 4: Add integration test
**File**: Update existing localnet e2e tests in `test/e2e/`

Add verification that ARP flooding works correctly after localnet setup:
- Create two VMs on different nodes with localnet NAD
- Verify ARP requests are properly flooded
- Check FDB contains entries for physical interface

## Expected Behavior After Fix
- When a localnet bridge is set up, the FDB will be flushed
- The kernel datapath will rebuild its FDB from the userspace configuration
- ARP requests will be properly flooded to all ports including the physical bond interface
- No reboot will be needed to fix the issue
- The fix is applied automatically during node initialization and bridge setup

## Testing Strategy

### Unit Tests
- Test `FlushOVSBridgeFDB` function with valid bridge name
- Test error handling when bridge doesn't exist
- Test error handling when ovs-vswitchd is not running

### Integration Tests
- Verify localnet networks work correctly after the fix
- Test VM-to-VM connectivity across nodes via localnet
- Verify ARP resolution works without manual intervention

### Manual Testing
1. Deploy two VMs on different nodes connected via localnet NAD
2. Verify ARP requests from VM1 reach VM2's node
3. Use `ovs-appctl fdb/show <bridge>` to verify FDB entries include bond interface
4. Monitor with `tcpdump -i <bond-interface> arp` to confirm ARP flooding

### Verification Commands
```bash
# Check bridge mappings
ovs-vsctl get Open_vSwitch . external_ids:ovn-bridge-mappings

# Verify FDB entries
ovs-appctl fdb/show br-ex

# Monitor ARP traffic
tcpdump -i bond0 arp -n

# Check datapath flows
ovs-appctl dpif/show
```

## Alternative Considerations

### Alternative 1: Flush FDB in controller code
Could flush FDB when localnet logical switch port is created in `go-controller/pkg/ovn/localnet_user_defined_network_controller.go`, but node-side is more appropriate since:
- It's closer to the actual OVS bridge setup
- Node code has direct access to OVS daemon
- Controller code operates on logical entities, not physical bridges

### Alternative 2: Periodic FDB refresh
Could add periodic FDB refresh using a background goroutine, but:
- Wasteful - clears MAC learning unnecessarily
- Doesn't address root cause
- Adds complexity

### Alternative 3: Add FDB flush to SetStaticFDBEntry
Could modify the existing `SetStaticFDBEntry` function, but:
- That function is used in multiple places (gateway setup)
- Would cause unnecessary FDB flushes
- Better to be surgical and only flush for localnet bridges

### Alternative 4: Wait for OVS upstream fix
Could wait for OVS to fix the datapath synchronization issue, but:
- Timeline uncertain
- Customer needs immediate solution
- Fix is low-risk and non-invasive

## Risk Assessment

**Risk Level: LOW**

**Why it's safe:**
1. FDB flush is a non-destructive operation
2. The FDB is immediately repopulated from OpenFlow rules
3. If flush fails, we log a warning but don't fail bridge setup
4. Operation is equivalent to what happens during reboot (which works)
5. No changes to OVN logical topology or OpenFlow rules

**Potential side effects:**
1. Brief MAC learning reset (milliseconds) - acceptable
2. Slight delay during bridge setup (negligible)
3. None of the existing flows or configurations are changed

**Rollback plan:**
- If issues arise, simply remove the FDB flush call
- No database migrations or persistent state changes
- Fully backward compatible

## References
- JIRA: https://issues.redhat.com/browse/OCPBUGS-86242
- Related (not a duplicate): https://issues.redhat.com/browse/OCPBUGS-84935
- OVS documentation: http://www.openvswitch.org/support/dist-docs/ovs-appctl.8.txt
