/*--------------------
MODULE: kmod_ui.lsl
VERSION: 1.10
REVISION: 11
PURPOSE: Session management, LSD policy filtering, and plugin list orchestration
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.1 rev 11: AUTH_BUS rename (Phase 1). auth.aclquery→auth.acl.query,
  auth.aclresult→auth.acl.result, auth.aclupdate→auth.acl.update.
- v1.1 rev 10: KERNEL_LIFECYCLE rename (Phase 1). kernel.register→
  kernel.register.declare, kernel.registernow→kernel.register.refresh,
  kernel.pluginlist→kernel.plugins.list, kernel.pluginlistrequest→
  kernel.plugins.request, kernel.reset→kernel.reset.soft, kernel.resetall
  →kernel.reset.factory.
- v1.1 rev 9: Longest-prefix plugin routing for namespaced chat subcommands.
  Context like "ui.core.animate.pose.nadu" matches plugin "ui.core.animate"
  and the remainder ("pose.nadu") is passed as a new `subpath` field in
  ui.menu.start. Plugins ignore subpath to keep menu behaviour, or read
  it to execute actions directly. ACL stays on the matched parent context.
- v1.1 rev 8: Handle ui.chat.command (sent by kmod_chat rev 12). Routes to
  handle_start just like ui.menu.start, but plugins never see ui.chat.command
  so the double-dialog bug (when a plugin label starts with the chat prefix)
  is eliminated cleanly without relying on per-plugin acl guards.
- v1.1 rev 7: Re-emit synthetic kernel.register for ROOT_CONTEXT/"Menu" in
  response to kernel.registernow. Previously only emitted from state_entry,
  so kmod_chat's alias table never contained "menu" after sending registernow.
  Also guard against raw unrouted ui.menu.start broadcasts in all dev plugins:
  messages without an acl field are ignored (fixes duplicate dialogs on chat
  commands).
- v1.1 rev 6: handle_start falls back to root session for unrecognized chat
  contexts (e.g. unresolved alias 'menu') instead of silently returning.
  Fixes 'an menu' doing nothing when the alias table was empty at startup.
- v1.1 rev 5: Fix chat-driven plugin dispatch. handle_start now handles
  plugin-specific contexts (e.g. "ui.core.chat") dispatched by kmod_chat.
  Added dispatch_to_plugin() helper (extracted from handle_button_click).
  handle_start guards against already-routed messages (have acl field) to
  avoid re-entrancy. handle_acl_result routes plugin contexts to the plugin
  instead of send_render_menu.
- v1.1 rev 4: Namespace context strings. ROOT_CONTEXT → "ui.core.root",
  SOS_CONTEXT → "ui.sos.root", SOS_PREFIX → "ui.sos.". SOS plugins are
  now detected structurally by namespace prefix rather than flat sos_ prefix.
- v1.1 rev 3: Views refactor. Replace per-session FilteredPluginIndices heap
  (SessionFilteredStarts, SessionFilteredCounts, FilteredPluginIndices) with
  pre-computed view tables (ViewRootIndices, ViewSosIndices) keyed by ACL
  level. Views are built once in build_views() at plugin list load time.
  Per-touch LSD reads: 0 (was O(plugins)). cleanup_session() no longer shifts
  start pointers; create_session() no longer scans plugin policies. Net: -22
  lines, eliminated off-by-one hazard in pointer-shifting loop.
- v1.1 rev 2: Dynamic no-access message for strangers when public access is
  off. If the collar has a primary owner, the toucher now sees "This collar is
  owned by [Honorific] Name and is exclusive to them." rather than the generic
  message. Falls back to the generic message when no owner is set. Added
  get_primary_owner_display() helper (reads LSD; supports single- and
  multi-owner modes; includes honorific when present).
- v1.1 rev 1: Namespaced internal message type strings (e.g. "start" -> "ui.menu.start",
  "acl_query" -> "auth.acl.query", "plugin_list" -> "kernel.plugins.list").
- v1.1 rev 0: Replaced min_acl filtering with LSD policy reads. Root menu
  visibility now determined by llLinksetDataRead("policy:<context>"). Removed
  PluginMinACLs parallel list and plugin_acl_list_request/response flow.
  Each plugin self-declares its policy via llLinksetDataWrite on registration.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- CONSTANTS -------------------- */
string ROOT_CONTEXT = "ui.core.root";
string SOS_CONTEXT = "ui.sos.root";
string SOS_PREFIX = "ui.sos.";  // Prefix for SOS plugin contexts
integer MAX_FUNC_BTNS = 9;
float TOUCH_RANGE_M = 5.0;
float LONG_TOUCH_THRESHOLD = 1.5;

