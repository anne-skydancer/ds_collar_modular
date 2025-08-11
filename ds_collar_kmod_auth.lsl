// =============================================================
//  MODULE: ds_collar_auth.lsl (DS Collar)
//  PURPOSE: Authoritative ACL and identity state
//           Works with dynamic ds_collar_settings.lsl
//  DATE:    2025-07-31 (Parametric message idiom + settings integration)
//  DEBUG:   All debug output prefixed with [AUTH][DEBUG]
// =============================================================

integer DEBUG = TRUE;

//── Protocol message constants (from core, MUST stay in sync) ─────────
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SOFT_RESET_MSG_START    = "core_soft_reset";
string SETTINGS_SYNC_MSG_START = "settings_sync";

//── Cached state, populated from settings sync ───────────────────
key     owner_key              = NULL_KEY;
string  owner_honorific        = "";
list    trustee_keys           = [];
list    trustee_honorifics     = [];
list    blacklist_keys         = [];
integer public_access_flag     = FALSE;

//── Link message numbers for ACL and Settings modules ───────────
integer ACL_QUERY_NUM        = 700;
integer UPDATE_OWNER_NUM     = 701;
integer UPDATE_TRUSTEES_NUM  = 702;
integer UPDATE_BLACKLIST_NUM = 703;
integer UPDATE_PUBLIC_NUM    = 704;
integer ACL_RESULT_NUM       = 710;
integer ACL_SYNC_NUM         = 711;

// Settings module message numbers
integer SETTINGS_QUERY_NUM   = 800;  // "get_settings"
integer SETTINGS_SYNC_NUM    = 870;  // "settings_sync|key=val|key=val|..."

//── Message roots (must use constants!) ─────────────────────────
string ACL_QUERY_MSG_START   = "acl_query";
string UPDATE_OWNER_MSG      = "update_owner";
string UPDATE_TRUSTEES_MSG   = "update_trustees";
string UPDATE_BLACKLIST_MSG  = "update_blacklist";
string UPDATE_PUBLIC_MSG     = "update_public";
string ACL_RESULT_MSG        = "acl_result";
string ACL_SYNC_MSG          = "acl_sync";
string SETTINGS_GET_MSG      = "get_settings"; // Parametric

// Settings keys (must match keys used in ds_collar_settings)
string KEY_OWNER_KEY         = "owner_key";
string KEY_OWNER_HON         = "owner_hon";
string KEY_TRUSTEES          = "trustees";
string KEY_TRUSTEE_HONS      = "trustee_honorifics";
string KEY_BLACKLIST         = "blacklist";
string KEY_PUBLIC_ACCESS     = "public_mode";

//── Universal message builder ───────────────────────────────────
string build_msg(list parts) {
    integer i;
    string out_str = "";
    for (i = 0; i < llGetListLength(parts); ++i) {
        if (i != 0) out_str += "|";
        out_str += llList2String(parts, i);
    }
    return out_str;
}

// Safely get the Nth element of the last-parsed parts list
list last_parsed_parts;
string get_part(integer idx) {
    if (idx < llGetListLength(last_parsed_parts)) {
        return llList2String(last_parsed_parts, idx);
    }
    return "";
}

// Helper: parse CSV string to list of keys or strings safely
list parse_csv(string csv) {
    if (csv == "") return [];
    return llParseString2List(csv, [","], []);
}

