# D/s Collar Installer/Updater System Design

## Overview

A one-click installation system where a user drops a **listener script** into any collar object, clicks the collar, and the system automatically transfers all necessary components (scripts, animations, HUD, leash holder, notecards) from a **donor collar** to the **target collar**.

---

## Architecture

### Components

1. **Donor Collar** (Master/Source)
   - Contains all up-to-date scripts, animations, objects, and notecards
   - Contains `ds_collar_installer.lsl` (transmitter script)
   - Prepared as the "master copy" for installations

2. **Target Collar** (Receiving Object)
   - Any collar/object being "collarized"
   - Contains only `ds_collar_receiver.lsl` (listener script)
   - Will receive all components from donor

3. **Installation Protocol**
   - Handshake-based communication on negative channel
   - Inventory manifest exchange
   - Chunked file transfer with acknowledgment
   - Automatic script removal and setup

---

## Installation Flow

```
┌─────────────────┐                    ┌─────────────────┐
│  Donor Collar   │                    │ Target Collar   │
│  (Transmitter)  │                    │  (Receiver)     │
└────────┬────────┘                    └────────┬────────┘
         │                                      │
         │  User touches donor collar           │
         │◄─────────────────────────────        │
         │                                      │
         │  1. INSTALLER_HELLO                  │
         │─────────────────────────────────────►│
         │     (broadcast on negative channel)  │
         │                                      │
         │  2. RECEIVER_READY                   │
         │◄─────────────────────────────────────│
         │     (includes target object key)     │
         │                                      │
         │  3. MANIFEST                         │
         │─────────────────────────────────────►│
         │     (JSON list of all items)         │
         │                                      │
         │  4. MANIFEST_ACK                     │
         │◄─────────────────────────────────────│
         │                                      │
         │  5. Transfer Scripts (chunked)       │
         │─────────────────────────────────────►│
         │  6. SCRIPT_ACK                       │
         │◄─────────────────────────────────────│
         │                                      │
         │  7. Transfer Animations (chunked)    │
         │─────────────────────────────────────►│
         │  8. ANIM_ACK                         │
         │◄─────────────────────────────────────│
         │                                      │
         │  9. Transfer Objects (HUD, Holder)   │
         │─────────────────────────────────────►│
         │  10. OBJECT_ACK                      │
         │◄─────────────────────────────────────│
         │                                      │
         │  11. Transfer Notecards              │
         │─────────────────────────────────────►│
         │  12. NOTECARD_ACK                    │
         │◄─────────────────────────────────────│
         │                                      │
         │  13. INSTALL_COMPLETE                │
         │─────────────────────────────────────►│
         │                                      │
         │  14. INSTALLER_DONE                  │
         │◄─────────────────────────────────────│
         │                                      │
         │     Target collar resets scripts     │
         │     Receiver script self-deletes     │
         │                                      │
```

---

## Message Protocol

### Channel Selection
- **Channel**: `-87654321` (negative, pseudo-random)
- **Alternative**: Generate channel from donor UUID hash to avoid collisions

### Message Format
All messages use JSON on the installation channel:

```lsl
{
    "type": "message_type",
    "session": "uuid",           // Session ID for pairing
    "donor": "uuid",             // Donor collar UUID
    "target": "uuid",            // Target collar UUID (after pairing)
    "data": { ... }              // Message-specific payload
}
```

### Message Types

#### 1. INSTALLER_HELLO
Broadcast from donor when user clicks it.

```json
{
    "type": "installer_hello",
    "session": "session-uuid",
    "donor": "donor-key",
    "version": "2.0",
    "range": 5.0
}
```

#### 2. RECEIVER_READY
Sent by receiver in response to HELLO (within range).

```json
{
    "type": "receiver_ready",
    "session": "session-uuid",
    "target": "target-key",
    "donor": "donor-key",
    "owner": "wearer-key"
}
```

#### 3. MANIFEST
Inventory manifest sent by donor.

```json
{
    "type": "manifest",
    "session": "session-uuid",
    "counts": {
        "scripts": 27,
        "animations": 45,
        "objects": 2,
        "notecards": 3
    },
    "scripts": ["ds_collar_kernel.lsl", "ds_collar_kmod_auth.lsl", ...],
    "animations": ["nadu.bvh", "kneel.bvh", ...],
    "objects": ["ds_collar_control_hud", "ds_collar_leash_holder"],
    "notecards": ["D/s Collar Manual", "D/s Collar Setup", "settings"]
}
```

