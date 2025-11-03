# Chat Commands Integration Guide

This guide explains how to integrate the generic chat command system into your DS Collar plugins.

## Architecture

The chat command system consists of:
- **kmod_chatcmd**: Generic command router (infrastructure)
- **plugin_chatcmd**: Configuration UI for enable/disable, prefix, and channel
- **Your plugin**: Registers commands and handles them

## How It Works

1. Plugin registers commands on startup
2. User types command in chat (e.g., `!grab`)
3. kmod_chatcmd parses, verifies ACL, routes to plugin
4. Plugin receives `chatcmd_invoke` message with ACL level
5. Plugin handles command logic

## Integration Steps

### Step 1: Register Commands

Add command registration to your plugin's `state_entry()`:

```lsl
state_entry() {
    // Your existing initialization...
    registerSelf();
    registerChatCommands();  // NEW: Register your commands
}
```

### Step 2: Implement Registration Function

```lsl
registerChatCommands() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "chatcmd_register",
        "context", PLUGIN_CONTEXT,
        "commands", llList2Json(JSON_ARRAY, [
            "grab",
            "release",
            "yank",
            "length"
        ])
    ]), NULL_KEY);

    logd("Chat commands registered");
}
```

### Step 3: Handle Commands

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

### Step 4: Implement Command Handler

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
                llRegionSayTo(user, 0, "Usage: !length <number>");
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
- `!grab` - Grab leash
- `!release` - Release leash
- `!yank` - Yank wearer to leasher
- `!length <n>` - Set leash length (1-20m)

### Bell Plugin (Example)
```lsl
registerChatCommands() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "chatcmd_register",
        "context", "core_bell",
        "commands", llList2Json(JSON_ARRAY, [
            "bell",
            "ring"
        ])
    ]), NULL_KEY);
}
```

### Owner Plugin (Example)
```lsl
registerChatCommands() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "chatcmd_register",
        "context", "core_owner",
        "commands", llList2Json(JSON_ARRAY, [
            "owner",
            "trustee"
        ])
    ]), NULL_KEY);
}
```

## Message Protocol

### Plugin → Module (Registration)
```json
{
  "type": "chatcmd_register",
  "context": "core_leash",
  "commands": ["grab", "release", "yank", "length"]
}
```

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

### Plugin → Module (Unregister)
```json
{
  "type": "chatcmd_unregister",
  "context": "core_leash"
}
```

## ACL Enforcement

**IMPORTANT:** The module verifies ACL before routing, but **your plugin must still check ACL** for each command since different commands may require different ACL levels.

Example:
- `!grab` might allow ACL 1+ (public)
- `!release` might require ACL 2+ (owned wearer)
- `!length` might require ACL 3+ (trustee/owner)

## Configuration

Users configure the chat command system via the "Chat Cmds" menu:
- Enable/Disable: Turns on/off chat command processing
- Prefix: Set command prefix (default: `!`)
- Private Channel: Set private chat channel (default: 1)

Commands are always active on both:
- Channel 0 (public chat) when enabled
- Configured private channel

## Best Practices

1. **Register on startup**: Call `registerChatCommands()` in `state_entry()`
2. **Check context**: Verify `context` field matches your plugin
3. **Validate ACL**: Each command should check `acl_level` appropriately
4. **Parse args carefully**: Handle missing/invalid arguments gracefully
5. **Provide feedback**: Always respond to user via `llRegionSayTo`
6. **Log for debug**: Use `logd()` to trace command handling

## Testing

1. Enable chat commands: Touch collar → Chat Cmds → Enable
2. Test command: Type in chat: `!grab`
3. Check response: Should execute or deny based on ACL
4. Test args: `!length 5` should parse argument correctly
5. Test unknown: `!invalid` should report unknown command

## Security

- ACL verified by module before routing
- Rate limiting (5s cooldown per user per command)
- Owner always has access regardless of enabled state
- Plugins responsible for command-specific ACL checks
