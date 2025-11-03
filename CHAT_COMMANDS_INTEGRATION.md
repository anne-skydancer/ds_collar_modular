# Chat Commands Integration Guide

This guide explains how to integrate the generic chat command system into your DS Collar plugins.

## Architecture

The chat command system consists of:
- **kmod_chatcmd**: Generic command router (infrastructure)
- **plugin_chatcmd**: Configuration UI for enable/disable, prefix, and channel
- **Your plugin**: Registers commands and handles them

## How It Works

1. Plugin registers with kernel, includes optional "commands" field
2. Kernel routes "commands" field to chat command module (kmod_chatcmd)
3. Chat command module registers commands in its registry
4. User types command in chat (e.g., `<prefix>grab`)
5. kmod_chatcmd parses, verifies ACL, routes to plugin
6. Plugin receives `chatcmd_invoke` message with ACL level
7. Plugin handles command logic

## Integration Steps

### Step 1: Update Plugin Registration

Modify your existing `registerSelf()` function to include commands:

```lsl
registerSelf() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName(),
        "commands", llList2Json(JSON_ARRAY, [    // NEW: Add this field
            "grab",
            "release",
            "yank",
            "length"
        ])
    ]), NULL_KEY);
}
```

**Note:** The `commands` field is optional. Plugins without chat commands can omit it.

### Step 2: Handle Commands

Add handler to your `link_message` event:

```lsl
link_message(integer sender, integer num, string msg, key id) {
    if (num == UI_BUS) {
        if (!jsonHas(msg, ["type"])) return;
        string msg_type = llJsonGetValue(msg, ["type"]);

        // NEW: Handle chat commands
        if (msg_type == "chatcmd_invoke") {
            handleChatCommand(msg, id);
            return;
        }

        // Your existing message handlers...
    }
}
```

### Step 3: Implement Command Handler

```lsl
handleChatCommand(string msg, key user) {
    if (!jsonHas(msg, ["command"]) || !jsonHas(msg, ["context"])) return;

    string context = llJsonGetValue(msg, ["context"]);
    if (context != PLUGIN_CONTEXT) return;  // Not for us

    string command = llJsonGetValue(msg, ["command"]);
    integer acl_level = (integer)llJsonGetValue(msg, ["acl_level"]);

    // Parse args if needed
    list args = [];
    if (jsonHas(msg, ["args"])) {
        string args_json = llJsonGetValue(msg, ["args"]);
        integer num_args = (integer)llJsonGetValue(args_json, ["length"]);
        integer i = 0;
        while (i < num_args) {
            args += [llJsonGetValue(args_json, [i])];
            i = i + 1;
        }
    }

    // Handle each command
    if (command == "grab") {
        if (acl_level >= 1) {
            sendLeashAction("grab");
            llRegionSayTo(user, 0, "Leash grabbed.");
        }
        else {
            llRegionSayTo(user, 0, "Access denied: insufficient permissions to grab leash");
        }
    }
    else if (command == "release") {
        if (acl_level >= 2) {
            sendLeashAction("release");
            llRegionSayTo(user, 0, "Leash released.");
        }
        else {
            llRegionSayTo(user, 0, "Access denied: insufficient permissions to release leash");
        }
    }
    else if (command == "yank") {
        sendLeashAction("yank");
    }
    else if (command == "length") {
        if (acl_level >= 3) {
            if (llGetListLength(args) > 0) {
                integer length = (integer)llList2String(args, 0);
                if (length >= 1 && length <= 20) {
                    sendSetLength(length);
                    llRegionSayTo(user, 0, "Leash length set to " + (string)length + "m");
                }
                else {
                    llRegionSayTo(user, 0, "Length must be between 1 and 20 meters.");
                }
            }
            else {
                llRegionSayTo(user, 0, "Usage: <prefix>length <number>");
            }
        }
        else {
            llRegionSayTo(user, 0, "Access denied: insufficient permissions to change leash length");
        }
    }
}
```

## Example Commands by Plugin

### Leash Plugin
- `<prefix>grab` - Grab leash
- `<prefix>release` - Release leash
- `<prefix>yank` - Yank wearer to leasher
- `<prefix>length <n>` - Set leash length (1-20m)

### Bell Plugin (Example)
```lsl
registerSelf() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", "core_bell",
        "label", "Bell",
        "min_acl", 1,
        "script", llGetScriptName(),
        "commands", llList2Json(JSON_ARRAY, ["bell", "ring"])
    ]), NULL_KEY);
}
```

### Owner Plugin (Example)
```lsl
registerSelf() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", "core_owner",
        "label", "Owner",
        "min_acl", 3,
        "script", llGetScriptName(),
        "commands", llList2Json(JSON_ARRAY, ["owner", "trustee"])
    ]), NULL_KEY);
}
```

## Message Protocol

### Plugin → Kernel (Registration - includes optional commands)
```json
{
  "type": "register",
  "context": "core_leash",
  "label": "Leash",
  "min_acl": 1,
  "script": "ds_collar_plugin_leash.lsl",
  "commands": ["grab", "release", "yank", "length"]
}
```
*(Channel 500 - KERNEL_LIFECYCLE)*

### Kernel → Chat Module (Routes commands field)
```json
{
  "type": "chatcmd_register",
  "context": "core_leash",
  "commands": ["grab", "release", "yank", "length"]
}
```
*(Channel 900 - UI_BUS)*
*(Kernel automatically routes "commands" field to chat command module)*

### Module → Plugin (Command Invocation)
```json
{
  "type": "chatcmd_invoke",
  "command": "grab",
  "args": ["arg1", "arg2"],
  "acl_level": 3,
  "context": "core_leash"
}
```
*(Sent with `id` = user's UUID)*

## ACL Enforcement

**IMPORTANT:** The module verifies ACL before routing, but **your plugin must still check ACL** for each command since different commands may require different ACL levels.

Example:
- `!grab` might allow ACL 1+ (public)
- `!release` might require ACL 2+ (owned wearer)
- `!length` might require ACL 3+ (trustee/owner)

## Configuration

Users configure the chat command system via the "Chat Cmds" menu:
- Enable/Disable: Turns on/off chat command processing
- Prefix: Set command prefix (default: `!`, configurable to any 1-5 character string)
- Private Channel: Set private chat channel (default: 1)

Commands are always active on both:
- Channel 0 (public chat) when enabled
- Configured private channel

**Example:** If prefix is set to `#`, commands become `#grab`, `#release`, etc.

## Best Practices

1. **Include commands in registration**: Add `commands` field to existing `registerSelf()` call
2. **Check context**: Verify `context` field matches your plugin
3. **Validate ACL**: Each command should check `acl_level` appropriately
4. **Parse args carefully**: Handle missing/invalid arguments gracefully
5. **Provide feedback**: Always respond to user via `llRegionSayTo`
6. **Log for debug**: Use `logd()` to trace command handling

## Testing

1. Enable chat commands: Touch collar → Chat Cmds → Enable
2. Test command: Type in chat: `<prefix>grab` (default: `!grab`)
3. Check response: Should execute or deny based on ACL
4. Test args: `<prefix>length 5` should parse argument correctly
5. Test unknown: `<prefix>invalid` should report unknown command
6. Test custom prefix: Change prefix to `#`, then use `#grab`

## Security

- ACL verified by module before routing
- Rate limiting (5s cooldown per user per command)
- Owner always has access regardless of enabled state
- Plugins responsible for command-specific ACL checks
