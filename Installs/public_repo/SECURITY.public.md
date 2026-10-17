# Security

Please report a security problem **privately** to **security@cockpit.ruggi.site**, with what you found, how to reproduce it, and the version
and build shown in the app's header. Please do not open a public issue for it.

You will get an answer, and credit if you want it. The app is single-user and runs as your own user; the areas most worth your time are
the file and command endpoints in `cockpit_app/`, the installers in `Installs/`, and the agent loop in `scripts/`.