/* Plugin list stride removed in v1.1 — no min_acl in plugin data */

integer MAX_SESSIONS = 5;
integer SESSION_MAX_AGE = 60;  // Seconds before ACL refresh required

// Per-user ACL cache prefix written by kmod_auth.lsl.
// Reading "acl.<avatar_uuid>.cache" skips the AUTH_BUS round-trip on touch.
// Value format: "<level>|<unix_timestamp>" — must match kmod_auth.lsl's store_cached_acl().
// CROSS-MODULE CONTRACT: this format must match LSD_ACL_CACHE_PREFIX/SUFFIX in kmod_auth.lsl.
string LSD_ACL_CACHE_PREFIX = "acl.";
string LSD_ACL_CACHE_SUFFIX = ".cache";

/* ACL levels (mirrors auth module) */
integer ACL_BLACKLIST = -1;


/* -------------------- STATE -------------------- */
// Parallel Lists for Plugins
list PluginContexts;
list PluginLabels;

// View tables: pre-computed per-(acl_level, context) filtered plugin index lists.
// Built once when the plugin list is received; zero LSD reads per touch.
// Parallel to VIEW_ACL_LEVELS; each entry is a JSON array of plugin indices.
list VIEW_ACL_LEVELS = [-1, 0, 1, 2, 3, 4, 5];  // CONSTANT — do not modify at runtime
list ViewRootIndices;  // root-menu plugin indices per ACL level
list ViewSosIndices;   // SOS-menu plugin indices per ACL level

// Parallel Lists for Sessions
list SessionUsers;
list SessionACLs;
list SessionBlacklisted;
list SessionPages;
list SessionTotalPages;
list SessionIDs;
list SessionCreatedTimes;
list SessionContexts;

// Parallel Lists for Pending ACL
list PendingAclAvatars;
list PendingAclContexts;

// Parallel Lists for Touch Data
list TouchKeys;
list TouchStartTimes;

// Parallel Lists for Plugin States
list PluginStateContexts;
list PluginStateValues;


/* -------------------- HELPERS -------------------- */


string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
}

// MEMORY OPTIMIZATION: Compact field validation helper
integer validate_required_fields(string json_str, list field_names) {
    integer i = 0;
    integer len = llGetListLength(field_names);
    while (i < len) {
        string field = llList2String(field_names, i);
        if (llJsonGetValue(json_str, [field]) == JSON_INVALID) {
            return FALSE;
        }
        i += 1;
    }
    return TRUE;
}

string generate_session_id(key user) {
    return "ui_" + (string)user + "_" + (string)llGetUnixTime();
}

/* -------------------- PLUGIN STATE MANAGEMENT -------------------- */

integer find_plugin_state_idx(string context) {
    return llListFindList(PluginStateContexts, [context]);
}

integer get_plugin_state(string context) {
    integer idx = find_plugin_state_idx(context);
    if (idx == -1) {
        return 0;  // Default state
    }
    return llList2Integer(PluginStateValues, idx);
}

set_plugin_state(string context, integer button_state) {
    integer idx = find_plugin_state_idx(context);

    if (idx != -1) {
        // Update existing state
        PluginStateValues = llListReplaceList(PluginStateValues, [button_state], idx, idx);
    }
    else {
        // Add new state
        PluginStateContexts += [context];
        PluginStateValues += [button_state];
    }
}

/* -------------------- ACL CACHE MANAGEMENT -------------------- */

// Reads the pre-computed ACL result written by kmod_auth into LSD.
// kmod_auth populates acl.<uuid>.cache for all named actors on every settings
// load/change via precompute_known_acl(). This path costs one LSD read and
// zero link_messages. Falls through to AUTH_BUS only on a true cold miss
// (unknown user whose entry was never written or has been cleared).
integer try_cached_session(key user_key, string context_filter) {
    string raw = llLinksetDataRead(LSD_ACL_CACHE_PREFIX + (string)user_key + LSD_ACL_CACHE_SUFFIX);
    if (raw == "") return FALSE;
    integer sep = llSubStringIndex(raw, "|");
    if (sep == -1) return FALSE;
    integer level = (integer)llGetSubString(raw, 0, sep - 1);
    integer is_blacklisted = (level == ACL_BLACKLIST);
    create_session(user_key, level, is_blacklisted, context_filter);
    send_render_menu(user_key, context_filter);
    return TRUE;
}

