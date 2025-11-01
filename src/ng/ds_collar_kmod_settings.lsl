/* =============================================================================
   MODULE: ds_collar_kmod_settings.lsl (v3.0 - Kanban Messaging Migration)
   SECURITY AUDIT: CRITICAL ISSUES FIXED
   MESSAGING: Kanban universal helper (v1.0)

   ROLE: Persistent key-value store with notecard loading and delta updates

   CHANNELS:
   - 800 (SETTINGS_BUS): All settings operations

   NOTECARD FORMAT:
   - File: "settings" in inventory
   - Lines: key=value
   - Lists: key=[uuid1,uuid2,uuid3]
   - Comments: # comment

   SECURITY FIXES APPLIED:
   - [CRITICAL] Wearer-owner separation enforcement
   - [CRITICAL] TPE-external-owner requirement validation (runtime API)
   - [CRITICAL] TPE-external-owner requirement validation (notecard parsing) v2.2
   - [CRITICAL] Badge broadcast guard-side removals (v2.3) - Fixes ACL sync issue
   - [MEDIUM] Blacklist guards in notecard parsing
   - [MEDIUM] Multi-owner support in trustee guards
   - [MEDIUM] Multi-owner support in blacklist guards
   - [LOW] Production mode guard for debug
   - [LOW] MaxListLen enforcement in notecard parsing

   v2.3 BROADCAST FIX:
   Guard functions (apply_owner_set_guard, apply_trustee_add_guard,
   apply_blacklist_add_guard) now broadcast delta updates for ALL role
   mutations they perform. This ensures downstream modules (auth, etc.)
   receive removal deltas when users are promoted/demoted between roles,
   preventing stale ACL entries that could deny access to promoted users.

   KANBAN MIGRATION (v3.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "settings";

/* ═══════════════════════════════════════════════════════════
   KANBAN UNIVERSAL HELPER (~500-800 bytes)
   ═══════════════════════════════════════════════════════════ */

string kFrom = "";  // Sender context (populated by kRecv)
string kTo = "";    // Recipient context (populated by kRecv)

kSend(string from, string to, integer channel, string payload, key k) {
    llMessageLinked(LINK_SET, channel,
        llList2Json(JSON_OBJECT, [
            "from", from,
            "payload", payload,
            "to", to
        ]),
        k
    );
}

string kRecv(string msg, string my_context) {
    // Quick validation: must be JSON object
    if (llGetSubString(msg, 0, 0) != "{") return "";

    // Extract from
    string from = llJsonGetValue(msg, ["from"]);
    if (from == JSON_INVALID) return "";

    // Extract to
    string to = llJsonGetValue(msg, ["to"]);
    if (to == JSON_INVALID) return "";

    // Check if for me (broadcast "" or direct to my_context)
    if (to != "" && to != my_context) return "";

    // Extract payload
    string payload = llJsonGetValue(msg, ["payload"]);
    if (payload == JSON_INVALID) return "";

    // Set globals for routing
    kFrom = from;
    kTo = to;

    return payload;
}

string kPayload(list kvp) {
    return llList2Json(JSON_OBJECT, kvp);
}

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer SETTINGS_BUS = 800;

/* ═══════════════════════════════════════════════════════════
   SETTINGS KEYS
   ═══════════════════════════════════════════════════════════ */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER_KEY        = "owner_key";
string KEY_OWNER_KEYS       = "owner_keys";
string KEY_OWNER_HON        = "owner_hon";
string KEY_OWNER_HONS       = "owner_honorifics";
string KEY_TRUSTEES         = "trustees";
string KEY_TRUSTEE_HONS     = "trustee_honorifics";
string KEY_BLACKLIST        = "blacklist";
string KEY_PUBLIC_ACCESS    = "public_mode";
string KEY_TPE_MODE         = "tpe_mode";
string KEY_LOCKED           = "locked";

// Bell plugin keys
string KEY_BELL_VISIBLE = "bell_visible";
string KEY_BELL_SOUND_ENABLED = "bell_sound_enabled";
string KEY_BELL_VOLUME = "bell_volume";
string KEY_BELL_SOUND = "bell_sound";

