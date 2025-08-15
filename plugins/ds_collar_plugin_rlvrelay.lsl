/* =========================================================================
   PLUGIN: ds_rlv_relay_plugin.lsl
   PURPOSE: Self-contained RLV Relay for DS Collar
   VERSION: Hardened ACL (AUTH-driven) + dynamic Unbind/Safeword button
   ========================================================================= */

integer DEBUG = FALSE;

/* ---------------- ABI Link Numbers ---------------- */
integer K_PLUGIN_REG_QUERY   = 500;
integer K_PLUGIN_REG_REPLY   = 501;
integer K_PLUGIN_SOFT_RESET  = 504;
integer K_PLUGIN_PING        = 650;
integer K_PLUGIN_PONG        = 651;
integer K_PLUGIN_START       = 900;
integer K_PLUGIN_RETURN_NUM  = 901;
integer SOS_MSG_NUM          = 999; /* SOS plugin link channel */

/* ---- AUTH (authoritative ACL) ---- */
integer AUTH_QUERY_NUM       = 700;
integer AUTH_RESULT_NUM      = 710;

/* ---------------- Constants ---------------- */
string CONS_TYPE_REGISTER          = "register";
string CONS_TYPE_PLUGIN_PING       = "plugin_ping";
string CONS_TYPE_PLUGIN_PONG       = "plugin_pong";
string CONS_TYPE_PLUGIN_SOFT_RESET = "plugin_soft_reset";
string CONS_TYPE_PLUGIN_START      = "plugin_start";
string CONS_TYPE_PLUGIN_RETURN     = "plugin_return";

string  PLUGIN_CONTEXT = "core_relay";
string  ROOT_CONTEXT   = "core_root";
string  PLUGIN_LABEL   = "RLV Relay";
integer PLUGIN_SN      = 0;

/* ---------- ACL levels (authoritative) ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* ---------- Allowed ACL levels for this plugin ---------- */
/* Allow owned wearer (2) for Safeword, trustee (3) and owner (5) for Unbind.
   Keep unowned wearer (4) allowed as before. */
list ALLOWED_ACL_LEVELS = [ACL_OWNED, ACL_TRUSTEE, ACL_UNOWNED, ACL_PRIMARY_OWNER];

integer in_allowed_levels(integer lvl) {
    if (llListFindList(ALLOWED_ACL_LEVELS, [lvl]) != -1) return TRUE;
    return FALSE;
}

/* ---------------- Relay Constants ---------------- */
integer RELAY_CHANNEL    = -1812221819;
integer RLV_RESP_CHANNEL = 4711;
integer MAX_RELAYS       = 5;

integer MODE_OFF         = 0;
integer MODE_ON          = 1;
integer MODE_HARDCORE    = 2;

integer g_mode     = MODE_ON;
integer g_hardcore = FALSE;

/* ---------------- Relay State ---------------- */
/* g_relays: [obj, name, chan, restrictionsCSV] */
list    g_relays         = [];

/* ---------------- Session Menus ---------------- */
integer DIALOG_TIMEOUT_SEC = 180;
key     g_user = NULL_KEY;
integer g_menu_chan = 0;
integer g_listen = 0;

/* ACL from AUTH for the current user */
integer g_acl_level   = ACL_NOACCESS;
integer g_acl_pending = FALSE;

list    g_menu_labels = [];
list    g_menu_contexts = [];

/* =========================================================================
   HELPERS
   ========================================================================= */
integer json_has(string j, list path) { return (llJsonGetValue(j, path) != JSON_INVALID); }
integer logd(string m) { if (DEBUG) llOwnerSay("[RELAY] " + m); return 0; }

integer send_response(key obj, integer chan, string command, integer success) {
    string reply;
    if (success) reply = "ok";
    else reply = "ko";
    string msg = "RLV," + (string)llGetKey() + "," + command + "," + reply;
    llRegionSayTo(obj, chan, msg);
    return 0;
}

integer close_dialog() {
    if (g_listen) {
        llListenRemove(g_listen);
        g_listen = 0;
    }
    g_menu_chan = 0;
    llSetTimerEvent(0.0);
    return 0;
}

integer begin_context_dialog(key user, string body, list labels, list contexts) {
    g_menu_labels   = labels;
    g_menu_contexts = contexts;

    /* pad to multiple of 3 */
    while ((llGetListLength(g_menu_labels) % 3) != 0) {
        g_menu_labels
