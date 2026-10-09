## 1. Engine

- [x] 1.1 `SiteIconEngine` records whether the replaced page's icons are the site's and takes a mid-load icon when both pages are.

## 2. Tests

- [x] 2.1 Engine: the first page's icon before `onLoadStop`, a page after a page of the site, after another host's page, after a badge swap, after a page left before it finished, across a non-web page, and a loading page on another host.
- [x] 2.2 Emulator: the multi-icon page takes 32px then 192px, and the badge page takes its own icon, whether or not either lands before `onLoadStop`.
