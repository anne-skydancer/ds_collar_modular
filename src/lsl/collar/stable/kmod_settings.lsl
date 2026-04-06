/*--------------------
MODULE: kmod_settings.lsl
VERSION: 1.10
REVISION: 2
PURPOSE: Notecard parser, validation guards, and LSD settings store
ARCHITECTURE: Consolidated message bus lanes, LSD-backed storage
CHANGES:
- v1.1 rev 2: Remove KvJson. All kv_* operations now read/write LSD
  directly. Remove recover_lsd_settings (LSD is authoritative). Remove
  ForceReseed (notecard parsing always writes to LSD). Simplify
  handle_settings_restore to write each key to LSD.
- v1.1 rev 1: Simplify broadcasts to lightweight signals. Consumers now
  read directly from LSD; four broadcast functions replaced by a single
  broadcast_settings_changed() signal. Notecard parsing now always writes
  validated values to LSD. Notecard removal clears LSD settings keys.
- v1.1 rev 0: Version bump for LSD policy architecture. No functional changes to this module.
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE = "access.multiowner";
string KEY_OWNER            = "access.owner";
string KEY_OWNERS           = "access.owners";
string KEY_TRUSTEES         = "access.trustees";
string KEY_BLACKLIST        = "access.blacklist";
string KEY_PUBLIC_ACCESS    = "public.mode";
string KEY_TPE_MODE         = "tpe.mode";
string KEY_LOCKED           = "lock.locked";

// RLV exception keys
string KEY_EX_OWNER_TP   = "rlvex.ownertp";
string KEY_EX_OWNER_IM   = "rlvex.ownerim";
string KEY_EX_TRUSTEE_TP = "rlvex.trusteetp";
string KEY_EX_TRUSTEE_IM = "rlvex.trusteeim";

// Access plugin keys
string KEY_RUNAWAY_ENABLED = "access.enablerunaway";


/* -------------------- NOTECARD CONFIG -------------------- */
string NOTECARD_NAME = "settings";
string COMMENT_PREFIX = "#";
string SEPARATOR = "=";
/* -------------------- STATE -------------------- */
key LastOwner = NULL_KEY;

key NotecardQuery = NULL_KEY;
integer NotecardLine = 0;
integer IsLoadingNotecard = FALSE;
key NotecardKey = NULL_KEY;

integer MaxListLen = 64;

/* -------------------- HELPERS -------------------- */


string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
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

/* -------------------- LSD OPERATIONS -------------------- */

string kv_get(string key_name) {
    return llLinksetDataRead(key_name);
}

integer kv_set_scalar(string key_name, string value) {
    if (llLinksetDataRead(key_name) == value) return FALSE;
    llLinksetDataWrite(key_name, value);
    return TRUE;
}

integer kv_set_list(string key_name, list values) {
    string new_arr = llList2Json(JSON_ARRAY, values);
    if (llLinksetDataRead(key_name) == new_arr) return FALSE;
    llLinksetDataWrite(key_name, new_arr);
    return TRUE;
}

integer kv_list_add_unique(string key_name, string elem) {
    string arr = llLinksetDataRead(key_name);
    list current_list = [];
    if (llJsonValueType(arr, []) == JSON_ARRAY) {
        current_list = llJson2List(arr);
    }

    if (llListFindList(current_list, [elem]) != -1) return FALSE;
    if (llGetListLength(current_list) >= MaxListLen) return FALSE;

    current_list += [elem];
    return kv_set_list(key_name, current_list);
}

/* ---- JSON OBJECT LSD OPERATIONS ---- */

integer kv_obj_set_field(string key_name, string field, string value) {
    string obj = llLinksetDataRead(key_name);
    if (obj == "" || llJsonValueType(obj, []) != JSON_OBJECT) {
        obj = "{}";
    }
    string new_obj = llJsonSetValue(obj, [field], value);
    return kv_set_scalar(key_name, new_obj);
}

integer kv_obj_remove_field(string key_name, string field) {
    string obj = llLinksetDataRead(key_name);
    if (obj == "" || llJsonValueType(obj, []) != JSON_OBJECT) return FALSE;
    if (llJsonGetValue(obj, [field]) == JSON_INVALID) return FALSE;
    string new_obj = llJsonSetValue(obj, [field], JSON_DELETE);
    return kv_set_scalar(key_name, new_obj);
}

integer kv_list_remove_all(string key_name, string elem) {
    string arr = llLinksetDataRead(key_name);
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
        broadcast_settings_changed();
    }

    // Remove owner from blacklist and broadcast the change
    string blacklist_arr = kv_get(KEY_BLACKLIST);
    if (llJsonValueType(blacklist_arr, []) == JSON_ARRAY) {
        list blacklist = llJson2List(blacklist_arr);
        if (llListFindList(blacklist, [who]) != -1) {
            // Only process if actually present
            blacklist = list_remove_all(blacklist, who);
            if (kv_set_list(KEY_BLACKLIST, blacklist)) {
                broadcast_settings_changed();
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
                broadcast_settings_changed();
            }
        }
    }

    return TRUE;
}

