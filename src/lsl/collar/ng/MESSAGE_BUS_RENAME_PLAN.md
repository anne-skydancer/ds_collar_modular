# Message Bus Rename Plan

Wire-only restructuring of `"type"` field values across the consolidated
link-message buses. LSD keys and notecard format are out of scope. External
protocol types (sent via `llRegionSay` to third-party tools) are also
out of scope — renaming them would break compatibility with OpenCollar,
Lockmeister, external HUDs.

## Principles

1. **Families** share a prefix so one dispatcher can route the group (e.g.
   `settings.owner.*` handled by a single `handle_owner_mutation`).
2. **Singletons** keep flat names — no forced grouping where no siblings
   exist. Don't reserve names for hypothetical future types.
3. **Semantic grouping, not token splitting.** `kernel.registernow` is not
   just `register` + `now`; it's related to `kernel.register` by domain
   (both concern the registration lifecycle), so they become siblings
   under `kernel.register.*` using distinct verbs.
4. **No wire breakage in mid-pass.** Each bus migrates atomically —
   producers and consumers in the same commit; no overlap window.
5. **Reserve nothing.** If a row below marks "no change", it's because
   the name is already correct, not because we're reserving the slot.

## Column legend

- **Old → New**: current wire string → proposed wire string.
- **Tag**: `family` (has siblings under the prefix), `singleton` (no
  siblings today), or `same` (no change).
- **Why**: one-line justification — ignore for `same`.

---

## 500 KERNEL_LIFECYCLE

| Old | New | Tag | Why |
|---|---|---|---|
| `kernel.register` | `kernel.register.declare` | family | Plugin→kernel declaration; pairs with `refresh`. |
| `kernel.registernow` | `kernel.register.refresh` | family | Kernel→plugins re-declaration request. |
| `kernel.ping` | `kernel.ping` | same | Heartbeat; no family benefit. |
| `kernel.pong` | `kernel.pong` | same | Heartbeat; no family benefit. |
| `kernel.pluginlist` | `kernel.plugins.list` | family | Response body; pairs with `request`. |
| `kernel.pluginlistrequest` | `kernel.plugins.request` | family | Request broadcast; pairs with `list`. |
| `kernel.reset` | `kernel.reset.soft` | family | Per-module/scoped reset. |
| `kernel.resetall` | `kernel.reset.factory` | family | Factory wipe (name now states intent). |
| `chat.alias.register` | `chat.alias.declare` | singleton | Parallel to `kernel.register.declare` vocabulary. Alone in its namespace today. |
| `settings.notecardloaded` | `settings.notecard.loaded` | singleton | Standard dot insertion at word boundary. |

## 700 AUTH_BUS

| Old | New | Tag | Why |
|---|---|---|---|
| `auth.aclquery` | `auth.acl.query` | family | Makes `auth.acl.*` a coherent dispatch group. |
| `auth.aclresult` | `auth.acl.result` | family | Same family. |
| `auth.aclupdate` | `auth.acl.update` | family | Same family. |

## 800 SETTINGS_BUS

| Old | New | Tag | Why |
|---|---|---|---|
| `settings.sync` | `settings.sync` | same | Generic broadcast. |
| `settings.delta` | `settings.delta` | same | See reference doc — producer still unresolved; don't rename until traced. |
| `settings.get` | `settings.get` | same | Generic sync trigger. |
| `settings.set` | `settings.set` | same | Generic scalar write (carries `key` field). |
| `settings.setowner` | `settings.owner.set` | family | Pairs with `clear`; opens `settings.owner.*` dispatcher. |
| `settings.clearowner` | `settings.owner.clear` | family | Pairs with `set`. |
| `settings.addtrustee` | `settings.trustee.add` | family | Pairs with `remove`; opens `settings.trustee.*` dispatcher. |
| `settings.removetrustee` | `settings.trustee.remove` | family | Pairs with `add`. |
| `settings.blacklistadd` | `settings.blacklist.add` | family | Pairs with `remove`; opens `settings.blacklist.*` dispatcher. |
| `settings.blacklistremove` | `settings.blacklist.remove` | family | Pairs with `add`. |
| `settings.runaway` | `settings.runaway` | same | Emergency factory reset; unique action. |

## 900 UI_BUS — core UI routing

