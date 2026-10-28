# t3machine

One command to set up, and later update, a Debian or Ubuntu server for
[T3 Code](https://github.com/pingdotgg/t3code), with [mise](https://mise.jdx.dev)
for the tools agents use in their sessions.

The same command works for the first install and for every update after that.

## Run it

From your machine, over SSH (the server needs nothing but SSH):

```sh
ssh root@<host> 'bash -s' < setup.sh
```

Or on the server itself:

```sh
curl -fsSL https://raw.githubusercontent.com/0xtlt/t3machine/main/setup.sh | sudo bash
```

Pass options as environment variables, for example:

```sh
ssh root@<host> 'T3_USER=agent APT_UPGRADE=1 bash -s' < setup.sh
curl -fsSL https://raw.githubusercontent.com/0xtlt/t3machine/main/setup.sh | sudo T3_USER=agent bash
```

## What it does

| Step | First run | Later runs |
| --- | --- | --- |
| apt base packages (`curl`, `git`, `ca-certificates`, `xz-utils`, `zstd`, `unzip`, `dbus-user-session`, ...) | install | keep installed |
| User `t3` (no password login) | create | leave as is |
| `loginctl enable-linger t3`, start `user@<uid>.service` | yes | yes |
| `~/.profile` and `~/.bashrc` | add a managed block | rewrite the managed block only |
| mise (in `~/.local/bin`) | `curl https://mise.run \| sh` | `mise self-update -y` |
| `mise.toml` from this repo | copy to `~/.config/mise/conf.d/t3machine.toml` | overwrite with the latest |
| `[bootstrap.packages]` (apt) | `mise bootstrap packages apply --update` | `apply`, then `mise bootstrap packages upgrade` |
| `[tools]` (node, gh) | `mise install` | `mise install`, then `mise upgrade` |
| T3 Code (in `~/.local/bin`) | `curl -fsSL https://t3.codes/install.sh \| sh` | `t3 update --yes` |
| T3 background service | `t3 service install` | `t3 service install` (repairs), restart if pending |

T3 Code and mise run as the `t3` user, never as root: running T3 Code as root
creates a separate installation and Connect identity.

The script does not touch SSH, the firewall, or Tailscale, and it does not log
in to anything.

### Shell setup

The managed block in `~/.profile` puts `~/.local/bin` on `PATH` and runs
`mise activate bash --shims`, so non-interactive login shells (the ones T3 Code
uses for agent sessions) find the mise tools. `~/.bashrc` gets the full
`mise activate bash` for interactive shells. Both blocks sit between
`# >>> t3machine >>>` and `# <<< t3machine <<<` markers and are replaced, never
duplicated.

### mise config

`mise.toml` in this repo is installed as
`~/.config/mise/conf.d/t3machine.toml` and overwritten on each run. Keep your
own additions in `~/.config/mise/config.toml` (for example with
`mise use -g python@3.14`), so updates never erase them.

System packages live under `[bootstrap.packages]` and are applied with
[mise bootstrap](https://mise.jdx.dev/bootstrap/packages/). apt needs root and
the `t3` user has no sudo, so the script runs this step as root with the `t3`
user's mise and config directory.

## Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `T3_USER` | `t3` | User that runs T3 Code (must not be `root`) |
| `APT_UPGRADE` | `0` | `1` runs `apt-get upgrade` first |
| `T3MACHINE_REF` | `main` | Branch, tag, or commit to fetch `mise.toml` from |
| `MISE_CONFIG_SRC` | `mise.toml` next to the script, else GitHub | Local path or URL of the mise config to install |
| `T3CODE_CHANNEL` | `stable` | T3 Code release train for the first install (`stable` or `nightly`) |
| `NO_COLOR` | unset | Set to disable colored output |

## After the install

These steps need an interactive login, so the script only prints them:

1. Become the user: `su - t3`
2. Install and log in to at least one provider, for example Claude Code:
   ```sh
   curl -fsSL https://claude.ai/install.sh | bash
   claude auth login
   ```
   (Codex: `codex login`, Cursor: `agent login`. See the
   [T3 Code provider docs](https://github.com/pingdotgg/t3code/blob/main/docs/user/install.md#providers).)
3. Pair your devices over Tailscale: `t3 pair --tailscale`. The pairing link
   works like a password; do not share it.

Check the service any time with `t3 service status`.

## Requirements

- Debian 12+ or Ubuntu 22.04+, x86_64 or arm64, with systemd
- Root access

Without systemd (for example in a plain container) the script still installs
mise, the tools and T3 Code, and skips linger and the background service.

## License

[MIT](LICENSE)
