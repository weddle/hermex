import XCTest
@testable import HermesMobile

final class OnboardingFlowTests: XCTestCase {
    func testPrimaryButtonTitlesFollowPagerFlow() {
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 0), "Get Started")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 1), "Set Up")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 2), "Continue")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 3), "Continue")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 4), "Connect")
    }

    func testCopyReminderOnlyAppliesToAgentPromptPageWithoutCopy() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                hasCopiedAgentPrompt: false
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                hasCopiedAgentPrompt: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                hasCopiedAgentPrompt: false,
                hasBypassedCopyReminder: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.connectPageIndex,
                hasCopiedAgentPrompt: false
            )
        )
    }

    func testForwardSwipeFromAgentPromptRequiresCopyOrBypass() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                hasCopiedAgentPrompt: false
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                hasCopiedAgentPrompt: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                hasCopiedAgentPrompt: false,
                hasBypassedCopyReminder: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 1,
                hasCopiedAgentPrompt: false
            )
        )
    }

    func testConnectFocusClearsWhenLeavingConnectPage() {
        XCTAssertTrue(OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(3))
        XCTAssertFalse(OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(OnboardingFlowPolicy.connectPageIndex))
    }

    func testServerShortcutShowsBeforeConnectPageOnly() {
        XCTAssertTrue(OnboardingFlowPolicy.showsServerShortcut(for: 0))
        XCTAssertTrue(OnboardingFlowPolicy.showsServerShortcut(for: 3))
        XCTAssertFalse(OnboardingFlowPolicy.showsServerShortcut(for: OnboardingFlowPolicy.connectPageIndex))
    }

    func testAgentSetupPromptDefaultsToSafeStateAwareTailscaleServe() {
        let prompt = OnboardingFlowPolicy.agentSetupPrompt

        let requiredInstructions = [
            "hermes dashboard",
            "not the older separate web UI",
            "do not add a separate web-ui package",
            "Inventory before changing anything",
            "lsof -nP -iTCP:9119 -sTCP:LISTEN",
            "Do not kill an unknown process",
            "command -v hermes",
            "hermes --version",
            "hermes dashboard --help",
            "command -v tailscale",
            "tailscale version",
            "tailscale status",
            "Only if `command -v tailscale` reports that Tailscale is absent",
            "correct method for this OS",
            "rerun `tailscale version`, `tailscale status`, and the authentication check",
            "tailscale serve status",
            "tailscale funnel status",
            "Do not run tailscale serve reset",
            "127.0.0.1:9119",
            "hermes dashboard --host 127.0.0.1 --port 9119 --no-open",
            "Do not configure auto-start yourself",
            "Do not touch `~/Library/LaunchAgents/` or restart Mac services",
            "only if HTTPS port 443 at the root path is free",
            "tailscale serve --bg 9119",
            "Never enable Funnel",
            "HTTPS consent",
            "certificate-transparency disclosure",
            "curl --fail http://127.0.0.1:9119/api/status",
            "actual ts.net HTTPS URL",
            "verify that exact URL's `/api/status` endpoint",
            "Do not use Cloudflare",
            "Optimize for Tailscale"
        ]

        for instruction in requiredInstructions {
            XCTAssertTrue(prompt.contains(instruction), "Missing native-dashboard setup instruction: \(instruction)")
        }

        XCTAssertFalse(prompt.contains("Node.js"))
        XCTAssertFalse(prompt.contains("HERMES_WEBUI_PASSWORD"))
        XCTAssertFalse(prompt.contains("python3 bootstrap.py"))
        XCTAssertFalse(prompt.contains("./ctl.sh"))
        XCTAssertFalse(prompt.contains("fall back: bind the server to 0.0.0.0"))
        XCTAssertFalse(prompt.contains("Otherwise configure auto-start appropriate for this OS"))
    }

    func testTailscaleAppStoreURLUsesITMSDeepLink() {
        XCTAssertEqual(
            OnboardingFlowPolicy.tailscaleAppStoreURL.absoluteString,
            "itms-apps://apps.apple.com/us/app/tailscale/id1470499037"
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.tailscaleAppStoreFallbackURL.absoluteString,
            "https://apps.apple.com/us/app/tailscale/id1470499037"
        )
    }

    func testConnectPageIndexIsFinalPagerPage() {
        XCTAssertEqual(OnboardingFlowPolicy.connectPageIndex, OnboardingFlowPolicy.pageCount - 1)
    }
}
