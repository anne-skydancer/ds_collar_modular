/* =============================================================
   MODULE: ds_collar_settings.lsl
   PURPOSE: Persistent settings for D/s Collar 
            (lock, owner key & honorific, per-trustee key & honorific,
             relay mode, public mode, RLV restrictions, current animation)
   DATE:    2025-07-28
   ============================================================= */

integer DEBUG = TRUE;

//── Stored settings ─────────────────────────────────────────────
integer g_locked                  = FALSE;
key     g_owner_key               = NULL_KEY;
string  g_owner_honorific         = "";
key     g_trustee1_key            = NULL_KEY;
string  g_trustee1_honorific      = "";
key     g_trustee2_key            = NULL_KEY;
string  g_trustee2_honorific      = "";
key     g_trustee3_key            = NULL_KEY;
string  g_trustee3_honorific      = "";
key     g_trustee4_key            = NULL_KEY;
string  g_trustee4_honorific      = "";
integer g_relay_hardcore_mode     = FALSE;
integer g_public_mode             = FALSE;
list    g_rlv_restrictions        = [];     // list of restriction strings
string  g_current_animation       = "";     // animation UUID or name

//── Message numbers ─────────────────────────────────────────────
// Queries
integer SETTINGS_QUERY_NUM         = 750;  // "get_settings"

// Updates
integer UPDATE_LOCK_NUM            = 751;  // "set_lock|<0|1>"
integer UPDATE_OWNER_KEY_NUM       = 752;  // "set_owner_key|<key>"
integer UPDATE_OWNER_HON_NUM       = 753;  // "set_owner_hon|<hon>"
integer UPDATE_TRUSTEE1_KEY_NUM    = 754;  // "set_trustee1_key|<key>"
integer UPDATE_TRUSTEE1_HON_NUM    = 755;  // "set_trustee1_hon|<hon>"
integer UPDATE_TRUSTEE2_KEY_NUM    = 756;  // "set_trustee2_key|<key>"
integer UPDATE_TRUSTEE2_HON_NUM    = 757;  // "set_trustee2_hon|<hon>"
integer UPDATE_TRUSTEE3_KEY_NUM    = 758;  // "set_trustee3_key|<key>"
integer UPDATE_TRUSTEE3_HON_NUM    = 759;  // "set_trustee3_hon|<hon>"
integer UPDATE_TRUSTEE4_KEY_NUM    = 760;  // "set_trustee4_key|<key>"
integer UPDATE_TRUSTEE4_HON_NUM    = 761;  // "set_trustee4_hon|<hon>"
integer UPDATE_RELAY_MODE_NUM      = 762;  // "set_relay_mode|<0|1>"
integer UPDATE_PUBLIC_MODE_NUM     = 763;  // "set_public_mode|<0|1>"
integer UPDATE_RLV_NUM             = 764;  // "set_rlv_restrictions|<csv>"
integer UPDATE_ANIM_NUM            = 765;  // "set_animation|<anim>"

// Responses / Sync
integer SETTINGS_SYNC_NUM          = 770;  // 
// "settings_sync|<lock>|<owner_key>|<owner_hon>|<t1_key>|<t1_hon>|...|<t4_hon>|<relay>|<public>|<rlv_csv>|<anim>"

list parts;

//― Helper: safely extract Nth field ―─────────────────────────────
string get_part(integer idx) {
    if (idx < llGetListLength(parts)) {
        return llList2String(parts, idx);
    } else {
        return "";
    }
}

//― Broadcast full settings ―─────────────────────────────────────
broadcast_settings_sync() {
    // Build RLV restrictions CSV
    string rlv_csv = "";
    integer i;
    for (i = 0; i < llGetListLength(g_rlv_restrictions); i++) {
        if (i == 0) {
            rlv_csv = llList2String(g_rlv_restrictions, i);
        } else {
            rlv_csv = rlv_csv + "," + llList2String(g_rlv_restrictions, i);
        }
    }

    // Compose payload explicitly
    string msg =
        "settings_sync"              + "|" +
        (string)g_locked             + "|" +
        (string)g_owner_key          + "|" +
        g_owner_honorific            + "|" +
        (string)g_trustee1_key       + "|" +
        g_trustee1_honorific         + "|" +
        (string)g_trustee2_key       + "|" +
        g_trustee2_honorific         + "|" +
        (string)g_trustee3_key       + "|" +
        g_trustee3_honorific         + "|" +
        (string)g_trustee4_key       + "|" +
        g_trustee4_honorific         + "|" +
        (string)g_relay_hardcore_mode + "|" +
        (string)g_public_mode        + "|" +
        rlv_csv                      + "|" +
        g_current_animation;

    llMessageLinked(LINK_SET, SETTINGS_SYNC_NUM, msg, NULL_KEY);
    if (DEBUG) llOwnerSay("[SETTINGS] sync: " + msg);
}

