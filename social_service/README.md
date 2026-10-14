# Harness Social

A small, separate account and text-conversation service for the native Social tab. It stores accounts, posts, direct replies, follows, mutes, likes, reposts, and sessions in SQLite. There are no seeded accounts, fake engagement counts, hosted endpoints, or companion/agent execution routes.

## Run locally

Python 3.10+ and its standard library are sufficient. From the repository root:

```sh
python3 -m social_service.server --database /private/tmp/harness-social/social.sqlite --port 8790
```

The listener binds only to `127.0.0.1`. The default database is `~/.harness-social/social.sqlite` when `--database` is omitted. Keep the database directory private and include it in your backup policy. The database file is restricted to its owner; SQLite may also create journal/WAL sidecars.

For the iPhone app, provide an HTTPS origin such as `https://social.your-domain.example` in **Social → Connect to Social**. The address is an example, not a deployed service. Terminate TLS with a trusted certificate at a reverse proxy and forward to the loopback listener. Do not expose the Python listener directly or disable iOS transport security. The native client requires HTTPS and rejects credentialed redirects; a loopback HTTP exception exists only for explicit core test setup.

Configure proxy request/body/connection limits and rate limits before exposing the service. The built-in account throttle permits ten register/login attempts per client socket IP per minute. Behind a reverse proxy, requests share its IP, deliberately ignoring spoofable forwarded headers. Apply per-client rate limiting at that proxy. This service is a functional small-community implementation, not an audited large-scale public platform. No service was deployed by this implementation.

## Account and privacy boundary

Passwords use per-account random salts and PBKDF2-HMAC-SHA256 with 600,000 iterations. The service stores only hashes of random bearer tokens; sessions expire after 30 days and logout revokes the current token. There is currently no email verification, password recovery, administrator UI, federation, media upload, or push notification system. Do not promise these flows to users until implemented.

All content and profile API reads require a valid session. People on the same service can read posts, replies, profiles and relationship counts; a mute is private to the requesting account and filters their timeline. Following is not an access control mechanism. Muting an author also hides reposts of that author's content; visiting a profile explicitly still shows its content.

The native app keeps the bearer session in its existing device-only Keychain. Draft text and its retry key are stored locally under `Application Support/Harness/Social/drafts.json`, protected with iOS file protection and scoped by service, account ID, and reply target. Switching accounts preserves each account's drafts separately. Social data and credentials are not inserted into the agent workspace, model context, exports, or companion requests. HTTP request logs are disabled; reverse-proxy logging should also omit authorization headers and request bodies.

## Expression and moderation

The product intent is broad freedom of expression with minimal moderation of users' posts. This implementation does not add automated content censorship or an algorithmic ranking system. Chronological order is a feed design choice, distinct from the moderation policy.

Users control follows and mutes, and can delete their own posts. Deletion removes the author's text while preserving other people's replies. The service owner must define and publish the deployment's moderation and legal-compliance policy, including abuse handling, before inviting a public community. This repository does not claim to provide a zero-moderation network or a production moderation operation.

## API

The native client uses `/v1`. JSON objects use camelCase keys. UTF-8 JSON request bodies are capped at 8 KiB; posts contain 1–500 Unicode scalar values, passwords 12–128 characters when registering, and handles 1–24 ASCII letters/digits/underscores. Handles normalize to lowercase.

| Method | Route | Behavior |
|---|---|---|
| POST | `/register` | `{handle, displayName, password}` → session |
| POST | `/login` | `{handle, password}` → session |
| POST | `/logout` | Revoke the current bearer token |
| GET | `/me` | Current profile |
| GET | `/feed?mode=all\|following&before=<cursor>&limit=30` | Newest activity first; `nextCursor` for earlier items |
| POST | `/posts` | `{text, parentID?}`, required `Idempotency-Key` header |
| GET | `/posts/{id}/thread?after=<cursor>` | Post plus up to 50 direct replies, oldest first |
| DELETE | `/posts/{id}` | Author-only soft deletion |
| PUT / DELETE | `/posts/{id}/like` | Explicitly set/unset this account's like |
| PUT / DELETE | `/posts/{id}/repost` | Explicitly set/unset this account's repost |
| GET | `/profiles/{handle}` | Profile plus 50 most recent top-level posts |
| PUT / DELETE | `/profiles/{handle}/follow` | Follow/unfollow |
| PUT / DELETE | `/profiles/{handle}/mute` | Mute/unmute in this account's feed |

Success objects include real counts and viewer-specific `liked`, `reposted`, `following`, and `muted` fields. Failures return `{ "error": "..." }` with appropriate HTTP status. Posts/replies share the same representation; open a reply's thread to read its children, and use `parentID` to navigate upward. Replies are paginated by insertion row ID; timeline activity uses a monotonically increasing sequence. New posts cannot shift items between previously fetched pages. A repost is its own timeline activity and links to the original post.

Publishing is transactional. A repeated `(account, Idempotency-Key)` with the same text and reply target returns the original post; reuse with different content returns 409. Native retries preserve that key across network failures and app relaunch. Editing a draft gives it a new key. An acknowledgement clears only the exact draft it published, preserving edits made while the request was in flight. Likes/follows/mutes/reposts use desired-state PUT/DELETE operations, so retrying an unchanged action does not toggle it twice.

## Verify

Service HTTP/SQLite integration tests create temporary accounts and databases, with no external network calls:

```sh
python3 -m unittest social_service.test_service -v
```

Native core draft, URL and archive tests:

```sh
swift test --scratch-path /private/tmp/harness-social-swift-build --filter SocialTests
```

Swift client integration starts isolated loopback services, drives real account/post/reply/relationship operations, and checks that redirects receive no credentials:

```sh
python3 -m social_service.test_swift_client
```

On this development machine, prefix Swift commands and the Swift integration runner with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`. Use the installed Xcode path on other machines. The two Swift HTTP tests skip during an ordinary package run because their temporary HTTP fixture is supplied by the Python runner. Run that runner explicitly when validating this boundary.

These checks prove local persisted network behavior. A configured HTTPS deployment, real-device connection, and public operational policy require their own verification.