/* ═══════════════════════════════════════════════════════════
   NOTECARD CONFIG
   ═══════════════════════════════════════════════════════════ */
string NOTECARD_NAME = "settings";
string COMMENT_PREFIX = "#";
string SEPARATOR = "=";

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
key LastOwner = NULL_KEY;
string KvJson = "{}";

key NotecardQuery = NULL_KEY;
integer NotecardLine = 0;
integer IsLoadingNotecard = FALSE;
key NotecardKey = NULL_KEY;  // Track settings notecard changes

integer MaxListLen = 64;

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    // SECURITY FIX: Production mode guard
    if (DEBUG && !PRODUCTION) llOwnerSay("[SETTINGS] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer is_json_obj(string s) {
    return (llGetSubString(s, 0, 0) == "{");
}

integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

string normalize_bool(string s) {
    integer v = (integer)s;
    if (v != 0) v = 1;
    return (string)v;
}

integer list_contains(list search_list, string s) {
    return (llListFindList(search_list, [s]) != -1);
}

list list_remove_all(list source_list, string s) {
    integer idx = llListFindList(source_list, [s]);
    while (idx != -1) {
        source_list = llDeleteSubList(source_list, idx, idx);
        idx = llListFindList(source_list, [s]);
    }
    return source_list;
}

list list_unique(list source_list) {
    list unique_list = [];
    integer i = 0;
    integer len = llGetListLength(source_list);
    while (i < len) {
        string s = llList2String(source_list, i);
        if (!list_contains(unique_list, s)) {
            unique_list += [s];
        }
        i += 1;
    }
    return unique_list;
}

/* ═══════════════════════════════════════════════════════════
   KV OPERATIONS
   ═══════════════════════════════════════════════════════════ */

string kv_get(string key_name) {
    string val = llJsonGetValue(KvJson, [key_name]);
    if (val == JSON_INVALID) return "";
    return val;
}

integer kv_set_scalar(string key_name, string value) {
    string old_val = kv_get(key_name);
    if (old_val == value) return FALSE;
    
    KvJson = llJsonSetValue(KvJson, [key_name], value);
    logd("SET " + key_name + " = " + value);
    return TRUE;
}

integer kv_set_list(string key_name, list values) {
    string new_arr = llList2Json(JSON_ARRAY, values);
    string old_arr = kv_get(key_name);
    if (old_arr == new_arr) return FALSE;
    
    KvJson = llJsonSetValue(KvJson, [key_name], new_arr);
    logd("SET " + key_name + " count=" + (string)llGetListLength(values));
    return TRUE;
}

integer kv_list_add_unique(string key_name, string elem) {
    string arr = kv_get(key_name);
    list current_list = [];
    if (is_json_arr(arr)) {
        current_list = llJson2List(arr);
    }
    
    if (llListFindList(current_list, [elem]) != -1) return FALSE;
    if (llGetListLength(current_list) >= MaxListLen) return FALSE;
    
    current_list += [elem];
    return kv_set_list(key_name, current_list);
}

integer kv_list_remove_all(string key_name, string elem) {
    string arr = kv_get(key_name);
    if (!is_json_arr(arr)) return FALSE;
    
    list current_list = llJson2List(arr);
    list new_list = list_remove_all(current_list, elem);
    
    if (llGetListLength(new_list) == llGetListLength(current_list)) return FALSE;
    
    return kv_set_list(key_name, new_list);
}

/* ═══════════════════════════════════════════════════════════
   VALIDATION HELPERS
   ═══════════════════════════════════════════════════════════ */

