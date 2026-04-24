# Chat Command Plan

Proposed chat command surface for every plugin. Framework is the
namespaced subcommand system from Phase 2 of the chat redesign:

- Each plugin emits `chat.alias.declare` entries at registration
  mapping an **alias word** to a **namespaced context**.
- `<prefix> <alias> [arg1 arg2 ...]` resolves head→context and appends
  tail tokens as a dot-path. The plugin receives the remainder as
  `subpath` on its `ui.menu.start` message and either:
  - opens its menu (empty subpath), or
  - executes the named action directly (non-empty subpath).
- **ACL: inherited from menu policy.** If the plugin's menu is visible
  to you, you can run its chat commands. The plugin gates per-action
  via `btn_allowed()` using the existing policy CSV.

## Alias style

Three patterns, each used where it reads best — don't force uniformity:

- **Single alias, verb as arg** (e.g. `pose <name>`, `folders attach <name>`)
- **Single alias, verb suffix** (e.g. `leash clip`, `leash unclip`)
- **Paired aliases** (e.g. `lock`, `unlock`, `safeword`)

---

## plugin_animate (`ui.core.animate`) — implemented

| Command | Action | Notes |
|---|---|---|
| `animate` | Open animate menu | Label alias (auto). |
| `pose <name>` | Play named animation | Done. |
| `pose stop` | Stop current animation | Special-cased; inventory anim literally named "stop" unreachable via chat. |
| `stand` | Stop current animation | Paired alias, equivalent to `pose stop`. |

## plugin_leash (`ui.core.leash`)

Mostly verb-suffix under a single `leash` alias. `unclip` is not a
second alias — `leash unclip` is less ambiguous than a bare `unclip`
which could mean anything.

| Command | Action |
|---|---|
| `leash` | Open leash menu |
| `leash clip` | Grab (leash the wearer to speaker) |
| `leash unclip` | Release |
| `leash pass <username>` | Hand leash to another avatar |
| `leash length <m>` | Change length in metres |
| `leash turn` | Toggle turn-to-face |

