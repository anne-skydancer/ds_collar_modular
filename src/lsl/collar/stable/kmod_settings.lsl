/*--------------------
MODULE: kmod_settings.lsl
VERSION: 1.10
REVISION: 4
PURPOSE: Notecard parser, validation guards, and LSD settings store
ARCHITECTURE: Two-mode access model. Single-owner mode uses scalar keys
              (access.owner, access.ownername, access.ownerhonorific) and
              is set via the menu UI. Multi-owner mode uses parallel CSVs
              (access.owneruuids/names/honorifics) and is set ONLY via the
              settings notecard. Mode is selected by access.multiowner.
              Trustees and blacklist always use CSVs. Display names are
              resolved asynchronously via llRequestDisplayName.
CHANGES:
- v1.1 rev 4: Notecard parser now accepts the documented JSON object form
  for owners and trustees: access.owner = {uuid: honorific} (single mode),
  access.owners = {uuid: hon, ...} (multi mode), and access.trustees =
  {uuid: hon, ...}. Previously only bare-UUID/CSV legacy forms were parsed,
  so the documented notecard format silently produced empty owner/trustee
  state. Bare-UUID forms still work for back-compat.
- v1.1 rev 3: Replace JSON object owner/trustee storage with explicit
  two-mode flat scheme (scalars for single-owner, parallel CSVs for
  multi-owner). Async display name resolution. access.isowned = 0
  triggers factory reset. New API messages: set_owner, clear_owner,
  add_trustee, remove_trustee, blacklist_add, blacklist_remove, runaway.
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
// Sentinel and mode
string KEY_ISOWNED          = "access.isowned";
string KEY_MULTI_OWNER_MODE = "access.multiowner";

// Single-owner mode (scalars)
string KEY_OWNER            = "access.owner";
string KEY_OWNER_NAME       = "access.ownername";
string KEY_OWNER_HONORIFIC  = "access.ownerhonorific";

// Multi-owner mode (parallel CSVs, notecard only)
string KEY_OWNER_UUIDS        = "access.owneruuids";
string KEY_OWNER_NAMES        = "access.ownernames";
string KEY_OWNER_HONORIFICS   = "access.ownerhonorifics";

// Trustees (parallel CSVs)
string KEY_TRUSTEE_UUIDS      = "access.trusteeuuids";
string KEY_TRUSTEE_NAMES      = "access.trusteenames";
string KEY_TRUSTEE_HONORIFICS = "access.trusteehonorifics";

// Blacklist (CSV of UUIDs only)
string KEY_BLACKLIST          = "blacklist.blklistuuid";

// Other access flags
string KEY_RUNAWAY_ENABLED    = "access.enablerunaway";

// Behaviour scalars
string KEY_PUBLIC_ACCESS = "public.mode";
string KEY_TPE_MODE      = "tpe.mode";
string KEY_LOCKED        = "lock.locked";

// Placeholder used while a display name is being resolved
string NAME_LOADING = "(loading...)";

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

// Pending display-name queries: parallel lists.
// Role values: "owner_scalar", "owner_csv", "trustee_csv"
list NameQueryIds   = [];
list NameQueryUuids = [];
list NameQueryRoles = [];

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

list csv_read(string key_name) {
    string raw = llLinksetDataRead(key_name);
    if (raw == "") return [];
    return llCSV2List(raw);
}

csv_write(string key_name, list values) {
    if (llGetListLength(values) == 0) {
        llLinksetDataDelete(key_name);
    }
    else {
        llLinksetDataWrite(key_name, llList2CSV(values));
    }
}

list list_remove_at(list source_list, integer idx) {
    return llDeleteSubList(source_list, idx, idx);
}

integer is_multi_owner_mode() {
    return (integer)llLinksetDataRead(KEY_MULTI_OWNER_MODE);
}

/* -------------------- BROADCASTING -------------------- */

broadcast_settings_changed() {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings_sync"
    ]), NULL_KEY);
}

/* -------------------- LSD CLEAR & FACTORY RESET -------------------- */