// SECURITY FIX: Check if external owner exists
integer has_external_owner() {
    key wearer = llGetOwner();
    
    if (kv_get(KEY_MULTI_OWNER_MODE) == "1") {
        string owner_keys = kv_get(KEY_OWNER_KEYS);
        if (is_json_arr(owner_keys)) {
            list owners = llJson2List(owner_keys);
            integer i = 0;
            while (i < llGetListLength(owners)) {
                key owner = llList2Key(owners, i);
                if (owner != wearer && owner != NULL_KEY) {
                    return TRUE;
                }
                i += 1;
            }
        }
    }
    else {
        key owner = (key)kv_get(KEY_OWNER_KEY);
        if (owner != NULL_KEY && owner != wearer) {
            return TRUE;
        }
    }
    
    return FALSE;
}

// SECURITY FIX: Check if someone is an owner (any mode)
integer is_owner(string who) {
    // Check single owner
    if (kv_get(KEY_OWNER_KEY) == who) return TRUE;
    
    // Check multi-owner list
    string owner_keys = kv_get(KEY_OWNER_KEYS);
    if (is_json_arr(owner_keys)) {
        list owners = llJson2List(owner_keys);
        if (llListFindList(owners, [who]) != -1) return TRUE;
    }
    
    return FALSE;
}

/* ═══════════════════════════════════════════════════════════
   ROLE EXCLUSIVITY GUARDS
   ═══════════════════════════════════════════════════════════ */

// SECURITY FIX: Returns FALSE if owner add should be rejected
// BROADCAST FIX: Emits deltas for all guard-side mutations to keep ACL consumers in sync
integer apply_owner_set_guard(string who) {
    key wearer = llGetOwner();

    // CRITICAL: Prevent self-ownership
    if ((key)who == wearer) {
        llOwnerSay("ERROR: Cannot add wearer as owner (role separation required)");
        logd("CRITICAL: Blocked attempt to add wearer as owner");
        return FALSE;
    }

    // Remove owner from trustees and broadcast the change
    string trustees_arr = kv_get(KEY_TRUSTEES);
    if (is_json_arr(trustees_arr)) {
        list trustees = llJson2List(trustees_arr);
        if (llListFindList(trustees, [who]) != -1) {
            // Only process if actually present
            trustees = list_remove_all(trustees, who);
            if (kv_set_list(KEY_TRUSTEES, trustees)) {
                broadcast_delta_list_remove(KEY_TRUSTEES, who);
                logd("BROADCAST: Removed " + who + " from trustees (owner promotion)");
            }
        }
    }

    // Remove owner from blacklist and broadcast the change
    string blacklist_arr = kv_get(KEY_BLACKLIST);
    if (is_json_arr(blacklist_arr)) {
        list blacklist = llJson2List(blacklist_arr);
        if (llListFindList(blacklist, [who]) != -1) {
            // Only process if actually present
            blacklist = list_remove_all(blacklist, who);
            if (kv_set_list(KEY_BLACKLIST, blacklist)) {
                broadcast_delta_list_remove(KEY_BLACKLIST, who);
                logd("BROADCAST: Removed " + who + " from blacklist (owner promotion)");
            }
        }
    }

    return TRUE;
}

// BROADCAST FIX: Emits deltas for blacklist removals to keep ACL consumers in sync
integer apply_trustee_add_guard(string who) {
    // SECURITY FIX: Can't add owner as trustee (check both modes)
    if (is_owner(who)) {
        logd("WARNING: Cannot add owner as trustee");
        return FALSE;
    }

    // Remove from blacklist and broadcast the change
    string blacklist_arr = kv_get(KEY_BLACKLIST);
    if (is_json_arr(blacklist_arr)) {
        list blacklist = llJson2List(blacklist_arr);
        if (llListFindList(blacklist, [who]) != -1) {
            // Only process if actually present
            blacklist = list_remove_all(blacklist, who);
            if (kv_set_list(KEY_BLACKLIST, blacklist)) {
                broadcast_delta_list_remove(KEY_BLACKLIST, who);
                logd("BROADCAST: Removed " + who + " from blacklist (trustee promotion)");
            }
        }
    }

    return TRUE;
}

