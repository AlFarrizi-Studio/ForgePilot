# ForgePilot 3.5.0 Patch and Upgrade

This patch keeps the release version at **3.5.0**. The ZIP contains rebuilt `plugin/ForgePilot.rbxm` and `plugin/ForgePilot.rbxmx`, updated source, bridge, documentation, and checksums.

## What changed

| Area | Fix |
| --- | --- |
| Question answers | Save selected IDs, submit custom text with its payload, validate through the current question, and preserve false/zero answers. |
| Chat disclosures | Compact Question/Provider Limit headers, bounded expansion, Close controls, answer/recovery folding, and live collapsed countdowns. |
| Approval | Add Always Approve beside Approve and Decline; persist the preference and expose its switch in Settings → Agent. |
| Shift+Enter | Read the Return event's Shift modifier, preserve cursor/selection through native focus loss, and avoid duplicate delivery. |
| Tool/build counts | Remove numeric task/round caps from both protocols, settings, and prompts. Yield between actions/turns so Stop remains available. |
| Provider editor | Keep diagnostic retry states separate from the current chat; restore buttons and text inputs after failed checks, Stop, and timeout. Show why configuration is locked during an active chat. |
| Dropdown input | Close the shared menu and its dismissal layer when the owner is hidden, disabled, detached, destroyed, or the widget is closed. |
| Diagnostic requests | Respect temporary one-attempt retry overrides and bounded request deadlines without changing saved chat preferences. |
| Retry ownership | Ignore unrelated and late retry callbacks; keep scheduled retries and recovery working for the current agent task. |
| Plugin icon | Original `assets/ForgePilot-Icon-512.png`; toolbar and header reference the published ForgePilot asset thumbnail. The header keeps a native mark until the image loads. |
| Reported Sky error | Remove the invalid `GetAncestors()` call. Use `Instance:IsA()` to select safe properties by class inheritance, rather than by parent objects. |
| Property inspection | Read actual values, preserve `false` and `0`, use `GetTags()`, merge inherited Part fields, and include Sky properties. |
| Auto Retry | Use one retry controller for streaming and complete responses. Fix sleep cancellation and numeric setting persistence. |
| Recovery | Preserve provider status/body/retry headers, respect mandatory cooldowns, discard incomplete tool calls, and reset only the current streamed answer before retrying. |

## Overwrite an existing installation

1. Close Roblox Studio and stop the ForgePilot bridge. Keep a backup of your current project folder.
2. Extract the complete updated ZIP. Copy its `ForgePilot/` contents over your existing ForgePilot folder, or use a fresh folder. Preserve your own workspaces and local configuration.
3. Run the installer for your operating system, or `npm run install:plugin` from that folder. The installer backs up the existing plugin and checks the updated checksum.
4. Start **9router** and the **bridge** separately using the provided launchers. If using a fresh folder, pair Studio with the token shown by the bridge.
5. Reopen Studio. Avoid enabling a local copy and a Creator Store copy of ForgePilot at the same time.
6. Open **Settings → Retry**. Existing settings are retained; enable Auto Retry and select **OpenCode** if desired.
7. In **Settings → AI & Provider**, open a profile and run **Test connection**. After the check finishes or is stopped, verify **Back**, the editor tabs, text inputs, and **Save changes** respond. A failed check must not lock chat. During an active chat, the footer explains the temporary configuration lock.
8. In chat, verify **Enter** sends and **Shift+Enter** adds a line. Open a Question, select or type an answer, and submit it; the answered result folds automatically. Open/Close a Provider Limit panel to inspect recovery.

The approval card now offers **Approve**, **Decline**, and **Always Approve**. Always Approve saves the preference and approves the current action. Disable it in **Settings → Agent** to restore prompts. Plan mode and disabled tool permissions continue to determine which actions are available.

Tool call/build action count settings are removed. Old saved values are discarded when settings load. Provider quotas, per-request limits, and output/context limits remain as documented.

