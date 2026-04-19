/*--------------------
PLUGIN: plugin_access.lsl
VERSION: 1.10
REVISION: 9
PURPOSE: Owner, trustee, and honorific management workflows
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 9: Chat command support (Phase 3). Registers "access" alias.
  "access add/rem owner/trustee" enter the corresponding menu flow
  (sensor pick + consent/honorific dialogs). No username in chat —
  target selection stays in the menu by design.
- v1.1 rev 8: Wire-type rename (Phase 2). kernel.register→kernel.register.declare,
  kernel.registernow→kernel.register.refresh, kernel.reset→kernel.reset.soft,
  kernel.resetall→kernel.reset.factory, settings.setowner→settings.owner.set,
  settings.clearowner→settings.owner.clear, settings.addtrustee→
  settings.trustee.add, settings.removetrustee→settings.trustee.remove.
- v1.1 rev 7: Guard ui.menu.start against raw kmod_chat broadcasts (no acl
  field). Fixes duplicate dialogs when commands are typed in chat.
- v1.1 rev 6: Namespace internal message type strings (kernel.*, settings.*,
  ui.*) for bus-wide clarity. No behavioral changes.
- v1.1 rev 5: Honor soft_reset / soft_reset_all from KERNEL_LIFECYCLE so
  factory reset wipes cached owner/trustee state, not just LSD.
- v1.1 rev 4: Fix phantom-trustee count. llCSV2List("") returns [""] (a
  single empty entry), not []. When the trustee/owner CSV keys were unset
  in LSD, the access plugin reported one trustee/owner that didn't exist.
  Added a csv_read() helper that returns [] for empty raw values and
  routed all CSV reads through it.
- v1.1 rev 3: Two-mode access model. Single-owner mode reads/writes scalar
  access.owner / access.ownername / access.ownerhonorific. Multi-owner mode
  is read-only from notecard CSVs (access.owneruuids/names/honorifics) and
  the menu hides all owner-editing buttons. New API messages: set_owner,
  clear_owner, add_trustee, remove_trustee, runaway. Runaway now triggers
  factory reset via kmod_settings instead of clearing settings individually.
- v1.1 rev 2: Migrate dialog buttons to button_data format with context-based routing.
- v1.1 rev 1: Migrate settings reads from JSON broadcast to direct LSD reads.
  Remove apply_settings_delta(); both sync and delta call apply_settings_sync().
  Remove request_settings_sync(); call apply_settings_sync() from state_entry.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL with policy reads.
  Button list built from get_policy_buttons() + btn_allowed() combined with
  state-dependent logic (has_owner, RunawayEnabled, is_owner, etc.).
--------------------*/


/* -------------------- ISP CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.owner";
string PLUGIN_LABEL = "Access";

/* -------------------- CONSTANTS -------------------- */
integer MAX_NUMBERED_LIST_ITEMS = 11;  // 12 dialog buttons - 1 Back button

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE   = "access.multiowner";
string KEY_OWNER              = "access.owner";              // single-owner uuid
string KEY_OWNER_NAME         = "access.ownername";          // single-owner display name
string KEY_OWNER_HONORIFIC    = "access.ownerhonorific";
string KEY_OWNER_UUIDS        = "access.owneruuids";         // multi-owner CSV (notecard)
string KEY_OWNER_NAMES        = "access.ownernames";
string KEY_OWNER_HONORIFICS   = "access.ownerhonorifics";
string KEY_TRUSTEE_UUIDS      = "access.trusteeuuids";
string KEY_TRUSTEE_NAMES      = "access.trusteenames";
string KEY_TRUSTEE_HONORIFICS = "access.trusteehonorifics";
string KEY_RUNAWAY_ENABLED    = "access.enablerunaway";