// BROADCAST FIX: Emits deltas for all guard-side mutations to keep ACL consumers in sync
integer apply_blacklist_add_guard(string who) {
    // Remove from trustees and broadcast the change
    string trustees_arr = kv_get(KEY_TRUSTEES);
    if (is_json_arr(trustees_arr)) {
        list trustees = llJson2List(trustees_arr);
        if (llListFindList(trustees, [who]) != -1) {
            // Only process if actually present
            trustees = list_remove_all(trustees, who);
            if (kv_set_list(KEY_TRUSTEES, trustees)) {
                broadcast_delta_list_remove(KEY_TRUSTEES, who);
                logd("BROADCAST: Removed " + who + " from trustees (blacklisted)");
            }
        }
    }

    // SECURITY FIX: Clear single owner if blacklisted and broadcast the change
    string cur_owner = kv_get(KEY_OWNER_KEY);
    if (cur_owner != "" && cur_owner == who) {
        if (kv_set_scalar(KEY_OWNER_KEY, (string)NULL_KEY)) {
            broadcast_delta_scalar(KEY_OWNER_KEY, (string)NULL_KEY);
            logd("BROADCAST: Cleared single owner (was blacklisted)");
        }
    }

    // Remove from multi-owner list and broadcast the change
    string owner_keys_arr = kv_get(KEY_OWNER_KEYS);
    if (is_json_arr(owner_keys_arr)) {
        list owner_keys = llJson2List(owner_keys_arr);
        if (llListFindList(owner_keys, [who]) != -1) {
            // Only process if actually present
            if (kv_list_remove_all(KEY_OWNER_KEYS, who)) {
                broadcast_delta_list_remove(KEY_OWNER_KEYS, who);
                logd("BROADCAST: Removed " + who + " from multi-owner list (blacklisted)");
            }
        }
    }

    return TRUE;
}

/* ═══════════════════════════════════════════════════════════
   BROADCASTING
   ═══════════════════════════════════════════════════════════ */

broadcast_full_sync() {
    string payload = kPayload(["kv", KvJson]);
    kSend(CONTEXT, "", SETTINGS_BUS, payload, NULL_KEY);
    logd("Broadcast: full sync");
}

broadcast_delta_scalar(string key_name, string new_value) {
    string changes = llList2Json(JSON_OBJECT, [
        key_name, new_value
    ]);

    string payload = kPayload([
        "op", "set",
        "changes", changes
    ]);

    kSend(CONTEXT, "", SETTINGS_BUS, payload, NULL_KEY);
    logd("Broadcast: delta set " + key_name);
}

broadcast_delta_list_add(string key_name, string elem) {
    string payload = kPayload([
        "op", "list_add",
        "key", key_name,
        "elem", elem
    ]);

    kSend(CONTEXT, "", SETTINGS_BUS, payload, NULL_KEY);
    logd("Broadcast: delta list_add " + key_name);
}

broadcast_delta_list_remove(string key_name, string elem) {
    string payload = kPayload([
        "op", "list_remove",
        "key", key_name,
        "elem", elem
    ]);

    kSend(CONTEXT, "", SETTINGS_BUS, payload, NULL_KEY);
    logd("Broadcast: delta list_remove " + key_name);
}

/* ═══════════════════════════════════════════════════════════
   KEY VALIDATION
   ═══════════════════════════════════════════════════════════ */

integer is_allowed_key(string k) {
    if (k == KEY_MULTI_OWNER_MODE) return TRUE;
    if (k == KEY_OWNER_KEY) return TRUE;
    if (k == KEY_OWNER_KEYS) return TRUE;
    if (k == KEY_OWNER_HON) return TRUE;
    if (k == KEY_OWNER_HONS) return TRUE;
    if (k == KEY_TRUSTEES) return TRUE;
    if (k == KEY_TRUSTEE_HONS) return TRUE;
    if (k == KEY_BLACKLIST) return TRUE;
    if (k == KEY_PUBLIC_ACCESS) return TRUE;
    if (k == KEY_TPE_MODE) return TRUE;
    if (k == KEY_LOCKED) return TRUE;
    // Bell plugin keys
    if (k == KEY_BELL_VISIBLE) return TRUE;
    if (k == KEY_BELL_SOUND_ENABLED) return TRUE;
    if (k == KEY_BELL_VOLUME) return TRUE;
    if (k == KEY_BELL_SOUND) return TRUE;
    return FALSE;
}

