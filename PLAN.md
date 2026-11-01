# Hackban for iOS: plan

Native SwiftUI client for any number of Hackban instances (hackban.hackclub.com, a personal server, ...).
iOS 18 minimum, built with the iOS 26 SDK so system chrome is Liquid Glass; custom glass surfaces use
`glassEffect` on iOS 26 and fall back to materials on 18.

## 1. Talking to a Hackban server

Hackban has no public REST API. The web app talks tRPC 11 (superjson) to `/api/trpc`, plus a handful of REST
routes (attachments, files, avatars, logos, board export). All of it is cookie-only (Auth.js). The only bearer-token
surface is `/api/mcp`, backed by a full OAuth 2.1 server (`src/server/oauth.ts`): dynamic client registration,
PKCE S256, 1 h access tokens, 30 day rotating refresh tokens with replay revocation.

**Server change (hackban, branch `leo/tender-meitner-9p4zv3`):** let the tRPC context and the REST routes accept
that same OAuth access token as `Authorization: Bearer ...`. A bearer session gets `isAdmin: false`, matching the
MCP rule that site-admin powers are browser-only. Native app redirect scheme added to the consent page's known list.
No new tables, no new endpoints.

**Client protocol:**

| Kind | Wire |
| --- | --- |
| query | `GET /api/trpc/<path>?input=<superjson>` |
| mutation | `POST /api/trpc/<path>` body `<superjson>` |
| subscription | `GET /api/trpc/board.onEvent?input=...` as SSE (`board.onEvent`) |
| upload | `POST /api/cards/:id/attachments` multipart |

superjson outputs carry dates as ISO strings in `json` (meta only marks them), so decoding is plain `JSONDecoder`
with an ISO-8601 date strategy. Inputs that carry dates (`card.update`, `card.updateCheckItem`) need
`meta.values` paths, which the encoder generates.