/* -------------------- STATE -------------------- */
integer MultiOwnerMode;
key OwnerKey;
list OwnerKeys;            // multi-owner list (read-only from notecard)
string OwnerHonorific;
list OwnerHonorifics;      // parallel to OwnerKeys (multi-owner)
list OwnerNames;           // parallel to OwnerKeys (multi-owner)
list TrusteeKeys;
list TrusteeHonorifics;
list TrusteeNames;
integer RunawayEnabled = TRUE;

key CurrentUser;
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId;
string MenuContext;

key PendingCandidate;
string PendingHonorific;
list CandidateKeys;

list NameCache;
key ActiveNameQuery;
key ActiveQueryTarget;

list OWNER_HONORIFICS = ["Master", "Mistress", "Daddy", "Mommy", "King", "Queen"];
list TRUSTEE_HONORIFICS = ["Sir", "Madame", "Milord", "Milady"];

/* -------------------- HELPERS -------------------- */

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

integer lsd_int(string lsd_key, integer fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (integer)v;
}

// llCSV2List("") returns [""] (length 1), not []. This wrapper returns a
// truly empty list when the LSD key is unset/empty so length-based UIs
// don't show phantom entries.
list csv_read(string lsd_key) {
    string raw = llLinksetDataRead(lsd_key);
    if (raw == "") return [];
    return llCSV2List(raw);
}

string gen_session() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* -------------------- LSD POLICY HELPER -------------------- */
list get_policy_buttons(string ctx, integer acl) {
    string policy = llLinksetDataRead("acl.policycontext:" + ctx);
    if (policy == "") return [];
    string csv = llJsonGetValue(policy, [(string)acl]);
    if (csv == JSON_INVALID) return [];
    return llCSV2List(csv);
}

integer btn_allowed(string label) {
    return (llListFindList(gPolicyButtons, [label]) != -1);
}

integer has_owner() {
    if (MultiOwnerMode) return (llGetListLength(OwnerKeys) > 0);
    return (OwnerKey != NULL_KEY);
}

key get_primary_owner() {
    if (MultiOwnerMode && llGetListLength(OwnerKeys) > 0) {
        return (key)llList2String(OwnerKeys, 0);
    }
    return OwnerKey;
}

integer is_owner(key k) {
    if (MultiOwnerMode) return (llListFindList(OwnerKeys, [(string)k]) != -1);
    return (k == OwnerKey);
}

/* -------------------- NAMES -------------------- */

cache_name(key k, string n) {
    if (k == NULL_KEY || n == "" || n == "???") return;
    integer idx = llListFindList(NameCache, [k]);
    if (idx != -1) {
        NameCache = llListReplaceList(NameCache, [n], idx + 1, idx + 1);
    }
    else {
        NameCache += [k, n];
        if (llGetListLength(NameCache) > 20) {
            NameCache = llDeleteSubList(NameCache, 0, 1);
        }
    }
}

string get_name(key k) {
    if (k == NULL_KEY) return "";
    integer idx = llListFindList(NameCache, [k]);
    if (idx != -1) return llList2String(NameCache, idx + 1);

    string n = llGetDisplayName(k);
    if (n != "" && n != "???") {
        cache_name(k, n);
        return n;
    }

    if (ActiveNameQuery == NULL_KEY) {
        ActiveNameQuery = llRequestDisplayName(k);
        ActiveQueryTarget = k;
    }

    return llKey2Name(k);
}

/* -------------------- LIFECYCLE -------------------- */

register_self() {
    // Write button visibility policy to LSD
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "2", "Add Owner,Runaway",
        "3", "Add Trustee,Rem Trustee,Release,Runaway: On,Runaway: Off",
        "4", "Add Owner,Runaway,Add Trustee,Rem Trustee",
        "5", "Transfer,Release,Runaway: On,Runaway: Off,Add Trustee,Rem Trustee"
    ]));

    // Register with kernel
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
    ]), NULL_KEY);

    // Declare chat alias.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "access",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

/* -------------------- SETTINGS -------------------- */

