## Settings Notecard Quick Reference

See [SETTINGS_REFERENCE.md](./SETTINGS_REFERENCE.md) for the full reference guide.

### Minimal Example

```
access.multiowner = 0
access.owner = {"12345678-1234-1234-1234-123456789abc": "Master"}
public.mode = 0
lock.locked = 0
```

### Multi-Owner Example

```
access.multiowner = 1
access.owners = {"uuid-owner-1": "Master", "uuid-owner-2": "Mistress"}
access.trustees = {"uuid-trustee-1": "Sir"}
```

### All Recognized Keys

| Key | Type | Notecard-only |
|-----|------|:---:|
| `access.multiowner` | 0/1 | Yes |
| `access.owner` | JSON object `{uuid: honorific}` | |
| `access.owners` | JSON object `{uuid: hon, ...}` | Yes (bulk) |
| `access.trustees` | JSON object `{uuid: hon, ...}` | |
| `access.blacklist` | CSV in brackets `[uuid, ...]` | |
| `public.mode` | 0/1 | |
| `lock.locked` | 0/1 | |
| `tpe.mode` | 0/1 | |
| `access.enablerunaway` | 0/1 | |
| `rlvex.ownertp` | 0/1 | |
| `rlvex.ownerim` | 0/1 | |
| `rlvex.trusteetp` | 0/1 | |
| `rlvex.trusteeim` | 0/1 | |
| `bell.visible` | 0/1 | |
| `bell.enablesound` | 0/1 | |
| `bell.volume` | 0.0-1.0 | |
| `bell.sound` | UUID | |

**Note:** `access.owner`, `access.owners`, and `access.trustees` use JSON object format `{uuid: honorific}`, not arrays. Arrays are rejected for these keys.