#### 4. MANIFEST_ACK
Acknowledgment from receiver.

```json
{
    "type": "manifest_ack",
    "session": "session-uuid",
    "ready": true
}
```

#### 5. TRANSFER_ITEM
Transfer notification for each item (sent before llGiveInventory).

```json
{
    "type": "transfer_item",
    "session": "session-uuid",
    "item_type": "script",        // script, animation, object, notecard
    "item_name": "ds_collar_kernel.lsl",
    "index": 1,
    "total": 27
}
```

#### 6. ITEM_ACK
Acknowledgment from receiver after receiving item.

```json
{
    "type": "item_ack",
    "session": "session-uuid",
    "item_type": "script",
    "item_name": "ds_collar_kernel.lsl",
    "received": true
}
```

#### 7. INSTALL_COMPLETE
Final message from donor.

```json
{
    "type": "install_complete",
    "session": "session-uuid",
    "timestamp": 1700000000
}
```

#### 8. INSTALLER_DONE
Confirmation from receiver, triggers cleanup.

```json
{
    "type": "installer_done",
    "session": "session-uuid"
}
```

---

## LSL Implementation

### Donor Script: `ds_collar_installer.lsl`

**Purpose**: Transmits all inventory to target collar

**Key Functions**:
- `scan_inventory()` - Build manifest of all transferable items
- `start_installation()` - Initiate handshake when touched
- `send_manifest()` - Send inventory list to receiver
- `transfer_items()` - Transfer items in chunks with acknowledgment
- `handle_ack()` - Process acknowledgments and continue transfer

**State Machine**:
- `idle` - Waiting for touch
- `handshake` - Broadcasting HELLO, waiting for RECEIVER_READY
- `transferring` - Sending items sequentially
- `complete` - Installation finished

**Key Challenges**:
- **llGiveInventory() to Objects**: Only works on objects in same region
- **Permission Requirements**: PERMISSION_DEBIT not required for objects
- **Throttling**: llGiveInventory has delays; need acknowledgment per item
- **Timeout Handling**: 60-second timeout per phase

### Receiver Script: `ds_collar_receiver.lsl`

**Purpose**: Listens for installer and receives inventory

**Key Functions**:
- `listen_for_installer()` - Set up listener on installation channel
- `respond_to_hello()` - Send RECEIVER_READY when donor detected
- `receive_manifest()` - Store expected inventory list
- `acknowledge_items()` - Send ACKs as items arrive
- `finalize_installation()` - Remove receiver script, reset collar

**State Machine**:
- `listening` - Waiting for INSTALLER_HELLO
- `paired` - Paired with specific donor
- `receiving` - Accepting inventory transfers
- `finalizing` - Cleanup and self-deletion

**Key Challenges**:
- **Detecting Inventory Changes**: Use `changed(CHANGED_INVENTORY)` event
- **Self-Deletion**: `llRemoveInventory(llGetScriptName())` after installation
- **Script Reset Trigger**: Broadcast soft_reset to KERNEL_LIFECYCLE after items received

---

## Security & Safety

### Range Limiting
- Only respond to donors within **5 meters**
- Use `llVecDist(llGetPos(), donor_pos)` to verify proximity
- Prevents accidental installations from distant donors

### Owner Validation
- Receiver only accepts installations from **same owner** as target collar
- Validates `llGetOwnerKey(donor) == llGetOwner()`
- Prevents griefing by unauthorized installers

### Session IDs
- Each installation uses unique session UUID
- Both scripts validate session ID on every message
- Prevents message injection or cross-installation interference

### Timeout Protection
- 60-second timeout per installation phase
- Auto-abort if donor goes silent
- Prevents stuck installations

### User Confirmation
- Optional: Dialog confirmation before accepting installation
- "Accept installation from [Donor Name]?" → Yes/No
- Adds user consent layer

---

## User Experience

### For Installer (Donor Owner)

1. **Prepare Donor Collar**
   - Ensure all scripts, animations, HUD, leash holder, and notecards are in donor
   - Drop `ds_collar_installer.lsl` into donor collar
   - Wear or rez donor collar