clear_owner_keys() {
    // Clear both single and multi-owner key sets, plus the sentinel.
    llLinksetDataDelete(KEY_ISOWNED);
    llLinksetDataDelete(KEY_OWNER);
    llLinksetDataDelete(KEY_OWNER_NAME);
    llLinksetDataDelete(KEY_OWNER_HONORIFIC);
    llLinksetDataDelete(KEY_OWNER_UUIDS);
    llLinksetDataDelete(KEY_OWNER_NAMES);
    llLinksetDataDelete(KEY_OWNER_HONORIFICS);
}

clear_trustee_keys() {
    llLinksetDataDelete(KEY_TRUSTEE_UUIDS);
    llLinksetDataDelete(KEY_TRUSTEE_NAMES);
    llLinksetDataDelete(KEY_TRUSTEE_HONORIFICS);
}

factory_reset() {
    llRegionSayTo(llGetOwner(), 0, "Collar factory reset triggered.");
    llLinksetDataReset();

    // Reset all scripts in the linkset
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "soft_reset_all",
        "from", "factory_reset"
    ]), NULL_KEY);

    llResetScript();
}

/* -------------------- VALIDATION HELPERS -------------------- */

// Returns TRUE if any external owner exists (not the wearer, not NULL_KEY)
integer has_external_owner() {
    key wearer = llGetOwner();

    if (is_multi_owner_mode()) {
        list uuids = csv_read(KEY_OWNER_UUIDS);
        integer i;
        integer len = llGetListLength(uuids);
        for (i = 0; i < len; i++) {
            key owner = (key)llList2String(uuids, i);
            if (owner != wearer && owner != NULL_KEY) return TRUE;
        }
        return FALSE;
    }

    key primary = (key)llLinksetDataRead(KEY_OWNER);
    if (primary != NULL_KEY && primary != wearer) return TRUE;
    return FALSE;
}

integer is_owner(string who) {
    if (is_multi_owner_mode()) {
        return (llListFindList(csv_read(KEY_OWNER_UUIDS), [who]) != -1);
    }
    return (llLinksetDataRead(KEY_OWNER) == who);
}

integer is_trustee(string who) {
    return (llListFindList(csv_read(KEY_TRUSTEE_UUIDS), [who]) != -1);
}

/* -------------------- ASYNC NAME RESOLUTION -------------------- */

request_name(string uuid_str, string role) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return;
    key qid = llRequestDisplayName((key)uuid_str);
    NameQueryIds   += [qid];
    NameQueryUuids += [uuid_str];
    NameQueryRoles += [role];
}

handle_name_response(key query_id, string name) {
    integer idx = llListFindList(NameQueryIds, [query_id]);
    if (idx == -1) return;

    string uuid_str = llList2String(NameQueryUuids, idx);
    string role     = llList2String(NameQueryRoles, idx);

    NameQueryIds   = list_remove_at(NameQueryIds, idx);
    NameQueryUuids = list_remove_at(NameQueryUuids, idx);
    NameQueryRoles = list_remove_at(NameQueryRoles, idx);

    if (name == "") return;

    if (role == "owner_scalar") {
        // Confirm the uuid still matches before writing
        if (llLinksetDataRead(KEY_OWNER) == uuid_str) {
            llLinksetDataWrite(KEY_OWNER_NAME, name);
            broadcast_settings_changed();
        }
        return;
    }

    if (role == "owner_csv") {
        list uuids = csv_read(KEY_OWNER_UUIDS);
        integer slot = llListFindList(uuids, [uuid_str]);
        if (slot == -1) return;
        list names = csv_read(KEY_OWNER_NAMES);
        while (llGetListLength(names) <= slot) names += [NAME_LOADING];
        names = llListReplaceList(names, [name], slot, slot);
        csv_write(KEY_OWNER_NAMES, names);
        broadcast_settings_changed();
        return;
    }

    if (role == "trustee_csv") {
        list uuids = csv_read(KEY_TRUSTEE_UUIDS);
        integer slot = llListFindList(uuids, [uuid_str]);
        if (slot == -1) return;
        list names = csv_read(KEY_TRUSTEE_NAMES);
        while (llGetListLength(names) <= slot) names += [NAME_LOADING];
        names = llListReplaceList(names, [name], slot, slot);
        csv_write(KEY_TRUSTEE_NAMES, names);
        broadcast_settings_changed();
    }
}