The installer copies the plugin; it does not publish a Creator Store update or replace a store copy through Roblox's update mechanism.

## Update the existing Creator Store listing

Use the rebuilt plugin as the source for your update. In Studio's plugin publishing flow, select your existing ForgePilot asset **82058489576798** as the update target. Verify the asset and owner before publishing.

If the listing does not already use the new artwork, upload `assets/ForgePilot-Icon-512.png` as its icon in the asset configuration. The toolbar and header load that listing's thumbnail; a source ZIP cannot change store metadata by itself. Roblox may cache a previous thumbnail until the update is available.

For GitHub, upload the updated source and replace the ZIP attachment on the existing **v3.5.0** release. Package and version strings remain **3.5.0**. The [publishing guide](PUBLISHING.md) covers the repository workflow.

## Configure Auto Retry

Click **Retry: On/Off** next to **New chat** to open Retry settings. Use **Enable Auto Retry** to turn recovery on or off.

- **OpenCode:** 2-second base, doubling, up to 25% extra jitter, local fallback capped at 30 seconds.
- **Maximum Retries:** additional requests after the initial attempt; default 5, allowed 0–20.
- **Maximum Automatic Wait:** default 120 seconds. If a required provider cooldown exceeds this limit, the turn ends with the required wait shown instead of keeping chat busy.
- **Other strategies:** Adaptive, Exponential, Linear, or a custom delay sequence. Per-provider overrides remain available.
- **Stop/Cancel Retry:** interrupts pending generation and countdowns. No further request starts after cancellation.

Provider retry/reset headers and known cooldowns take precedence. An estimated scheduler cooldown does not override an explicit `Retry-After` value in the OpenCode preset.

Temporary failures such as 429, 408, 5xx, network disconnects, idle timeouts, and premature stream termination can recover automatically. Wrong credentials, invalid requests/models, and local programming errors require correction. The reported Sky error is fixed in code; retry alone could not fix it.

Each retry starts the current provider request again. It replaces that turn's partial text/reasoning and discards incomplete tool calls. Completed tool actions and previous turns are preserved. When recovery is exhausted, useful partial output remains visible with the error. Requests may still count toward quota or billing.

## Verification and limits

See the [test report](TEST-REPORT.md) for results and scope. Tests cover the Sky failure, inherited properties, actual retry waits, cancellation, partial stream recovery, permanent errors, numeric settings, bridge retry metadata, and icon loading.

Native Roblox Studio, live provider accounts/OAuth, and Windows/macOS launcher execution are not exercised in this environment.

The provider-freeze regression runs with the production retry subscription enabled, including actual complete/stream diagnostics and an agent chat that recovers from HTTP 503. It also checks unrelated/stale retry events and shared dropdown cleanup. This covers two reproduced input-lock defects; verify the affected menu in native Studio after installing the rebuilt plugin.

The chat-controls regression covers the real Question manager/widgets, approval persistence and reversal, native Return modifier events, responsive action rows, live provider folding, 64 native tool rounds, 210 build actions, structured actions, and Stop during an uncapped task.

## References

- [Roblox Instance API](https://create.roblox.com/docs/reference/engine/classes/Instance): inheritance, properties, and tags.
- [Roblox Sky API](https://create.roblox.com/docs/reference/engine/classes/Sky): Sky properties.
- [Roblox asset URI reference](https://create.roblox.com/docs/projects/assets#rbxthumb): published asset thumbnails.
- [Roblox TextBox API](https://create.roblox.com/docs/reference/engine/classes/TextBox) and [InputObject API](https://create.roblox.com/docs/reference/engine/classes/InputObject): native FocusLost input and modifier handling.
- [OpenCode retry source](https://github.com/anomalyco/opencode/blob/c789868/packages/opencode/src/session/retry.ts): backoff, jitter, classification, and retry limits. ForgePilot adds bounded fallback waits, settings, bridge metadata, and cancellation.
