/*--------------------
MODULE: ds_collar_kmod_settings.lsl
VERSION: 1.00
REVISION: 32
PURPOSE: Persistent key-value store with notecard loading and delta updates
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- REVISION 32: Consolidated owner storage format — owner_key+owner_hon merged
  into "owner" JSON object {uuid:honorific}; owner_keys+owner_honorifics merged
  into "owners" JSON object {uuid:honorific}; single/multi-owner modes preserved
  as separate keys with separate runtime behavior
- REVISION 31: Added runaway_enabled to allowed keys (bug fix: access plugin
  writes were silently rejected); added boolean normalization for runaway_enabled
- REVISION 30: Trustees stored as JSON object {uuid:honorific} instead of
  parallel arrays; owner_honorifics stored as JSON object {uuid:honorific};
  removed trustee_honorifics key; atomic add/remove via obj_set/obj_remove
- REVISION 28: Added RLV exception keys (ex_owner_tp/im, ex_trustee_tp/im) to allowed list
- REVISION 27: Cache llGetListLength in loop conditions for performance
- Enforced wearer-owner separation and TPE external owner validation rules
- Added guard-side delta broadcasts to keep ACL modules synchronized
- Hardened blacklist and trustee parsing with max list length enforcement
- Guarded debug logging for production deployments
- Consolidated settings channel handling for consistent module access
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER            = "owner";
string KEY_OWNERS           = "owners";
string KEY_TRUSTEES         = "trustees";
string KEY_BLACKLIST        = "blacklist";
string KEY_PUBLIC_ACCESS    = "public_mode";
string KEY_TPE_MODE         = "tpe_mode";
string KEY_LOCKED           = "locked";

// RLV exception keys
string KEY_EX_OWNER_TP = "ex_owner_tp";
string KEY_EX_OWNER_IM = "ex_owner_im";
string KEY_EX_TRUSTEE_TP = "ex_trustee_tp";
string KEY_EX_TRUSTEE_IM = "ex_trustee_im";

// Access plugin keys
string KEY_RUNAWAY_ENABLED = "runaway_enabled";

// Bell plugin keys
string KEY_BELL_VISIBLE = "bell_visible";
string KEY_BELL_SOUND_ENABLED = "bell_sound_enabled";
string KEY_BELL_VOLUME = "bell_volume";
string KEY_BELL_SOUND = "bell_sound";

/* -------------------- NOTECARD CONFIG -------------------- */
string NOTECARD_NAME = "settings";
string COMMENT_PREFIX = "#";
string SEPARATOR = "=";

/* -------------------- STATE -------------------- */
key LastOwner = NULL_KEY;
string KvJson = "{}";

key NotecardQuery = NULL_KEY;
integer NotecardLine = 0;
integer IsLoadingNotecard = FALSE;
key NotecardKey = NULL_KEY;  // Track settings notecard changes

integer MaxListLen = 64;

/* -------------------- HELPERS -------------------- */


integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
string get_msg_type(string msg) {
    if (!json_has(msg, ["type"])) return "";
    return llJsonGetValue(msg, ["type"]);
}

string normalize_bool(string s) {
    integer v = (integer)s;
    if (v != 0) v = 1;
    return (string)v;
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
    if (llGetListLength(source_list) < 2) return source_list;
    source_list = llListSort(source_list, 1, TRUE);
    integer i = 0;
    while (i < llGetListLength(source_list) - 1) {
        if (llList2String(source_list, i) == llList2String(source_list, i + 1)) {
            source_list = llDeleteSubList(source_list, i, i);
        } else {
            i += 1;
        }
    }
    return source_list;
}

/* -------------------- KV OPERATIONS -------------------- */

string kv_get(string key_name) {
    string val = llJsonGetValue(KvJson, [key_name]);
    if (val == JSON_INVALID) return "";
    return val;
}

integer kv_set_scalar(string key_name, string value) {
    string old_val = kv_get(key_name);
    if (old_val == value) return FALSE;
    
    KvJson = llJsonSetValue(KvJson, [key_name], value);
    return TRUE;
}