| Old | New | Tag | Why |
|---|---|---|---|
| `ui.chat.command` | `ui.chat.command` | same | Already correct shape. |
| `ui.menu.start` | `ui.menu.start` | same | `ui.menu.*` already exists as a family. |
| `ui.menu.return` | `ui.menu.return` | same | Same. |
| `ui.menu.render` | `ui.menu.render` | same | Same. |
| `ui.message.show` | `ui.message.show` | same | Already correct shape. |
| `ui.label.update` | `ui.label.update` | same | Singleton, clear name. |
| `ui.state.update` | `ui.state.update` | same | Singleton, clear name. |

## 900 UI_BUS — particles sub-protocol

| Old | New | Tag | Why |
|---|---|---|---|
| `particles.start` | `particles.start` | same | Generic chain control. |
| `particles.stop` | `particles.stop` | same | Generic chain control. |
| `particles.update` | `particles.update` | same | Generic chain control. |
| `particles.lmenable` | `particles.lm.enable` | family | Groups Lockmeister protocol under `particles.lm.*`. |
| `particles.lmdisable` | `particles.lm.disable` | family | Same family. |
| `particles.lmgrabbed` | `particles.lm.grabbed` | family | Same family. |
| `particles.lmreleased` | `particles.lm.released` | family | Same family. |

## 900 UI_BUS — leash sub-protocol (internal)

| Old | New | Tag | Why |
|---|---|---|---|
| `plugin.leash.action` | `plugin.leash.action` | same | Carries sub-action in `action` field; renaming adds noise. |
| `plugin.leash.state` | `plugin.leash.state` | same | Single state broadcast. |
| `plugin.leash.offerpending` | `plugin.leash.offer.pending` | singleton | Dot at word boundary. No siblings today, but clearer. |

## 900 UI_BUS — SOS sub-protocol

| Old | New | Tag | Why |
|---|---|---|---|
| `sos.leashrelease` | `sos.leash.release` | singleton | Dot at word boundary. No `sos.leash.*` siblings; still clearer. |
| `sos.restrictclear` | `sos.restrict.clear` | singleton | Same rationale. |
| `sos.relayclear` | `sos.relay.clear` | singleton | Same rationale. |

## 950 DIALOG_BUS

| Old | New | Tag | Why |
|---|---|---|---|
| `ui.dialog.open` | `ui.dialog.open` | same | `ui.dialog.*` already correct. |
| `ui.dialog.close` | `ui.dialog.close` | same | Same. |
| `ui.dialog.response` | `ui.dialog.response` | same | Same. |
| `ui.dialog.timeout` | `ui.dialog.timeout` | same | Same. |

## Out of scope

External protocols (on `llRegionSay` channels, not link-messages) are
**not** renamed. Changing them would break wire compatibility with
third-party tools.

| Type | Channel | Reason |
|---|---|---|
| `remote.collarscan` / `remote.collarscanresponse` / `remote.collarready` | -8675309 / -8675310 | HUD discovery protocol. |
| `plugin.leash.request` / `plugin.leash.target` | -192837465 | Native holder protocol; external objects reply. |
| `auth.aclqueryexternal` / `auth.aclresultexternal` | external | HUD access check. |

---

## Dispatch families that emerge

Buses where a single prefix-match dispatcher replaces an if/else ladder
after rename:

- `kernel.register.*` — 2 types (declare, refresh)
- `kernel.plugins.*` — 2 types (list, request)
- `kernel.reset.*` — 2 types (soft, factory)
- `auth.acl.*` — 3 types (query, result, update)
- `settings.owner.*` — 2 types (set, clear)
- `settings.trustee.*` — 2 types (add, remove)
- `settings.blacklist.*` — 2 types (add, remove)
- `particles.lm.*` — 4 types (enable, disable, grabbed, released)
- `ui.menu.*` — 3 types (start, return, render) — already a family today
- `ui.dialog.*` — 4 types (open, close, response, timeout) — already a family today

Singletons and generic broadcasts stay on exact-match handlers.

## Migration order

One bus per pass; each pass is a single commit with all producers and
consumers updated together.

1. KERNEL_LIFECYCLE — 10 types, touches kernel + every plugin (high surface but mechanical).
2. AUTH_BUS — 3 types, producer is kmod_auth, consumers are kmod_ui + every plugin that queries.
3. SETTINGS_BUS — 7 renames, producers/consumers scattered; largest risk.
4. UI_BUS — split into three sub-passes: core UI, particles, leash/SOS.
5. DIALOG_BUS — no renames; skip.

Rev bump and changelog entry per file touched, per the repository convention.

---

**Plan version:** 1.0
**Status:** Draft — awaiting approval before any code changes.