Headers on every call: `x-client-id` (per-process id so live-update echoes are skipped) and `x-tz-offset`
(repeating cards roll over in the user's zone).

## 2. Accounts

- `Account { id, baseURL, user, oauthClientId, label, tint }`, list stored in the App Group; tokens in the shared
  Keychain access group, so the app, widgets and intents all see them.
- Sign in: enter a server URL (default hackban.hackclub.com) -> discover `/.well-known/oauth-authorization-server`
  -> register a public client once per server -> `ASWebAuthenticationSession` + PKCE -> exchange -> `me.profile`.
- Scope switcher: **All accounts** (default) or one account. In All mode, Home lists every account's workspaces in
  sections, and My Cards / Notifications / Search merge results with an account badge. Everything is keyed by
  `(accountId, id)`.

## 3. Feature parity with hackban web

Excluded on purpose: site admin panel, Trello import (both stay on the web).

- **Home:** starred, recent, workspaces with boards, guest boards, closed boards (reopen/delete), create board
  (colors/gradients, visibility, template), create workspace, join by invite link.
- **Board:** horizontally paged lists, drag cards between lists and reorder lists, add card top/bottom, filters
  (text, members, labels, due buckets, my cards), live updates, star, share (members, roles, invite link on/off/reset,
  invite by email, remove, leave), menu (description, background, labels CRUD, archived items restore/delete,
  activity, visibility, close/reopen, copy, move to workspace, export JSON).
- **List menu:** rename, color, add card, copy, move (board/position), move all cards, sort (+ group by assignee),
  archive all cards, archive list, delete.
- **Card front:** cover, labels, title, due badge (overdue/soon/complete), recurrence, checklist progress, comment and
  attachment counts, members, blocked/blocking badges, watching, complete toggle. Long-press = quick edit menu
  (open, complete, archive, join/leave, labels, dates, move, copy).
- **Card detail:** title, markdown description, members, labels, start/due/recurrence/complete, cover
  (color/attachment/size), checklists (add/copy/rename/delete, items add/rename/check/due/assignee/reorder/delete),
  attachments (photos, files, links; rename, delete, make cover, Quick Look), comments (add/edit/delete),
  activity, watch, dependencies, move, copy, archive/restore, delete, share link.
- **Notifications, search, me:** profile (name, username, avatar upload/remove), my activity, my cards, connected
  apps (revoke), theme.
- **Workspace settings:** name, description, logo, members (add by person or email, roles, remove, leave),
  auto-join rules, delete workspace.

## 4. Beyond the web

- **Quick add** (Todoist-style): a sheet reachable from everywhere with inline parsing:
  `Ship deck tomorrow 5pm #Events/To Do @me !red` -> due date, board/list, assign me, label. Saved **quick add
  targets** (account + board + list + top/bottom + assign me) are the "customisable shortcut"; they surface as
  - Home screen quick actions (long-press the icon),
  - a configurable **Control Center / lock screen control** (iOS 18 ControlWidget), usable from the Action button,
  - a configurable home screen widget button,
  - App Shortcuts / Siri phrases.
- **Widgets** (home screen small/medium/large, lock screen circular/rectangular/inline): My cards / due soon across
  all accounts with an interactive complete button, a board's list, due-today count.
- **Apple Shortcuts (App Intents):** Add Card, Complete Card, Open Board, Open Card, Get My Cards, Find Cards, Quick
  Add (opens the sheet). Entities: Account, Board, List, Card, with queries spanning accounts.

## 5. Structure

```
project.yml                  XcodeGen spec (app, widget extension, test target)
HackbanKit/                  shared code, compiled into the app and the widget extension
  API/                       superjson, tRPC client, SSE, models
  Auth/                      OAuth + PKCE, Keychain, refresh coordinator
  Store/                     AccountStore, cache (App Group), quick-add parser + targets
  Intents/                   App Intents + entities (shared so widgets can run them)
Hackban/                     app target: SwiftUI screens
HackbanWidgets/              widget extension: widgets + controls
HackbanTests/                unit tests (superjson, parser, filters, sorting)
.github/workflows/ios.yml    xcodegen + xcodebuild build & test on macOS
```

## 6. Critique

1. **Scale vs. verification.** Web is ~8.5k lines of TSX; parity in SwiftUI is similar. There is no Swift compiler
   in the dev container, so every compile goes through GitHub Actions macOS runners. Risk: a large, unbuildable
   first push. *Fix:* push early, iterate on CI logs until green, keep logic in plain Swift with unit tests that run
   in the same job.
2. **Refresh-token rotation across processes.** The app, the widget extension and intent runs share one grant. Two
   processes refreshing with the same refresh token trips the server's replay detection, which revokes the whole
   grant and logs the user out. *Fix:* one refresh coordinator guarded by an `flock` on a file in the App Group;
   after taking the lock it re-reads the Keychain, and only refreshes if the stored token is still the one it saw.
   Widgets only refresh when their access token is actually expired.
3. **tRPC is not a public API.** Procedure shapes can change under the app. *Fix:* decode leniently (optionals,
   defaults), never crash on unknown fields, show the server's error message. A versioned REST API would be cleaner
   but is a large server change for no user-visible gain right now.
4. **Custom URL scheme redirects can be claimed by other apps.** PKCE means an intercepted code is useless, and
   `ASWebAuthenticationSession` delivers the callback to the app that started it. Acceptable.
5. **Drag and drop on a phone across horizontally scrolling columns is fiddly.** *Fix:* system drag and drop for
   cards and lists, plus an explicit Move sheet (board, list, position) on every card and list as the reliable path.
6. **Widgets are budgeted.** iOS gives a few dozen reloads a day. *Fix:* the app writes a shared cache after every
   fetch and calls `WidgetCenter.reloadAllTimelines()` after mutations; timelines fall back to the network only when
   the cache is stale.
7. **No push notifications.** Real-time pushes need APNs on the server (keys, device tokens, a sender). Out of scope;
   notifications refresh on foreground and via background refresh. Noted as a follow-up.
8. **Bearer sessions are never site admin.** Site admins lose admin overrides in the app. Matches the decision to
   leave admin on the web and the existing MCP rule.
9. **Signing.** App Groups and Keychain sharing need a development team to run on a device. CI builds for the
   simulator unsigned; `DEVELOPMENT_TEAM` is a one-line change in `project.yml`.
10. **Offline.** Read-only cache of last-seen data; no offline edit queue. Writes fail with a visible error and
    optimistic changes roll back.

## 7. Revised order of work

1. Server bearer auth (+ tests) in hackban.
2. HackbanKit networking, auth and models; CI workflow; get to green.
3. Accounts, Home, Board, Card detail.
4. Remaining parity screens.
5. Quick add + targets, App Intents, widgets, controls, quick actions.
6. Tests, README.
