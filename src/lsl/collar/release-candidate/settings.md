## Settings Notecard Quick Reference

See [SETTINGS_REFERENCE.md](./SETTINGS_REFERENCE.md) for the full reference guide.

### Minimal Example (Single Owner)

```
access.multiowner = 0
access.owner = 12345678-1234-1234-1234-123456789abc
access.ownerhonorific = Master
public.mode = 0
lock.locked = 0
```

### Multi-Owner Example

```
access.multiowner = 1
access.owneruuids = 12345678-1234-1234-1234-123456789abc,87654321-4321-4321-4321-cba987654321
access.ownerhonorifics = Master,Mistress
access.trusteeuuids = aaaaaaaa-1111-2222-3333-444444444444
access.trusteehonorifics = Sir
```

`access.owneruuids` and `access.ownerhonorifics` are parallel CSVs — the
first uuid pairs with the first honorific, and so on. Same for trustees.

### All Recognized Keys

| Key | Type | Notes |
|-----|------|-------|
| `access.multiowner` | 0/1 | Notecard-only. Selects single vs multi-owner mode. |
| `access.owner` | bare UUID | Single-owner mode only. |
| `access.ownerhonorific` | string | Single-owner mode only. |
| `access.owneruuids` | CSV of UUIDs | Multi-owner mode, notecard-only. |
| `access.ownerhonorifics` | CSV of strings | Multi-owner mode, parallel to `access.owneruuids`. |
| `access.trusteeuuids` | CSV of UUIDs | Notecard-only. |
| `access.trusteehonorifics` | CSV of strings | Parallel to `access.trusteeuuids`. |
| `blacklist.blklistuuid` | CSV of UUIDs | |
| `public.mode` | 0/1 | |
| `lock.locked` | 0/1 | |
| `tpe.mode` | 0/1 | Requires an external owner already set. |
| `access.enablerunaway` | 0/1 | |
| `rlvex.ownertp` | 0/1 | |
| `rlvex.ownerim` | 0/1 | |
| `rlvex.trusteetp` | 0/1 | |
| `rlvex.trusteeim` | 0/1 | |
| `bell.visible` | 0/1 | |
| `bell.enablesound` | 0/1 | |
| `bell.volume` | 0.0-1.0 | |
| `bell.sound` | UUID | |

**Note:** Owner/trustee data is stored as flat scalars (single mode) or
parallel CSVs (multi mode). JSON object syntax is **not** accepted by the
parser. Display names are resolved automatically; you only supply UUIDs and
honorifics.
