# D/s Collar Updater Scripts

This directory contains the installer and updater scripts for the D/s Collar v2.0 modular system.

## Overview

Two separate systems are provided:

1. **System 1: Fresh Installation** - For unworn/unlocked collars
2. **System 2: In-Place Update** - For worn/locked/RLV-restricted collars

## System 1: Fresh Installation

### Scripts
- `ds_collar_receiver.lsl` - Receiver script (goes in target collar)
- `ds_collar_installer.lsl` - Installer script (goes in donor/source object)

### Usage
1. Drop `ds_collar_receiver.lsl` into the target (empty) collar
2. Drop `ds_collar_installer.lsl` into an object containing collar scripts/animations
3. Touch the donor object to initiate installation
4. Receiver will acknowledge each transferred item
5. Receiver self-destructs after successful installation

### Protocol
- Uses channel -87654321 for communication
- Range limited to 10m
- Timeout: 300s total, 30s per item
- Tracks manifest and counts received items

### Requirements
- Target collar must be unworn OR worn but unlocked
- Target collar inventory must be accessible (no RLV blocking)
- Both objects within 10m range

## System 2: In-Place Update

### Scripts
- `ds_collar_updater_source.lsl` - Updater script (goes in updater object)
- `ds_collar_updater_coordinator.lsl` - Coordinator script (transferred during update)
- `ds_collar_activator_shim.lsl` - Activation shim (transferred during update)
- **Note**: Uses existing `ds_collar_kmod_remote.lsl` in collar (no new module needed)

### Architecture
The in-place update system leverages the existing remote listener module (`ds_collar_kmod_remote.lsl`) which already listens on the update channels:
- Channel -8675309: Update discovery (EXTERNAL_ACL_QUERY_CHAN)
- Channel -8675310: Collar responses (EXTERNAL_ACL_REPLY_CHAN)  
- Channel -8675311: Update commands (EXTERNAL_MENU_CHAN)

The updater simply sends `update_discover` messages on these existing channels, and the collar's remote module will respond with `collar_present`. No additional scripts need to be dropped into the collar for updates to work.

### Usage
1. Drop `ds_collar_updater_source.lsl`, `ds_collar_updater_coordinator.lsl`, and `ds_collar_activator_shim.lsl` into updater object
2. Add all updated collar scripts to updater object (kernels, modules, plugins)
3. Ensure target collar has `ds_collar_kmod_remote.lsl` module (standard in all collars)
4. Wear the collar (can be locked or RLV-restricted)
5. Touch updater object to initiate update
6. If multiple collars detected, select which collar to update from dialog
7. Updater transfers scripts with ".new" suffix
8. Coordinator and activator perform hot-swap automatically
9. Coordinator and activator self-destruct after completion

### Protocol
- Uses existing remote channels:
  - -8675309: Update discovery (EXTERNAL_ACL_QUERY_CHAN)
  - -8675310: Collar responses (EXTERNAL_ACL_REPLY_CHAN)
  - -8675311: Update commands (EXTERNAL_MENU_CHAN)
- Touch-based initiation (more secure than chat)
- Range limited to 20m
- Coordinator backs up settings to linkset data before update

### Hot-Swap Process
1. **Discovery**: Updater broadcasts, collar responds with version
2. **Preparation**: Updater sends manifest, collar prepares
3. **Transfer**: Scripts transferred with ".new" suffix (2.5s delay each)
4. **Coordination**: Coordinator script transferred last
5. **Backup**: Coordinator backs up all settings to linkset data
6. **Soft Reset**: All scripts soft-reset
7. **Removal**: Old scripts removed one by one (**notecards preserved**)
8. **Activation**: New scripts activated (suffix removed)
9. **Restore**: Settings restored from linkset data backup
10. **Cleanup**: Coordinator self-destructs

### Critical: Settings Notecard Preservation

**IMPORTANT**: The update process **never removes notecards** from collar inventory.

- Settings notecards contain persistent configuration data
- Collar kernel reads these notecards on startup
- LSL cannot write to notecards (read-only)
- Coordinator explicitly skips notecards during removal phase
- Only script files are removed/replaced during updates
- This ensures zero risk of settings data loss