apply_settings_sync() {
    MultiOwnerMode = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    OwnerHonorific = "";
    OwnerHonorifics = [];
    OwnerNames = [];
    TrusteeKeys = [];
    TrusteeHonorifics = [];
    TrusteeNames = [];

    string tmp = llLinksetDataRead(KEY_MULTI_OWNER_MODE);
    if (tmp != "") MultiOwnerMode = (integer)tmp;

    if (MultiOwnerMode) {
        // Multi-owner: parallel CSVs (read-only, notecard managed)
        OwnerKeys       = csv_read(KEY_OWNER_UUIDS);
        OwnerNames      = csv_read(KEY_OWNER_NAMES);
        OwnerHonorifics = csv_read(KEY_OWNER_HONORIFICS);
        if (llGetListLength(OwnerKeys) > 0) {
            OwnerKey = (key)llList2String(OwnerKeys, 0);
            if (llGetListLength(OwnerHonorifics) > 0) {
                OwnerHonorific = llList2String(OwnerHonorifics, 0);
            }
        }
    }
    else {
        // Single-owner: scalar trio
        string raw = llLinksetDataRead(KEY_OWNER);
        if (raw != "") {
            OwnerKey = (key)raw;
            OwnerHonorific = llLinksetDataRead(KEY_OWNER_HONORIFIC);
        }
    }

    // Trustees (always parallel CSVs)
    TrusteeKeys       = csv_read(KEY_TRUSTEE_UUIDS);
    TrusteeNames      = csv_read(KEY_TRUSTEE_NAMES);
    TrusteeHonorifics = csv_read(KEY_TRUSTEE_HONORIFICS);

    RunawayEnabled = lsd_int(KEY_RUNAWAY_ENABLED, TRUE);
}


persist_owner(key owner, string hon) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.owner.set",
        "uuid", (string)owner,
        "honorific", hon
    ]), NULL_KEY);
}

add_trustee(key trustee, string hon) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.trustee.add",
        "uuid", (string)trustee,
        "honorific", hon
    ]), NULL_KEY);
}

remove_trustee(key trustee) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.trustee.remove",
        "uuid", (string)trustee
    ]), NULL_KEY);
}

clear_owner() {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.owner.clear"
    ]), NULL_KEY);
}

trigger_runaway() {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.runaway"
    ]), NULL_KEY);
}

/* -------------------- MENUS -------------------- */

show_main() {
    SessionId = gen_session();
    MenuContext = "main";

    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    string body = "Owner Management\n\n";

    if (has_owner()) {
        if (MultiOwnerMode) {
            body += "Multi-owner mode (notecard managed)\n";
            body += "Owners: " + (string)llGetListLength(OwnerKeys) + "\n";
        }
        else {
            string display_name = llLinksetDataRead(KEY_OWNER_NAME);
            if (display_name == "") display_name = get_name(OwnerKey);
            body += "Owner: " + display_name;
            if (OwnerHonorific != "") body += " (" + OwnerHonorific + ")";
        }
    }
    else {
        body += "Unowned";
    }

    body += "\nTrustees: " + (string)llGetListLength(TrusteeKeys);

    list button_data = [btn("Back", "back")];

    // In multi-owner mode, all owner editing is disabled (notecard managed).
    // Trustee management remains available.
    if (!MultiOwnerMode) {
        // Add Owner: policy allows + wearer + no current owner
        if (btn_allowed("Add Owner") && CurrentUser == llGetOwner() && !has_owner()) {
            button_data += [btn("Add Owner", "add_owner")];
        }

        // Runaway: policy allows + wearer + has owner + runaway enabled
        if (btn_allowed("Runaway") && CurrentUser == llGetOwner() && has_owner() && RunawayEnabled) {
            button_data += [btn("Runaway", "runaway")];
        }

        // Transfer: policy allows + is_owner
        if (btn_allowed("Transfer") && is_owner(CurrentUser)) {
            button_data += [btn("Transfer", "transfer")];
        }

        // Release: policy allows + is_owner
        if (btn_allowed("Release") && is_owner(CurrentUser)) {
            button_data += [btn("Release", "release")];
        }

        // Runaway toggle: policy allows + is_owner
        if (is_owner(CurrentUser)) {
            if (RunawayEnabled && btn_allowed("Runaway: On")) {
                button_data += [btn("Runaway: On", "runaway_toggle")];
            }
            else if (!RunawayEnabled && btn_allowed("Runaway: Off")) {
                button_data += [btn("Runaway: Off", "runaway_toggle")];
            }
        }
    }

    // Trustee management: available in both modes
    if (btn_allowed("Add Trustee")) button_data += [btn("Add Trustee", "add_trustee")];
    if (btn_allowed("Rem Trustee")) button_data += [btn("Rem Trustee", "rem_trustee")];

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 60
    ]), NULL_KEY);
}

