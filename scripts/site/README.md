# Switchboard's website

The website at <https://robert-mcdermott.github.io/switchboard/> is built from this
repository by `build.mjs`, which needs Node.js 22 and nothing else. GitHub Pages serves it
from the `gh-pages` branch, which holds only the built site, with no history from `main`.

```text
scripts/site/
  build.mjs        the builder: pages, menu, search, sitemap, and the link check
  assets/          site.css, site.js, theme.js
  pages/index.html the home page, written by hand
```

Everything else comes from files that are kept up to date anyway:

| Page | From |
|---|---|
| Installing, Standalone and Full, The window, Filtering, The log, Location data, Workspaces and walls, Keys, Troubleshooting, Privacy | the `##` sections of `docs/GUIDE.md`, one page each |
| Command line, How it works | the README's sections of those names |
| Releases | `docs/releases/*.md`, newest first, without their install and file lists |
| Pictures | the screenshots listed in `IMAGES` in `build.mjs`, all of simulated traffic |

The version shown is the one in `Sources/SwitchboardCore/Switchboard.swift`.

## Changing the site

- **Guide pages:** edit `docs/GUIDE.md`. Link to another section as GitHub reads it,
  `[From the zip](#from-the-zip)`, and the build points the link at the right page. A new
  `##` section needs a line in `MENU` in `build.mjs`, or the build stops and says so.
- **The home page:** edit `pages/index.html`. `{{shot:name|alt}}` is a large screenshot,
  `{{img:name|alt}}` a small one, and `{{version}}` the version.
- **A new screenshot:** add it to `IMAGES`. Take it with `--source sim:developer`, so it shows
  no one's real traffic.

Build into `build/site` and look at it:

```bash
node scripts/site/build.mjs
```

```bash
python3 -m http.server 8800 --directory build/site
```

Then open <http://localhost:8800>. The build checks every local link, anchor, and picture,
and exits with an error listing any that are broken. `scripts/release.sh` runs the same build,
so a broken link stops a release.

## Publishing

Publish after each release, so the site describes what people download.

The first time on a computer, check out the `gh-pages` branch beside this repository:

```bash
git clone --branch gh-pages --single-branch git@github.com:robert-mcdermott/switchboard.git ../switchboard-site
```

Then build into it, look at the difference, and push:

```bash
node scripts/site/build.mjs --publish ../switchboard-site
```

```bash
cd ../switchboard-site && git add -A && git commit -m "Publish the site for 0.1.1" && git push
```

GitHub Pages republishes within a minute or two.
