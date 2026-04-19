# Message Bus Reference — dev branch

Reference for every JSON `"type"` string exchanged on the consolidated
`llMessageLinked` buses in `src/lsl/collar/dev/`. Use this when adding or
wiring a new module.

## Bus numbers

| Constant | Number | Scope |
|---|---|---|
| `KERNEL_LIFECYCLE` | 500 | Plugin registration, lifecycle, soft/factory reset |
| `AUTH_BUS` | 700 | ACL queries and cache invalidation |
| `SETTINGS_BUS` | 800 | Settings read/write + sync broadcasts |
| `UI_BUS` | 900 | Menu/chat routing, UI updates, particles, leash state |
| `DIALOG_BUS` | 950 | Dialog open/close/response/timeout |

External protocols (not on any bus, transmitted via `llRegionSay`/`llRegionSayTo`)
are listed at the bottom.

---

## 500 — KERNEL_LIFECYCLE

### `kernel.register`
Plugin -> Kernel, Kernel -> kmod_chat (for alias table).
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes | `"kernel.register"` |
| `context` | string | yes | Plugin context (e.g. `"ui.core.animate"`) |
| `label` | string | yes | Human label and default chat alias |
| `script` | string | yes | `llGetScriptName()` of the plugin |

### `kernel.registernow`
Broadcast -> all plugins. Tells every plugin to re-emit `kernel.register`.
Sender: kmod_chat (on state_entry), kmod_ui (on state_entry), kernel (on rediscover).
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |

### `kernel.ping` / `kernel.pong`
Kernel <-> plugin heartbeat.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes | `"kernel.ping"` or `"kernel.pong"` |
| `context` | string | yes on pong | Plugin context echoing the ping |

### `kernel.pluginlistrequest`
Requester -> Kernel. Asks kernel to broadcast `kernel.pluginlist`.
Sender: kmod_ui (state_entry).
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |

### `kernel.pluginlist`
Kernel -> kmod_ui.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes | `"kernel.pluginlist"` |
| `plugins` | JSON array | yes | Each element `{context, label}` |

### `kernel.reset` / `kernel.resetall`
Broadcast. Soft module reset (self-reset) vs factory reset trigger.
Plugin-scoped resets may include a `context` field to target one plugin;
unscoped = everyone resets.
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |
| `context` | string | no |

### `chat.alias.register` (rev 13)
Plugin -> kmod_chat only. Declares a chat subcommand root (e.g. `"pose"`
for animate). Invisible to the kernel plugin list.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes | `"chat.alias.register"` |
| `alias` | string | yes | Lowercase alias word (`"pose"`) |
| `context` | string | yes | Full namespaced context (`"ui.core.animate.pose"`) |

### `settings.notecardloaded`
kmod_settings -> kernel. Notecard parse complete on cold start.
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |

---

## 700 — AUTH_BUS

### `auth.aclquery`
Plugin/UI -> kmod_auth. Request ACL level.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `avatar` | string UUID | yes | Subject of the query |
| `id` | string | no | Correlation id echoed on result |

### `auth.aclresult`
kmod_auth -> plugin/UI.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `avatar` | string UUID | yes | Subject |
| `level` | integer | yes | -1 blacklist, 0..5 escalating |
| `is_wearer` | integer bool | yes |  |
| `is_blacklisted` | integer bool | yes |  |
| `owner_set` | integer bool | yes | Whether primary owner configured |
| `id` | string | no | Echo of query correlation id |

### `auth.aclupdate`
kmod_auth -> everyone. ACL state changed; consumers invalidate caches /
re-render menus.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `scope` | string | yes | `"global"` or avatar UUID |
| `avatar` | string UUID | yes | Changed user, or empty for global |

---

## 800 — SETTINGS_BUS

### `settings.sync`
kmod_settings -> everyone. LSD settings reloaded; consumers re-read their keys.
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |

### `settings.delta` (consumer-only; producer missing in dev)
Treated identically to `settings.sync` by kmod_chat rev 12 and plugin_chat
rev 5. No producer found in the current dev tree. Either legacy or a
planned optimization.

### `settings.get`
Caller -> kmod_settings. Force a `settings.sync` broadcast.
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |

### `settings.set`
Caller -> kmod_settings. Generic scalar write.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `key` | string | yes | LSD key (e.g. `"chat.prefix"`) |
| `value` | string | yes | Serialized scalar (`"0"`/`"1"` for bools) |