/* -------------------- INTERNAL MUTATORS -------------------- */

// Single-owner: write the scalar trio. Also sets isowned and clears any
// stale multi-owner CSV data.
integer set_single_owner(string uuid_str, string honorific) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return FALSE;
    if ((key)uuid_str == llGetOwner()) {
        llOwnerSay("ERROR: Cannot add wearer as owner (role separation required)");
        return FALSE;
    }

    // Role exclusivity: drop from trustees and blacklist
    remove_trustee_internal(uuid_str);
    remove_blacklist_internal(uuid_str);

    // Clear multi-owner CSVs (we are in single-owner mode now)
    llLinksetDataDelete(KEY_OWNER_UUIDS);
    llLinksetDataDelete(KEY_OWNER_NAMES);
    llLinksetDataDelete(KEY_OWNER_HONORIFICS);
    llLinksetDataDelete(KEY_MULTI_OWNER_MODE);

    llLinksetDataWrite(KEY_OWNER, uuid_str);
    llLinksetDataWrite(KEY_OWNER_NAME, NAME_LOADING);
    llLinksetDataWrite(KEY_OWNER_HONORIFIC, honorific);
    llLinksetDataWrite(KEY_ISOWNED, "1");

    request_name(uuid_str, "owner_scalar");
    return TRUE;
}

clear_single_owner() {
    llLinksetDataDelete(KEY_OWNER);
    llLinksetDataDelete(KEY_OWNER_NAME);
    llLinksetDataDelete(KEY_OWNER_HONORIFIC);
    llLinksetDataDelete(KEY_ISOWNED);
}

integer add_trustee_internal(string uuid_str, string honorific) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return FALSE;
    if ((key)uuid_str == llGetOwner()) return FALSE;
    if (is_owner(uuid_str)) return FALSE;

    list uuids = csv_read(KEY_TRUSTEE_UUIDS);
    if (llListFindList(uuids, [uuid_str]) != -1) return FALSE;
    if (llGetListLength(uuids) >= MaxListLen) return FALSE;

    remove_blacklist_internal(uuid_str);

    list names = csv_read(KEY_TRUSTEE_NAMES);
    list hons  = csv_read(KEY_TRUSTEE_HONORIFICS);

    uuids += [uuid_str];
    names += [NAME_LOADING];
    hons  += [honorific];

    csv_write(KEY_TRUSTEE_UUIDS,      uuids);
    csv_write(KEY_TRUSTEE_NAMES,      names);
    csv_write(KEY_TRUSTEE_HONORIFICS, hons);

    request_name(uuid_str, "trustee_csv");
    return TRUE;
}

integer remove_trustee_internal(string uuid_str) {
    list uuids = csv_read(KEY_TRUSTEE_UUIDS);
    integer idx = llListFindList(uuids, [uuid_str]);
    if (idx == -1) return FALSE;

    list names = csv_read(KEY_TRUSTEE_NAMES);
    list hons  = csv_read(KEY_TRUSTEE_HONORIFICS);

    uuids = list_remove_at(uuids, idx);
    if (idx < llGetListLength(names)) names = list_remove_at(names, idx);
    if (idx < llGetListLength(hons))  hons  = list_remove_at(hons,  idx);

    csv_write(KEY_TRUSTEE_UUIDS,      uuids);
    csv_write(KEY_TRUSTEE_NAMES,      names);
    csv_write(KEY_TRUSTEE_HONORIFICS, hons);
    return TRUE;
}

integer add_blacklist_internal(string uuid_str) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return FALSE;
    if ((key)uuid_str == llGetOwner()) return FALSE;
    if (is_owner(uuid_str)) return FALSE;
    if (is_trustee(uuid_str)) return FALSE;

    list bl = csv_read(KEY_BLACKLIST);
    if (llListFindList(bl, [uuid_str]) != -1) return FALSE;
    if (llGetListLength(bl) >= MaxListLen) return FALSE;

    bl += [uuid_str];
    csv_write(KEY_BLACKLIST, bl);
    return TRUE;
}