integer find_pending_acl_idx(key avatar_key) {
    return llListFindList(PendingAclAvatars, [avatar_key]);
}

/* -------------------- SESSION MANAGEMENT -------------------- */

integer find_session_idx(key user) {
    return llListFindList(SessionUsers, [user]);
}

list get_session_filtered_indices(integer session_idx) {
    integer acl = llList2Integer(SessionACLs, session_idx);
    string ctx = llList2String(SessionContexts, session_idx);
    integer view_idx = llListFindList(VIEW_ACL_LEVELS, [acl]);
    if (view_idx == -1) return [];
    string json_array;
    if (ctx == SOS_CONTEXT) {
        json_array = llList2String(ViewSosIndices, view_idx);
    }
    else {
        json_array = llList2String(ViewRootIndices, view_idx);
    }
    if (json_array == "" || json_array == "[]") return [];
    return llJson2List(json_array);
}

cleanup_session(key user) {
    integer idx = find_session_idx(user);
    if (idx == -1) return;

    // BUGFIX: Close dialog before cleaning up session
    string session_id = llList2String(SessionIDs, idx);
    string close_msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.close",
        "session_id", session_id
    ]);
    llMessageLinked(LINK_SET, DIALOG_BUS, close_msg, NULL_KEY);

    // Remove session from parallel lists
    SessionUsers = llDeleteSubList(SessionUsers, idx, idx);
    SessionACLs = llDeleteSubList(SessionACLs, idx, idx);
    SessionBlacklisted = llDeleteSubList(SessionBlacklisted, idx, idx);
    SessionPages = llDeleteSubList(SessionPages, idx, idx);
    SessionTotalPages = llDeleteSubList(SessionTotalPages, idx, idx);
    SessionIDs = llDeleteSubList(SessionIDs, idx, idx);
    SessionCreatedTimes = llDeleteSubList(SessionCreatedTimes, idx, idx);
    SessionContexts = llDeleteSubList(SessionContexts, idx, idx);
}

create_session(key user, integer acl, integer is_blacklisted, string context_filter) {
    integer existing_idx = find_session_idx(user);
    if (existing_idx != -1) {
        cleanup_session(user);
    }

    if (llGetListLength(SessionUsers) >= MAX_SESSIONS) {
        key oldest_user = llList2Key(SessionUsers, 0);
        cleanup_session(oldest_user);
    }

    // Views supply filtered indices — no per-session policy scan needed.
    // Track session creation time
    string session_id = generate_session_id(user);
    integer created_time = llGetUnixTime();

    SessionUsers += [user];
    SessionACLs += [acl];
    SessionBlacklisted += [is_blacklisted];
    SessionPages += [0];
    SessionTotalPages += [0];
    SessionIDs += [session_id];
    SessionCreatedTimes += [created_time];
    SessionContexts += [context_filter];
}

/* -------------------- PLUGIN LIST MANAGEMENT -------------------- */

apply_plugin_list(string plugins_json) {
    // Clear parallel lists
    PluginContexts = [];
    PluginLabels = [];

    if (llJsonValueType(plugins_json, []) != JSON_ARRAY) {
        return;
    }

    // Temporary strided list for sorting
    list temp_plugins = [];
    integer SORT_STRIDE = 2;

    integer count = llGetListLength(llJson2List(plugins_json));

    integer i = 0;
    while (i < count) {
        string plugin_obj = llJsonGetValue(plugins_json, [i]);

        if ((llJsonGetValue(plugin_obj, ["context"]) != JSON_INVALID) &&
            (llJsonGetValue(plugin_obj, ["label"]) != JSON_INVALID)) {

            string context = llJsonGetValue(plugin_obj, ["context"]);
            string label = llJsonGetValue(plugin_obj, ["label"]);

            temp_plugins += [context, label];
        }

        i += 1;
    }

    // Sort once to avoid per-session sorting overhead
    if (llGetListLength(temp_plugins) > SORT_STRIDE) {
        temp_plugins = llListSortStrided(temp_plugins, SORT_STRIDE, 1, TRUE);
    }

    // Split into parallel lists
    i = 0;
    integer len = llGetListLength(temp_plugins);
    while (i < len) {
        PluginContexts += [llList2String(temp_plugins, i)];
        PluginLabels += [llList2String(temp_plugins, i + 1)];
        i += SORT_STRIDE;
    }
    // No ACL list request needed — policies are in LSD, written by plugins
    build_views();
}

