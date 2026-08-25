# sparrow_ui

The control panel every other module plugs into, at `/sparrowkit`.

It is where API keys, sender addresses and settings are entered, so none of them
have to be typed into a file or kept in an environment variable you have to
remember to set on every machine. Each module you install adds its own panel;
this gem supplies the mount, the page around them, the stylesheet, and the rule
about who may reach it.

## Installing

Nothing to install. It arrives with the other modules and mounts itself at
`/sparrowkit` when the installer runs.

It belongs in your **development group**, and must never be outside it:

```ruby
# Gemfile -- not on RubyGems yet, so it comes from the repository
git "https://github.com/sparrow-soft/sparrowkit.git", tag: "v1.0.2", glob: "gems/*/*.gemspec" do
  group :development do
    gem "sparrow_ui"
  end
end
```

`sparrow_ui` is where the `sparrowkit:install` task lives. Without it in the
Gemfile that command does not exist, and each module is installed with its own:
`bin/rails sparrow_mail:install`, `sparrow_auth:install`, `sparrow_pay:install`.

## Using it

Start your application and open `http://localhost:3000/sparrowkit`. Every module
you have installed is listed, each with a badge saying whether it is ready,
needs attention, or has not been configured yet.

What you enter there is written to your Rails encrypted credentials, so it is
committed with your application and deployed with it — there is no separate
place to keep secrets in step.

**The panel is served to your own machine, in development, and nowhere else.**
A request is refused unless the application is running in development *and* it
came from this machine. It is not an admin area, it is not protected by a
password, and it is not something to expose deliberately.

A refusal is a plain `404`, not a `403`. A `403` would say "this exists and you
may not have it", which tells anybody scanning you that the console is
installed.

That check is one of two things keeping it shut. The other is packaging: the gem
is in your development group, so on a production machine it is not in the bundle
at all and there is nothing mounted to reach. Both are true at once on purpose,
because either one alone has a way of quietly stopping being true.

## Light and dark

The console is dark by default, and that default is in the stylesheet rather
than in JavaScript, so a page is already dark when the CSS parses — before any
script runs, with scripting off entirely, and with no flash when you navigate.
The switcher in the header remembers your choice.

## The stylesheet

You never build it. It ships compiled, because you installed a gem and not a
build toolchain: no Node, no watch process, and nothing to run before the
console looks right.

## Further reading

How the console is put together, and how a module registers a panel of its own,
is in this README.

## Licence

MIT. See [LICENSE.txt](LICENSE.txt).