integer remove_blacklist_internal(string uuid_str) {
    list bl = csv_read(KEY_BLACKLIST);
    integer idx = llListFindList(bl, [uuid_str]);
    if (idx == -1) return FALSE;
    bl = list_remove_at(bl, idx);
    csv_write(KEY_BLACKLIST, bl);
    return TRUE;
}

/* -------------------- NOTECARD-ONLY KEYS -------------------- */

// Keys that may only be set via notecard, not the runtime API
integer is_notecard_only_key(string k) {
    if (k == KEY_MULTI_OWNER_MODE) return TRUE;
    if (k == KEY_OWNER_UUIDS)      return TRUE;
    if (k == KEY_OWNER_NAMES)      return TRUE;
    if (k == KEY_OWNER_HONORIFICS) return TRUE;
    return FALSE;
}

/* -------------------- NOTECARD PARSING -------------------- */

parse_notecard_line(string line) {
    line = llStringTrim(line, STRING_TRIM);
    if (line == "") return;
    if (llGetSubString(line, 0, 0) == COMMENT_PREFIX) return;

    integer sep_pos = llSubStringIndex(line, SEPARATOR);
    if (sep_pos == -1) return;

    string key_name = llStringTrim(llGetSubString(line, 0, sep_pos - 1), STRING_TRIM);
    string value    = llStringTrim(llGetSubString(line, sep_pos + 1, -1), STRING_TRIM);

    // Multi-owner mode flag
    if (key_name == KEY_MULTI_OWNER_MODE) {
        llLinksetDataWrite(KEY_MULTI_OWNER_MODE, normalize_bool(value));
        return;
    }

    // Single-owner: documented notecard form is {uuid: honorific}.
    // Bare-UUID legacy form is still accepted for back-compat.
    if (key_name == KEY_OWNER) {
        if (llJsonValueType(value, []) == JSON_OBJECT) {
            list pairs = llJson2List(value);
            if (llGetListLength(pairs) < 2) return;
            string uuid_str = llList2String(pairs, 0);
            string hon      = llList2String(pairs, 1);
            key u = (key)uuid_str;
            if (u == NULL_KEY || u == llGetOwner()) return;
            llLinksetDataWrite(KEY_OWNER, uuid_str);
            llLinksetDataWrite(KEY_OWNER_NAME, NAME_LOADING);
            llLinksetDataWrite(KEY_OWNER_HONORIFIC, hon);
            llLinksetDataWrite(KEY_ISOWNED, "1");
            request_name(uuid_str, "owner_scalar");
            return;
        }
        key u = (key)value;
        if (u == NULL_KEY || u == llGetOwner()) return;
        llLinksetDataWrite(KEY_OWNER, value);
        if (llLinksetDataRead(KEY_OWNER_NAME) == "") {
            llLinksetDataWrite(KEY_OWNER_NAME, NAME_LOADING);
        }
        llLinksetDataWrite(KEY_ISOWNED, "1");
        request_name(value, "owner_scalar");
        return;
    }

    // Multi-owner (documented notecard form): access.owners = {uuid: hon, ...}
    if (key_name == "access.owners") {
        if (llJsonValueType(value, []) != JSON_OBJECT) return;
        list pairs = llJson2List(value);
        integer plen = llGetListLength(pairs);
        list uuids = [];
        list hons  = [];
        list names = [];
        integer pi = 0;
        while (pi < plen) {
            string uuid_str = llList2String(pairs, pi);
            string hon      = llList2String(pairs, pi + 1);
            key u = (key)uuid_str;
            if (u != NULL_KEY && u != llGetOwner()) {
                uuids += [uuid_str];
                hons  += [hon];
                names += [NAME_LOADING];
                request_name(uuid_str, "owner_csv");
            }
            pi += 2;
        }
        if (llGetListLength(uuids) > MaxListLen) {
            uuids = llList2List(uuids, 0, MaxListLen - 1);
            hons  = llList2List(hons,  0, MaxListLen - 1);
            names = llList2List(names, 0, MaxListLen - 1);
        }
        csv_write(KEY_OWNER_UUIDS,      uuids);
        csv_write(KEY_OWNER_NAMES,      names);
        csv_write(KEY_OWNER_HONORIFICS, hons);
        if (llGetListLength(uuids) > 0) {
            llLinksetDataWrite(KEY_ISOWNED, "1");
        }
        return;
    }

    // Trustees (documented notecard form): access.trustees = {uuid: hon, ...}
    if (key_name == "access.trustees") {
        if (llJsonValueType(value, []) != JSON_OBJECT) return;
        list pairs = llJson2List(value);
        integer plen = llGetListLength(pairs);
        list uuids = [];
        list hons  = [];
        list names = [];
        integer pi = 0;
        while (pi < plen) {
            string uuid_str = llList2String(pairs, pi);
            string hon      = llList2String(pairs, pi + 1);
            key u = (key)uuid_str;
            if (u != NULL_KEY && u != llGetOwner() && !is_owner(uuid_str)) {
                uuids += [uuid_str];
                hons  += [hon];
                names += [NAME_LOADING];
                request_name(uuid_str, "trustee_csv");
            }
            pi += 2;
        }
        if (llGetListLength(uuids) > MaxListLen) {
            uuids = llList2List(uuids, 0, MaxListLen - 1);
            hons  = llList2List(hons,  0, MaxListLen - 1);
            names = llList2List(names, 0, MaxListLen - 1);
        }
        csv_write(KEY_TRUSTEE_UUIDS,      uuids);
        csv_write(KEY_TRUSTEE_NAMES,      names);
        csv_write(KEY_TRUSTEE_HONORIFICS, hons);
        return;
    }

    if (key_name == KEY_OWNER_HONORIFIC) {
        llLinksetDataWrite(KEY_OWNER_HONORIFIC, value);
        return;
    }

    // Multi-owner CSVs (notecard only)
    if (key_name == KEY_OWNER_UUIDS) {
        list uuids = llCSV2List(value);
        if (llGetListLength(uuids) > MaxListLen) {
            uuids = llList2List(uuids, 0, MaxListLen - 1);
        }
        list valid = [];
        integer i;
        integer len = llGetListLength(uuids);
        for (i = 0; i < len; i++) {
            key u = (key)llList2String(uuids, i);
            if (u != NULL_KEY && u != llGetOwner()) {
                valid += [(string)u];
                request_name((string)u, "owner_csv");
            }
        }
        csv_write(KEY_OWNER_UUIDS, valid);
        // Initialize names CSV with placeholders
        list placeholders = [];
        integer pi = 0;
        integer plen = llGetListLength(valid);
        while (pi < plen) {
            placeholders += [NAME_LOADING];
            pi += 1;
        }
        csv_write(KEY_OWNER_NAMES, placeholders);
        if (llGetListLength(valid) > 0) {
            llLinksetDataWrite(KEY_ISOWNED, "1");
        }
        return;
    }

    if (key_name == KEY_OWNER_HONORIFICS) {
        list hons = llCSV2List(value);
        csv_write(KEY_OWNER_HONORIFICS, hons);
        return;
    }

    // Trustees CSVs
    if (key_name == KEY_TRUSTEE_UUIDS) {
        list uuids = llCSV2List(value);
        if (llGetListLength(uuids) > MaxListLen) {
            uuids = llList2List(uuids, 0, MaxListLen - 1);
        }
        list valid = [];
        integer i;
        integer len = llGetListLength(uuids);
        for (i = 0; i < len; i++) {
            key u = (key)llList2String(uuids, i);
            if (u != NULL_KEY && u != llGetOwner() && !is_owner((string)u)) {
                valid += [(string)u];
                request_name((string)u, "trustee_csv");
            }
        }
        csv_write(KEY_TRUSTEE_UUIDS, valid);
        list placeholders = [];
        integer pi = 0;
        integer plen = llGetListLength(valid);
        while (pi < plen) {
            placeholders += [NAME_LOADING];
            pi += 1;
        }
        csv_write(KEY_TRUSTEE_NAMES, placeholders);
        return;
    }

    if (key_name == KEY_TRUSTEE_HONORIFICS) {
        list hons = llCSV2List(value);
        csv_write(KEY_TRUSTEE_HONORIFICS, hons);
        return;
    }

    // Blacklist CSV
    if (key_name == KEY_BLACKLIST) {
        list bl = llCSV2List(value);
        if (llGetListLength(bl) > MaxListLen) {
            bl = llList2List(bl, 0, MaxListLen - 1);
        }
        list valid = [];
        integer i;
        integer len = llGetListLength(bl);
        for (i = 0; i < len; i++) {
            key u = (key)llList2String(bl, i);
            if (u != NULL_KEY && u != llGetOwner() && !is_owner((string)u) && !is_trustee((string)u)) {
                valid += [(string)u];
            }
        }
        csv_write(KEY_BLACKLIST, valid);
        return;
    }

    // Boolean scalars
    if (key_name == KEY_PUBLIC_ACCESS
        || key_name == KEY_LOCKED
        || key_name == KEY_RUNAWAY_ENABLED
        || key_name == KEY_ISOWNED) {
        llLinksetDataWrite(key_name, normalize_bool(value));
        return;
    }

    // TPE — requires external owner
    if (key_name == KEY_TPE_MODE) {
        value = normalize_bool(value);
        if ((integer)value == 1 && !has_external_owner()) {
            llOwnerSay("ERROR: Cannot enable TPE via notecard - requires external owner");
            llOwnerSay("HINT: Set owner BEFORE tpe.mode in notecard");
            return;
        }
        llLinksetDataWrite(KEY_TPE_MODE, value);
        return;
    }

    // Generic plugin scalars (any other dotted key) — write through
    if (llSubStringIndex(key_name, ".") != -1) {
        llLinksetDataWrite(key_name, value);
    }
}

