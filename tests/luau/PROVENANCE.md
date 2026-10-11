# Verification inputs

The API signature snapshot contains names, member kinds, enum names and values extracted on 2026-10-11 from https://github.com/MaximumADHD/Roblox-Client-Tracker/blob/roblox/API-Dump.json. It excludes the full documentation and API security metadata.

The mock checks module behavior and API member names. It approximates geometry and does not enforce all native property types, permissions, font metrics or Studio lifecycle behavior. It uses local provider fixtures and no real credentials.

CLI verification used Luau 0.742 (https://github.com/luau-lang/luau/releases/tag/0.742) and Rojo 7.7.1 (https://github.com/rojo-rbx/rojo/releases/tag/v7.7.1). Executables are not included in the package.

9router display-only registry and PNG logos were read from https://github.com/decolua/9router at commit ce4460ef79382bfddb4aa5fc0ff9f3cb0d5f95a8. The snapshot contains 82 visible chat providers in oauth/free/freeTier/apikey categories; 75 PNGs are copied byte-for-byte from public/providers. Original MIT license: assets/9router-LICENSE.txt. OAuth credentials/client secrets from the upstream registry are not included. UI aliases follow uiAlias || alias. Upstream hidden/non-chat and web-cookie/media categories are excluded.

Streaming interaction reference: https://github.com/anomalyco/opencode and https://opencode.ai/docs/sdk/. Studio local HTTP/stream API reference: https://create.roblox.com/docs/cloud-services/http-service and the official creator-docs HttpService/WebStreamClient definitions. The plugin uses a local companion for external file/terminal operations because these are outside the Roblox plugin sandbox.

The bridge uses only Node.js built-ins and requires Node.js 22+. Endpoint fixtures cover web and provider responses; local HTTP/SSE, file operations and subprocess cancellation are real. JSON Schema validation used jsonschema 4.26.0. Logs and fixtures contain synthetic test keys only.

ForgePilot 3.5.0 runs separate Node entry points for router and bridge. Router launches 9router@0.5.99 with --host 127.0.0.1 --no-browser --skip-update --log, following cli/cli.js in the retained 9router snapshot. Startup/teardown and independent service lifecycle are exercised using a real local fixture child; no real 9router package or provider account is started by these tests. Platform folder tests simulate Windows/macOS and Wine/Vinegar directory structures. POSIX wrappers and help commands are checked on Linux; native Studio, Windows/macOS launcher execution and OAuth accounts remain unverified. Active/idle SSE tests use real local HTTP; deterministic Luau tests exercise the real plugin modules with mocked engine signals/scheduler.