2. **Prepare Target Collar**
   - Give `ds_collar_receiver.lsl` to person who will receive collar
   - They drop it into their collar object
   - Target collar is now ready to receive

3. **Execute Installation**
   - Stand within 5 meters of target collar wearer
   - Touch donor collar
   - Installer broadcasts HELLO
   - Receiver responds automatically
   - Watch progress messages in local chat

4. **Completion**
   - "Installation complete: 27 scripts, 45 animations, 2 objects, 3 notecards transferred"
   - Target collar automatically resets and becomes functional
   - Installer script remains in donor for future installations

### For Recipient (Target Owner)

1. **Drop receiver script** into collar
2. **Wait for installer** to initiate (no action needed)
3. **Automatic installation** proceeds
4. **Collar ready** after reset

**Progress Messages**:
```
"Installation started: Receiving manifest..."
"Manifest received: 77 items total"
"Receiving scripts: 1/27 (ds_collar_kernel.lsl)"
"Receiving scripts: 27/27 (complete)"
"Receiving animations: 45/45 (complete)"
"Receiving objects: 2/2 (complete)"
"Receiving notecards: 3/3 (complete)"
"Installation complete! Collar is ready."
"Resetting collar scripts..."
```

---

## Error Handling

### Timeout Scenarios

1. **No Receiver Response** (30s timeout)
   - Installer: "No collar found within range. Aborting."
   - Return to idle state

2. **Receiver Disappears** (60s timeout during transfer)
   - Installer: "Connection lost with target collar. Aborting."
   - Receiver: "Installation timed out. Receiver script remains active."

3. **Incomplete Transfer**
   - Receiver tracks expected vs received items
   - If timeout occurs: "Installation incomplete: 23/27 scripts received. Keeping receiver active for retry."

### Inventory Issues

1. **Item Not Found in Donor**
   - Installer: "Warning: Item 'missing_script.lsl' not found. Skipping."
   - Continue with remaining items

2. **Transfer Failure**
   - LSL error messages appear in owner chat
   - Installer retries once per item
   - After retry failure: "Failed to transfer 'item_name'. Continuing."

3. **Full Inventory** (unlikely for scripts/anims)
   - Receiver: "Error: Inventory full. Cannot accept more items."
   - Abort installation

### Pairing Errors

1. **Multiple Receivers in Range**
   - Installer detects multiple RECEIVER_READY messages
   - Dialog: "Multiple collars detected. Click the collar you want to update."
   - User clicks target collar to confirm pairing

2. **Wrong Owner**
   - Receiver validates `llGetOwnerKey(donor) == llGetOwner()`
   - If mismatch: Silently ignore (no error spam)

---

## Advanced Features

### Update Mode vs Fresh Install

**Update Mode**: Target collar already has D/s Collar scripts (COMPLEX)
- Receiver detects existing `ds_collar_kernel.lsl`
- Sends `"mode": "update"` in RECEIVER_READY
- **Critical Challenge**: Cannot remove running scripts while collar is locked/worn
- **Solution**: Multi-phase update with atomic swap (see Update Strategy below)

**Fresh Install Mode**: Target collar is empty/different system
- Sends `"mode": "fresh"`
- Transfers everything
- Simpler: no existing scripts to preserve

### Selective Transfer

Optional enhancement: Allow user to choose what to transfer
- Dialog: "What to install?"
  - [Core Scripts] [Animations] [Objects] [All]
- Installer only transfers selected categories
- Useful for animation-only updates

### Version Detection

- Donor includes version in INSTALLER_HELLO: `"version": "2.0"`
- Receiver checks if it has version metadata
- If donor version ≤ receiver version: "Already up to date. Installation cancelled."
- Prevents downgrade accidents

### Backup/Rollback

- Before installation, receiver could notify: "Backup your settings notecard!"
- Or: Auto-copy existing settings notecard to wearer's inventory before overwrite

---

## Implementation Checklist

### Phase 1: Basic Functionality
- [ ] Create `ds_collar_receiver.lsl` with listen and inventory tracking
- [ ] Create `ds_collar_installer.lsl` with inventory scan and transfer
- [ ] Implement handshake protocol (HELLO → READY → MANIFEST)
- [ ] Implement chunked transfer with acknowledgment
- [ ] Test with 2-3 scripts only