Notes:
- `clip` target defaults to speaker (same as menu "Grab").
- `leash pass` takes **SL username** (`firstname.lastname` or mononame),
  not UUID — UUIDs aren't chat-typeable. Resolution via `llName2Key`
  requires the avatar to be in-sim at command time (fine — can't leash
  to someone who isn't present anyway).
- **Dot-parsing caveat**: `leash pass alice.wonder` arrives as subpath
  `pass.alice.wonder`. Plugin splits on `.` → [pass, alice, wonder],
  then dot-joins tokens[1..] to reconstruct the username.

## plugin_lock (`ui.core.lock`)

Single alias, state-as-arg. The passive form reads as "set lock state to X" rather than an imperative, matching the mental model of a stateful lock.

| Command | Action |
|---|---|
| `lock` | Open lock menu (empty subpath) |
| `lock locked` | Set lock state to locked |
| `lock unlocked` | Set lock state to unlocked |

## plugin_public (`ui.core.public`)

Single alias, verb-suffix.

| Command | Action |
|---|---|
| `public` | Open public access menu |
| `public on` | Enable public access |
| `public off` | Disable public access |

## plugin_bell (`ui.core.bell`)

| Command | Action |
|---|---|
| `bell` | Open bell menu |
| `bell show` / `bell hide` | Visibility toggle |
| `bell jingle` | Manual jingle |

## plugin_status (`ui.core.status`)

Read-only, so just one command.

| Command | Action |
|---|---|
| `status` | Show status report |

## plugin_chat (`ui.core.chat`)

Meta — mistyping could break the prefix. Chat-driven changes are risky; recommend **menu-only**.

| Command | Action | Notes |
|---|---|---|
| `chatcfg` | Open chat config menu | Use a distinct alias so `chat` isn't ambiguous. |

## plugin_access (`ui.core.access`)

Chat enters the existing menu flows. No username in chat — consent,
honorific selection, and confirmation dialogs all live in the menu
path and must not be bypassed.

| Command | Action |
|---|---|
| `access` | Open access menu |
| `access add owner` | Enter "Add Owner" flow (sensor pick + honorific + consent) |
| `access rem owner` | Enter "Remove Owner" flow (single-mode: confirm; multi-mode: pick from list) |
| `access add trustee` | Enter "Add Trustee" flow (sensor pick + honorific + consent) |
| `access rem trustee` | Enter "Remove Trustee" flow (pick from existing) |

## plugin_blacklist (`ui.core.blacklist`)

Chat enters the existing menu flows. No username in chat — sensor-based
avatar selection lives in the menu path and handles visual confirmation.

| Command | Action |
|---|---|
| `blacklist` | Open blacklist menu |
| `blacklist add` | Enter "Add to Blacklist" flow (sensor pick) |
| `blacklist rem` | Enter "Remove from Blacklist" flow (pick from existing) |

## plugin_maint (`ui.core.maint`)

Destructive actions (kernel reset, factory reset, clear leash). All confirmation-driven. Recommend **menu-only**.

| Command | Action |
|---|---|
| `maint` | Open maintenance menu |

## plugin_tpe (`ui.core.tpe`)

TPE enable/disable requires wearer confirmation. Menu-only preserves the confirm dialog. Recommend **menu-only**.

| Command | Action |
|---|---|
| `tpe` | Open TPE menu |

## plugin_folders (`ui.core.folders`)

| Command | Action |
|---|---|
| `folders` | Open folder menu |
| `folders lock <folder>` | Lock folder |
| `folders unlock <folder>` | Unlock folder |
| `folders attach <folder>` | Attach folder |
| `folders detach <folder>` | Detach folder |

**Folder names containing dots are not accessible via chat.** Parsing
`subpath` splits on `.` — any folder name with a literal dot would be
ambiguous with the action/arg separator. If the parsed token count is
> 2 (action + one name fragment), the plugin rejects with a "use the
menu for this folder" message. Folders like `#RLV/boots.v2` or
`#RLV/outfit.gorean` must be managed via menu.

## plugin_restrict (`ui.core.restrict`)

Individual toggles are per-category, per-name. Chat surface for each is awkward. Recommend **menu-only for individual toggles, chat for emergency clear**.

| Command | Action |
|---|---|
| `restrict` | Open restrict menu |
| `restrict clear` | Remove all RLV restrictions |

## plugin_rlvex (`ui.core.rlvex`)

Exceptions for owner/trustee/public, separate categories (tp, im). Arg-heavy. Recommend **menu-only**.

| Command | Action |
|---|---|
| `rlvex` | Open RLV exceptions menu |

## plugin_relay (`ui.core.relay`)

Mode toggle and safeword. `safeword` deserves its own alias — it's the wearer's panic verb.

| Command | Action |
|---|---|
| `relay` | Open relay menu |
| `relay on` | Enable relay |
| `relay off` | Disable relay |
| `relay ask` | Switch to ask mode |
| `safeword` | Emergency clear (bypasses Hardcore) |

Note: `safeword` as a standalone alias makes it typeable under panic without needing to remember the plugin name.

## plugin_sos (`ui.sos.root`)

Emergency wearer-only. SOS menu is already long-touch gated. Chat should mirror but reject non-wearers.

| Command | Action |
|---|---|
| `sos` | Open SOS menu |
| `sosunleash` | Emergency unleash |
| `sosrestrict` | Emergency clear RLV restrictions |
| `sosrelay` | Emergency safeword relay |

Paired-alias style for the individual emergencies since each is a distinct panic action.

---

## Cross-cutting considerations

1. **UUID parsing.** Several commands take a UUID (`leash pass`, maybe trustee/owner ops if we ever add them). Need a helper to accept either a 36-char UUID or a region-resolvable short name. Out-of-session; plan for when first implementation needs it.
2. **Folder / name with dots.** `plugin_folders` subcommand tail could contain dots in folder names. Either restrict or have the plugin re-split its received subpath string carefully.
3. **Case sensitivity.** `kmod_chat.command_is_known()` lowercases the head. If aliases are declared as `"Safeword"` vs `"safeword"`, the lowercased form wins. Plugins should declare aliases in lowercase.
4. **Alias collision across plugins.** `kmod_chat.register_alias` is first-wins with an owner warning (Phase 1 addition). If two plugins claim `bell` or `lock`, the second is dropped; the full namespaced form still works. Keep aliases unique.
5. **SOS aliases need the wearer gate.** SOS plugin's ACL policy is wearer-only. The inherited-ACL model handles this automatically: non-wearers won't pass the policy check on dispatch, so `sosunleash` from a non-wearer is rejected at the dispatch layer.

---

## Implementation checklist

Per plugin, implementation is:

1. Emit `chat.alias.declare` messages at registration for each alias.
2. In `ui.menu.start` handler, read `subpath`. If non-empty, parse and execute.
3. Gate each parsed action through `btn_allowed("<button name>")` as per the menu flow.
4. Bump REVISION, add terse changelog entry.
5. lslint clean.

Plugins to implement (in order of likely chat usefulness):

- [x] plugin_animate — reference implementation (done)
- [ ] plugin_leash
- [ ] plugin_lock
- [ ] plugin_public
- [ ] plugin_bell
- [ ] plugin_status
- [ ] plugin_relay (incl. `safeword` alias)
- [ ] plugin_sos (emergency aliases)
- [ ] plugin_restrict (chat: `clear` only)
- [ ] plugin_folders (reject names containing dots)
- [ ] plugin_access (chat → existing menu flows)
- [ ] plugin_blacklist (chat → existing menu flows)

Deferred (menu-only):
- plugin_chat, plugin_maint, plugin_tpe, plugin_rlvex

---

## Resolved decisions (v1.1)

1. **plugin_lock**: single alias with state-as-arg. `lock` opens menu; `lock locked` / `lock unlocked` set the state directly.
2. **plugin_public**: single alias, verb-suffix. `public` opens menu; `public on` / `public off` toggle state.
3. **plugin_folders**: forbid folder names containing dots. Plugin rejects any chat subcommand whose name token-count exceeds 1 after the action; those folders must be managed via menu.
4. **Deferred list narrowed**: plugin_access and plugin_blacklist now in-scope for chat, routing into their existing menu flows (sensor pick + consent/honorific dialogs). Remaining menu-only: plugin_chat, plugin_maint, plugin_tpe, plugin_rlvex.

---

**Plan version:** 1.1
**Status:** Approved — ready for implementation.