// Builds the view tables for all ACL levels and both menu contexts.
// Called once after apply_plugin_list(). Per-touch cost: zero LSD reads.
build_views() {
    ViewRootIndices = [];
    ViewSosIndices = [];

    integer num_levels = llGetListLength(VIEW_ACL_LEVELS);
    integer plugin_count = llGetListLength(PluginContexts);

    integer lv = 0;
    while (lv < num_levels) {
        integer acl = llList2Integer(VIEW_ACL_LEVELS, lv);
        list root_idx = [];
        list sos_idx = [];

        integer i = 0;
        while (i < plugin_count) {
            string ctx = llList2String(PluginContexts, i);
            string policy = llLinksetDataRead("acl.policycontext:" + ctx);
            if (policy != "") {
                if (llJsonGetValue(policy, [(string)acl]) != JSON_INVALID) {
                    if (llSubStringIndex(ctx, SOS_PREFIX) == 0) {
                        sos_idx += [i];
                    }
                    else {
                        root_idx += [i];
                    }
                }
            }
            i++;
        }

        ViewRootIndices += [llList2Json(JSON_ARRAY, root_idx)];
        ViewSosIndices  += [llList2Json(JSON_ARRAY, sos_idx)];
        lv++;
    }
}

// apply_plugin_acl_list removed in v1.1 — ACL filtering via LSD policies

/* -------------------- MENU RENDERING (delegated to kmod_menu.lsl) -------------------- */

// Returns "[Honorific] Name" for the primary owner (single- or multi-owner mode),
// or "" when no owner is set.
string get_primary_owner_display() {
    // Single-owner mode
    string owner_uuid = llLinksetDataRead("access.owner");
    if (owner_uuid != "" && owner_uuid != NULL_KEY) {
        string owner_name = llLinksetDataRead("access.ownername");
        string honorific  = llLinksetDataRead("access.ownerhonorific");
        if (honorific != "") return honorific + " " + owner_name;
        return owner_name;
    }
    // Multi-owner mode — use first owner
    string names_csv = llLinksetDataRead("access.ownernames");
    if (names_csv != "") {
        list names_list = llCSV2List(names_csv);
        string first_name = llList2String(names_list, 0);
        if (first_name != "") {
            string hons_csv = llLinksetDataRead("access.ownerhonorifics");
            if (hons_csv != "") {
                string first_hon = llList2String(llCSV2List(hons_csv), 0);
                if (first_hon != "") return first_hon + " " + first_name;
            }
            return first_name;
        }
    }
    return "";
}

send_message(key user, string message_text) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.message.show",
        "user", (string)user,
        "message", message_text
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

send_render_menu(key user, string menu_type) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) {
        return;
    }

    list filtered_indices = get_session_filtered_indices(session_idx);
    integer plugin_count = llGetListLength(filtered_indices);

    if (plugin_count == 0) {
        integer user_acl = llList2Integer(SessionACLs, session_idx);
        integer is_blacklisted = llList2Integer(SessionBlacklisted, session_idx);

        if (menu_type == SOS_CONTEXT) {
            send_message(user, "No emergency options are currently available.");
        }
        else {
            if (user_acl == -1) {
                if (is_blacklisted) {
                    send_message(user, "You have been barred from using this collar.");
                }
                else {
                    string primary_owner = get_primary_owner_display();
                    if (primary_owner != "") {
                        send_message(user, "This collar is owned by " + primary_owner + " and is exclusive to them.");
                    }
                    else {
                        send_message(user, "This collar is not available for public use.");
                    }
                }
            }
            else if (user_acl == 0) {
                send_message(user, "You have relinquished control of the collar.");
            }
            else {
                send_message(user, "No plugins are currently installed.");
            }
        }

        cleanup_session(user);
        return;
    }

    integer current_page = llList2Integer(SessionPages, session_idx);

    integer total_pages = (plugin_count + MAX_FUNC_BTNS - 1) / MAX_FUNC_BTNS;
    if (current_page >= total_pages) current_page = 0;
    if (current_page < 0) current_page = total_pages - 1;

    // Update session state
    SessionPages = llListReplaceList(SessionPages, [current_page], session_idx, session_idx);
    SessionTotalPages = llListReplaceList(SessionTotalPages, [total_pages], session_idx, session_idx);

    // Build button data with context and state
    list button_data = [];
    integer start_idx = current_page * MAX_FUNC_BTNS;
    integer end_idx = start_idx + MAX_FUNC_BTNS;
    if (end_idx > plugin_count) {
        end_idx = plugin_count;
    }

    integer i = start_idx;
    while (i < end_idx) {
        integer plugin_idx = llList2Integer(filtered_indices, i);
        
        string context = llList2String(PluginContexts, plugin_idx);
        string label = llList2String(PluginLabels, plugin_idx);
        integer button_state = get_plugin_state(context);

        // Create button data object with context, label, and state
        string btn_obj = llList2Json(JSON_OBJECT, [
            "context", context,
            "label", label,
            "state", button_state
        ]);
        button_data += [btn_obj];
        i++;
    }

    string buttons_json = llList2Json(JSON_ARRAY, button_data);
    string session_id = llList2String(SessionIDs, session_idx);

    // DESIGN DECISION: Navigation row is ALWAYS present (DO NOT CHANGE)
    integer has_nav = 1;

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.menu.render",
        "user", (string)user,
        "session_id", session_id,
        "menu_type", menu_type,
        "page", current_page,
        "total_pages", total_pages,
        "buttons", buttons_json,
        "has_nav", has_nav
    ]);

    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

