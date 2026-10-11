# ForgePilot

**An AI assistant for Roblox Studio, with support for multiple providers and a local companion.**

Inspect your place, edit Luau scripts, build scenes, and use external tools from one Studio panel. Choose your AI provider and connect the local bridge when your task needs web or file access.

![Version 3.5.0](https://img.shields.io/badge/version-3.5.0-2563eb)
![Node.js 22 or newer](https://img.shields.io/badge/Node.js-22%2B-339933)
![Roblox Studio plugin](https://create.roblox.com/store/asset/82058489576798/ForgePilot)

[Quick Start](#quick-start) · [Providers](#providers-and-authentication) · [How It Works](#how-it-works) · [Limitations](#capabilities-and-limitations) · [Documentation](#documentation)

Repository: [AlFarrizi-Studio/ForgePilot](https://github.com/AlFarrizi-Studio/ForgePilot)

## Features

- **Chat inside Studio.** Text and supported reasoning appear as provider data arrives, without a typing queue after the response finishes.
- **Build and Plan modes.** New chats default to Build. Switch to Plan for inspection and planning without applying changes.
- **Place inspection.** Read the Workspace hierarchy, instance properties, script source, selection, Lighting settings, and UI structure.
- **Roblox tools.** Create and edit parts, models, terrain, Luau scripts, and GUI elements through validated tool calls.
- **External tools through the bridge.** Search the web, fetch URLs, read and search local files, download files, edit files, and run terminal commands within the configured permissions.
- **Provider choice.** The bundled 9router catalog contains 82 presets across OAuth, free/free-tier, and API key categories. Direct API and custom endpoint profiles are also available.
- **Readable activity panels.** Thinking, tool calls, tool results, and web activity can be expanded or closed. Long results use a bounded scroll area.
- **Provider logos and interface icons.** The package includes upstream provider images and native fallback icons for Thinking, Custom Provider, web, terminal, and tools.
- **Keyboard controls.** Enter sends a chat message; Shift+Enter inserts a new line. The send button becomes Stop while the agent is working.

## Quick Start

### 1. Check the requirements

- Roblox Studio on Windows or macOS. Linux launchers are included for an existing, working Wine/Vinegar installation; there is no official native Linux Studio build.
- [Node.js 22 or newer](https://nodejs.org/), including npm and npx, for the installer and local services.
- An internet connection for the initial 9router download and online AI providers.
- An account or API key for your selected provider, when required.

Extract the **entire release ZIP** before starting. The RBXM alone does not include the bridge or launchers. ForgePilot's Node runtime uses built-in modules, so `npm install` in the project root is not required.

### 2. Install the plugin

Close Roblox Studio and run the installer for your operating system:

| Operating system | Installer |
| --- | --- |
| Windows | [`Install-ForgePilot.cmd`](scripts/windows/Install-ForgePilot.cmd) |
| macOS | [`Install-ForgePilot.command`](scripts/macos/Install-ForgePilot.command) |
| Linux | `sh scripts/linux/Install-ForgePilot.sh` |

Alternatively, run this command from the extracted ForgePilot directory:

```sh
npm run install:plugin
```

The installer detects the Studio plugins folder, verifies the plugin checksum, backs up the previous version, and copies the plugin. It does not start either local service or change your system PATH.

If automatic detection does not find your installation, specify the folder shown by Studio's **Plugins Folder** command:

```sh
npm run install:plugin -- --plugin-dir "/path/to/Plugins"
```

### 3. Start the local services

**9router and the ForgePilot bridge run separately.** Open each launcher in its own terminal:

| Operating system | 9router launcher | Bridge launcher |
| --- | --- | --- |
| Windows | [`Start-9Router.cmd`](scripts/windows/Start-9Router.cmd) | [`Start-ForgePilot-Bridge.cmd`](scripts/windows/Start-ForgePilot-Bridge.cmd) |
| macOS | [`Start-9Router.command`](scripts/macos/Start-9Router.command) | [`Start-ForgePilot-Bridge.command`](scripts/macos/Start-ForgePilot-Bridge.command) |
| Linux | `sh scripts/linux/Start-9Router.sh` | `sh scripts/linux/Start-ForgePilot-Bridge.sh` |

The same npm commands work across all three platforms. In the first terminal:

```sh
npm run start:router
```

In a second terminal:

```sh
npm run start:bridge
```

| Service | Default address | Purpose |
| --- | --- | --- |
| 9router dashboard | [http://127.0.0.1:20128/dashboard](http://127.0.0.1:20128/dashboard) | Provider connections, OAuth sign-in, and models |
| ForgePilot bridge | `http://127.0.0.1:20129` | Local tools and streaming relay |

Keep the required terminals open during your session. `npm start` starts **only the bridge**. Stopping one service does not stop the other. Direct API profiles can work without 9router; external tools still require the bridge.

### 4. Connect Studio and choose a provider

1. Open Roblox Studio, then **Plugins → ForgePilot**. Allow HTTP requests if Studio prompts you.
2. Open **Settings → Agent Access**. Enter the bridge URL and the pairing token printed in the bridge terminal, then select **Connect bridge**.
3. Open **AI & Provider** and add a provider profile.
4. For a router profile, connect the provider account or API key in the 9router dashboard. For a direct profile, enter the API endpoint and authentication details.
5. Refresh the connection status and available models where supported. Select a model, save the profile, and run **Test connection**.
6. Open Chat and send a message. Use Build to make changes, or select Plan for inspection and planning.

The bridge generates a new token at startup. Pair again after restarting the bridge or Studio. See the [installation guide](docs/INSTALLATION.md) for custom ports and upgrades.

### Optional: limit local access to one workspace

The bridge defaults to file access permitted by your operating system account. To restrict file operations to one workspace and disable terminal execution, start it with:

```sh
npm run start:bridge -- --workspace-only --workspace "/path/to/project"
```

## Providers and Authentication

The bundled catalog is a snapshot of [9router](https://github.com/decolua/9router): **21 OAuth, 16 free/free-tier, and 45 API key presets**. A listed preset does not guarantee current availability, account eligibility, or model access.

| Connection type | Setup | Credentials |
| --- | --- | --- |
| OAuth through 9router | Select **Sign in / Connect in 9Router**, complete the provider login or device-code flow, then refresh status and models. | Provider account; router client API key if required |
| Free/free-tier through 9router | Connect the selected service in the dashboard and choose an available model. | Account or API key if required by the service |
| API key through 9router | Add the provider API key to its connection in the dashboard. | Provider key in 9router; separate router client API key if required |
| Direct API / Custom Provider | Configure the base URL, protocol or adapter, endpoint path, model ID, and authentication in ForgePilot. | Credentials required by that API |

**The dashboard password, provider OAuth login, router client API key, and bridge pairing token serve different purposes.** Use the credential required by each screen. Provider keys for router connections belong in the router dashboard.

A connected account does not prove that a model supports chat, tool calling, reasoning, or image input. Test the connection and check the capabilities you need. Custom REST profiles require request and response mappings; model IDs must match the endpoint.

Plugin API keys and bridge tokens are kept for the current plugin session. Non-secret preferences and profiles may persist. OAuth credentials are managed by 9router. Keep credentials out of chat messages and repository commits.

See the [provider guide](docs/PROVIDERS.md) for authentication flows, model selection, and capability checks.

## How It Works

| Component | Responsibility |
| --- | --- |
| Studio plugin | Chat UI, place context, conversation mode, Roblox tools, and validation of requested actions |
| Provider adapter | Formats model requests and interprets text, reasoning, tool calls, and supported attachments |
| 9router | Connects supported provider accounts and exposes their models through the local router API |
| Local bridge | Relays streaming requests and executes available web, file, download, and terminal tools |

For each turn, ForgePilot assembles the conversation, place context, selected mode, and tools that are actually available. It sends the request through the selected adapter and displays incoming text immediately. When the model requests a tool, the plugin validates its name, arguments, mode, and permissions, obtains any required confirmation, and returns the real result to the model. This loop continues until completion, cancellation, or a reported limit or error.

Roblox actions run inside Studio. External actions run on your computer through the bridge. When the bridge is unavailable, the interface and AI receive setup guidance with a link to the [ForgePilot repository](https://github.com/AlFarrizi-Studio/ForgePilot).

Streaming timeouts measure **inactivity**, rather than total response duration. Incoming provider data, including heartbeats, keeps an active stream alive beyond two minutes. If the upstream connection goes silent, closes before completion, or reports an error, partial text remains visible and the chat becomes usable again. Certain output-limit responses can trigger up to three automatic continuation turns before a visible notice asks you to continue manually.

See [How It Works](docs/HOW-IT-WORKS.md) and [Architecture](docs/ARCHITECTURE.md) for the detailed flow.

## Capabilities and Limitations

| Area | What to expect |
| --- | --- |
| Plugin without the bridge | API chat and Roblox tools remain available. Web search, URL fetch, local files, downloads, and terminal tools require the bridge. |
| Tool calling | Native tool calling is used when supported. Otherwise, a validated JSON action format is available; success depends on the model following that format. |
| Image input | Requires both a compatible model and adapter. Reading image bytes through the bridge does not give a text-only model vision. |
| Audio, video, and documents | Support depends on the model, adapter, and capability checks. ForgePilot does not include a universal media generator. |
| Web search | Uses DuckDuckGo HTML or a configured SearXNG JSON endpoint. Challenges, rate limits, and pages requiring login or JavaScript may prevent useful results. |
| Downloaded assets | Downloads create local files. They do not automatically publish assets or create Roblox asset IDs. |
| Local access | Follows OS permissions, bridge scope, conversation mode, and tool permissions. Both services bind to localhost by default. Full access does not grant administrator privileges. |
| Provider availability | Models, pricing, quotas, OAuth access, and rate limits are controlled by each provider. A free-tier label does not imply unlimited or permanent free access. |
| Linux | Node launchers are provided. Studio requires a separately configured Wine/Vinegar installation. |
| Release verification | Automated Luau simulations, Node tests, and build checks are included. Native Studio execution, Windows/macOS launcher execution, and live provider/OAuth sessions were not verified in the release environment. |

For size limits, timeout settings, connection errors, and recovery steps, see [Troubleshooting](docs/TROUBLESHOOTING.md).

## Project Structure

| Path | Contents |
| --- | --- |
| [`plugin/`](plugin/) | Built RBXM/RBXMX plugins and Luau source in `plugin/src/` |
| [`scripts/`](scripts/) | OS-specific installers and separate router/bridge launchers |
| [`runtime/`](runtime/) | Node entry points, plugin folder detection, and process management |
| [`bridge/`](bridge/) | Local server, provider catalog, and bridge tests |
| [`assets/`](assets/) | Provider logos and upstream license information |
| [`tests/`](tests/) | Luau simulation harness, fixtures, and verification reports |
| [`docs/`](docs/) | Setup, architecture, troubleshooting, and publishing guides |
| [`tools/`](tools/) | Release packaging utilities |
| [`SHA256SUMS.txt`](SHA256SUMS.txt) | Package checksums, including the plugin checksum checked by the installer |

## Development and Releases

Run the Node test suite from the project root:

```sh
npm test
```

Follow [CONTRIBUTING.md](CONTRIBUTING.md) for Luau verification and rebuilding the plugin. Read the [publishing guide](docs/PUBLISHING.md) before preparing a GitHub Release; the release packager regenerates checksums and validates the archive.

## Documentation

| Guide | Purpose |
| --- | --- |
| [Installation](docs/INSTALLATION.md) | Setup, plugin paths, service arguments, and upgrades |
| [Providers](docs/PROVIDERS.md) | OAuth, API keys, custom endpoints, models, and capabilities |
| [How It Works](docs/HOW-IT-WORKS.md) | Chat lifecycle and tool execution |
| [Architecture](docs/ARCHITECTURE.md) | Internal components and integration contracts |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Limits, errors, and recovery |
| [Test Report](docs/TEST-REPORT.md) | Automated checks and verification scope |
| [Release Notes](docs/RELEASE_NOTES.md) | Changes in the packaged release |
| [Changelog](CHANGELOG.md) | Version history |

This README is in English. The detailed guides are currently in Indonesian.

## Acknowledgements and Licensing

The provider catalog and 75 original provider PNGs come from the referenced 9router snapshot. Its upstream MIT license is retained in [`assets/9router-LICENSE.txt`](assets/9router-LICENSE.txt). Provider names and logos belong to their respective owners.

See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for sources and attribution. This package does not assign a new license to ForgePilot's own source code.