### Phase 2: Full Transfer
- [ ] Transfer all scripts (27 items)
- [ ] Transfer all animations (45+ items)
- [ ] Transfer objects (HUD, leash holder)
- [ ] Transfer notecards (manual, setup, "settings" notecard)
- [ ] Handle timeout scenarios

### Phase 3: Polish & Safety
- [ ] Add range validation (5m limit)
- [ ] Add owner validation
- [ ] Add session ID validation
- [ ] Add progress messages to owner chat
- [ ] Add error recovery

### Phase 4: Advanced Features
- [ ] Update vs fresh install detection
- [ ] Version checking
- [ ] Selective transfer (optional categories)
- [ ] Multi-receiver disambiguation

---

## Technical Constraints & LSL Limitations

### llGiveInventory Limitations

1. **Object-to-Object Transfer**
   - Only works within same region
   - Both objects must be rezzed or worn
   - Cannot transfer to avatars directly (use llGiveInventory for that)

2. **Transfer Delays**
   - LSL enforces delays between llGiveInventory calls
   - Minimum ~1-2 seconds per item
   - 77 items = ~2-3 minutes total transfer time

3. **No Folder Support**
   - Cannot transfer entire folders
   - Must transfer items individually
   - Cannot preserve folder organization

### Script Memory

- Each script has 64KB limit (Mono)
- Installer must be efficient with memory
- Manifest stored as JSON string (compact)
- Use strided lists for tracking

### Listen Limitations

- Listeners consume script resources
- Use single listener on negative channel
- Remove listener when not needed
- 64-message queue limit (rarely hit)

### Inventory Detection

- `changed(CHANGED_INVENTORY)` fires on any inventory change
- Cannot distinguish between additions and removals
- Must track expected items separately
- Race condition: event may fire before item fully appears

### Recommended Workarounds

1. **Chunked Transfer**: Transfer in batches of 10 items, wait for ACK
2. **Retry Logic**: Retry failed transfers once
3. **Manifest Comparison**: Receiver verifies final inventory matches manifest
4. **Progressive Messages**: Show "X/Y items transferred" every 5 items

---

## Example Code Snippets

### Inventory Scanning (Donor)

```lsl
list scan_inventory() {
    list manifest = [];
    
    // Scan scripts
    integer script_count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    while (i < script_count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (name != llGetScriptName()) {  // Don't include installer itself
            manifest += ["script", name];
        }
        i += 1;
    }
    
    // Scan animations
    integer anim_count = llGetInventoryNumber(INVENTORY_ANIMATION);
    i = 0;
    while (i < anim_count) {
        string name = llGetInventoryName(INVENTORY_ANIMATION, i);
        manifest += ["animation", name];
        i += 1;
    }
    
    // Scan objects
    integer obj_count = llGetInventoryNumber(INVENTORY_OBJECT);
    i = 0;
    while (i < obj_count) {
        string name = llGetInventoryName(INVENTORY_OBJECT, i);
        manifest += ["object", name];
        i += 1;
    }
    
    // Scan notecards
    integer nc_count = llGetInventoryNumber(INVENTORY_NOTECARD);
    i = 0;
    while (i < nc_count) {
        string name = llGetInventoryName(INVENTORY_NOTECARD, i);
        manifest += ["notecard", name];
        i += 1;
    }
    
    return manifest;
}
```

### Transfer Loop (Donor)

```lsl
transfer_next_item() {
    if (TransferIndex >= llGetListLength(Manifest)) {
        // All items sent
        send_install_complete();
        return;
    }
    
    string item_type = llList2String(Manifest, TransferIndex);
    string item_name = llList2String(Manifest, TransferIndex + 1);
    
    // Send notification
    string msg = llList2Json(JSON_OBJECT, [
        "type", "transfer_item",
        "session", SessionId,
        "item_type", item_type,
        "item_name", item_name,
        "index", (TransferIndex / 2) + 1,
        "total", llGetListLength(Manifest) / 2
    ]);
    llRegionSay(INSTALL_CHANNEL, msg);
    
    // Give item to target
    llGiveInventory(TargetKey, item_name);
    
    // Wait for ACK (timer handles timeout)
    llSetTimerEvent(10.0);  // 10s timeout per item
}
```

### Inventory Tracking (Receiver)