// Core ACL decision logic (unchanged)
integer compute_acl(key av) {
    if (DEBUG) {
        llOwnerSay("[AUTH][DEBUG] compute_acl: av=" + (string)av +
                   " owner_key=" + (string)owner_key +
                   " llGetOwner()=" + (string)llGetOwner());
        llOwnerSay("[AUTH][DEBUG] Trustees: " + llDumpList2String(trustee_keys, ","));
        llOwnerSay("[AUTH][DEBUG] Blacklist: " + llDumpList2String(blacklist_keys, ","));
        llOwnerSay("[AUTH][DEBUG] Public: " + (string)public_access_flag);
    }
    if (llListFindList(blacklist_keys, [av]) != -1) {
        if (DEBUG) llOwnerSay("[AUTH][DEBUG] compute_acl: DENY - Blacklisted");
        return 5;
    }
    if (av == owner_key) {
        if (DEBUG) llOwnerSay("[AUTH][DEBUG] compute_acl: LEVEL 1 - Primary Owner");
        return 1;
    }
    if (owner_key == NULL_KEY && av == llGetOwner()) {
        if (DEBUG) llOwnerSay("[AUTH][DEBUG] compute_acl: LEVEL 1 - Unowned wearer");
        return 1;
    }
    if (av == llGetOwner() && owner_key != NULL_KEY) {
        if (DEBUG) llOwnerSay("[AUTH][DEBUG] compute_acl: LEVEL 3 - Owned wearer");
        return 3;
    }
    if (llListFindList(trustee_keys, [av]) != -1) {
        if (DEBUG) llOwnerSay("[AUTH][DEBUG] compute_acl: LEVEL 2 - Trustee");
        return 2;
    }
    if (public_access_flag) {
        if (DEBUG) llOwnerSay("[AUTH][DEBUG] compute_acl: LEVEL 4 - Public");
        return 4;
    }
    if (DEBUG) llOwnerSay("[AUTH][DEBUG] compute_acl: LEVEL 5 - Deny fallback");
    return 5;
}

// Broadcast a single ACL result (uses parametric builder)
broadcast_acl_result(key av, integer level) {
    string msg = build_msg([
        ACL_RESULT_MSG,
        (string)av,
        (string)level
    ]);
    llMessageLinked(LINK_SET, ACL_RESULT_NUM, msg, NULL_KEY);
    if (DEBUG) llOwnerSay("[AUTH][DEBUG] Sent ACL result: " + msg);
}

// Broadcast the full ACL state (from local cache)
broadcast_acl_sync() {
    string msg = build_msg([
        ACL_SYNC_MSG,
        (string)owner_key,
        owner_honorific,
        llDumpList2String(trustee_keys, ","),
        llDumpList2String(trustee_honorifics, ","),
        llDumpList2String(blacklist_keys, ","),
        (string)public_access_flag
    ]);
    llMessageLinked(LINK_SET, ACL_SYNC_NUM, msg, NULL_KEY);
    if (DEBUG) llOwnerSay("[AUTH][DEBUG] Broadcast sync: " + msg);
}

// Send update commands to settings module (set_<key>|<value>)
send_settings_update(string key_str, string val_str) {
    string msg = build_msg([ "set_" + key_str, val_str ]);
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, msg, NULL_KEY);
    if (DEBUG) llOwnerSay("[AUTH][DEBUG] Sent settings update: " + msg);
}

// Parse and update cached state from settings sync message
update_from_settings_sync(list parts) {
    integer len = llGetListLength(parts);
    integer i;
    // Reset current caches
    owner_key = NULL_KEY;
    owner_honorific = "";
    trustee_keys = [];
    trustee_honorifics = [];
    blacklist_keys = [];
    public_access_flag = FALSE;

    for (i = 1; i < len; i++) {
        string key_val = llList2String(parts, i);
        integer sep_idx = llSubStringIndex(key_val, "=");
        if (sep_idx != -1) {
            string key_str = llGetSubString(key_val, 0, sep_idx - 1);
            string val_str = llGetSubString(key_val, sep_idx + 1, -1);

            if (key_str == KEY_OWNER_KEY) {
                owner_key = (key)val_str;
            }
            else if (key_str == KEY_OWNER_HON) {
                owner_honorific = val_str;
            }
            else if (key_str == KEY_TRUSTEES) {
                trustee_keys = parse_csv(val_str);
            }
            else if (key_str == KEY_TRUSTEE_HONS) {
                trustee_honorifics = parse_csv(val_str);
            }
            else if (key_str == KEY_BLACKLIST) {
                blacklist_keys = parse_csv(val_str);
            }
            else if (key_str == KEY_PUBLIC_ACCESS) {
                public_access_flag = (val_str == "1");
            }
            else {
                if (DEBUG) llOwnerSay("[AUTH][DEBUG] Unknown settings key in sync: " + key_str);
            }
        }
    }
    if (DEBUG) {
        llOwnerSay("[AUTH][DEBUG] Updated state from settings sync:");
        llOwnerSay("  owner_key=" + (string)owner_key);
        llOwnerSay("  owner_hon=" + owner_honorific);
        llOwnerSay("  trustees=" + llDumpList2String(trustee_keys, ","));
        llOwnerSay("  trustee_hons=" + llDumpList2String(trustee_honorifics, ","));
        llOwnerSay("  blacklist=" + llDumpList2String(blacklist_keys, ","));
        llOwnerSay("  public_access=" + (string)public_access_flag);
    }
}