// Match a requested context to the longest registered plugin context that
// is either an exact match or a dot-boundary prefix. Returns the matched
// plugin context, or "" if none matches.
// Example: requested "ui.core.animate.pose.nadu" against registered
// ["ui.core.animate", "ui.core.lock"] returns "ui.core.animate".
string resolve_plugin_context(string requested) {
    integer exact = llListFindList(PluginContexts, [requested]);
    if (exact != -1) return requested;

    integer best_len = 0;
    string best = "";
    integer n = llGetListLength(PluginContexts);
    integer i = 0;
    while (i < n) {
        string pc = llList2String(PluginContexts, i);
        integer plen = llStringLength(pc);
        if (plen > best_len && llStringLength(requested) > plen) {
            if (llGetSubString(requested, 0, plen - 1) == pc &&
                llGetSubString(requested, plen, plen) == ".") {
                best = pc;
                best_len = plen;
            }
        }
        i++;
    }
    return best;
}

// Compute the subpath remainder after stripping a matched plugin context.
// resolve_plugin_context("ui.core.animate.pose.nadu", "ui.core.animate")
// returns "pose.nadu". Exact matches return "".
string extract_subpath(string requested, string plugin_context) {
    integer plen = llStringLength(plugin_context);
    if (llStringLength(requested) <= plen + 1) return "";
    return llGetSubString(requested, plen + 1, -1);
}

// Dispatch ui.menu.start to a specific plugin, with ACL from an existing session.
// Policy is re-checked here (LSD read) to catch changes since session creation.
// The subpath field carries namespaced subcommand args (e.g. "pose.nadu");
// plugins that ignore it keep menu-only behaviour.
dispatch_to_plugin(key user, string context, string subpath, integer session_idx) {
    integer user_acl = llList2Integer(SessionACLs, session_idx);
    string policy = llLinksetDataRead("acl.policycontext:" + context);
    if (policy == "") {
        send_message(user, "Access denied.");
        return;
    }
    string csv = llJsonGetValue(policy, [(string)user_acl]);
    if (csv == JSON_INVALID) {
        send_message(user, "Access denied.");
        return;
    }
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "ui.menu.start",
        "context", context,
        "subpath", subpath,
        "user",    (string)user,
        "acl",     user_acl
    ]), user);
}

handle_button_click(key user, string button, string context) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) {
        return;
    }

    // Blacklist gate
    integer is_blacklisted = llList2Integer(SessionBlacklisted, session_idx);
    if (is_blacklisted) {
        send_message(user, "You have been barred from using this collar.");
        cleanup_session(user);
        return;
    }

    integer current_page = llList2Integer(SessionPages, session_idx);
    integer total_pages = llList2Integer(SessionTotalPages, session_idx);
    string session_context = llList2String(SessionContexts, session_idx);

    // Handle navigation buttons (no context)
    if (button == "<<") {
        current_page -= 1;
        if (current_page < 0) current_page = total_pages - 1;
        SessionPages = llListReplaceList(SessionPages, [current_page], session_idx, session_idx);
        send_render_menu(user, session_context);
        return;
    }

    if (button == "Close") {
        cleanup_session(user);
        return;
    }

    if (button == ">>") {
        current_page += 1;
        if (current_page >= total_pages) current_page = 0;
        SessionPages = llListReplaceList(SessionPages, [current_page], session_idx, session_idx);
        send_render_menu(user, session_context);
        return;
    }

    // Plugin button clicked - use context directly for fast lookup.
    // Menu buttons always carry an exact plugin context; no subpath.
    if (context != "") {
        integer i = llListFindList(PluginContexts, [context]);
        if (i != -1) {
            dispatch_to_plugin(user, context, "", session_idx);
        }
        return;
    }
}