show_candidates(string context, string title, string prompt) {
    if (llGetListLength(CandidateKeys) == 0) {
        llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
        show_main();
        return;
    }

    list names = [];
    integer i = 0;
    while (i < llGetListLength(CandidateKeys) && i < MAX_NUMBERED_LIST_ITEMS) {
        names += [get_name((key)llList2String(CandidateKeys, i))];
        i++;
    }

    SessionId = gen_session();
    MenuContext = context;

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", title,
        "prompt", prompt,
        "items", llList2Json(JSON_ARRAY, names),
        "timeout", 60
    ]), NULL_KEY);
}

show_honorific(key target, string context) {
    PendingCandidate = target;
    SessionId = gen_session();
    MenuContext = context;

    list choices = OWNER_HONORIFICS;
    if (context == "trustee_hon") choices = TRUSTEE_HONORIFICS;

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", (string)target,
        "title", "Honorific",
        "prompt", "What would you like to be called?",
        "items", llList2Json(JSON_ARRAY, choices),
        "timeout", 60
    ]), NULL_KEY);
}

show_confirm(string title, string body, string ctx) {
    SessionId = gen_session();
    MenuContext = ctx;

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", title,
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, [btn("Yes", "confirm"), btn("No", "cancel")]),
        "timeout", 60
    ]), NULL_KEY);
}