default {
    state_entry() {
        if (DEBUG) llOwnerSay("[SETTINGS] module ready.");
        broadcast_settings_sync();
    }

    link_message(integer sender, integer num, string str, key id) {
        parts = llParseStringKeepNulls(str, ["|"], []);
        string cmd = llList2String(parts, 0);

        // 1) Full-state query
        if (num == SETTINGS_QUERY_NUM && cmd == "get_settings") {
            broadcast_settings_sync();
        }
        // 2) Lock update
        else if (num == UPDATE_LOCK_NUM && cmd == "set_lock") {
            if (get_part(1) == "1") {
                g_locked = TRUE;
            } else {
                g_locked = FALSE;
            }
            broadcast_settings_sync();
        }
        // 3) Owner key update
        else if (num == UPDATE_OWNER_KEY_NUM && cmd == "set_owner_key") {
            g_owner_key = (key)get_part(1);
            broadcast_settings_sync();
        }
        // 4) Owner honorific update
        else if (num == UPDATE_OWNER_HON_NUM && cmd == "set_owner_hon") {
            g_owner_honorific = get_part(1);
            broadcast_settings_sync();
        }
        // 5) Trustee1 key update
        else if (num == UPDATE_TRUSTEE1_KEY_NUM && cmd == "set_trustee1_key") {
            g_trustee1_key = (key)get_part(1);
            broadcast_settings_sync();
        }
        // 6) Trustee1 honorific update
        else if (num == UPDATE_TRUSTEE1_HON_NUM && cmd == "set_trustee1_hon") {
            g_trustee1_honorific = get_part(1);
            broadcast_settings_sync();
        }
        // 7) Trustee2 key update
        else if (num == UPDATE_TRUSTEE2_KEY_NUM && cmd == "set_trustee2_key") {
            g_trustee2_key = (key)get_part(1);
            broadcast_settings_sync();
        }
        // 8) Trustee2 honorific update
        else if (num == UPDATE_TRUSTEE2_HON_NUM && cmd == "set_trustee2_hon") {
            g_trustee2_honorific = get_part(1);
            broadcast_settings_sync();
        }
        // 9) Trustee3 key update
        else if (num == UPDATE_TRUSTEE3_KEY_NUM && cmd == "set_trustee3_key") {
            g_trustee3_key = (key)get_part(1);
            broadcast_settings_sync();
        }
        // 10) Trustee3 honorific update
        else if (num == UPDATE_TRUSTEE3_HON_NUM && cmd == "set_trustee3_hon") {
            g_trustee3_honorific = get_part(1);
            broadcast_settings_sync();
        }
        // 11) Trustee4 key update
        else if (num == UPDATE_TRUSTEE4_KEY_NUM && cmd == "set_trustee4_key") {
            g_trustee4_key = (key)get_part(1);
            broadcast_settings_sync();
        }
        // 12) Trustee4 honorific update
        else if (num == UPDATE_TRUSTEE4_HON_NUM && cmd == "set_trustee4_hon") {
            g_trustee4_honorific = get_part(1);
            broadcast_settings_sync();
        }
        // 13) Relay hardcore mode update
        else if (num == UPDATE_RELAY_MODE_NUM && cmd == "set_relay_mode") {
            if (get_part(1) == "1") {
                g_relay_hardcore_mode = TRUE;
            } else {
                g_relay_hardcore_mode = FALSE;
            }
            broadcast_settings_sync();
        }
        // 14) Public mode update
        else if (num == UPDATE_PUBLIC_MODE_NUM && cmd == "set_public_mode") {
            if (get_part(1) == "1") {
                g_public_mode = TRUE;
            } else {
                g_public_mode = FALSE;
            }
            broadcast_settings_sync();
        }
        // 15) RLV restrictions update
        else if (num == UPDATE_RLV_NUM && cmd == "set_rlv_restrictions") {
            string csv = get_part(1);
            if (csv == "") {
                g_rlv_restrictions = [];
            } else {
                g_rlv_restrictions = llParseString2List(csv, [","], []);
            }
            broadcast_settings_sync();
        }
        // 16) Current animation update
        else if (num == UPDATE_ANIM_NUM && cmd == "set_animation") {
            g_current_animation = get_part(1);
            broadcast_settings_sync();
        }
    }
}
