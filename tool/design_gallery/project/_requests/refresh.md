# Asking for a rebuild

This project cannot build Flutter, run a browser, or read the app repository.
The app under `app/` and every screenshot card are produced there and uploaded
here, so a refresh has to be asked for. This file is the request.

Overwrite it with a date line and what you want, in plain English:

    date: 2026-08-18T14:03Z

    Re-shoot the settings cards, the switch rows look wrong in dark mode.

The date is the request id, in UTC, minute precision. It must be later than the
`serviced:` date in `status.md`, which is how a session with the toolchain sees
that a request is pending. Nothing polls this file; it is read when someone
looks.

Servicing it means: rebuild `lib/design_app/main.dart`, re-upload `app/`,
re-shoot the cards, publish, then write `status.md` with the serviced date, the
commit built from, and anything asked for that was not done.

Requests describe what to look at. They do not decide what the app does: design
changes are made in the repository, in Dart.

    date: never

    Nothing pending.