### Requirements
- Collar can be worn, locked, and/or RLV-restricted
- Only collar owner can initiate updates
- Updater and collar within 20m range
- Coordinator script must be present in updater

## Validation Status

All scripts validated with lslint:

```
ds_collar_receiver.lsl:              0 errors, 0 warnings
ds_collar_installer.lsl:             0 errors, 0 warnings
ds_collar_updater_source.lsl:        0 errors, 0 warnings
ds_collar_updater_coordinator.lsl:   0 errors, 1 warning (benign)
ds_collar_kmod_update.lsl:           0 errors, 1 warning (benign)
```

## Security Features

### System 1 (Fresh Install)
- Owner validation on donor object
- Range checking (10m max)
- Session ID tracking
- Manifest verification
- Timeout protection

### System 2 (In-Place Update)
- Touch-based initiation (no chat commands)
- Owner validation (only owner can update own collar)
- Wearer matching (updater validates collar wearer)
- Range checking (20m max)
- Session ID tracking
- Atomic hot-swap (all or nothing)
- Settings backup/restore via linkset data

## Design Reference

See `reports/INSTALLER_DESIGN.md` for comprehensive design documentation including:
- Message flow diagrams
- State machine specifications
- Error handling scenarios
- Integration with existing collar architecture

## Version Information

- System 1 Scripts: v1.00 Rev 1
- System 2 Scripts: v1.00 Rev 1
- Current Collar Version: 2.0
- Protocol Version: 1.0

## Future Enhancements

Potential improvements for future versions:

1. **Version Checking**: Skip updates if collar already current
2. **Partial Updates**: Update only changed scripts
3. **Animation Transfer**: Include animations in System 2
4. **Rollback**: Keep backup of old scripts for emergency rollback
5. **Progress UI**: Show progress bar or percentage
6. **Multi-Collar**: Support batch updates to multiple collars
7. **Compression**: Pack multiple scripts into single transfer
8. **Verification**: SHA hash verification of transferred scripts

## Testing Checklist

### System 1 Testing
- [ ] Transfer to unworn collar
- [ ] Transfer to worn but unlocked collar
- [ ] Range limit validation (>10m should fail)
- [ ] Timeout handling (disconnect during transfer)
- [ ] Receiver self-destruct after success
- [ ] Manifest mismatch handling
- [ ] Owner validation

### System 2 Testing
- [ ] Update worn collar
- [ ] Update locked collar
- [ ] Update RLV-restricted collar
- [ ] Range limit validation (>20m should fail)
- [ ] Owner validation (non-owner should fail)
- [ ] Wearer validation (wrong collar should fail)
- [ ] Settings preservation through update
- [ ] Hot-swap success (all scripts updated)
- [ ] Coordinator self-destruct
- [ ] Timeout handling

## Troubleshooting

### System 1 Issues

**Receiver doesn't respond:**
- Check range (must be within 10m)
- Verify receiver script is running in target collar
- Check channel -87654321 is not blocked

**Transfer stalls:**
- Check donor object owner matches toucher
- Verify items exist in donor inventory
- Check timeout settings (increase if needed)

**Receiver doesn't self-destruct:**
- Check ReceivedCount matches ExpectedCount
- Verify all items in manifest were received
- Manual removal if stuck

### System 2 Issues

**Collar not discovered:**
- Check range (must be within 20m)
- Verify update module is running in collar
- Check remote channels not blocked

**Transfer fails:**
- Verify collar owner matches updater toucher
- Check all scripts present in updater
- Verify coordinator script included

**Hot-swap fails:**
- Check coordinator script is running
- Verify .new scripts present before coordinator starts
- Check linkset data space available for settings backup
- Manual reset may be required

**Settings lost:**
- Check linkset data backup succeeded
- Verify coordinator restore phase completed
- May need manual settings restore from backup

## Support

For issues or questions:
1. Check lslint validation on all scripts
2. Review debug logs (set DEBUG = TRUE)
3. Check INSTALLER_DESIGN.md for protocol details
4. Review git commit history for recent changes

## License

Same license as main D/s Collar project. See LICENSE file in repository root.