integer is_notecard_only_key(string k) {
    if (k == KEY_MULTI_OWNER_MODE) return TRUE;
    if (k == KEY_OWNER_KEYS) return TRUE;
    return FALSE;
}

/* ═══════════════════════════════════════════════════════════
   NOTECARD PARSING
   ═══════════════════════════════════════════════════════════ */

parse_notecard_line(string line) {
    line = llStringTrim(line, STRING_TRIM);
    
    if (line == "") return;
    if (llGetSubString(line, 0, 0) == COMMENT_PREFIX) return;
    
    integer sep_pos = llSubStringIndex(line, SEPARATOR);
    if (sep_pos == -1) {
        logd("Invalid line (no separator): " + line);
        return;
    }
    
    string key_name = llStringTrim(llGetSubString(line, 0, sep_pos - 1), STRING_TRIM);
    string value = llStringTrim(llGetSubString(line, sep_pos + 1, -1), STRING_TRIM);
    
    if (!is_allowed_key(key_name)) {
        logd("Unknown key ignored: " + key_name);
        return;
    }
    
    // Check if it's a list (starts with [)
    if (llGetSubString(value, 0, 0) == "[") {
        // Parse as CSV list
        string list_contents = llGetSubString(value, 1, -2);  // Strip [ ]
        list parsed_list = llCSV2List(list_contents);
        parsed_list = list_unique(parsed_list);
        
        // SECURITY FIX: Enforce MaxListLen for notecard
        if (llGetListLength(parsed_list) > MaxListLen) {
            parsed_list = llList2List(parsed_list, 0, MaxListLen - 1);
            llOwnerSay("WARNING: " + key_name + " list truncated to " + (string)MaxListLen + " entries");
            logd("WARNING: Truncated " + key_name + " to MaxListLen");
        }
        
        // Apply guards for special lists
        if (key_name == KEY_OWNER_KEYS) {
            integer i = 0;
            integer len = llGetListLength(parsed_list);
            list validated_list = [];
            while (i < len) {
                string owner = llList2String(parsed_list, i);
                if (apply_owner_set_guard(owner)) {
                    validated_list += [owner];
                }
                i += 1;
            }
            parsed_list = validated_list;
        }
        else if (key_name == KEY_TRUSTEES) {
            string cur_owner = kv_get(KEY_OWNER_KEY);
            if (cur_owner != "") {
                parsed_list = list_remove_all(parsed_list, cur_owner);
            }
        }
        // SECURITY FIX: Add blacklist guards for notecard
        else if (key_name == KEY_BLACKLIST) {
            integer i = 0;
            integer len = llGetListLength(parsed_list);
            while (i < len) {
                apply_blacklist_add_guard(llList2String(parsed_list, i));
                i += 1;
            }
        }
        
        kv_set_list(key_name, parsed_list);
    }
    else {
        // Scalar value
        if (key_name == KEY_MULTI_OWNER_MODE) value = normalize_bool(value);
        if (key_name == KEY_PUBLIC_ACCESS) value = normalize_bool(value);
        if (key_name == KEY_LOCKED) value = normalize_bool(value);

        // SECURITY FIX: Validate TPE mode in notecard (same as runtime API)
        if (key_name == KEY_TPE_MODE) {
            value = normalize_bool(value);

            if ((integer)value == 1) {
                if (!has_external_owner()) {
                    llOwnerSay("ERROR: Cannot enable TPE via notecard - requires external owner");
                    llOwnerSay("HINT: Set owner_key or owner_keys BEFORE tpe_mode in notecard");
                    logd("CRITICAL: Blocked TPE enable from notecard (no external owner)");
                    return;  // Don't set TPE
                }
            }
        }

        if (key_name == KEY_OWNER_KEY) {
            if (!apply_owner_set_guard(value)) {
                return;  // Rejected (self-ownership)
            }
        }

        kv_set_scalar(key_name, value);
    }
}

