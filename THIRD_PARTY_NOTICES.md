# Third-party notices

## CodexHost

`Resources/CodexCacheHUD.js` is a minimal adaptation of the renderer-side
Usage control patterns from [BytePioneer-AI/codex-host](https://github.com/BytePioneer-AI/codex-host).

The reference project is MIT licensed. This adaptation keeps only the CH
formatting, 28px footer placement, popover chrome, and hover/click interaction.
It does not include CodexHost Host Runtime, Shim, Proxy, Launcher, model
switching, harness support, account limits, or cost display.

The integration only connects to a Codex process explicitly launched with a
loopback `--remote-debugging-port=<port>` argument. It never connects to a
CodexHost Node Inspector, sends a signal to a normal stock launch, or changes
the launch environment used by plugins and MCP.

CodexIsland oc does include a separate one-click convenience action that
starts the unchanged official Codex executable with that same Renderer
argument. It is not the CodexHost Launcher and does not replace the official
application bundle or intercept Launchpad.