// Chat subcommand handler. Routes into the existing menu flows by
// setting session state and triggering the same code paths the
// corresponding main-menu button would fire.
handle_subpath(key user, integer acl_level, string subpath) {
    list tokens = llParseString2List(subpath, ["."], []);
    if (llGetListLength(tokens) < 2) {
        llRegionSayTo(user, 0, "Usage: access <add|rem> <owner|trustee>");
        return;
    }
    string verb = llList2String(tokens, 0);
    string role = llList2String(tokens, 1);

    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);

    // Session setup mirrors the menu flow entry.
    CurrentUser = user;
    UserAcl = acl_level;
    MenuContext = "main";

    if (verb == "add" && role == "owner") {
        if (!btn_allowed("Add Owner")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        gPolicyButtons = [];
        MenuContext = "set_scan";
        CandidateKeys = [];
        llSensor("", NULL_KEY, AGENT, 10.0, PI);
        return;
    }
    if (verb == "rem" && role == "owner") {
        if (!btn_allowed("Release")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        gPolicyButtons = [];
        show_confirm("Confirm Release",
            "Release " + get_name(llGetOwner()) + "?", "release_owner");
        return;
    }
    if (verb == "add" && role == "trustee") {
        if (!btn_allowed("Add Trustee")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        gPolicyButtons = [];
        MenuContext = "trustee_scan";
        CandidateKeys = [];
        llSensor("", NULL_KEY, AGENT, 10.0, PI);
        return;
    }
    if (verb == "rem" && role == "trustee") {
        if (!btn_allowed("Rem Trustee")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        gPolicyButtons = [];
        show_remove_trustee();
        return;
    }

    gPolicyButtons = [];
    llRegionSayTo(user, 0, "Unknown access subcommand: " + verb + " " + role);
}

show_remove_trustee() {
    if (llGetListLength(TrusteeKeys) == 0) {
        llRegionSayTo(CurrentUser, 0, "No trustees.");
        show_main();
        return;
    }

    list names = [];
    integer i = 0;
    while (i < llGetListLength(TrusteeKeys) && i < MAX_NUMBERED_LIST_ITEMS) {
        string display_name = "";
        if (i < llGetListLength(TrusteeNames)) display_name = llList2String(TrusteeNames, i);
        if (display_name == "") display_name = get_name((key)llList2String(TrusteeKeys, i));
        string hon = "";
        if (i < llGetListLength(TrusteeHonorifics)) hon = llList2String(TrusteeHonorifics, i);
        if (hon != "") display_name += " (" + hon + ")";
        names += [display_name];
        i++;
    }

    SessionId = gen_session();
    MenuContext = "remove_trustee";

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Remove Trustee",
        "prompt", "Select to remove:",
        "items", llList2Json(JSON_ARRAY, names),
        "timeout", 60
    ]), NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button(string cmd, string label) {
    // Numbered list contexts use the label as a number index; button_data contexts use cmd
    // "Back" from numbered_list has empty context, route by label
    if (cmd == "back" || (cmd == "" && label == "Back")) {
        if (MenuContext == "main") {
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "ui.menu.return", "user", (string)CurrentUser
            ]), NULL_KEY);
            cleanup();
        }
        else show_main();
        return;
    }

    if (MenuContext == "main") {
        if (cmd == "add_owner") {
            MenuContext = "set_scan";
            CandidateKeys = [];
            llSensor("", NULL_KEY, AGENT, 10.0, PI);
        }
        else if (cmd == "transfer") {
            MenuContext = "transfer_scan";
            CandidateKeys = [];
            llSensor("", NULL_KEY, AGENT, 10.0, PI);
        }
        else if (cmd == "release") {
            show_confirm("Confirm Release", "Release " + get_name(llGetOwner()) + "?", "release_owner");
        }
        else if (cmd == "runaway") {
            show_confirm("Confirm Runaway", "Run away from " + get_name(get_primary_owner()) + "?\n\nThis removes ownership without consent.", "runaway");
        }
        else if (cmd == "runaway_toggle") {
            if (RunawayEnabled) {
                // Disabling requires wearer consent - send dialog to WEARER
                string hon = OwnerHonorific;
                if (hon == "") hon = "Owner";

                string msg_body = "Your " + hon + " wants to disable runaway for you.\n\nPlease confirm.";

                SessionId = gen_session();
                MenuContext = "runaway_disable_confirm";

                llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                    "type", "ui.dialog.open",
                    "session_id", SessionId,
                    "user", (string)llGetOwner(),  // Send to WEARER, not CurrentUser
                    "title", "Disable Runaway",
                    "body", msg_body,
                    "button_data", llList2Json(JSON_ARRAY, [btn("Yes", "confirm"), btn("No", "cancel")]),
                    "timeout", 60
                ]), NULL_KEY);
            }
            else {
                // Enabling is direct (no consent needed)
                RunawayEnabled = TRUE;
                llLinksetDataWrite(KEY_RUNAWAY_ENABLED, "1");

                llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
                    "type", "settings.set",
                    "key", KEY_RUNAWAY_ENABLED,
                    "value", "1"
                ]), NULL_KEY);

                llRegionSayTo(CurrentUser, 0, "Runaway enabled.");
                show_main();
            }
            return;
        }
        else if (cmd == "add_trustee") {
            MenuContext = "trustee_scan";
            CandidateKeys = [];
            llSensor("", NULL_KEY, AGENT, 10.0, PI);
        }
        else if (cmd == "rem_trustee") {
            show_remove_trustee();
        }
        return;
    }

    // Numbered list contexts: use label as number index
    integer idx = (integer)label - 1;

    if (MenuContext == "set_select") {
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            PendingCandidate = (key)llList2String(CandidateKeys, idx);
            SessionId = gen_session();
            MenuContext = "set_accept";

            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "ui.dialog.open",
                "session_id", SessionId,
                "user", (string)PendingCandidate,
                "title", "Accept Ownership",
                "body", get_name(llGetOwner()) + " wishes to submit to you.\n\nAccept?",
                "button_data", llList2Json(JSON_ARRAY, [btn("Yes", "confirm"), btn("No", "cancel")]),
                "timeout", 60
            ]), NULL_KEY);
        }
    }
    else if (MenuContext == "set_accept") {
        if (cmd == "confirm") show_honorific(PendingCandidate, "set_hon");
        else {
            llRegionSayTo(CurrentUser, 0, "Declined.");
            show_main();
        }
    }
    else if (MenuContext == "set_hon") {
        if (idx >= 0 && idx < llGetListLength(OWNER_HONORIFICS)) {
            PendingHonorific = llList2String(OWNER_HONORIFICS, idx);
            SessionId = gen_session();
            MenuContext = "set_confirm";

            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "ui.dialog.open",
                "session_id", SessionId,
                "user", (string)llGetOwner(),
                "title", "Confirm",
                "body", "Submit to " + get_name(PendingCandidate) + " as your " + PendingHonorific + "?",
                "button_data", llList2Json(JSON_ARRAY, [btn("Yes", "confirm"), btn("No", "cancel")]),
                "timeout", 60
            ]), NULL_KEY);
        }
    }
    else if (MenuContext == "set_confirm") {
        if (cmd == "confirm") {
            persist_owner(PendingCandidate, PendingHonorific);
            llRegionSayTo(PendingCandidate, 0, get_name(llGetOwner()) + " has submitted to you as their " + PendingHonorific + ".");
            llRegionSayTo(llGetOwner(), 0, "You are now property of " + PendingHonorific + " " + get_name(PendingCandidate) + ".");
            cleanup();
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "ui.menu.return", "user", (string)CurrentUser
            ]), NULL_KEY);
        }
        else show_main();
    }
    else if (MenuContext == "transfer_select") {
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            PendingCandidate = (key)llList2String(CandidateKeys, idx);
            SessionId = gen_session();
            MenuContext = "transfer_accept";

            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "ui.dialog.open",
                "session_id", SessionId,
                "user", (string)PendingCandidate,
                "title", "Accept Transfer",
                "body", "Accept ownership of " + get_name(llGetOwner()) + "?",
                "button_data", llList2Json(JSON_ARRAY, [btn("Yes", "confirm"), btn("No", "cancel")]),
                "timeout", 60
            ]), NULL_KEY);
        }
    }
    else if (MenuContext == "transfer_accept") {
        if (cmd == "confirm") show_honorific(PendingCandidate, "transfer_hon");
        else {
            llRegionSayTo(CurrentUser, 0, "Declined.");
            show_main();
        }
    }
    else if (MenuContext == "transfer_hon") {
        if (idx >= 0 && idx < llGetListLength(OWNER_HONORIFICS)) {
            PendingHonorific = llList2String(OWNER_HONORIFICS, idx);
            key old = OwnerKey;
            persist_owner(PendingCandidate, PendingHonorific);
            llRegionSayTo(old, 0, "You have transferred " + get_name(llGetOwner()) + " to " + get_name(PendingCandidate) + ".");
            llRegionSayTo(PendingCandidate, 0, get_name(llGetOwner()) + " is now your property as " + PendingHonorific + ".");
            llRegionSayTo(llGetOwner(), 0, "You are now property of " + PendingHonorific + " " + get_name(PendingCandidate) + ".");
            cleanup();
        }
    }
    else if (MenuContext == "release_owner") {
        if (cmd == "confirm") {
            SessionId = gen_session();
            MenuContext = "release_wearer";

            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "ui.dialog.open",
                "session_id", SessionId,
                "user", (string)llGetOwner(),
                "title", "Confirm Release",
                "body", "Released by " + get_name(CurrentUser) + ".\n\nConfirm freedom?",
                "button_data", llList2Json(JSON_ARRAY, [btn("Yes", "confirm"), btn("No", "cancel")]),
                "timeout", 60
            ]), NULL_KEY);
        }
        else show_main();
    }
    else if (MenuContext == "release_wearer") {
        if (cmd == "confirm") {
            clear_owner();
            llRegionSayTo(llGetOwner(), 0, "Released. You are free.");
            cleanup();
        }
        else {
            llRegionSayTo(CurrentUser, 0, "Release cancelled.");
            cleanup();
        }
    }
    else if (MenuContext == "runaway") {
        if (cmd == "confirm") {
            key old = get_primary_owner();
            string old_hon = OwnerHonorific;

            // Notify wearer and former owner before triggering reset
            if (old != NULL_KEY) {
                string notify_msg = "You have run away from ";
                if (old_hon != "") notify_msg += old_hon + " ";
                notify_msg += get_name(old) + ".";
                llRegionSayTo(llGetOwner(), 0, notify_msg);
                llRegionSayTo(old, 0, get_name(llGetOwner()) + " ran away.");
            }
            else {
                llRegionSayTo(llGetOwner(), 0, "You have run away.");
            }

            // Runaway = factory reset. kmod_settings wipes LSD and resets all scripts.
            trigger_runaway();
            cleanup();
        }
        else show_main();
    }
    else if (MenuContext == "runaway_disable_confirm") {
        if (cmd == "confirm") {
            // Wearer consented - disable runaway
            RunawayEnabled = FALSE;
            llLinksetDataWrite(KEY_RUNAWAY_ENABLED, "0");

            llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
                "type", "settings.set",
                "key", KEY_RUNAWAY_ENABLED,
                "value", "0"
            ]), NULL_KEY);

            llRegionSayTo(llGetOwner(), 0, "Runaway disabled.");
            llRegionSayTo(CurrentUser, 0, "Runaway disabled.");
            show_main();
        }
        else {
            // Wearer declined
            llRegionSayTo(llGetOwner(), 0, "You declined to disable runaway.");
            llRegionSayTo(CurrentUser, 0, get_name(llGetOwner()) + " declined to disable runaway.");
            show_main();
        }
    }
    else if (MenuContext == "trustee_select") {
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            PendingCandidate = (key)llList2String(CandidateKeys, idx);

            if (llListFindList(TrusteeKeys, [(string)PendingCandidate]) != -1) {
                llRegionSayTo(CurrentUser, 0, "Already trustee.");
                show_main();
                return;
            }

            SessionId = gen_session();
            MenuContext = "trustee_accept";

            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "ui.dialog.open",
                "session_id", SessionId,
                "user", (string)PendingCandidate,
                "title", "Accept Trustee",
                "body", get_name(llGetOwner()) + " wants you as trustee.\n\nAccept?",
                "button_data", llList2Json(JSON_ARRAY, [btn("Yes", "confirm"), btn("No", "cancel")]),
                "timeout", 60
            ]), NULL_KEY);
        }
    }
    else if (MenuContext == "trustee_accept") {
        if (cmd == "confirm") show_honorific(PendingCandidate, "trustee_hon");
        else {
            llRegionSayTo(CurrentUser, 0, "Declined.");
            show_main();
        }
    }
    else if (MenuContext == "trustee_hon") {
        if (idx >= 0 && idx < llGetListLength(TRUSTEE_HONORIFICS)) {
            PendingHonorific = llList2String(TRUSTEE_HONORIFICS, idx);
            add_trustee(PendingCandidate, PendingHonorific);
            llRegionSayTo(PendingCandidate, 0, "You are trustee of " + get_name(llGetOwner()) + " as " + PendingHonorific + ".");
            llRegionSayTo(CurrentUser, 0, get_name(PendingCandidate) + " is trustee.");
            show_main();
        }
    }
    else if (MenuContext == "remove_trustee") {
        if (idx >= 0 && idx < llGetListLength(TrusteeKeys)) {
            key trustee_key = (key)llList2String(TrusteeKeys, idx);
            remove_trustee(trustee_key);
            llRegionSayTo(CurrentUser, 0, "Removed.");
            llRegionSayTo(trustee_key, 0, "Removed as trustee.");
            show_main();
        }
    }
    else show_main();
}