/* -------------------- PLUGIN LABEL UPDATE -------------------- */

update_plugin_label(string context, string new_label) {
    integer i = llListFindList(PluginContexts, [context]);
    
    if (i != -1) {
        PluginLabels = llListReplaceList(PluginLabels, [new_label], i, i);
        return;
    }
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_plugin_list(string msg) {
    if (llJsonGetValue(msg, ["plugins"]) == JSON_INVALID) {
        return;
    }

    string plugins_json = llJsonGetValue(msg, ["plugins"]);
    apply_plugin_list(plugins_json);

    // Invalidate all sessions when plugin list changes
    if (llGetListLength(SessionUsers) > 0) {
        // Close all dialogs before clearing sessions
        integer i = 0;
        integer len = llGetListLength(SessionIDs);
        while (i < len) {
            string session_id = llList2String(SessionIDs, i);
            string close_msg = llList2Json(JSON_OBJECT, [
                "type", "ui.dialog.close",
                "session_id", session_id
            ]);
            llMessageLinked(LINK_SET, DIALOG_BUS, close_msg, NULL_KEY);
            i++;
        }

        SessionUsers = [];
        SessionACLs = [];
        SessionBlacklisted = [];
        SessionPages = [];
        SessionTotalPages = [];
        SessionIDs = [];
        SessionCreatedTimes = [];
        SessionContexts = [];

        PendingAclAvatars = [];
        PendingAclContexts = [];
    }
}

handle_acl_result(string msg) {
    if (!validate_required_fields(msg, ["avatar", "level", "is_blacklisted"])) return;

    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    integer is_blacklisted = (integer)llJsonGetValue(msg, ["is_blacklisted"]);

    integer idx = find_pending_acl_idx(avatar);
    if (idx == -1) return;

    string requested_context = llList2String(PendingAclContexts, idx);
    
    PendingAclAvatars = llDeleteSubList(PendingAclAvatars, idx, idx);
    PendingAclContexts = llDeleteSubList(PendingAclContexts, idx, idx);

    if (requested_context == ROOT_CONTEXT || requested_context == SOS_CONTEXT) {
        create_session(avatar, level, is_blacklisted, requested_context);
        send_render_menu(avatar, requested_context);
    }
    else {
        // Plugin context from chat dispatch — create root session for navigation,
        // then dispatch directly to the plugin (with subpath if namespaced).
        create_session(avatar, level, is_blacklisted, ROOT_CONTEXT);
        integer session_idx = find_session_idx(avatar);
        if (session_idx != -1) {
            string matched = resolve_plugin_context(requested_context);
            if (matched != "") {
                string subpath = extract_subpath(requested_context, matched);
                dispatch_to_plugin(avatar, matched, subpath, session_idx);
            }
        }
    }
}

handle_start(string msg, key user_key) {
    // Messages with an acl field are already routed — destined for a plugin,
    // not for kmod_ui to process again.
    if (llJsonGetValue(msg, ["acl"]) != JSON_INVALID) return;

    if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) {
        start_root_session(user_key);
        return;
    }

    string context = llJsonGetValue(msg, ["context"]);

    if (context == ROOT_CONTEXT) {
        start_root_session(user_key);
        return;
    }

    if (context == SOS_CONTEXT) {
        start_sos_session(user_key);
        return;
    }

    // Plugin-specific context from kmod_chat dispatch. Longest-prefix match
    // handles namespaced subcommands (ui.core.animate.pose.nadu → animate +
    // subpath "pose.nadu"). ACL policy is checked on the matched parent.
    string matched = resolve_plugin_context(context);
    if (matched == "") {
        // Unrecognized context — unresolved alias or typo. Fall back to root
        // menu so the user gets something useful rather than silence.
        start_root_session(user_key);
        return;
    }
    string subpath = extract_subpath(context, matched);

    // Existing session — dispatch immediately using cached ACL.
    integer session_idx = find_session_idx(user_key);
    if (session_idx != -1) {
        dispatch_to_plugin(user_key, matched, subpath, session_idx);
        return;
    }

    // LSD cache hit — create root session for navigation then dispatch.
    string raw = llLinksetDataRead(LSD_ACL_CACHE_PREFIX + (string)user_key + LSD_ACL_CACHE_SUFFIX);
    if (raw != "") {
        integer sep = llSubStringIndex(raw, "|");
        if (sep != -1) {
            integer level = (integer)llGetSubString(raw, 0, sep - 1);
            create_session(user_key, level, (level == ACL_BLACKLIST), ROOT_CONTEXT);
            session_idx = find_session_idx(user_key);
            if (session_idx != -1) dispatch_to_plugin(user_key, matched, subpath, session_idx);
            return;
        }
    }

    // Cold miss — queue ACL query, store original requested context so the
    // subpath is preserved when handle_acl_result resumes dispatch.
    integer pending_idx = find_pending_acl_idx(user_key);
    if (pending_idx != -1) return;
    PendingAclAvatars += [user_key];
    PendingAclContexts += [context];
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type",   "auth.acl.query",
        "avatar", (string)user_key
    ]), NULL_KEY);
}

