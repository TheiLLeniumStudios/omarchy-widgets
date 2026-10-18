# ai usage

One Omalauncher tile for any number of AI subscriptions and API accounts:

- **Claude** — the 5-hour and weekly windows (plus model-scoped windows) from
  Claude Code's OAuth login.
- **OpenCode Go** — rolling 5-hour, weekly and monthly usage from the Go usage
  API.
- **OpenRouter** — key status, spend today/week/month, key limit, and account
  credits when a management key is supplied.
- **DeepSeek** — balance, available state, and today/month spend. Exact spend
  needs a platform usage token; without one it is estimated from the balance
  history the widget records.

Tap the tile for the usage screen, then **accounts** to add, edit, reorder or
remove accounts. An account is a provider plus a name, a key, and (for
OpenRouter/DeepSeek) an optional second credential.

For Claude, the key is a Claude Code `.credentials.json` path. Claude Code owns
that login flow: in the account form, **log in** and **log in 2nd** start it in a
terminal with `CLAUDE_CONFIG_DIR=$HOME/.claude` and `$HOME/.claude-2`, so the
browser/terminal login writes the matching file. **default path** and
**2nd path** fill the key field with the resulting path; a leading `~` is
expanded by the fetcher. **agents** opens the launcher's agent installer if
Claude Code is not installed. The widget cannot capture the OAuth callback
itself, so it hands that step to Claude Code.

Keys are kept in the launcher's saved widget state, not in this repository or
the `.owl` file. They are written to a mode-0600 cache file only so the local
fetcher can read them.

## Files

- `widget.owl` — the tile, its full screen, and the account editor.
- `fetch.sh` — the provider fetcher. The widget downloads this file from the
  repository once a day and runs it locally, so fixes here reach the phone
  without a widget version bump. It needs `curl` and `jq`.

The account list is passed to the fetcher from the widget's state; `fetch.sh`
never stores or logs keys.

## Credentials by provider

| provider | key | extra (optional) |
| --- | --- | --- |
| `claude` | path to a Claude Code `.credentials.json`, or an OAuth access token | — |
| `opencode-go` | OpenCode Go API key | — |
| `openrouter` | OpenRouter API key | management key, for account-wide credit balance |
| `deepseek` | DeepSeek API key | platform usage token, for exact spend |
