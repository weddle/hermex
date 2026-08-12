import Foundation

enum OnboardingFlowPolicy {
    static let pageCount = 5
    static let connectPageIndex = 4
    static let agentPromptPageIndex = 2

    static let agentSetupPrompt = """
Set up the Hermes Agent dashboard on this machine for access from my iPhone via Tailscale.

The dashboard is the native Hermes Agent web dashboard (the `hermes dashboard` command), not the older separate web UI. Use the installed Hermes Agent CLI; do not add a separate web-ui package.

Inventory before changing anything:
- Locate any existing Hermes Agent installation, `hermes` binary, configuration, dashboard service, and running process. Reuse and preserve working state instead of reinstalling it.
- Check who owns port 9119 with `lsof -nP -iTCP:9119 -sTCP:LISTEN` (or the OS equivalent). Do not kill an unknown process; stop and report the owner or conflict.
- Run `command -v hermes`, `hermes --version`, and `hermes dashboard --help` to confirm the dashboard subcommand is available. If `hermes` is absent, install Hermes Agent using the correct method for this OS, then rerun the version and help checks before proceeding.
- Run `command -v tailscale`, `tailscale version`, and `tailscale status`. If Tailscale is installed, do not reinstall it. Only if `command -v tailscale` reports that Tailscale is absent, install it using the correct method for this OS, then rerun `tailscale version`, `tailscale status`, and the authentication check before proceeding. If it is installed but not running or authenticated, explain the exact user action required.
- Run `tailscale serve status` and `tailscale funnel status` before changing routes. Preserve every existing Serve and Funnel route. Do not run tailscale serve reset, remove routes, or overwrite an occupied HTTPS listener or path.

Start the native Hermes Agent dashboard safely:
- Run `hermes dashboard --host 127.0.0.1 --port 9119 --no-open` (or the supported launcher for this installation) so it stays bound to loopback. Preserve an existing dashboard configuration; do not truncate or replace config files.
- Reuse an existing service when present. Do not configure auto-start yourself. Propose the exact OS-appropriate commands and steps around the verified launcher, then wait for me to run them. Do not touch `~/Library/LaunchAgents/` or restart Mac services.

Expose only the localhost dashboard through private Tailscale HTTPS:
- First confirm from `tailscale serve status` and `tailscale funnel status` that HTTPS port 443 at the root path is unused. Run `tailscale serve --bg 9119` only if HTTPS port 443 at the root path is free. Never enable Funnel.
- If Tailscale requires HTTPS consent, show me the consent URL and explain the certificate-transparency disclosure before continuing.
- If the root listener or route is already occupied, do not reset or replace it. Stop and report the exact conflict and safe options.

Verify in this order:
1. Confirm localhost health with `curl --fail http://127.0.0.1:9119/api/status`.
2. Read back `tailscale serve status`, identify the actual ts.net HTTPS URL, and verify that exact URL's `/api/status` endpoint with `curl --fail https://<actual-ts.net-hostname>/api/status`.

Treat binding to `0.0.0.0` or using a Tailscale IP over plain HTTP as an explicit manual fallback only. Explain the additional exposure and require my confirmation. Do not automate it.

Reply with the exact HTTPS URL, the dashboard launch command, and both health-check results, plus any remaining action required on my iPhone.
Do not use Cloudflare. Optimize for Tailscale + iPhone.
"""

    static let tailscaleAppStoreURL = URL(string: "itms-apps://apps.apple.com/us/app/tailscale/id1470499037")!

    static let tailscaleAppStoreFallbackURL = URL(string: "https://apps.apple.com/us/app/tailscale/id1470499037")!

    static func primaryButtonTitle(for page: Int) -> String {
        switch page {
        case 0:
            return String(localized: "Get Started")
        case 1:
            return String(localized: "Set Up")
        case connectPageIndex:
            return String(localized: "Connect")
        default:
            return String(localized: "Continue")
        }
    }

    static func shouldShowCopyReminder(
        page: Int,
        hasCopiedAgentPrompt: Bool,
        hasBypassedCopyReminder: Bool = false
    ) -> Bool {
        page == agentPromptPageIndex && !hasCopiedAgentPrompt && !hasBypassedCopyReminder
    }

    static func shouldInterceptForwardNavigationFromAgentPrompt(
        from oldPage: Int,
        to newPage: Int,
        hasCopiedAgentPrompt: Bool,
        hasBypassedCopyReminder: Bool = false
    ) -> Bool {
        oldPage == agentPromptPageIndex
            && newPage > oldPage
            && !hasCopiedAgentPrompt
            && !hasBypassedCopyReminder
    }

    static func shouldClearConnectFocusWhenLeavingPage(_ page: Int) -> Bool {
        page != connectPageIndex
    }

    static func showsServerShortcut(for page: Int) -> Bool {
        page < connectPageIndex
    }
}
