# Preview host

A Rails application whose only job is showing the SparrowKit developer console
so it can be looked at and changed.

```bash
preview/bin/console
```

Then open **http://127.0.0.1:4500/sparrowkit**. Pass a port to use another one:
`preview/bin/console 4300`.

## Why it exists

It is the only place all three panels are registered at once. Each gem's own
dummy sees itself and whatever it depends on — sparrow_ui's sees Mail,
sparrow_auth's sees Auth and Mail — so the header nav, the hub's card grid and
the ordering of panels have nowhere else to be looked at.

It is not part of `rake`, not in any gem's bundle, and nothing depends on it.
Delete the directory and the repository is unchanged. Adding these four gems to
sparrow_ui's Gemfile instead would have put webauthn and a payment SDK into its
test bundle in order to render a nav bar.

## The loop

Both halves show on a refresh. Neither needs a restart.

**Views** — edit any `.erb` under a gem's `app/views/*/console/` and reload. The
running server reads the file again.

**Styles** — the layout inlines `console.css` and re-reads it from disk on every
render, so a rebuild is picked up by a refresh:

```bash
bundle exec rake ui:watch
```

Leave that running in a second terminal and Tailwind recompiles on each change.
Run `bundle exec rake ui:css` once before committing: unlike the watcher it
deletes the output first, so a removed view cannot leave its utilities behind in
the committed artifact.

**Ruby** — changing a gem's `.rb` needs a restart.

## What it can and cannot do

The panels save for real. Every value written goes into this host's own
encrypted credentials under `tmp/`, generated on first boot and ignored by git —
separate from any application that matters, because the forms write for real.

It cannot exercise signing in, sending mail or billing. The database is created
and never migrated, so a page that reached for one of those tables would fail on
a missing table — which is the right way for that boundary to announce itself.
Use a gem's own dummy for anything past the console.

## Requirements

PostgreSQL, running. `bin/console` creates `sparrowkit_preview` on first start
and never migrates it.

The console queries nothing — every panel reads and writes encrypted credentials
alone. The database is there because sparrow_auth mounts Rodauth, whose
middleware opens a Sequel connection on every request through the application,
and its configuration names the postgres adapter outright (ADR 0001). Running
this on SQLite was tried; every page 500s on `cannot load such file -- pg`
before rendering a byte.

## Files

| | |
|---|---|
| `bin/console` | start it |
| `bin/rails` | the standard stub — without it `rails server` prints `rails new` help |
| `Rakefile` | the standard stub — without it `bin/rails db:create` finds the repository's Rakefile |
| `config/application.rb` | why ActiveRecord and PostgreSQL are here, and why nothing is migrated |
| `config/environments/development.rb` | why view reloading takes the settings it does, and which inviting ones break it |
