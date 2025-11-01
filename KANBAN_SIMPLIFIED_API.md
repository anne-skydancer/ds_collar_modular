# Kanban Messaging - Simplified API (v4.00)

## Key Insight: Auto-Detect "from" Field

Since LSL provides `llGetScriptName()`, we can automatically determine the sender instead of passing it as a parameter!

---

## Original API

```lsl
kSend(from, to, channel, payload, key)
```

**Usage:**
```lsl
kSend("bell", "kernel", 500, kPayload([...]), NULL_KEY);
```

**Problem:** Every call site must specify "bell" - repetitive and error-prone!

---

## Simplified API (v4.00)

```lsl
kSend(to, channel, payload, key)  // Auto-detects "from"!
```

**Usage:**
```lsl
kSend("kernel", 500, kPayload([...]), NULL_KEY);
```

**Benefit:** "from" is automatically derived from `llGetScriptName()`!

---

## Updated Helper Functions

### Core Functions (~400-600 bytes)

```lsl
/* ===== KANBAN MESSAGING HELPERS (v4.00) ===== */

string kFrom = "";  // Set by kRecv
string kTo = "";    // Set by kRecv

// Send Kanban message - "from" auto-detected from script name
kSend(string to, integer channel, string payload, key k) {
    llMessageLinked(LINK_SET, channel,
        llList2Json(JSON_OBJECT, [
            "from", llGetScriptName(),
            "payload", payload,
            "to", to
        ]),
        k
    );
}

// Receive Kanban message - sets kFrom and kTo globals
string kRecv(string msg) {
    if (llGetSubString(msg, 0, 0) != "{") return "";

    string from = llJsonGetValue(msg, ["from"]);
    if (from == JSON_INVALID) return "";

    string to = llJsonGetValue(msg, ["to"]);
    if (to == JSON_INVALID) return "";

    // Check if for me (broadcast or direct)
    string my_name = llGetScriptName();
    if (to != "" && to != my_name) return "";

    string payload = llJsonGetValue(msg, ["payload"]);
    if (payload == JSON_INVALID) return "";

    kFrom = from;
    kTo = to;

    return payload;
}

// Build simple key-value payload
string kPayload(list kvp) {
    return llList2Json(JSON_OBJECT, kvp);
}

// Build delta SET payload
string kDeltaSet(string key, string val) {
    return llList2Json(JSON_OBJECT, ["op", "set", "key", key, "value", val]);
}

// Build delta LIST_ADD payload
string kDeltaAdd(string key, string elem) {
    return llList2Json(JSON_OBJECT, ["op", "list_add", "key", key, "elem", elem]);
}

// Build delta LIST_REMOVE payload
string kDeltaDel(string key, string elem) {
    return llList2Json(JSON_OBJECT, ["op", "list_remove", "key", key, "elem", elem]);
}

/* ===== END KANBAN HELPERS ===== */
```

---

## API Comparison

### Registration

**Old (5 parameters):**
```lsl
kSend("bell", "kernel", 500,
    kPayload(["label", "Bell", "min_acl", 1]),
    NULL_KEY
);
```

**New (4 parameters):**
```lsl
kSend("kernel", 500,
    kPayload(["label", "Bell", "min_acl", 1]),
    NULL_KEY
);
```

### ACL Query

**Old:**
```lsl
kSend("bell", "auth", 700,
    kPayload(["avatar", (string)user]),
    user
);
```

**New:**
```lsl
kSend("auth", 700,
    kPayload(["avatar", (string)user]),
    user
);
```

### Settings Delta

**Old:**
```lsl
kSend("bell", "", 800,
    kDeltaSet("bell_visible", "1"),
    NULL_KEY
);
```

**New:**
```lsl
kSend("", 800,
    kDeltaSet("bell_visible", "1"),
    NULL_KEY
);
```

### Dialog

**Old:**
```lsl
kSend("bell", "dialogs", 950,
    kPayload([...]),
    NULL_KEY
);
```