integer kv_set_list(string key_name, list values) {
    string new_arr = llList2Json(JSON_ARRAY, values);
    string old_arr = kv_get(key_name);
    if (old_arr == new_arr) return FALSE;
    
    KvJson = llJsonSetValue(KvJson, [key_name], new_arr);
    return TRUE;
}

integer kv_list_add_unique(string key_name, string elem) {
    string arr = kv_get(key_name);
    list current_list = [];
    if (llJsonValueType(arr, []) == JSON_ARRAY) {
        current_list = llJson2List(arr);
    }

    if (llListFindList(current_list, [elem]) != -1) return FALSE;
    if (llGetListLength(current_list) >= MaxListLen) return FALSE;

    current_list += [elem];
    return kv_set_list(key_name, current_list);
}

/* ---- JSON OBJECT KV OPERATIONS ---- */

// Set a field in a JSON object stored at key_name
integer kv_obj_set_field(string key_name, string field, string value) {
    string obj = kv_get(key_name);
    if (obj == "" || llJsonValueType(obj, []) != JSON_OBJECT) {
        obj = "{}";
    }
    string new_obj = llJsonSetValue(obj, [field], value);
    return kv_set_scalar(key_name, new_obj);
}

// Remove a field from a JSON object stored at key_name
integer kv_obj_remove_field(string key_name, string field) {
    string obj = kv_get(key_name);
    if (obj == "" || llJsonValueType(obj, []) != JSON_OBJECT) return FALSE;
    if (llJsonGetValue(obj, [field]) == JSON_INVALID) return FALSE;
    string new_obj = llJsonSetValue(obj, [field], JSON_DELETE);
    return kv_set_scalar(key_name, new_obj);
}

integer kv_list_remove_all(string key_name, string elem) {
    string arr = kv_get(key_name);
    if (llJsonValueType(arr, []) != JSON_ARRAY) return FALSE;
    
    list current_list = llJson2List(arr);
    list new_list = list_remove_all(current_list, elem);
    
    if (llGetListLength(new_list) == llGetListLength(current_list)) return FALSE;
    
    return kv_set_list(key_name, new_list);
}

/* -------------------- VALIDATION HELPERS -------------------- */

// Check if external owner exists
integer has_external_owner() {
    key wearer = llGetOwner();

    string obj_key = KEY_OWNER;
    if (kv_get(KEY_MULTI_OWNER_MODE) == "1") {
        obj_key = KEY_OWNERS;
    }

    string obj = kv_get(obj_key);
    if (llJsonValueType(obj, []) == JSON_OBJECT) {
        list pairs = llJson2List(obj);
        integer i = 0;
        integer pairs_len = llGetListLength(pairs);
        while (i < pairs_len) {
            key owner = (key)llList2String(pairs, i);
            if (owner != wearer && owner != NULL_KEY) {
                return TRUE;
            }
            i += 2;
        }
    }

    return FALSE;
}

// Check if someone is an owner (any mode)
integer is_owner(string who) {
    // Check single owner object
    string owner_obj = kv_get(KEY_OWNER);
    if (llJsonValueType(owner_obj, []) == JSON_OBJECT) {
        if (llJsonGetValue(owner_obj, [who]) != JSON_INVALID) return TRUE;
    }

    // Check multi-owner object
    string owners_obj = kv_get(KEY_OWNERS);
    if (llJsonValueType(owners_obj, []) == JSON_OBJECT) {
        if (llJsonGetValue(owners_obj, [who]) != JSON_INVALID) return TRUE;
    }

    return FALSE;
}

/* -------------------- ROLE EXCLUSIVITY GUARDS -------------------- */

