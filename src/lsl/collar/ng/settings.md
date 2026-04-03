## Settings Notecard Quick Reference

See [SETTINGS_REFERENCE.md](./SETTINGS_REFERENCE.md) for the full reference guide.

### Minimal Example

```
multi_owner_mode=0
owner={"12345678-1234-1234-1234-123456789abc": "Master"}
public_mode=0
locked=0
```

### Multi-Owner Example

```
multi_owner_mode=1
owners={"uuid-owner-1": "Master", "uuid-owner-2": "Mistress"}
trustees={"uuid-trustee-1": "Sir"}
```

### All Recognized Keys

| Key | Type | Notecard-only |
|-----|------|:---:|
| `multi_owner_mode` | 0/1 | Yes |
| `owner` | JSON object `{uuid: honorific}` | |
| `owners` | JSON object `{uuid: hon, ...}` | Yes (bulk) |
| `trustees` | JSON object `{uuid: hon, ...}` | |
| `blacklist` | JSON array `[uuid, ...]` | |
| `public_mode` | 0/1 | |
| `locked` | 0/1 | |
| `tpe_mode` | 0/1 | |
| `runaway_enabled` | 0/1 | |
| `ex_owner_tp` | 0/1 | |
| `ex_owner_im` | 0/1 | |
| `ex_trustee_tp` | 0/1 | |
| `ex_trustee_im` | 0/1 | |
| `bell_visible` | 0/1 | |
| `bell_sound_enabled` | 0/1 | |
| `bell_volume` | 0.0-1.0 | |
| `bell_sound` | UUID | |

**Note:** `owner`, `owners`, and `trustees` use JSON object format `{uuid: honorific}`, not arrays. Arrays are rejected for these keys.
