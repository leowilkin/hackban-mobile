# Hackban for iOS

A native SwiftUI client for [Hackban](https://github.com/hackclub/hackban), Hack Club's self-hosted Trello.
Sign in to as many Hackban servers as you like (your organization's, your own) and see them separately or
all together.

iOS 18+, built with the iOS 26 SDK: Liquid Glass on iOS 26, materials on iOS 18.

## Features

- **Multiple accounts.** Each account is a server + user. The account switcher shows one, or **All accounts**
  merged (Boards, My Cards, Notifications, Search), with a colored badge per account.
- **Parity with the web app** (except the site admin panel and Trello import, which stay on the web):
  boards, lists and cards with drag and drop, filters, sorting (incl. group by assignee), live updates, labels,
  members, start/due dates, repeating cards, checklists, attachments (photos, files, links, covers), comments,
  activity, watching, dependencies (blocked/blocking), archive/restore, copy/move, sharing (roles, email invites,
  invite links), board settings (background, visibility, close/reopen, move, copy, export), workspace settings
  (members, logo, auto-join domains), profile (name, username, avatar), connected apps, notifications, search.
- **Quick add**, Todoist-style: `Ship deck tomorrow 5pm #Events/To_Do @me !red ^top *weekly`
  - `#board` or `#board/list` (underscores for spaces, fuzzy matched across accounts)
  - `@name` assigns (`@me` is you), `!label` by name or color, `^top`/`^bottom`, `*daily|weekdays|weekly|monthly|yearly`
  - any date phrase becomes the due date
  - **Quick add targets** (Settings → Quick add) are saved destinations. They appear as Home Screen quick actions,
    in the Quick Add widget, the Control Center / Lock Screen control (which the Action button can run), and in Shortcuts.
- **Widgets:** My Cards (small/medium/large, interactive complete button; Lock Screen circular/rectangular/inline),
  Board List (a list of a chosen board), Quick Add (home + Lock Screen), and a Quick Add control.
- **Shortcuts / Siri:** Add Card, Quick Add Card, Open Quick Add, Complete Card, Open Board, Open Card,
  Get My Cards, Find Cards. Board, list, card, account and target entities work across accounts.

## Server requirements

The app uses the server's OAuth 2.1 provider (the one MCP clients use: dynamic client registration + PKCE)
and calls the tRPC API and REST routes with `Authorization: Bearer <token>`. The server must accept bearer tokens
on `/api/trpc` (including the `board.onEvent` SSE stream) and on the attachment, file, avatar, logo and export
routes. The redirect URI is `hackban-ios://oauth/callback`.

Bearer sessions never get site-admin powers, the same as MCP.

## Building

```bash
brew install xcodegen
```

```bash
xcodegen generate && open Hackban.xcodeproj
```

To run on a device, set `DEVELOPMENT_TEAM` in `project.yml` (App Groups and Keychain sharing need signing),
and change the bundle IDs / App Group if you're not on the Hack Club team.

CI (`.github/workflows/ios.yml`) generates the project and runs `xcodebuild test` on a simulator, unsigned.

## Layout

```
project.yml          XcodeGen spec: app, widget extension, unit tests
HackbanKit/          shared by the app and the widget extension
  API/               superjson, tRPC client (queries, mutations, SSE), models, typed endpoints
  Auth/              OAuth + PKCE, Keychain, cross-process token refresh
  Store/             accounts, disk cache, filters/sorts, quick add parser + service, My Cards feed
  Intents/           App Intents and entities (shared so widgets and controls can run them)
  UI/                palette, board backgrounds, formatting, authenticated images
Hackban/             the app: SwiftUI screens
HackbanWidgets/      widgets and the Control Center control
HackbanTests/        unit tests
```

### Notes

- **Token refresh.** Refresh tokens rotate and the server revokes the whole grant when one is replayed. The app,
  widgets and intents share tokens, so refreshes are serialized with an `flock` on a file in the App Group, and a
  process re-reads the Keychain after taking the lock before refreshing.
- **Live updates** use the board's SSE subscription while a board is open; the app's own changes are tagged with
  `x-client-id` so their echoes are skipped.
- **Widgets** read the cache the app writes and only fetch when it's older than 15 minutes.
- No push notifications yet: that needs APNs on the server. Notifications refresh on launch and in background refresh.

See [PLAN.md](PLAN.md) for the design and its critique.