// Returns FALSE if owner add should be rejected
// BROADCAST FIX: Emits deltas for all guard-side mutations to keep ACL consumers in sync
integer apply_owner_set_guard(string who) {
    key wearer = llGetOwner();

    // CRITICAL: Prevent self-ownership
    if ((key)who == wearer) {
        llOwnerSay("ERROR: Cannot add wearer as owner (role separation required)");
        return FALSE;
    }

    // Remove owner from trustees object and broadcast the change
    if (kv_obj_remove_field(KEY_TRUSTEES, who)) {
        broadcast_delta_scalar(KEY_TRUSTEES, kv_get(KEY_TRUSTEES));
    }

    // Remove owner from blacklist and broadcast the change
    string blacklist_arr = kv_get(KEY_BLACKLIST);
    if (llJsonValueType(blacklist_arr, []) == JSON_ARRAY) {
        list blacklist = llJson2List(blacklist_arr);
        if (llListFindList(blacklist, [who]) != -1) {
            // Only process if actually present
            blacklist = list_remove_all(blacklist, who);
            if (kv_set_list(KEY_BLACKLIST, blacklist)) {
                broadcast_delta_list_remove(KEY_BLACKLIST, who);
            }
        }
    }

    return TRUE;
}

// BROADCAST FIX: Emits deltas for blacklist removals to keep ACL consumers in sync
integer apply_trustee_add_guard(string who) {
    // Can't add owner as trustee (check both modes)
    if (is_owner(who)) {
        return FALSE;
    }

    // Remove from blacklist and broadcast the change
    string blacklist_arr = kv_get(KEY_BLACKLIST);
    if (llJsonValueType(blacklist_arr, []) == JSON_ARRAY) {
        list blacklist = llJson2List(blacklist_arr);
        if (llListFindList(blacklist, [who]) != -1) {
            // Only process if actually present
            blacklist = list_remove_all(blacklist, who);
            if (kv_set_list(KEY_BLACKLIST, blacklist)) {
                broadcast_delta_list_remove(KEY_BLACKLIST, who);
            }
        }
    }

    return TRUE;
}

// BROADCAST FIX: Emits deltas for all guard-side mutations to keep ACL consumers in sync
integer apply_blacklist_add_guard(string who) {
    // Remove from trustees object and broadcast the change
    if (kv_obj_remove_field(KEY_TRUSTEES, who)) {
        broadcast_delta_scalar(KEY_TRUSTEES, kv_get(KEY_TRUSTEES));
    }

    // Remove from single owner object and broadcast
    if (kv_obj_remove_field(KEY_OWNER, who)) {
        broadcast_delta_scalar(KEY_OWNER, kv_get(KEY_OWNER));
    }

    // Remove from multi-owner object and broadcast
    if (kv_obj_remove_field(KEY_OWNERS, who)) {
        broadcast_delta_scalar(KEY_OWNERS, kv_get(KEY_OWNERS));
    }

    return TRUE;
}

// Guard a trustees JSON object: remove any owner or wearer UUIDs
string guard_trustees_object(string obj) {
    key wearer = llGetOwner();
    // Remove wearer
    if (llJsonGetValue(obj, [(string)wearer]) != JSON_INVALID) {
        obj = llJsonSetValue(obj, [(string)wearer], JSON_DELETE);
    }
    // Remove owners from single-owner and multi-owner objects
    list owner_sources = [kv_get(KEY_OWNER), kv_get(KEY_OWNERS)];
    integer si = 0;
    while (si < 2) {
        string src = llList2String(owner_sources, si);
        if (llJsonValueType(src, []) == JSON_OBJECT) {
            list pairs = llJson2List(src);
            integer i = 0;
            integer pairs_len = llGetListLength(pairs);
            while (i < pairs_len) {
                string ok = llList2String(pairs, i);
                if (llJsonGetValue(obj, [ok]) != JSON_INVALID) {
                    obj = llJsonSetValue(obj, [ok], JSON_DELETE);
                }
                i += 2;
            }
        }
        si += 1;
    }
    return obj;
}

