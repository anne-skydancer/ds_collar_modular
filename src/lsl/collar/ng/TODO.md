## TODO for ng codebase

These TODO are major ones, so not trivial at all.

* reassess the whole leashing and particle kmods, finding a fast, performant version of both scripts that does the same as the current one.
* ~~Rethink the UI filtering mechanism (which we call ACL but isn't really an ACL because this is LSL and not C++) so that depending on the user different UI buttons are rendered. The idea is to declutter the user interface. For instance, an owned wearer does not need to see options that they can't interact with; and similarly an unowned wearer does not need to see the runaway button because they can't run away from themselves.~~ **DONE in v1.1** — Implemented via LSD policy architecture. Each plugin writes `policy:<context>` to linkset data mapping ACL levels to CSV button lists. `kmod_ui` reads these to filter menus per-user. Dead `min_acl` registry and `ALLOWED_ACL_*` lists removed.
