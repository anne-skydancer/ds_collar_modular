# D/s Collar Settings Notecard Reference

Lines starting with `#` are comments and ignored by the parser.
Key-value pairs use `=` as separator. Whitespace around `=` is trimmed.

## Single Owner Mode (default)

```
owner_key = 1a2b3c4d-5e6f-7890-abcd-ef1234567890
owner_hon = Master
```

## Multi-Owner Mode

```
multi_owner_mode = 1
owner_keys = [1a2b3c4d-5e6f-7890-abcd-ef1234567890, 9f8e7d6c-5b4a-3210-fedc-ba0987654321]
owner_honorifics = {"1a2b3c4d-5e6f-7890-abcd-ef1234567890":"King", "9f8e7d6c-5b4a-3210-fedc-ba0987654321":"Mistress"}
```

## Trustees

```
trustees = {"a1b2c3d4-e5f6-7890-abcd-111111111111":"Sir", "b2c3d4e5-f6a7-8901-bcde-222222222222":"Madame"}
```

Trustee honorifics: Sir, Madame, Milord, Milady

## Access Control

```
public_mode = 0
locked = 0
tpe_mode = 0
runaway_enabled = 1
```

## Blacklist

```
blacklist = [deadbeef-dead-beef-dead-beefdeadbeef]
```

## RLV Exceptions

```
ex_owner_tp = 1
ex_owner_im = 1
ex_trustee_tp = 0
ex_trustee_im = 0
```

## Format Notes

- `trustees` and `owner_honorifics` use JSON object format: `{"uuid":"honorific"}`
- `owner_keys`, `blacklist` use JSON array format: `[uuid, uuid]`
- Scalar values are plain strings or integers (0/1 for booleans)
- Array syntax `[...]` is rejected for `trustees` and `owner_honorifics`
- Owner honorifics: Master, Mistress, Daddy, Mommy, King, Queen
- Trustee honorifics: Sir, Madame, Milord, Milady
