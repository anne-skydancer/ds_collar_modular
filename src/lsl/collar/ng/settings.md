## Settings Notecard Quick Reference

See [SETTINGS_REFERENCE.md](./SETTINGS_REFERENCE.md) for the full reference guide.

### Minimal Example

```
multi_owner_mode=0
owner_key=12345678-1234-1234-1234-123456789abc
owner_hon=Master
public_mode=0
locked=0
```

### All Recognized Keys

| Key | Type | Notecard-only |
|-----|------|:---:|
| `multi_owner_mode` | 0/1 | Yes |
| `owner_key` | UUID | |
| `owner_keys` | [uuid,...] | Yes |
| `owner_hon` | string | |
| `owner_honorifics` | [string,...] | |
| `trustees` | [uuid,...] | |
| `trustee_honorifics` | [string,...] | |
| `blacklist` | [uuid,...] | |
| `public_mode` | 0/1 | |
| `locked` | 0/1 | |
| `tpe_mode` | 0/1 | |
| `bell_visible` | 0/1 | |
| `bell_sound_enabled` | 0/1 | |
| `bell_volume` | 0.0-1.0 | |
| `bell_sound` | UUID | |