**New:**
```lsl
kSend("dialogs", 950,
    kPayload([...]),
    NULL_KEY
);
```

---

## Receiving Simplified Too

**Old:**
```lsl
link_message(integer sender, integer num, string msg, key id) {
    string payload = kRecv(msg, "bell");  // Must specify context
    if (payload == "") return;

    // ...
}
```

**New:**
```lsl
link_message(integer sender, integer num, string msg, key id) {
    string payload = kRecv(msg);  // Auto-detects script name!
    if (payload == "") return;

    // ...
}
```

---

## No CONTEXT Constant Needed!

**Old approach:**
```lsl
string CONTEXT = "bell";  // Must define this

// Use everywhere
kSend(CONTEXT, "kernel", 500, ...);
kRecv(msg, CONTEXT);
```

**New approach:**
```lsl
// No CONTEXT needed - llGetScriptName() handles it!

kSend("kernel", 500, ...);  // Automatic
kRecv(msg);                 // Automatic
```

---

## Benefits

### 1. Fewer Parameters
- **Old:** `kSend(from, to, channel, payload, key)` - 5 params
- **New:** `kSend(to, channel, payload, key)` - 4 params
- **Saved:** 1 parameter per call

### 2. No CONTEXT Constant
- Old: Must define `string CONTEXT = "bell";`
- New: Automatic via `llGetScriptName()`
- **Saved:** 1 global string per script

### 3. Less Error-Prone
- Old: Could accidentally type wrong context name
- New: Always correct (comes from script name)

### 4. Less Code per Call
- Old: `kSend("bell", "kernel", 500, ...)`
- New: `kSend("kernel", 500, ...)`
- **Saved:** ~6 characters per call × many calls = significant!

### 5. Cleaner API
```lsl
// What you care about: WHERE am I sending?
kSend("kernel", 500, payload, key);

// Not: WHO am I? (script already knows!)
```

---

## Memory Savings

### Per Call Site
- Old: `kSend("bell", ...` = ~6 extra bytes
- New: `kSend(...` = cleaner
- With 20+ calls per script: ~120 bytes saved!

### Per Script
- Old: `string CONTEXT = "bell";` = ~20 bytes
- New: (not needed) = 0 bytes
- **Total per script: ~140 bytes saved**

### Code Size
- Helper block slightly larger (2 extra `llGetScriptName()` calls)
- But call sites much smaller
- **Net savings: ~50-100 bytes per script**

---

## Script Name → Message Name Mapping

Scripts automatically identify themselves:

| Script File | "from" in Messages |
|-------------|-------------------|
| ds_collar_kernel.lsl | "ds_collar_kernel" |
| ds_collar_kmod_auth.lsl | "ds_collar_kmod_auth" |
| ds_collar_plugin_bell.lsl | "ds_collar_plugin_bell" |

**Note:** This is actually BETTER for debugging - you see the full script name in messages!

### Alternative: Strip Prefix

If you want shorter names, add a helper:

```lsl
string kGetContext() {
    string name = llGetScriptName();
    // Strip "ds_collar_" prefix if present
    if (llSubStringIndex(name, "ds_collar_") == 0) {
        name = llGetSubString(name, 10, -1);  // Skip "ds_collar_"
    }
    // Strip ".lsl" suffix if present
    if (llSubStringIndex(name, ".lsl") > 0) {
        name = llGetSubString(name, 0, -5);  // Remove ".lsl"
    }
    return name;
}
```

Then use in `kSend()` and `kRecv()`:
```lsl
"from", kGetContext(),  // Returns "plugin_bell" instead of "ds_collar_plugin_bell.lsl"
```

But honestly, **full script names are fine** - clearer for debugging!

---

## Recommendation

**Use the simplified API:**
- ✅ 4 parameters instead of 5
- ✅ No CONTEXT constant needed
- ✅ Auto-detects from `llGetScriptName()`
- ✅ Less code per call site
- ✅ More accurate (can't typo the context)
- ✅ Better debugging (full script name visible)

**This is the TRUE simplified Kanban approach!**
