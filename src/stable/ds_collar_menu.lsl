/*--------------------
MODULE: ds_collar_menu.lsl
VERSION: 1.00
REVISION: 11
PURPOSE: Menu rendering and visual presentation service
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Updated to support parallel arrays for buttons and contexts
- Optimized reordering logic to handle split data streams
- Reduced JSON parsing overhead by passing raw lists
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- HELPERS -------------------- */


integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
string get_msg_type(string msg) {
    if (!json_has(msg, ["type"])) return "";
    return llJsonGetValue(msg, ["type"]);
}


// MEMORY OPTIMIZATION: Compact field validation helper
// Validates multiple required JSON fields and logs errors for missing ones
// Returns TRUE if all fields present, FALSE if any missing
integer validate_required_fields(string json_str, list field_names, string function_name) {
    integer i = 0;
    integer len = llGetListLength(field_names);
    while (i < len) {
        string field = llList2String(field_names, i);
        if (!json_has(json_str, [field])) {
            return FALSE;
        }
        i += 1;
    }
    return TRUE;
}

/* -------------------- BUTTON LAYOUT -------------------- */

list reorder_list_for_display(list items, string pad_char) {
    // Reorder buttons for natural reading (left-to-right, top-to-bottom)
    // LSL dialog positions: [9-11]=top, [6-8]=mid, [3-5]=low, [0-2]=bottom
    // We chunk the list into rows of 3, pad them to ensure alignment,
    // and then reverse the order of the rows.

    integer count = llGetListLength(items);
    if (count == 0) return [];

    list result = [];
    integer row_size = 3;
    integer i = 0;

    while (i < count) {
        // Get chunk of buttons for this row
        // llList2List handles out-of-bounds end index by clamping to list end
        list chunk = llList2List(items, i, i + row_size - 1);
        
        // Pad chunk if incomplete to maintain alignment
        // This ensures that when this row is stacked above others,
        // it doesn't "steal" buttons from the row above it in the dialog layout
        integer chunk_len = llGetListLength(chunk);
        while (chunk_len < row_size) {
            chunk += [pad_char];
            chunk_len++;
        }
        
        // Prepend to result (reversing the order of rows)
        // Row 0 (Top) becomes the last row in the list
        // Row N (Bottom) becomes the first row in the list
        result = chunk + result;
        
        i += row_size;
    }
    
    return result;
}

/* -------------------- RENDERING -------------------- */

render_menu(string msg) {
    // Validate required fields
    if (!validate_required_fields(msg, ["user", "session_id", "menu_type", "buttons", "contexts"], "render_menu")) {
        return;
    }

    // Extract fields
    key user = (key)llJsonGetValue(msg, ["user"]);
    string session_id = llJsonGetValue(msg, ["session_id"]);
    string menu_type = llJsonGetValue(msg, ["menu_type"]);
    integer current_page = (integer)llJsonGetValue(msg, ["page"]);
    integer total_pages = (integer)llJsonGetValue(msg, ["total_pages"]);
    string buttons_json = llJsonGetValue(msg, ["buttons"]);
    string contexts_json = llJsonGetValue(msg, ["contexts"]);
    integer has_nav = (integer)llJsonGetValue(msg, ["has_nav"]);

    // Parse parallel arrays
    list button_list = llJson2List(buttons_json);
    list context_list = llJson2List(contexts_json);

    // Reorder for natural display
    list reordered_buttons = reorder_list_for_display(button_list, "-");
    list reordered_contexts = reorder_list_for_display(context_list, "");

    // DESIGN DECISION: Navigation row is ALWAYS present (DO NOT CHANGE)
    list final_buttons = [];
    list final_contexts = [];
    
    if (has_nav) {
        final_buttons = ["<<", ">>", "Close"] + reordered_buttons;
        final_contexts = ["", "", ""] + reordered_contexts;
    }
    else {
        final_buttons = ["Close"] + reordered_buttons;
        final_contexts = [""] + reordered_contexts;
    }

    // Construct title based on menu type
    string title = "";
    if (menu_type == "core_root") {
        title = "Main Menu";
    }
    else if (menu_type == "sos_root") {
        title = "Emergency Menu";
    }
    else {
        title = "Menu";
    }

    // Add page numbers if multi-page
    if (total_pages > 1) {
        title = title + " (" + (string)(current_page + 1) + "/" + (string)total_pages + ")";
    }

    // Construct body based on menu type
    string body_text = "";
    if (menu_type == "core_root") {
        body_text = "Select an option:";
    }
    else if (menu_type == "sos_root") {
        body_text = "Emergency options:";
    }
    else {
        body_text = "Choose:";
    }

    // Send to dialog bus with split arrays
    string dialog_msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", session_id,
        "user", (string)user,
        "title", title,
        "body", body_text,
        "buttons", llList2Json(JSON_ARRAY, final_buttons),
        "contexts", llList2Json(JSON_ARRAY, final_contexts),
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, dialog_msg, NULL_KEY);
}

show_message(string msg) {
    if (!validate_required_fields(msg, ["user", "message"], "show_message")) {
        return;
    }

    key user = (key)llJsonGetValue(msg, ["user"]);
    string message_text = llJsonGetValue(msg, ["message"]);

    llRegionSayTo(user, 0, message_text);
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
    }

    link_message(integer sender_num, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        if (num == UI_BUS) {
            if (msg_type == "render_menu") {
                render_menu(msg);
            }
            else if (msg_type == "show_message") {
                show_message(msg);
            }
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