default
{
    state_entry()
    {
        if (DEBUG) llOwnerSay("[AUTH][DEBUG] ds_collar_auth ready. Querying settings.");
        // Query settings module for initial sync
        llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, SETTINGS_GET_MSG, NULL_KEY);
    }

    link_message(integer sender, integer num, string str, key id)
    {
        // Only handle intended channels
        if (num == SETTINGS_SYNC_NUM) {
            last_parsed_parts = llParseStringKeepNulls(str, ["|"], []);
            if (llList2String(last_parsed_parts, 0) == SETTINGS_SYNC_MSG_START) {
                update_from_settings_sync(last_parsed_parts);
            }
            return;
        }
        if (num == SETTINGS_QUERY_NUM) {
            // (Settings update/commands are not handled here.)
            return;
        }
        if (num == ACL_QUERY_NUM && llList2String(llParseStringKeepNulls(str, ["|"], []), 0) == ACL_QUERY_MSG_START) {
            last_parsed_parts = llParseStringKeepNulls(str, ["|"], []);
            key av = (key)get_part(1);
            if (DEBUG) llOwnerSay("[AUTH][DEBUG] Received " + ACL_QUERY_MSG_START + " for " + (string)av);
            integer level = compute_acl(av);
            broadcast_acl_result(av, level);
            return;
        }
        if (num == UPDATE_OWNER_NUM && llList2String(llParseStringKeepNulls(str, ["|"], []), 0) == UPDATE_OWNER_MSG) {
            last_parsed_parts = llParseStringKeepNulls(str, ["|"], []);
            string new_owner = get_part(1);
            string new_hon   = get_part(2);
            send_settings_update(KEY_OWNER_KEY, new_owner);
            send_settings_update(KEY_OWNER_HON, new_hon);
            return;
        }
        if (num == UPDATE_TRUSTEES_NUM && llList2String(llParseStringKeepNulls(str, ["|"], []), 0) == UPDATE_TRUSTEES_MSG) {
            last_parsed_parts = llParseStringKeepNulls(str, ["|"], []);
            string csv     = get_part(1);
            string hon_csv = get_part(2);
            send_settings_update(KEY_TRUSTEES, csv);
            send_settings_update(KEY_TRUSTEE_HONS, hon_csv);
            return;
        }
        if (num == UPDATE_BLACKLIST_NUM && llList2String(llParseStringKeepNulls(str, ["|"], []), 0) == UPDATE_BLACKLIST_MSG) {
            last_parsed_parts = llParseStringKeepNulls(str, ["|"], []);
            string csv = get_part(1);
            send_settings_update(KEY_BLACKLIST, csv);
            return;
        }
        if (num == UPDATE_PUBLIC_NUM && llList2String(llParseStringKeepNulls(str, ["|"], []), 0) == UPDATE_PUBLIC_MSG) {
            last_parsed_parts = llParseStringKeepNulls(str, ["|"], []);
            string val = get_part(1);
            send_settings_update(KEY_PUBLIC_ACCESS, val);
            return;
        }
        if (DEBUG && (num == ACL_QUERY_NUM || num == UPDATE_OWNER_NUM || num == UPDATE_TRUSTEES_NUM || num == UPDATE_BLACKLIST_NUM || num == UPDATE_PUBLIC_NUM)) {
            llOwnerSay("[AUTH][DEBUG] Unknown or unhandled message: num=" + (string)num + " str=" + str);
        }
    }
}