start_root_session(key user_key) {
    integer idx = find_pending_acl_idx(user_key);
    if (idx != -1) return;

    if (try_cached_session(user_key, ROOT_CONTEXT)) {
        return;
    }

    PendingAclAvatars += [user_key];
    PendingAclContexts += [ROOT_CONTEXT];

    string acl_query = llList2Json(JSON_OBJECT, [
        "type", "auth.acl.query",
        "avatar", (string)user_key
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, acl_query, NULL_KEY);
}

start_sos_session(key user_key) {
    integer idx = find_pending_acl_idx(user_key);
    if (idx != -1) return;

    if (try_cached_session(user_key, SOS_CONTEXT)) {
        return;
    }

    PendingAclAvatars += [user_key];
    PendingAclContexts += [SOS_CONTEXT];

    string acl_query = llList2Json(JSON_OBJECT, [
        "type", "auth.acl.query",
        "avatar", (string)user_key
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, acl_query, NULL_KEY);
}

handle_return(string msg) {
    string user_key_str = llJsonGetValue(msg, ["user"]);
    if (user_key_str == JSON_INVALID) return;
    key user_key = (key)user_key_str;

    // Re-validate stale sessions
    integer session_idx = find_session_idx(user_key);
    if (session_idx != -1) {
        integer created_time = llList2Integer(SessionCreatedTimes, session_idx);
        integer age = llGetUnixTime() - created_time;

        if (age > SESSION_MAX_AGE) {
            string session_context = llList2String(SessionContexts, session_idx);
            cleanup_session(user_key);

            if (session_context == SOS_CONTEXT) {
                start_sos_session(user_key);
            }
            else {
                start_root_session(user_key);
            }
        }
        else {
            string session_context = llList2String(SessionContexts, session_idx);
            send_render_menu(user_key, session_context);
        }
    }
    else {
        start_root_session(user_key);
    }
}

handle_update_label(string msg) {
    if (!validate_required_fields(msg, ["context", "label"])) return;

    string context = llJsonGetValue(msg, ["context"]);
    string new_label = llJsonGetValue(msg, ["label"]);

    update_plugin_label(context, new_label);
}

handle_update_state(string msg) {
    if (!validate_required_fields(msg, ["context", "state"])) return;

    string context = llJsonGetValue(msg, ["context"]);
    integer plugin_state = (integer)llJsonGetValue(msg, ["state"]);

    set_plugin_state(context, plugin_state);
}

// handle_plugin_acl_bus removed in v1.1 — ACL filtering via LSD policies

handle_dialog_response(string msg) {
    if (!validate_required_fields(msg, ["session_id", "button", "user"])) return;

    string session_id = llJsonGetValue(msg, ["session_id"]);
    string button = llJsonGetValue(msg, ["button"]);
    key user = (key)llJsonGetValue(msg, ["user"]);

    // Extract context (may be empty string for navigation buttons)
    string context = "";
    string tmp = llJsonGetValue(msg, ["context"]);
    if (tmp != JSON_INVALID) {
        context = tmp;
    }

    integer idx = llListFindList(SessionIDs, [session_id]);
    if (idx != -1) {
        handle_button_click(user, button, context);
        return;
    }
}

handle_dialog_timeout(string msg) {
    if (!validate_required_fields(msg, ["session_id", "user"])) return;

    string session_id = llJsonGetValue(msg, ["session_id"]);
    key user = (key)llJsonGetValue(msg, ["user"]);

    integer idx = llListFindList(SessionIDs, [session_id]);
    if (idx != -1) {
        cleanup_session(user);
    }
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        PluginContexts = [];
        PluginLabels = [];
        
        SessionUsers = [];
        SessionACLs = [];
        SessionBlacklisted = [];
        SessionPages = [];
        SessionTotalPages = [];
        SessionIDs = [];
        SessionCreatedTimes = [];
        SessionContexts = [];

        ViewRootIndices = [];
        ViewSosIndices = [];

        PendingAclAvatars = [];
        PendingAclContexts = [];
        
        TouchKeys = [];
        TouchStartTimes = [];
        
        PluginStateContexts = [];
        PluginStateValues = [];
        
        // Advertise root menu context so kmod_chat can build a 'menu' alias
        llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
            "type",    "kernel.register.declare",
            "context", ROOT_CONTEXT,
            "label",   "Menu",
            "script",  llGetScriptName()
        ]), NULL_KEY);

        // Request plugin list (kernel defers response during active registration)
        string request = llList2Json(JSON_OBJECT, [
            "type", "kernel.plugins.request"
        ]);
        llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, request, NULL_KEY);
    }
    
    touch_start(integer num_detected) {
        integer i = 0;
        while (i < num_detected) {
            key toucher = llDetectedKey(i);
            vector touch_pos = llDetectedTouchPos(i);

            // Skip invalid touches
            if (touch_pos == ZERO_VECTOR) {
                i += 1;
                jump next_touch;
            }

            // Validate touch distance
            float distance = llVecDist(touch_pos, llGetPos());
            if (distance > TOUCH_RANGE_M) {
                i += 1;
                jump next_touch;
            }

            // Record touch start time
            integer idx = llListFindList(TouchKeys, [toucher]);
            if (idx != -1) {
                TouchStartTimes = llListReplaceList(TouchStartTimes, [llGetTime()], idx, idx);
            } else {
                TouchKeys += [toucher];
                TouchStartTimes += [llGetTime()];
            }

            @next_touch;
            i += 1;
        }
    }

    touch_end(integer num_detected) {
        key wearer = llGetOwner();
        integer i = 0;

        while (i < num_detected) {
            key toucher = llDetectedKey(i);

            integer idx = llListFindList(TouchKeys, [toucher]);
            if (idx != -1) {
                float start_time = llList2Float(TouchStartTimes, idx);
                float duration = llGetTime() - start_time;

                TouchKeys = llDeleteSubList(TouchKeys, idx, idx);
                TouchStartTimes = llDeleteSubList(TouchStartTimes, idx, idx);

                if (duration >= LONG_TOUCH_THRESHOLD && toucher == wearer) {
                    start_sos_session(toucher);
                }
                else {
                    // Provide feedback if non-wearer attempted long-touch (SOS is wearer-only)
                    if (duration >= LONG_TOUCH_THRESHOLD && toucher != wearer) {
                        send_message(toucher, "Long-touch SOS is only available to the wearer.");
                    }
                    start_root_session(toucher);
                }
            }

            i += 1;
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.plugins.list") handle_plugin_list(msg);
            else if (msg_type == "kernel.register.refresh") {
                // Re-emit synthetic registration so kmod_chat rebuilds its alias table.
                llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
                    "type",    "kernel.register.declare",
                    "context", ROOT_CONTEXT,
                    "label",   "Menu",
                    "script",  llGetScriptName()
                ]), NULL_KEY);
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            return;
        }

        /* -------------------- AUTH BUS -------------------- */
        if (num == AUTH_BUS) {
            if (msg_type == "auth.acl.result") handle_acl_result(msg);
            else if (msg_type == "auth.acl.update") {
                // ACL roles changed (ownership, trustees, public, TPE, etc.)
                // Invalidate all active sessions so they re-create with fresh ACL
                // on next touch. This prevents stale ACL from granting wrong buttons.
                integer si = llGetListLength(SessionUsers) - 1;
                while (si >= 0) {
                    key sess_user = llList2Key(SessionUsers, si);
                    cleanup_session(sess_user);
                    si--;
                }
            }
            return;
        }

        /* -------------------- UI BUS -------------------- */
        if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") handle_start(msg, id);
            else if (msg_type == "ui.chat.command") handle_start(msg, id);
            else if (msg_type == "ui.menu.return") handle_return(msg);
            else if (msg_type == "ui.label.update") handle_update_label(msg);
            else if (msg_type == "ui.state.update") handle_update_state(msg);
            return;
        }

        /* -------------------- DIALOG BUS -------------------- */
        if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") handle_dialog_response(msg);
            else if (msg_type == "ui.dialog.timeout") handle_dialog_timeout(msg);
            return;
        }
    }
    
    // Reset on owner change
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