// Guard an owner JSON object: validate each UUID (no self-ownership)
string guard_owner_object(string obj) {
    list pairs = llJson2List(obj);
    string result = "{}";
    integer i = 0;
    integer pairs_len = llGetListLength(pairs);
    while (i < pairs_len) {
        string uuid = llList2String(pairs, i);
        string hon = llList2String(pairs, i + 1);
        if (apply_owner_set_guard(uuid)) {
            result = llJsonSetValue(result, [uuid], hon);
        }
        i += 2;
    }
    return result;
}

/* -------------------- BROADCASTING -------------------- */

broadcast_full_sync() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_sync",
        "kv", KvJson
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

broadcast_delta_scalar(string key_name, string new_value) {
    string changes = llList2Json(JSON_OBJECT, [
        key_name, new_value
    ]);
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_delta",
        "op", "set",
        "changes", changes
    ]);
    
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

broadcast_delta_list_add(string key_name, string elem) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_delta",
        "op", "list_add",
        "key", key_name,
        "elem", elem
    ]);
    
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

broadcast_delta_list_remove(string key_name, string elem) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_delta",
        "op", "list_remove",
        "key", key_name,
        "elem", elem
    ]);
    
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

/* -------------------- KEY VALIDATION -------------------- */

integer is_allowed_key(string k) {
    list allowed = [
        KEY_MULTI_OWNER_MODE, KEY_OWNER, KEY_OWNERS,
        KEY_TRUSTEES, KEY_BLACKLIST, KEY_PUBLIC_ACCESS,
        KEY_TPE_MODE, KEY_LOCKED, KEY_RUNAWAY_ENABLED,
        KEY_EX_OWNER_TP, KEY_EX_OWNER_IM,
        KEY_EX_TRUSTEE_TP, KEY_EX_TRUSTEE_IM,
        KEY_BELL_VISIBLE, KEY_BELL_SOUND_ENABLED,
        KEY_BELL_VOLUME, KEY_BELL_SOUND
    ];
    return (llListFindList(allowed, [k]) != -1);
}

// Keys stored as JSON objects (not arrays or scalars)
integer is_json_object_key(string k) {
    if (k == KEY_OWNER) return TRUE;
    if (k == KEY_OWNERS) return TRUE;
    if (k == KEY_TRUSTEES) return TRUE;
    return FALSE;
}

integer is_notecard_only_key(string k) {
    if (k == KEY_MULTI_OWNER_MODE) return TRUE;
    if (k == KEY_OWNERS) return TRUE;
    return FALSE;
}

/* -------------------- NOTECARD PARSING -------------------- */