### `settings.setowner`
Caller -> kmod_settings.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `uuid` | string UUID | yes | New primary owner |
| `honorific` | string | yes | Title prepended to display name |

### `settings.clearowner`
Caller -> kmod_settings. Unowned mode.
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |

### `settings.addtrustee` / `settings.removetrustee`
Caller -> kmod_settings.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `uuid` | string UUID | yes |  |
| `honorific` | string | add only |  |

### `settings.blacklistadd` / `settings.blacklistremove`
Caller -> kmod_settings. Role-exclusive (adding blacklist removes owner/trustee).
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |
| `uuid` | string UUID | yes |

### `settings.runaway`
Caller -> kmod_settings. Factory reset (wearer / ACL 0).
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |

---

## 900 — UI_BUS

### `ui.chat.command`
kmod_chat -> kmod_ui only. kmod_ui routes onward via `ui.menu.start`.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `context` | string | yes | Resolved full context, may include subpath |
| `source` | string | no | `"chat"` — origin tag |

### `ui.menu.start`
kmod_ui -> plugin. Plugins MUST ignore messages without an `acl` field
(rejects raw kmod_chat broadcasts).
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `context` | string | yes | Plugin's own context |
| `subpath` | string | no | Namespaced subcommand remainder (e.g. `"pose.nadu"`). Empty or absent = open menu. |
| `user` | string UUID | yes | Invoking avatar |
| `acl` | integer | yes | Pre-verified ACL level |

### `ui.menu.return`
Plugin -> kmod_ui. Return to the session's menu context.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `context` | string | no | Source plugin context (log only) |
| `user` | string UUID | yes |  |

### `ui.menu.render`
kmod_ui -> kmod_menu. Paginated menu payload.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `user` | string UUID | yes |  |
| `session_id` | string | yes |  |
| `menu_type` | string | yes | `"ui.core.root"` or `"ui.sos.root"` |
| `page` | integer | yes |  |
| `total_pages` | integer | yes |  |
| `buttons` | JSON array | yes | Each `{context, label, state}` |
| `has_nav` | integer bool | yes | Always 1 in current code |

### `ui.message.show`
Any -> kmod_menu. Lightweight console/chat message, no dialog.
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |
| `user` | string UUID | yes |
| `message` | string | yes |

### `ui.label.update`
Plugin -> kmod_ui. Retarget a plugin's menu button label (e.g. Lock/Unlock toggle).
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |
| `context` | string | yes |
| `label` | string | yes |

### `ui.state.update`
Plugin -> kmod_ui. Set visual pressed/active state of a plugin's button.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `context` | string | yes |  |
| `state` | integer bool | yes | 0 unpressed, 1 toggled/active |

### Particles sub-protocol (lives on UI_BUS)

#### `particles.start`
Leash -> particles.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `source` | string | yes | Originating plugin context |
| `target` | string UUID | yes | Avatar/prim to render to |
| `style` | string | yes | `"chain"` (reserved for variants) |

#### `particles.stop`
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |
| `source` | string | no |

#### `particles.update`
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |
| `target` | string UUID | yes |

#### `particles.lmenable` / `particles.lmdisable`
Leash <-> particles. Toggle Lockmeister protocol mode.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `controller` | string UUID | enable only | LM holder |

#### `particles.lmgrabbed` / `particles.lmreleased`
Particles -> leash. LM holder state change notifications.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `controller` | string UUID | grabbed | Holder avatar |
| `prim` | string UUID | grabbed | Holder prim |

### Leash sub-protocol (lives on UI_BUS)

#### `plugin.leash.action`
Plugin -> kmod_leash. ACL-verified.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `action` | string | yes | `"grab"`, `"release"`, `"force_release"`, `"query"`, ... |

#### `plugin.leash.state`
kmod_leash -> UI/plugins. Broadcast after state change.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `leashed` | integer bool | yes |  |
| `leasher` | string UUID | yes | May be `NULL_KEY` when unleashed |
| `length` | integer | yes | Metres |
| `turnto` | integer bool | yes |  |
| `mode` | integer | yes | 0 avatar, 1 coffle, 2 post |

#### `plugin.leash.offerpending`
kmod_leash -> UI. Visual cue that an offer is in flight.
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |
| `target` | string UUID | yes |
| `originator` | string UUID | yes |

### SOS sub-protocol (lives on UI_BUS)