```lsl
changed(integer change) {
    if (change & CHANGED_INVENTORY) {
        // Check if expected item arrived
        if (ExpectingItem != "") {
            if (llGetInventoryType(ExpectingItem) != INVENTORY_NONE) {
                // Item received
                ReceivedCount += 1;
                
                // Send ACK
                string msg = llList2Json(JSON_OBJECT, [
                    "type", "item_ack",
                    "session", SessionId,
                    "item_name", ExpectingItem,
                    "received", TRUE
                ]);
                llRegionSay(INSTALL_CHANNEL, msg);
                
                // Progress message
                llOwnerSay("Received " + (string)ReceivedCount + "/" + (string)TotalItems + ": " + ExpectingItem);
                
                ExpectingItem = "";
            }
        }
    }
}
```

---

## Deployment Strategy

### Packaging

1. **Donor Collar Package**
   - All 27 scripts (kernel + modules + plugins)
   - All 45+ animations
   - Control HUD object
   - Leash holder object
   - 3 notecards (manual, setup guide, "settings" notecard)
   - `ds_collar_installer.lsl` (installer script)

2. **Receiver Package**
   - Single script: `ds_collar_receiver.lsl`
   - Distribute as freebie or give with documentation

### Distribution

- **In-World Vendors**: Sell/give complete donor collar package
- **Marketplace**: Package as boxed product
- **Documentation**: Include INSTALLER_GUIDE.md in package

---

## In-Place Update Strategy (CRITICAL)

### The Challenge

Updating a **worn, locked collar** presents unique problems:

1. **Cannot Remove Running Scripts**: `llRemoveInventory()` fails on running scripts
2. **Settings Must Persist**: Settings notecard contains ownership, ACL, restrictions
3. **No Downtime**: Collar must remain functional during update
4. **Lock State**: Collar may be locked, preventing manual intervention
5. **RLV Restrictions**: May be locked by RLV, can't detach/edit
6. **Atomic Updates**: Must avoid partially-updated state (half old, half new scripts)

### Solution: Hot-Swap Update Protocol

#### Phase 1: Preparation (Before Update)
```
1. Receiver detects update mode (existing kernel present)
2. Broadcasts BACKUP_SETTINGS on SETTINGS_BUS
3. Settings module writes current KV store to linkset data
4. Receiver confirms backup complete
```

#### Phase 2: Transfer New Scripts (Parallel Inventory)
```
1. Installer transfers new scripts with ".new" suffix
   - ds_collar_kernel.lsl.new
   - ds_collar_kmod_auth.lsl.new
   - ds_collar_plugin_access.lsl.new
   
2. All new scripts transferred to inventory (not running yet)
3. Receiver tracks: 27 scripts x 2 versions = 54 scripts in inventory
```

#### Phase 3: Settings Preservation
```
1. Receiver reads current settings notecard
2. Stores in temporary linkset data under "update_backup_*" keys
3. Extracts critical settings:
   - owner_key / owner_keys
   - multi_owner_mode
   - blacklist
   - trustees
   - RLV restrictions
   - Lock state
   - Any plugin-specific settings
```

#### Phase 4: Atomic Swap
```
1. Receiver sends PREPARE_SWAP to all running scripts
2. All scripts write final state to linkset data
3. Receiver waits 2 seconds for state sync
4. Receiver performs atomic rename operation:
   
   FOR EACH script in manifest:
       // Remove old version (now safe - they wrote state)
       llRemoveInventory("ds_collar_kernel.lsl")
       
       // Wait 0.5s for removal
       llSleep(0.5)
       
       // Rename new version to active name
       llSetInventoryPermMask("ds_collar_kernel.lsl.new", ...)
       // (LSL NOTE: Cannot rename directly - must use workaround)
```

#### Phase 5: Restore & Reboot
```
1. New scripts now have correct names, old scripts removed
2. Receiver writes settings from linkset data backup to notecard
3. Receiver broadcasts SOFT_RESET_ALL on KERNEL_LIFECYCLE
4. All new scripts start, read restored settings
5. Collar functional with new scripts + old settings
6. Receiver self-destructs after confirmation
```

### LSL Script Rename Workaround

**Problem**: LSL has no `llRenameInventory()`

**Solution**: Use object description field as staging area

