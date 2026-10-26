# Project page

A buildless, static landing page for mixerMac. It uses the app's artwork and actual screenshots, with no third-party scripts, fonts, or analytics.

## Local preview

From the repository root:

```sh
./script/build_site.sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory work/pages-site
```

Open `http://127.0.0.1:4173`. Edit `site/index.html`, `site/styles.css`, or `site/app.js`, then run the build helper again. Generated files stay in the ignored `work/` directory.

## GitHub Pages

The workflow publishes only `work/pages-site`, including four copied image assets. Application source, bundles, and test artifacts are not part of the Pages artifact.

To publish, enable GitHub Pages with **GitHub Actions** as the source in the repository's Pages settings. Push the website files and workflow to `main`, or run the workflow manually after they have been committed.

Expected project URL: `https://jueuunn7.github.io/mixerMac/`.

The workflow follows GitHub's [static Pages starter](https://github.com/actions/starter-workflows/blob/main/pages/static.yml). Download buttons point to the latest release asset, `mixerMac-macOS.zip`.