integer start_notecard_reading() {
    if (llGetInventoryType(NOTECARD_NAME) != INVENTORY_NOTECARD) {
        logd("Notecard '" + NOTECARD_NAME + "' not found");
        return FALSE;
    }
    
    logd("Loading notecard: " + NOTECARD_NAME);
    IsLoadingNotecard = TRUE;
    NotecardLine = 0;
    NotecardQuery = llGetNotecardLine(NOTECARD_NAME, NotecardLine);
    return TRUE;
}

/* ═══════════════════════════════════════════════════════════
   MESSAGE HANDLERS
   ═══════════════════════════════════════════════════════════ */

handle_settings_get() {
    broadcast_full_sync();
}

handle_set(string payload) {
    if (!json_has(payload, ["key"])) return;

    string key_name = llJsonGetValue(payload, ["key"]);
    if (!is_allowed_key(key_name)) return;
    if (is_notecard_only_key(key_name)) {
        logd("Blocked: " + key_name + " is notecard-only");
        return;
    }

    integer did_change = FALSE;

    // Bulk list set
    if (json_has(payload, ["values"])) {
        string values_arr = llJsonGetValue(payload, ["values"]);
        if (is_json_arr(values_arr)) {
            list new_list = llJson2List(values_arr);
            new_list = list_unique(new_list);
            
            if (key_name == KEY_OWNER_KEYS) {
                integer i = 0;
                integer len = llGetListLength(new_list);
                list validated_list = [];
                while (i < len) {
                    string owner = llList2String(new_list, i);
                    if (apply_owner_set_guard(owner)) {
                        validated_list += [owner];
                    }
                    i += 1;
                }
                new_list = validated_list;
            }
            else if (key_name == KEY_TRUSTEES) {
                string cur_owner = kv_get(KEY_OWNER_KEY);
                if (cur_owner != "") {
                    new_list = list_remove_all(new_list, cur_owner);
                }
            }
            else if (key_name == KEY_BLACKLIST) {
                integer i = 0;
                integer len = llGetListLength(new_list);
                while (i < len) {
                    apply_blacklist_add_guard(llList2String(new_list, i));
                    i += 1;
                }
            }
            
            did_change = kv_set_list(key_name, new_list);
            
            if (did_change) {
                broadcast_full_sync();  // Bulk operations get full sync
            }
        }
        return;
    }
    
    // Scalar set
    if (json_has(payload, ["value"])) {
        string value = llJsonGetValue(payload, ["value"]);
        
        if (key_name == KEY_PUBLIC_ACCESS) value = normalize_bool(value);
        if (key_name == KEY_LOCKED) value = normalize_bool(value);
        
        // SECURITY FIX: Validate TPE mode
        if (key_name == KEY_TPE_MODE) {
            value = normalize_bool(value);
            
            if ((integer)value == 1) {
                if (!has_external_owner()) {
                    llOwnerSay("ERROR: Cannot enable TPE - requires external owner");
                    logd("CRITICAL: Blocked TPE enable (no external owner)");
                    return;  // Don't set TPE
                }
            }
        }
        
        if (key_name == KEY_OWNER_KEY) {
            if (!apply_owner_set_guard(value)) {
                return;  // Rejected (self-ownership)
            }
        }
        
        did_change = kv_set_scalar(key_name, value);
        
        if (did_change) {
            broadcast_delta_scalar(key_name, value);
        }
    }
}