```lsl
// Pseudo-code for atomic swap
atomic_swap_script(string old_name, string new_name) {
    // 1. Read new script content into memory (not possible - too large)
    // 2. Alternative: Use object description as signal
    
    // ACTUAL SOLUTION: Two-phase commit
    
    // Method A: Reset + Rename Pattern
    // - All old scripts listen for "swap_commit" message
    // - On receiving, they call llRemoveInventory(llGetScriptName())
    // - New scripts detect removal, rename themselves via external helper
    
    // Method B: External Helper Script
    // - Transfer temporary "updater" script that does the rename
    // - Updater removes old, renames new, then self-destructs
    
    // Method C: Linkset Data State Machine (RECOMMENDED)
    // - Old scripts write state to linkset data with timestamp
    // - Old scripts voluntarily self-delete when "swap_now" flag set
    // - New scripts start, detect "swap_complete", rename themselves
    //   by having kernel do: llRemoveInventory(old), then old script
    //   had already set a flag that new script should take over
}
```

### Recommended Implementation: Updater Coordinator Script

**Better Approach**: Use a dedicated **coordinator script** for the swap:

```
ds_collar_updater_coordinator.lsl (temporary script)

Responsibilities:
1. Transferred as part of update package
2. Takes over during swap phase
3. Coordinates orderly shutdown of old scripts
4. Manages rename/removal operations
5. Triggers restart of new scripts
6. Self-destructs when update complete
```

#### Coordinator Update Flow

```
┌─────────────────────────────────────────────────────────────┐
│  Phase 1: Backup & Prepare                                  │
├─────────────────────────────────────────────────────────────┤
│  1. Receiver detects update mode                            │
│  2. Backup settings to linkset data                         │
│  3. Old scripts write state to linkset data                 │
│  4. Confirm backup complete                                 │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  Phase 2: Transfer New Scripts                              │
├─────────────────────────────────────────────────────────────┤
│  1. Transfer all new scripts with ".update" suffix          │
│  2. Transfer ds_collar_updater_coordinator.lsl              │
│  3. Coordinator script starts automatically                 │
│  4. All scripts present: old (running) + new (dormant)      │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  Phase 3: Coordinated Shutdown                              │
├─────────────────────────────────────────────────────────────┤
│  1. Coordinator broadcasts PREPARE_SHUTDOWN                 │
│  2. All old scripts:                                        │
│     - Stop timers                                           │
│     - Close listeners                                       │
│     - Write final state to linkset data                    │
│     - Set script to NOT RUNNING                            │
│  3. Coordinator verifies all scripts stopped                │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  Phase 4: Atomic Swap (Coordinator Active)                  │
├─────────────────────────────────────────────────────────────┤
│  1. FOR EACH old script:                                    │
│     a. llRemoveInventory(old_script_name)                   │
│     b. llSleep(0.5) // Wait for removal                     │
│     c. Check inventory to confirm removed                   │
│  2. Verify all old scripts removed                          │
│  3. No rename needed - new scripts stay with ".update"      │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  Phase 5: Activate New Scripts                              │
├─────────────────────────────────────────────────────────────┤
│  1. FOR EACH new script:                                    │
│     a. llSetScriptState(script_name + ".update", TRUE)      │
│     b. Script starts, detects ".update" in own name         │
│     c. Script broadcasts "ready" to coordinator             │
│  2. Coordinator waits for all scripts to start              │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  Phase 6: Settings Restoration                              │
├─────────────────────────────────────────────────────────────┤
│  1. Coordinator reads settings backup from linkset data     │
│  2. Writes settings notecard (or updates existing)          │
│  3. Broadcasts SETTINGS_RESTORED on KERNEL_LIFECYCLE        │
│  4. New scripts load settings from notecard                 │
│  5. Collar fully functional with new scripts + old settings │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│  Phase 7: Cleanup & Self-Destruct                           │
├─────────────────────────────────────────────────────────────┤
│  1. Coordinator verifies collar functional                  │
│  2. Coordinator removes receiver script                     │
│  3. Coordinator removes itself                              │
│  4. Update complete!                                        │
└─────────────────────────────────────────────────────────────┘
```

### Alternative: Simplified ".update" Suffix Approach

**Simpler but requires script cooperation:**

#### New Scripts Detect Their Own Suffix

```lsl
// In each new script's state_entry():
default {
    state_entry() {
        string my_name = llGetScriptName();
        
        if (llSubStringIndex(my_name, ".update") != -1) {
            // I'm an update version - wait for coordinator signal
            // Don't start normal operations yet
            
            // Listen for coordinator commands
            llListen(UPDATE_CHANNEL, "", NULL_KEY, "");
            return;
        }
        
        // Normal startup for active scripts
        normal_initialization();
    }
}
```

