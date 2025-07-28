/* =============================================================
   MODULE: ds_collar_auth.lsl
   PURPOSE: Authoritative ACL and identity state for DS Collar
   DATE:    2025-07-28
   ============================================================= */

integer DEBUG = TRUE;

//── State ───────────────────────────────────────────────────────
key     g_owner              = NULL_KEY;
string  g_owner_honorific    = "";
list    g_trustees           = [];  // list of keys
list    g_trustee_honorifics = [];  // parallel list of strings
list    g_blacklist          = [];  // list of keys
integer g_public_access      = FALSE;

//── Message numbers ─────────────────────────────────────────────
integer ACL_QUERY_NUM        = 700;  // query for ACL level
integer UPDATE_OWNER_NUM     = 701;
integer UPDATE_TRUSTEES_NUM  = 702;
integer UPDATE_BLACKLIST_NUM = 703;
integer UPDATE_PUBLIC_NUM    = 704;

integer ACL_RESULT_NUM       = 710;  // response to query
integer ACL_SYNC_NUM         = 711;  // full-state broadcast

//── Helpers ────────────────────────────────────────────────────
list parts;

// Safely get the Nth element of parts as string
string get_part(integer idx) {
    if (idx < llGetListLength(parts)) {
        return llList2String(parts, idx);
    } else {
        return "";
    }
}

// Core ACL decision logic
// Levels: 1=primary owner, 3=owned wearer, 2=trustee, 4=public, 5=deny
integer compute_acl(key av) {
    // 5 = deny if blacklisted
    if (llListFindList(g_blacklist, [av]) != -1) {
        return 5;
    }
    // 1 = primary owner
    if (av == g_owner) {
        return 1;
    }
    // 3 = owned wearer (when collar is owned by someone else)
    if (av == llGetOwner() && g_owner != NULL_KEY) {
        return 3;
    }
    // 2 = trustee
    if (llListFindList(g_trustees, [av]) != -1) {
        return 2;
    }
    // 4 = public access
    if (g_public_access) {
        return 4;
    }
    // fallback = deny
    return 5;
}

// Broadcast a single ACL result back to core/plugins
broadcast_acl_result(key av, integer level) {
    string msg =
        "acl_result" + "|" +
        (string)av     + "|" +
        (string)level;
    llMessageLinked(LINK_SET, ACL_RESULT_NUM, msg, NULL_KEY);
}

// Broadcast the full ACL state
broadcast_acl_sync() {
    string msg =
        "acl_sync"  + "|" +
        (string)g_owner               + "|" +
        g_owner_honorific             + "|" +
        llDumpList2String(g_trustees, ",")           + "|" +
        llDumpList2String(g_trustee_honorifics, ",") + "|" +
        llDumpList2String(g_blacklist, ",")          + "|" +
        (string)g_public_access;
    llMessageLinked(LINK_SET, ACL_SYNC_NUM, msg, NULL_KEY);
    if (DEBUG) llOwnerSay("[AUTH] Broadcast sync: " + msg);
}

//── Event Handlers ─────────────────────────────────────────────
default {
    state_entry() {
        if (DEBUG) llOwnerSay("[AUTH] ds_collar_auth ready.");
    }

    link_message(integer sender, integer num, string str, key id) {
        // Split every value by the literal "|" separator
        parts = llParseStringKeepNulls(str, ["|"], []);

        // 1) ACL query
        if (num == ACL_QUERY_NUM && llList2String(parts, 0) == "acl_query") {
            key av = (key)get_part(1);
            integer level = compute_acl(av);
            broadcast_acl_result(av, level);
        }
        // 2) Owner update
        else if (num == UPDATE_OWNER_NUM && llList2String(parts, 0) == "update_owner") {
            g_owner = (key)get_part(1);
            g_owner_honorific = get_part(2);
            if (DEBUG) llOwnerSay("[AUTH] Owner set to " + (string)g_owner);
            broadcast_acl_sync();
        }
        // 3) Trustees update
        else if (num == UPDATE_TRUSTEES_NUM && llList2String(parts, 0) == "update_trustees") {
            string csv     = get_part(1);
            string hon_csv = get_part(2);

            // parse trustees
            if (csv == "") {
                g_trustees = [];
            } else {
                g_trustees = llParseString2List(csv, [","], []);
            }
            // parse trustee honorifics
            if (hon_csv == "") {
                g_trustee_honorifics = [];
            } else {
                g_trustee_honorifics = llParseString2List(hon_csv, [","], []);
            }

            if (DEBUG) llOwnerSay("[AUTH] Trustees updated.");
            broadcast_acl_sync();
        }
        // 4) Blacklist update
        else if (num == UPDATE_BLACKLIST_NUM && llList2String(parts, 0) == "update_blacklist") {
            string csv = get_part(1);

            if (csv == "") {
                g_blacklist = [];
            } else {
                g_blacklist = llParseString2List(csv, [","], []);
            }

            if (DEBUG) llOwnerSay("[AUTH] Blacklist updated.");
            broadcast_acl_sync();
        }
        // 5) Public-access toggle
        else if (num == UPDATE_PUBLIC_NUM && llList2String(parts, 0) == "update_public") {
            if (get_part(1) == "1") {
                g_public_access = TRUE;
            } else {
                g_public_access = FALSE;
            }
            if (DEBUG) llOwnerSay("[AUTH] Public access = " + (string)g_public_access);
            broadcast_acl_sync();
        }
    }
}