handle_list_add(string payload) {
    if (!json_has(payload, ["key"])) return;
    if (!json_has(payload, ["elem"])) return;

    string key_name = llJsonGetValue(payload, ["key"]);
    string elem = llJsonGetValue(payload, ["elem"]);
    
    if (!is_allowed_key(key_name)) return;
    if (is_notecard_only_key(key_name)) {
        logd("Blocked: " + key_name + " is notecard-only");
        return;
    }
    
    integer did_change = FALSE;
    
    if (key_name == KEY_OWNER_KEYS) {
        if (apply_owner_set_guard(elem)) {
            did_change = kv_list_add_unique(key_name, elem);
        }
    }
    else if (key_name == KEY_TRUSTEES) {
        if (apply_trustee_add_guard(elem)) {
            did_change = kv_list_add_unique(key_name, elem);
        }
    }
    else if (key_name == KEY_BLACKLIST) {
        apply_blacklist_add_guard(elem);
        did_change = kv_list_add_unique(key_name, elem);
    }
    else {
        did_change = kv_list_add_unique(key_name, elem);
    }
    
    if (did_change) {
        broadcast_delta_list_add(key_name, elem);
    }
}

handle_list_remove(string payload) {
    if (!json_has(payload, ["key"])) return;
    if (!json_has(payload, ["elem"])) return;

    string key_name = llJsonGetValue(payload, ["key"]);
    string elem = llJsonGetValue(payload, ["elem"]);
    
    if (!is_allowed_key(key_name)) return;
    
    integer did_change = kv_list_remove_all(key_name, elem);
    
    if (did_change) {
        broadcast_delta_list_remove(key_name, elem);
    }
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default
{
    state_entry() {
        LastOwner = llGetOwner();
        NotecardKey = llGetInventoryKey(NOTECARD_NAME);
        
        integer notecard_found = start_notecard_reading();
        
        if (!notecard_found) {
            broadcast_full_sync();
        }
    }
    
    on_rez(integer start_param) {
        key current_owner = llGetOwner();
        if (current_owner != LastOwner) {
            LastOwner = current_owner;
            llResetScript();
        }
    }
    
    attach(key id) {
        if (id == NULL_KEY) return;
        
        key current_owner = llGetOwner();
        if (current_owner != LastOwner) {
            LastOwner = current_owner;
            llResetScript();
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            key current_owner = llGetOwner();
            if (current_owner != LastOwner) {
                LastOwner = current_owner;
                llResetScript();
            }
        }
        
        if (change & CHANGED_INVENTORY) {
            // Only act if the settings notecard specifically changed
            key current_notecard_key = llGetInventoryKey(NOTECARD_NAME);
            if (current_notecard_key != NotecardKey) {
                // Notecard was deleted → reset to defaults
                if (current_notecard_key == NULL_KEY) {
                    logd("Settings notecard deleted, resetting to defaults");
                    llResetScript();
                }
                else {
                    // Notecard edited or re-added → reload and overlay
                    logd("Settings notecard changed, reloading settings");
                    NotecardKey = current_notecard_key;
                    start_notecard_reading();
                }
            }
        }
    }
    
    dataserver(key query_id, string data) {
        if (query_id != NotecardQuery) return;
        
        if (data != EOF) {
            parse_notecard_line(data);
            
            NotecardLine += 1;
            NotecardQuery = llGetNotecardLine(NOTECARD_NAME, NotecardLine);
        }
        else {
            IsLoadingNotecard = FALSE;
            logd("Notecard loading complete");
            broadcast_full_sync();
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (num != SETTINGS_BUS) return;

        // Parse kanban message - kRecv validates and sets kFrom, kTo
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;  // Not for us or invalid

        // Settings get: has "get" marker
        if (json_has(payload, ["get"])) {
            handle_settings_get();
        }
        // Set: has "key" and ("value" or "values")
        else if (json_has(payload, ["key"]) &&
                 (json_has(payload, ["value"]) || json_has(payload, ["values"]))) {
            handle_set(payload);
        }
        // List operations: has "key" and "elem" (distinguish by "op" field)
        else if (json_has(payload, ["key"]) && json_has(payload, ["elem"])) {
            string op = llJsonGetValue(payload, ["op"]);
            if (op == "list_remove") {
                handle_list_remove(payload);
            } else {
                // Default to list_add for backwards compatibility
                handle_list_add(payload);
            }
        }
    }
}