parse_notecard_line(string line) {
    line = llStringTrim(line, STRING_TRIM);
    
    if (line == "") return;
    if (llGetSubString(line, 0, 0) == COMMENT_PREFIX) return;
    
    integer sep_pos = llSubStringIndex(line, SEPARATOR);
    if (sep_pos == -1) {
        return;
    }
    
    string key_name = llStringTrim(llGetSubString(line, 0, sep_pos - 1), STRING_TRIM);
    string value = llStringTrim(llGetSubString(line, sep_pos + 1, -1), STRING_TRIM);
    
    if (!is_allowed_key(key_name)) {
        return;
    }
    
    // Check for JSON object (owner, owners, trustees)
    if (is_json_object_key(key_name) && llGetSubString(value, 0, 0) == "{") {
        if (llJsonValueType(value, []) == JSON_OBJECT) {
            // Guard trustees: remove owners from trustee object
            if (key_name == KEY_TRUSTEES) {
                value = guard_trustees_object(value);
            }
            // Guard owner objects: validate UUIDs (no self-ownership)
            if (key_name == KEY_OWNER || key_name == KEY_OWNERS) {
                value = guard_owner_object(value);
            }
            kv_set_scalar(key_name, value);
        }
    }
    // Check if it's a list (starts with [)
    else if (llGetSubString(value, 0, 0) == "[") {
        // Reject array syntax for keys that must be JSON objects
        if (is_json_object_key(key_name)) {
            llOwnerSay("WARNING: " + key_name + " requires JSON object format, not array");
            return;
        }
        // Parse as CSV list
        string list_contents = llGetSubString(value, 1, -2);  // Strip [ ]
        list parsed_list = llCSV2List(list_contents);
        parsed_list = list_unique(parsed_list);

        // Enforce MaxListLen for notecard
        if (llGetListLength(parsed_list) > MaxListLen) {
            parsed_list = llList2List(parsed_list, 0, MaxListLen - 1);
            llOwnerSay("WARNING: " + key_name + " list truncated to " + (string)MaxListLen + " entries");
        }

        // Apply blacklist guards for notecard
        if (key_name == KEY_BLACKLIST) {
            integer i = 0;
            integer bl_len = llGetListLength(parsed_list);
            while (i < bl_len) {
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
        if (key_name == KEY_RUNAWAY_ENABLED) value = normalize_bool(value);

        // Validate TPE mode in notecard (same as runtime API)
        if (key_name == KEY_TPE_MODE) {
            value = normalize_bool(value);

            if ((integer)value == 1) {
                if (!has_external_owner()) {
                    llOwnerSay("ERROR: Cannot enable TPE via notecard - requires external owner");
                    llOwnerSay("HINT: Set owner or owners BEFORE tpe_mode in notecard");
                    return;  // Don't set TPE
                }
            }
        }

        kv_set_scalar(key_name, value);
    }
}

integer start_notecard_reading() {
    if (llGetInventoryType(NOTECARD_NAME) != INVENTORY_NOTECARD) {
        return FALSE;
    }
    IsLoadingNotecard = TRUE;
    NotecardLine = 0;
    NotecardQuery = llGetNotecardLine(NOTECARD_NAME, NotecardLine);
    return TRUE;
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_settings_get() {
    broadcast_full_sync();
}

handle_set(string msg) {
    if (!json_has(msg, ["key"])) return;
    
    string key_name = llJsonGetValue(msg, ["key"]);
    if (!is_allowed_key(key_name)) return;
    if (is_notecard_only_key(key_name)) {
        return;
    }
    
    integer did_change = FALSE;
    
    // Bulk list set
    if (json_has(msg, ["values"])) {
        string values_arr = llJsonGetValue(msg, ["values"]);
        if (llJsonValueType(values_arr, []) == JSON_ARRAY) {
            list new_list = llJson2List(values_arr);
            new_list = list_unique(new_list);

            if (key_name == KEY_BLACKLIST) {
                integer i = 0;
                integer nbl_len = llGetListLength(new_list);
                while (i < nbl_len) {
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
    if (json_has(msg, ["value"])) {
        string value = llJsonGetValue(msg, ["value"]);

        if (key_name == KEY_PUBLIC_ACCESS) value = normalize_bool(value);
        if (key_name == KEY_LOCKED) value = normalize_bool(value);
        if (key_name == KEY_RUNAWAY_ENABLED) value = normalize_bool(value);

        // Validate TPE mode
        if (key_name == KEY_TPE_MODE) {
            value = normalize_bool(value);

            if ((integer)value == 1) {
                if (!has_external_owner()) {
                    llOwnerSay("ERROR: Cannot enable TPE - requires external owner");
                    return;  // Don't set TPE
                }
            }
        }

        // Guard owner objects on scalar set
        if ((key_name == KEY_OWNER || key_name == KEY_OWNERS) && llJsonValueType(value, []) == JSON_OBJECT) {
            value = guard_owner_object(value);
        }

        // Guard trustees object on scalar set
        if (key_name == KEY_TRUSTEES && llJsonValueType(value, []) == JSON_OBJECT) {
            value = guard_trustees_object(value);
        }

        did_change = kv_set_scalar(key_name, value);

        if (did_change) {
            broadcast_delta_scalar(key_name, value);
        }
    }
}

handle_list_add(string msg) {
    if (!json_has(msg, ["key"])) return;
    if (!json_has(msg, ["elem"])) return;
    
    string key_name = llJsonGetValue(msg, ["key"]);
    string elem = llJsonGetValue(msg, ["elem"]);
    
    if (!is_allowed_key(key_name)) return;
    if (is_notecard_only_key(key_name)) {
        return;
    }
    
    integer did_change = FALSE;
    
    if (key_name == KEY_BLACKLIST) {
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

handle_obj_set(string msg) {
    if (!json_has(msg, ["key"])) return;
    if (!json_has(msg, ["field"])) return;
    if (!json_has(msg, ["value"])) return;

    string key_name = llJsonGetValue(msg, ["key"]);
    string field = llJsonGetValue(msg, ["field"]);
    string value = llJsonGetValue(msg, ["value"]);

    if (!is_allowed_key(key_name)) return;
    if (!is_json_object_key(key_name)) return;

    // Guard: trustee can't be an owner
    if (key_name == KEY_TRUSTEES) {
        if (!apply_trustee_add_guard(field)) return;
    }

    // Guard: owner can't be wearer, removes from trustees/blacklist
    if (key_name == KEY_OWNER || key_name == KEY_OWNERS) {
        if (!apply_owner_set_guard(field)) return;
    }

    // Enforce MaxListLen on JSON object fields
    string current_obj = kv_get(key_name);
    if (current_obj != "" && llJsonValueType(current_obj, []) == JSON_OBJECT) {
        // Only count if field is new (not updating existing)
        if (llJsonGetValue(current_obj, [field]) == JSON_INVALID) {
            integer field_count = llGetListLength(llJson2List(current_obj)) / 2;
            if (field_count >= MaxListLen) return;
        }
    }

    integer did_change = kv_obj_set_field(key_name, field, value);
    if (did_change) {
        broadcast_delta_scalar(key_name, kv_get(key_name));
    }
}

handle_obj_remove(string msg) {
    if (!json_has(msg, ["key"])) return;
    if (!json_has(msg, ["field"])) return;

    string key_name = llJsonGetValue(msg, ["key"]);
    string field = llJsonGetValue(msg, ["field"]);

    if (!is_allowed_key(key_name)) return;
    if (!is_json_object_key(key_name)) return;

    integer did_change = kv_obj_remove_field(key_name, field);
    if (did_change) {
        broadcast_delta_scalar(key_name, kv_get(key_name));
    }
}

handle_list_remove(string msg) {
    if (!json_has(msg, ["key"])) return;
    if (!json_has(msg, ["elem"])) return;
    
    string key_name = llJsonGetValue(msg, ["key"]);
    string elem = llJsonGetValue(msg, ["elem"]);
    
    if (!is_allowed_key(key_name)) return;
    
    integer did_change = kv_list_remove_all(key_name, elem);
    
    if (did_change) {
        broadcast_delta_list_remove(key_name, elem);
    }
}

handle_settings_restore(string msg) {
    if (!json_has(msg, ["kv"])) return;
    
    KvJson = llJsonGetValue(msg, ["kv"]);
    
    // After restoring state, broadcast full sync to all other modules
    broadcast_full_sync();
}

/* -------------------- EVENTS -------------------- */

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
                // Notecard was deleted -> reset to defaults
                if (current_notecard_key == NULL_KEY) {
                    llResetScript();
                }
                else {
                    // Notecard edited or re-added -> reload and overlay
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
            broadcast_full_sync();
            
            // Trigger bootstrap after notecard load completes
            string bootstrap_msg = llList2Json(JSON_OBJECT, [
                "type", "notecard_loaded"
            ]);
            llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, bootstrap_msg, NULL_KEY);
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (num != SETTINGS_BUS) return;
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;
        
        if (msg_type == "settings_get") {
            handle_settings_get();
        }
        else if (msg_type == "set") {
            handle_set(msg);
        }
        else if (msg_type == "list_add") {
            handle_list_add(msg);
        }
        else if (msg_type == "list_remove") {
            handle_list_remove(msg);
        }
        else if (msg_type == "obj_set") {
            handle_obj_set(msg);
        }
        else if (msg_type == "obj_remove") {
            handle_obj_remove(msg);
        }
        else if (msg_type == "settings_restore") {
            handle_settings_restore(msg);
        }
    }
}