// BROADCAST FIX: Emits deltas for all guard-side mutations to keep ACL consumers in sync
integer apply_blacklist_add_guard(string who) {
    // Remove from trustees object and broadcast the change
    if (kv_obj_remove_field(KEY_TRUSTEES, who)) {
        broadcast_settings_changed();
    }

    // Remove from single owner object and broadcast
    if (kv_obj_remove_field(KEY_OWNER, who)) {
        broadcast_settings_changed();
    }

    // Remove from multi-owner object and broadcast
    if (kv_obj_remove_field(KEY_OWNERS, who)) {
        broadcast_settings_changed();
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

broadcast_settings_changed() {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings_sync"
    ]), NULL_KEY);
}

/* -------------------- KEY NAMING CONVENTION -------------------- */
// No whitelist is enforced. LSL link_message is sandboxed to the same linkset,
// so any script that can write to SETTINGS_BUS is already trusted by the owner.
//
// Convention (not enforced in code):
//   Access keys — access.<setting>  (owner, trustees, blacklist, multi_owner_mode, runaway_enabled)
//   Plugin keys — <plugin>.<setting>
//                 e.g. bell.volume, restrict.list, lock.locked, relay.mode
//
// is_notecard_only_key() and all business-logic guards (role exclusivity, TPE
// validation, MaxListLen) remain active — those are correctness constraints, not
// access control.

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
        return;
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

// Clear all known settings keys from LSD so removed notecard entries
// don't persist as stale data.
clear_lsd_settings() {
    list keys = [
        KEY_MULTI_OWNER_MODE, KEY_OWNER, KEY_OWNERS, KEY_TRUSTEES,
        KEY_BLACKLIST, KEY_PUBLIC_ACCESS, KEY_TPE_MODE, KEY_LOCKED,
        KEY_EX_OWNER_TP, KEY_EX_OWNER_IM, KEY_EX_TRUSTEE_TP, KEY_EX_TRUSTEE_IM,
        KEY_RUNAWAY_ENABLED
    ];
    integer i = 0;
    integer len = llGetListLength(keys);
    while (i < len) {
        llLinksetDataDelete(llList2String(keys, i));
        i += 1;
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
    broadcast_settings_changed();
}

handle_set(string msg) {
    string key_name = llJsonGetValue(msg, ["key"]);
    if (key_name == JSON_INVALID) return;

    if (is_notecard_only_key(key_name)) {
        return;
    }
    
    integer did_change = FALSE;
    
    // Bulk list set
    string values_arr = llJsonGetValue(msg, ["values"]);
    if (values_arr != JSON_INVALID) {
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
                broadcast_settings_changed();
            }
        }
        return;
    }

    // Scalar set
    string value = llJsonGetValue(msg, ["value"]);
    if (value != JSON_INVALID) {

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
            broadcast_settings_changed();
        }
    }
}

handle_list_add(string msg) {
    if (llJsonGetValue(msg, ["key"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["elem"]) == JSON_INVALID) return;
    
    string key_name = llJsonGetValue(msg, ["key"]);
    string elem = llJsonGetValue(msg, ["elem"]);
    

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
        broadcast_settings_changed();
    }
}

handle_obj_set(string msg) {
    if (llJsonGetValue(msg, ["key"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["field"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["value"]) == JSON_INVALID) return;

    string key_name = llJsonGetValue(msg, ["key"]);
    string field = llJsonGetValue(msg, ["field"]);
    string value = llJsonGetValue(msg, ["value"]);


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
        broadcast_settings_changed();
    }
}

handle_obj_remove(string msg) {
    if (llJsonGetValue(msg, ["key"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["field"]) == JSON_INVALID) return;

    string key_name = llJsonGetValue(msg, ["key"]);
    string field = llJsonGetValue(msg, ["field"]);


    if (!is_json_object_key(key_name)) return;

    integer did_change = kv_obj_remove_field(key_name, field);
    if (did_change) {
        broadcast_settings_changed();
    }
}

handle_list_remove(string msg) {
    if (llJsonGetValue(msg, ["key"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["elem"]) == JSON_INVALID) return;
    
    string key_name = llJsonGetValue(msg, ["key"]);
    string elem = llJsonGetValue(msg, ["elem"]);
    

    
    integer did_change = kv_list_remove_all(key_name, elem);

    if (did_change) {
        broadcast_settings_changed();
    }
}

handle_settings_restore(string msg) {
    string kv = llJsonGetValue(msg, ["kv"]);
    if (kv == JSON_INVALID) return;

    // Write each key-value pair from the restore payload to LSD
    list pairs = llJson2List(kv);
    integer i = 0;
    integer len = llGetListLength(pairs);
    while (i < len) {
        llLinksetDataWrite(llList2String(pairs, i), llList2String(pairs, i + 1));
        i += 2;
    }

    broadcast_settings_changed();
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        LastOwner = llGetOwner();
        NotecardKey = llGetInventoryKey(NOTECARD_NAME);

        integer notecard_found = start_notecard_reading();

        if (!notecard_found) {
            // No notecard — LSD already has settings from previous session
            broadcast_settings_changed();
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
                // Notecard was deleted -> clear LSD and reset to defaults
                if (current_notecard_key == NULL_KEY) {
                    clear_lsd_settings();
                    broadcast_settings_changed();
                    llResetScript();
                }
                else {
                    // Notecard edited or re-added -> reload
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
            broadcast_settings_changed();

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