#### `sos.leashrelease`
SOS plugin -> kmod_leash. Emergency release.
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |

#### `sos.restrictclear`
SOS plugin -> RLV/restrict modules. Clear all restrictions.
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |

#### `sos.relayclear`
SOS plugin -> relay module. Clear relay restrictions.
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |

---

## 950 — DIALOG_BUS

### `ui.dialog.open`
Caller -> kmod_dialog.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `session_id` | string | yes | Unique per dialog |
| `user` | string UUID | yes |  |
| `title` | string | yes |  |
| `body` | string | yes | Plugins also use `message` in places — see inconsistencies. |
| `button_data` | JSON array | yes | Each `{label, context}` |
| `timeout` | integer | no | Seconds; default 60 |

### `ui.dialog.close`
Caller -> kmod_dialog.
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |
| `session_id` | string | yes |

### `ui.dialog.response`
kmod_dialog -> caller.
| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | string | yes |  |
| `session_id` | string | yes |  |
| `button` | string | yes | Raw button label pressed |
| `context` | string | no | Associated command context if button carried one |
| `user` | string UUID | yes |  |

### `ui.dialog.timeout`
kmod_dialog -> caller.
| Field | Type | Req |
|---|---|---|
| `type` | string | yes |
| `session_id` | string | yes |
| `user` | string UUID | yes |

---

## External protocols (not on any bus)

Transmitted via `llRegionSay`/`llRegionSayTo` on fixed negative channels.

| Direction | Channel | Message | Fields |
|---|---|---|---|
| HUD scan -> collar | -8675309 | `remote.collarscan` | type |
| Collar -> HUD reply | -8675310 | `remote.collarscanresponse` | type, collar, wearer |
| Collar -> HUD | varies | `remote.collarready` | type, collar |
| Collar -> holder | -192837465 | `plugin.leash.request` | type, wearer, collar, controller, session, origin |
| Holder -> collar | -192837465 | `plugin.leash.target` | type, ok, holder, session, name |
| HUD -> collar | varies | `auth.aclqueryexternal` | type |
| Collar -> HUD | varies | `auth.aclresultexternal` | type, level |

---

## Encoding rules

Follow these when authoring a new message or module. Three different
layers force three different encodings; don't blur them.

1. **Integers in JSON messages: pass native integer, no `(string)` cast.**
   `llList2Json(JSON_OBJECT, ["flag", MyInt, ...])` emits unquoted JSON
   numbers. Consumers use `(integer)llJsonGetValue(...)` which coerces
   cleanly. Casting to string produces JSON strings like `"0"` — still
   decodes, but larger on the wire and out of idiom. See kmod_auth
   templates for the reference pattern.
2. **`key` values in JSON messages: `(string)` cast is required.** JSON
   has no key type; keys must be serialized as strings. `(string)NULL_KEY`
   is fine.
3. **LSD values are always strings.** `llLinksetDataWrite` is string-only.
   Booleans go through `normalize_bool()` in kmod_settings so they land
   as canonical `"0"` / `"1"`. Integers use `(string)n`.
4. **Optional fields: omit the key rather than sending a sentinel.**
   Consumers check `llJsonGetValue(...) == JSON_INVALID`. Example:
   `ui.menu.start.subpath` is absent when opening a menu, present when
   executing a subcommand.

## Known issues

1. **`settings.delta` has consumers but no producer** in dev. Consumed
   identically to `settings.sync` by kmod_chat and plugin_chat. Either
   legacy or planned — trace before depending on.
2. **Dialog body field name.** `ui.dialog.open` uses `body` in newer
   modules (plugin_chat rev 5) and `message` in older ones (plugin_animate).
   Dialog manager currently accepts both; do not rely on this silently
   continuing.
3. **UI_BUS is overloaded.** Menu routing, particles, leash state, and SOS
   emergency broadcasts all share 900. Functionally fine today; if the
   router grows, splitting `PLUGIN_BUS` out is an option.
4. **Plugins must filter raw kmod_chat broadcasts.** Any `ui.menu.start`
   without an `acl` field is unrouted; plugins MUST drop it or risk
   duplicate dialogs when a plugin label prefix-matches the chat prefix.

---

**Document version:** 1.0
**Last updated:** 2026-04-19
**Covers:** dev branch as of kmod_chat rev 13 / kmod_ui rev 9 / plugin_animate rev 4