integer start_notecard_reading() {
    if (llGetInventoryType(NOTECARD_NAME) != INVENTORY_NOTECARD) {
        return FALSE;
    }
    // Notecard is canonical for ownership data — clear it before reading
    // so removed entries don't persist as stale data.
    clear_owner_keys();
    clear_trustee_keys();
    llLinksetDataDelete(KEY_BLACKLIST);

    IsLoadingNotecard = TRUE;
    NotecardLine = 0;
    NotecardQuery = llGetNotecardLine(NOTECARD_NAME, NotecardLine);
    return TRUE;
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_settings_get() {
    broadcast_settings_changed();
}

// Generic scalar set for non-access keys (and a few access scalars).
// Owner/trustee/blacklist data must use the dedicated handlers below.
handle_set(string msg) {
    string key_name = llJsonGetValue(msg, ["key"]);
    if (key_name == JSON_INVALID) return;
    if (is_notecard_only_key(key_name)) return;

    string value = llJsonGetValue(msg, ["value"]);
    if (value == JSON_INVALID) return;

    // Refuse direct writes to managed access lists
    if (key_name == KEY_OWNER
        || key_name == KEY_OWNER_NAME
        || key_name == KEY_OWNER_HONORIFIC
        || key_name == KEY_TRUSTEE_UUIDS
        || key_name == KEY_TRUSTEE_NAMES
        || key_name == KEY_TRUSTEE_HONORIFICS
        || key_name == KEY_BLACKLIST) {
        return;
    }

    // Boolean normalization
    if (key_name == KEY_PUBLIC_ACCESS
        || key_name == KEY_LOCKED
        || key_name == KEY_RUNAWAY_ENABLED
        || key_name == KEY_ISOWNED) {
        value = normalize_bool(value);
    }

    // TPE validation
    if (key_name == KEY_TPE_MODE) {
        value = normalize_bool(value);
        if ((integer)value == 1 && !has_external_owner()) {
            llOwnerSay("ERROR: Cannot enable TPE - requires external owner");
            return;
        }
    }

    // isowned = 0 → factory reset trigger
    if (key_name == KEY_ISOWNED && value == "0") {
        factory_reset();
        return;
    }

    if (llLinksetDataRead(key_name) == value) return;
    llLinksetDataWrite(key_name, value);
    broadcast_settings_changed();
}

handle_set_owner(string msg) {
    if (is_multi_owner_mode()) {
        llOwnerSay("ERROR: Cannot set owner via menu in multi-owner mode (notecard managed)");
        return;
    }

    string uuid_str  = llJsonGetValue(msg, ["uuid"]);
    string honorific = llJsonGetValue(msg, ["honorific"]);
    if (uuid_str == JSON_INVALID || honorific == JSON_INVALID) return;

    if (set_single_owner(uuid_str, honorific)) {
        broadcast_settings_changed();
    }
}

handle_clear_owner() {
    if (is_multi_owner_mode()) {
        llOwnerSay("ERROR: Cannot clear owner via menu in multi-owner mode (notecard managed)");
        return;
    }
    clear_single_owner();
    broadcast_settings_changed();
}

handle_add_trustee(string msg) {
    string uuid_str  = llJsonGetValue(msg, ["uuid"]);
    string honorific = llJsonGetValue(msg, ["honorific"]);
    if (uuid_str == JSON_INVALID || honorific == JSON_INVALID) return;

    if (add_trustee_internal(uuid_str, honorific)) {
        broadcast_settings_changed();
    }
}

handle_remove_trustee(string msg) {
    string uuid_str = llJsonGetValue(msg, ["uuid"]);
    if (uuid_str == JSON_INVALID) return;

    if (remove_trustee_internal(uuid_str)) {
        broadcast_settings_changed();
    }
}

handle_blacklist_add(string msg) {
    string uuid_str = llJsonGetValue(msg, ["uuid"]);
    if (uuid_str == JSON_INVALID) return;

    if (add_blacklist_internal(uuid_str)) {
        broadcast_settings_changed();
    }
}

handle_blacklist_remove(string msg) {
    string uuid_str = llJsonGetValue(msg, ["uuid"]);
    if (uuid_str == JSON_INVALID) return;

    if (remove_blacklist_internal(uuid_str)) {
        broadcast_settings_changed();
    }
}

handle_runaway() {
    factory_reset();
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
            key current_notecard_key = llGetInventoryKey(NOTECARD_NAME);
            if (current_notecard_key != NotecardKey) {
                if (current_notecard_key == NULL_KEY) {
                    // Notecard removed → factory reset
                    factory_reset();
                }
                else {
                    NotecardKey = current_notecard_key;
                    start_notecard_reading();
                }
            }
        }
    }

    dataserver(key query_id, string data) {
        // Notecard line read
        if (query_id == NotecardQuery) {
            if (data != EOF) {
                parse_notecard_line(data);
                NotecardLine += 1;
                NotecardQuery = llGetNotecardLine(NOTECARD_NAME, NotecardLine);
            }
            else {
                IsLoadingNotecard = FALSE;
                broadcast_settings_changed();

                // Trigger bootstrap completion
                llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
                    "type", "notecard_loaded"
                ]), NULL_KEY);
            }
            return;
        }

        // Display name response
        handle_name_response(query_id, data);
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num != SETTINGS_BUS) return;
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        if      (msg_type == "settings_get")     handle_settings_get();
        else if (msg_type == "set")              handle_set(msg);
        else if (msg_type == "set_owner")        handle_set_owner(msg);
        else if (msg_type == "clear_owner")      handle_clear_owner();
        else if (msg_type == "add_trustee")      handle_add_trustee(msg);
        else if (msg_type == "remove_trustee")   handle_remove_trustee(msg);
        else if (msg_type == "blacklist_add")    handle_blacklist_add(msg);
        else if (msg_type == "blacklist_remove") handle_blacklist_remove(msg);
        else if (msg_type == "runaway")          handle_runaway();
    }
}