/* -------------------- CLEANUP -------------------- */

cleanup() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    MenuContext = "";
    PendingCandidate = NULL_KEY;
    PendingHonorific = "";
    CandidateKeys = [];
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        cleanup();
        register_self();
        apply_settings_sync();
    }

    on_rez(integer p) {
        llResetScript();
    }

    changed(integer c) {
        if (c & CHANGED_OWNER) llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        string type = llJsonGetValue(msg, ["type"]);
        if (type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (type == "kernel.register.refresh") register_self();
            else if (type == "kernel.ping") send_pong();
            else if (type == "kernel.reset.soft" || type == "kernel.reset.factory") {
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) return;
                }
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            if (type == "settings.sync" || type == "settings.delta") apply_settings_sync();
        }
        else if (num == UI_BUS) {
            if (type == "ui.menu.start" && (llJsonGetValue(msg, ["context"]) != JSON_INVALID)) {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    integer acl = (integer)llJsonGetValue(msg, ["acl"]);

                    string subpath = "";
                    string sp = llJsonGetValue(msg, ["subpath"]);
                    if (sp != JSON_INVALID) subpath = sp;

                    if (subpath != "") {
                        handle_subpath(id, acl, subpath);
                        return;
                    }

                    CurrentUser = id;
                    UserAcl = acl;
                    show_main();
                }
            }
        }
        else if (num == DIALOG_BUS) {
            if (type == "ui.dialog.response") {
                if (llJsonGetValue(msg, ["session_id"]) != JSON_INVALID) {
                    if (llJsonGetValue(msg, ["session_id"]) == SessionId) {
                        string resp_ctx = llJsonGetValue(msg, ["context"]);
                        if (resp_ctx == JSON_INVALID) resp_ctx = "";
                        string resp_btn = llJsonGetValue(msg, ["button"]);
                        if (resp_btn == JSON_INVALID) resp_btn = "";
                        handle_button(resp_ctx, resp_btn);
                    }
                }
            }
            else if (type == "ui.dialog.timeout") {
                if ((llJsonGetValue(msg, ["session_id"]) != JSON_INVALID)) {
                    if (llJsonGetValue(msg, ["session_id"]) == SessionId) cleanup();
                }
            }
        }
    }

    sensor(integer count) {
        if (CurrentUser == NULL_KEY) return;

        list candidates = [];
        key wearer = llGetOwner();
        integer i;

        while (i < count) {
            key k = llDetectedKey(i);
            if (k != wearer) candidates += [(string)k];
            i++;
        }

        CandidateKeys = candidates;

        if (MenuContext == "set_scan") {
            show_candidates("set_select", "Set Owner", "Choose owner:");
        }
        else if (MenuContext == "transfer_scan") {
            show_candidates("transfer_select", "Transfer", "Choose new owner:");
        }
        else if (MenuContext == "trustee_scan") {
            show_candidates("trustee_select", "Add Trustee", "Choose trustee:");
        }
    }

    no_sensor() {
        if (CurrentUser == NULL_KEY) return;
        CandidateKeys = [];

        if (MenuContext == "set_scan") {
            show_candidates("set_select", "Set Owner", "Choose owner:");
        }
        else if (MenuContext == "transfer_scan") {
            show_candidates("transfer_select", "Transfer", "Choose new owner:");
        }
        else if (MenuContext == "trustee_scan") {
            show_candidates("trustee_select", "Add Trustee", "Choose trustee:");
        }
    }

    dataserver(key qid, string data) {
        if (qid != ActiveNameQuery) return;
        if (data != "" && data != "???") cache_name(ActiveQueryTarget, data);
        ActiveNameQuery = NULL_KEY;
        ActiveQueryTarget = NULL_KEY;
    }
}