#### Coordinator Commands

```json
// Coordinator broadcasts on UPDATE_CHANNEL
{
    "type": "shutdown_old",
    "session": "uuid"
}

// Old scripts self-terminate
old_script_shutdown() {
    string my_name = llGetScriptName();
    if (llSubStringIndex(my_name, ".update") == -1) {
        // I'm an old version - shut down gracefully
        write_state_to_linkset_data();
        llRemoveInventory(my_name);  // Self-destruct
    }
}
```

```json
// After old scripts removed
{
    "type": "activate_new",
    "session": "uuid"
}

// New scripts activate
new_script_activation() {
    string my_name = llGetScriptName();
    if (llSubStringIndex(my_name, ".update") != -1) {
        // I'm a new version - start operations
        load_state_from_linkset_data();
        normal_initialization();
    }
}
```

### Settings Preservation Details

#### Critical Settings to Preserve

```lsl
// Settings that MUST survive update
list CRITICAL_SETTINGS = [
    "owner_key",
    "owner_keys",
    "owner_hon",
    "owner_hons",
    "multi_owner_mode",
    "trustees",
    "blacklist",
    "public_access",
    "locked",
    "rlv_relay_mode",
    "rlv_restrictions",
    "tpe_mode",
    "bell_enabled",
    "leash_length",
    // ... all plugin-specific settings
];

backup_settings() {
    // Read current settings notecard
    if (llGetInventoryType("settings") != INVENTORY_NOTECARD) {
        llOwnerSay("WARNING: No settings notecard found!");
        return;
    }
    
    // Request settings from settings module
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    
    // Settings module responds with full KV store
    // Receiver writes to linkset data with "backup_" prefix
}

restore_settings() {
    // Read from linkset data backup
    list keys = llGetLinksetData();
    integer i = 0;
    integer len = llGetListLength(keys);
    
    list kv_pairs = [];
    
    while (i < len) {
        string key = llList2String(keys, i);
        if (llSubStringIndex(key, "backup_") == 0) {
            string actual_key = llGetSubString(key, 7, -1);  // Strip "backup_"
            string value = llLinksetDataRead(key);
            kv_pairs += [actual_key, value];
        }
        i += 1;
    }
    
    // Write settings notecard with preserved values
    write_settings_notecard(kv_pairs);
    
    // Clean up backup
    i = 0;
    while (i < len) {
        string key = llList2String(keys, i);
        if (llSubStringIndex(key, "backup_") == 0) {
            llLinksetDataDelete(key);
        }
        i += 1;
    }
}
```

### Handling Lock State During Update

**Problem**: Collar may be locked, preventing normal access

**Solution**: Lock is a **settings value**, not a physical lock

```lsl
// Lock state is stored in settings, not enforced by LSL permissions
// During update:
// 1. Lock state preserved in settings backup
// 2. Update proceeds (scripts can be modified even when "locked")
// 3. New scripts read lock state from restored settings
// 4. Lock functionality resumes immediately

// No special handling needed - it's just a setting!
```

### Handling RLV Restrictions During Update

**Problem**: RLV may prevent editing/removing inventory

**Solution**: RLV restrictions are **self-imposed** by collar scripts

```lsl
// RLV restrictions (e.g., @editobj=n) are issued by collar scripts
// During update:
// 1. Coordinator broadcasts RLV_RELEASE on appropriate channel
// 2. RLV plugin releases all restrictions temporarily
// 3. Update proceeds
// 4. New RLV plugin reads restrictions from restored settings
// 5. Restrictions re-applied automatically

rlv_temporary_release() {
    // RLV plugin receives PREPARE_SHUTDOWN
    // Release all active restrictions
    llOwnerSay("@clear");  // Clear all RLV restrictions
    
    // Store restrictions in linkset data for restoration
    llLinksetDataWrite("rlv_restrictions_backup", current_restrictions);
}
```

### Update Conflict Resolution

**Scenario**: User modified settings during transfer

**Solution**: Last-write-wins with timestamp checking

```lsl
// Backup settings include timestamp
backup_settings() {
    integer backup_time = llGetUnixTime();
    llLinksetDataWrite("backup_timestamp", (string)backup_time);
    // ... backup settings
}

restore_settings() {
    integer backup_time = (integer)llLinksetDataRead("backup_timestamp");
    integer current_time = llGetUnixTime();
    
    if (current_time - backup_time > 300) {  // 5 minutes
        // Long update - warn user about potential conflicts
        llOwnerSay("WARNING: Update took over 5 minutes. Some settings may have changed.");
    }
    
    // Restore anyway (last-write-wins)
    // Alternative: Merge strategies for specific settings
}
```

### Rollback on Failure

**Scenario**: Update fails midway (donor disconnects, errors, etc.)

**Solution**: Keep old scripts until update confirmed successful

```lsl
// Instead of removing old scripts immediately:
// 1. Set old scripts to NOT RUNNING
// 2. Verify new scripts started successfully
// 3. Only then remove old scripts
// 4. If new scripts fail to start: rollback

rollback_update() {
    llOwnerSay("Update failed! Rolling back to previous version...");
    
    // Set new scripts to NOT RUNNING
    // Set old scripts to RUNNING
    // Restore settings from backup
    // Remove new scripts
    // Remove coordinator
    
    llOwnerSay("Rollback complete. Collar restored to previous version.");
}
```

### Testing Strategy

**Critical Test Cases**:

1. ✅ Update while worn and locked
2. ✅ Update while RLV restricted (@editobj=n)
3. ✅ Update with active leash
4. ✅ Update with owner present (active session)
5. ✅ Update with complex settings (multi-owner, trustees, blacklist)
6. ✅ Update interruption (donor leaves range mid-update)
7. ✅ Update with full inventory (memory pressure)
8. ✅ Update with missing animations (partial update)

### Memory Considerations

**Challenge**: Coordinator + Receiver + Old Scripts + New Scripts = 4x memory

**Solutions**:
1. Receiver transfers control to coordinator early, self-destructs
2. Coordinator is minimal (< 10KB)
3. Old scripts stop timers/listeners to free memory
4. Linkset data used instead of script memory for settings

### Update Time Estimation

**Typical Update Timeline**:
```
Phase 1: Backup (10 seconds)
Phase 2: Transfer 27 scripts (54 seconds @ 2s each)
Phase 3: Shutdown old scripts (5 seconds)
Phase 4: Remove old scripts (14 seconds @ 0.5s each)
Phase 5: Start new scripts (5 seconds)
Phase 6: Restore settings (10 seconds)
Phase 7: Cleanup (5 seconds)

TOTAL: ~2 minutes
```

**User Experience**:
- "Update started. Do not remove collar or leave area."
- "Backing up settings..."
- "Transferring new scripts: 1/27..."
- "Transferring new scripts: 27/27 (complete)"
- "Shutting down old scripts..."
- "Swapping to new version..."
- "Restoring settings..."
- "Update complete! Collar is ready."

---

## Future Enhancements

### Remote Installation
- Installer in separate "installation box" object
- User touches box → selects collar in range → transfers to collar
- Allows updating collars without wearing master collar

### Multi-Target Updates
- Touch donor once → updates ALL nearby collars with receiver scripts
- Useful for updating multiple collars at once
- Requires collision avoidance (stagger transfers)

### Settings Preservation
- Detect existing settings notecard
- Copy to temporary storage before transfer
- Restore after installation (merge with new settings)

### Differential Updates
- Only transfer items that changed since last version
- Requires version tracking per item
- Reduces transfer time for minor updates

### Web-Based Installer
- LSL HTTP request to fetch manifest from external server
- Download scripts from web (if SL permissions allow)
- Always get latest version without manual updates

---

## Conclusion

This installer system provides a **seamless, one-click solution** for installing and updating D/s Collar on any object. By separating the concerns into **donor** (transmitter) and **receiver** (listener), and using a robust **handshake protocol**, the system ensures reliable transfers even with LSL's limitations.

**Key Benefits**:
- ✅ One-click installation
- ✅ No manual script copying
- ✅ Automatic updates for existing collars
- ✅ Safe (range-limited, owner-validated)
- ✅ Robust (timeout handling, retry logic)
- ✅ User-friendly (progress messages, error handling)

The system can be implemented in phases, starting with basic script transfer and expanding to full automation with advanced features like version detection and selective updates.
