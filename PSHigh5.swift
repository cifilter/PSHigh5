#!/usr/bin/swift sh

// -------------------------------------------------------------------------------
// PSHigh5
// https://github.com/cifilter/PSHigh5
//
// AUTHOR
// ======
// Shannon Potter
// shannon@calayer.com
// https://github.com/cifilter
//
// LICENSE
// =======
// This script is licensed under the Creative Commons Zero 1.0 Universal License
// (https://creativecommons.org/publicdomain/zero/1.0/):
//
// To the extent possible under law, Shannon Potter has waived all copyright and
// related or neighboring rights to PSHigh5.
//
// This work is published from: United States
//
// -------------------------------------------------------------------------------

// v1.1

// MARK: - Imports

import AppKit
import WebKit

import SwiftSoup // @scinfu

// The core premise of this script involves rendering the product site's HTML in a web browser;
// attempting to simply request the contents of the page URL will return a shallow "your browser
// must support JavaScript" page. Techniques to use various headless browser libraries failed, so
// this script relies on the awesome WebKit framework to use its browser to do all the heavy lifting.

// MARK: - AppKit Hook

class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {

    // This window can be any size you want; however, it's _possible_ that a very narrow window size
    // could result in an unexpected rendered DOM due to mobile-friendly display widths.
    let window: NSWindow = .init(
        contentRect: NSMakeRect(0.0, 0.0, 960.0, 540.0),
        styleMask: [.titled, .resizable, .closable],
        backing: .buffered,
        defer: false,
        screen: nil
    )

    private let webView: WKWebView = .init()

    private lazy var script: Script = .init(webView: self.webView)

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.window.delegate = self
        self.window.makeKeyAndOrderFront(nil)

        self.webView.frame = self.window.contentView?.bounds ?? .zero
        self.webView.autoresizingMask = [.width, .height]
        self.webView.navigationDelegate = self

        self.window.contentView?.addSubview(self.webView)

        self.script.run()
    }

}

// MARK: - Window Delegate

extension AppDelegate: NSWindowDelegate {

    // See 'NSWindowDelegate`.
    func windowWillClose(_ notification: Notification) {
        app.terminate(self)
    }

}

// MARK: - App Execution

// This creates an ad-hoc application delegate and starts the main run loop.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// MARK: - Script

class Script: NSObject {

    // MARK: - Properties

    /// The principle web view that renders product pages, and from which the resultant HTML is analyzed.
    let webView: WKWebView

    /// A timer that starts when a product page load operation begins. If this timer exceeds a certain number
    /// of seconds—defined below—then the page load is cancelled and attempted again.
    private var pageLoadingTimer: Timer?

    /// The current product page URL the script will use.
    private var productPageUrl: URL = .init(fileURLWithPath: "")  // Placeholder for non-optional URL

    /// The number of successive CAPTCHAs that have been displayed. If this exceeds a certain number—defined
    /// below—then the user is prompted to complete the CAPTCHA challenge in order for the script to resume.
    private var successiveCAPTCHACount: Int = 0

    /// The web content rules that block the web view from loading a massive product video file every time
    /// the page is loaded.
    static private let blockRules =
        """
        [{
            "trigger": {
                "url-filter": ".*",
                "resource-type": ["media"]
            },
            "action": {
                "type": "block"
            }
        }]
        """

    /// The time formatter used for logging to standard output.
    static private var timeFormatter: DateFormatter = {
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .long

        return timeFormatter
    }()

    // MARK: - Initialization

    /// Creates a new script instance using the provided web view.
    ///
    /// - Parameter webView: The web view that is used to load PlayStation 5 product pages to analyze.
    ///
    init(webView: WKWebView) {
        self.webView = webView

        super.init()

        self.configureWebView()
    }

    /// Configures the provided web view to start loading page content, excluding content defined by the static
    /// `blockRules` variable.
    private func configureWebView() {
        self.webView.navigationDelegate = self

        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "com.cifilter.PSHigh5.ContentRuleList",
            encodedContentRuleList: Self.blockRules,
            completionHandler: { [weak self] contentRuleList, error in
                guard let self = self else { return }
                guard let contentRuleList = contentRuleList else {
                    self.exitWith(.generalError, error?.localizedDescription ?? nil)
                }

                self.webView.configuration.userContentController.add(contentRuleList)
            }
        )
    }

    // MARK: - Script Execution

    /// Executes the script.
    ///
    /// - Parameters:
    ///   - asynchronous: Whether or not the script should be executed asynchronously.
    ///   - delay: How long of a delay before performing the actual script execution.
    ///
    /// - Note: If `asynchronous` is `true` and `delay` is non-zero, this function will still immediately return.
    /// The asynchronous dispatch will have been enqueued with the provided delay.
    ///
    func run(asynchronously asynchronous: Bool = false, after delay: TimeInterval = 0.0) {
        let executeScript = {
            guard let url = URL.PS5.next() else {
                self.exitWith(.generalError, "Invalid product page URL.")
            }

            self.productPageUrl = url

            let urlRequest = URLRequest(url: url)

            self.webView.navigationDelegate = self
            self.webView.load(urlRequest)
        }

        if asynchronous {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: executeScript)
        } else {
            Thread.sleep(forTimeInterval: delay)
            executeScript()
        }
    }

    /// Stops the web view from loading any additional resources on the current product page.
    func stop() {
        self.webView.stopLoading()
        self.webView.navigationDelegate = nil
    }

    /// Evaluates the loaded product page's HTML.
    fileprivate func evaluateLoadedHTML() {
        self.webView.evaluateJavaScript(
            "document.documentElement.outerHTML.toString()",
            completionHandler: { [weak self] (html: Any?, error: Error?) in
                guard let self = self else { return }
                guard let html = html as? String else {
                    self.exitWith(.generalError, error?.localizedDescription ?? nil)
                }

                if html.contains("When you reach the front of the queue") {
                    // If the script gets to this point, then it has detected that the store page is showing
                    // the product queue. An alert sound will be played to notify the user.
                    self.log("PlayStation Direct queue is up! ⚠️", withPrompt: true)
                    self.log("Product page URL: \(self.productPageUrl.absoluteString)")

                    self.playSound(named: "alert.m4a", andExitWith: .success)
                } else if html.contains("We’re trying to get you in") {
                    // If the script gets to this point, then it has encountered a CAPTCHA challenge _not_
                    // related to the store queue. As of 11/19/2020, it appears that this rate-limiting CAPTCHA
                    // for regular page views can be subverted by simply reloading the page immediately. If this
                    // fails three times, then the user is prompted to solve the CAPTCHA and press **Enter** to
                    // proceed.
                    if self.successiveCAPTCHACount < 3 {
                        self.log("Product page CAPTCHA detected! Attempting to subvert it...")
                        self.successiveCAPTCHACount += 1
                        self.run(after: 3.0)
                    } else {
                        self.promptToSolveCAPTCHA()
                        self.stop()
                    }
                } else {
                    // If the script gets to this point, then it means the product page was able to be successfully
                    // loaded.
                    self.successiveCAPTCHACount = 0

                    do {
                        let document = try SwiftSoup.parse(html)
                        if self.heroProductIsInStock(in: document) {
                            // At this point, the product page has been loaded successfully, and an "Add to Cart"
                            // button was detected for the PlayStation 5. A fanfare sound is played to alert the user.
                            self.log("High five! 🙏 PS5 is in stock! 🥳", withPrompt: true)
                            self.log("Product page URL: \(self.productPageUrl.absoluteString)")

                            self.playSound(named: "success.m4a", andExitWith: .success)
                        } else {
                            // At this point, the product page has been loaded successfully, but the product is out
                            // of stock. After a short delay, the script will be executed again.
                            self.log("PS5 is sold out. 😡 Trying again...")
                            self.run(asynchronously: true, after: 3.0)
                        }
                    } catch {
                        self.exitWith(.generalError, error.localizedDescription)
                    }
                }
            }
        )
    }

    /// Whether or not the provided HTML document indicates that the hero product—that is, the PlayStation 5 and
    /// _not_ some other product lower down the page—is available to be added to a cart.
    ///
    /// - Parameter document: A parsed `SwiftSoup.Document` instance.
    ///
    /// - Returns `true` if an "Add to Cart" button was detected in the correct place. Otherwise, `false`.
    ///
    private func heroProductIsInStock(in document: Document) -> Bool {
        let addToCartButtonIsVisible =
            try? document
            .select("div.productHero-info div.button-placeholder button.add-to-cart")
            .first()
            .map { !$0.hasClass("hide") }

        return addToCartButtonIsVisible ?? false
    }

    /// Logs a message to standard output.
    ///
    /// - Parameters:
    ///   - message: The text message to log.
    ///   - shouldPrompt: Whether or not a `BEL` character should be prepended to `message`, which results in
    ///   `Termina.app` bouncing in the Dock and showing a badge to get the user's attention.
    ///
    fileprivate func log(_ message: String, withPrompt shouldPrompt: Bool = false) {
        let message = shouldPrompt ? "\u{7}" + message : message
        print("[LOG] \(Self.timeFormatter.string(from: .init())):", message)
    }

    /// Exits the script.
    ///
    /// - Parameters:
    ///   - status: The `ExitStatus` with which to exit the script.
    ///   - message: An optional text message to display along with the exit action.
    ///
    /// - Returns `Never` to indicate that this function never returns; that is, execution is unconditionally
    /// halted at this point.
    ///
    fileprivate func exitWith(_ status: ExitStatus, _ message: String? = nil) -> Never {
        let output: String = ["\(status)", message].compactJoined(separator: ": ")

        print(output)
        exit(status.exitCode)
    }

}

// MARK: - Web View Navigation Delegate

extension Script: WKNavigationDelegate {

    // See `WKNavigationDelegate`.
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        self.log("Began loading product page.")

        // Change the time interval value below to affect how long the script will wait for a page to finish
        // loading before it cancels it and tries again.
        self.pageLoadingTimer?.invalidate()
        self.pageLoadingTimer = .scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.log("Page loading took too long. Reloading...")

            self?.pageLoadingTimer?.invalidate()
            self?.pageLoadingTimer = nil

            self?.webView.stopLoading()
            self?.run()
        }
    }

    // See `WKNavigationDelegate`.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.log("Finished loading product page.")
        self.pageLoadingTimer?.invalidate()
        self.pageLoadingTimer = nil

        self.evaluateLoadedHTML()
    }

    // See `WKNavigationDelegate`.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.log("Web view content process was terminated! Reloading...")
        self.run()
    }

}

// MARK: - Nested Types

private extension Script {

    /// A type that indicates the exit status of the script.
    enum ExitStatus: CustomStringConvertible {

        /// The script exited successfully.
        case success

        /// The script exited with an error code.
        case error(Int32)

        /// A convenience variable that represents a general script exit error, which is generally used
        /// universally to indicate a problem.
        static var generalError: Self { .error(1) }

        /// The exit code associated with the exit status.
        var exitCode: Int32 {
            switch self {
            case .success: return 0
            case let .error(code): return code
            }
        }

        // See `CustomStringConvertible`.
        var description: String {
            switch self {
            case .success:
                return "[SUCCESS] (0)"
            case let .error(code):
                return "[ERROR] (\(code))"
            }
        }

    }

}

// MARK: - Utilities

private extension Script {

    // Taken from https://stackoverflow.com/a/59957764/89170
    /// Executes a command in the shell.
    ///
    /// - Parameter command: The full command string to execute in the shell.
    ///
    /// - Returns A tuple containing the command output and exit termination status of the command's execution.
    ///
    @discardableResult func shell(_ command: String) -> (String?, Int32) {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", command]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)
        task.waitUntilExit()
        return (output, task.terminationStatus)
    }

    /// Plays a sound file.
    ///
    /// - Parameters:
    ///   - filename: The filename of the audio file inside the root-level `.sounds` folder to play. The extension
    ///   should be included.
    ///   - exitStatus: An optional exit status to emit after playing the sound, which results in the termination
    ///   of the script.
    ///
    func playSound(named filename: String, andExitWith exitStatus: ExitStatus? = nil) {
        DispatchQueue.global().async {
            self.shell("`which afplay` `pwd`/.sounds/\(filename)")
            exitStatus.do { self.exitWith($0) }
        }
    }

    /// Prompts the user to solve the displayed CAPTCHA in the browser window.
    ///
    /// - Important: The script will halt here until **Enter** it pressed in the terminal window. The user should
    /// first solve the CAPTCHA challenge in the browser window before resuming the script.
    ///
    func promptToSolveCAPTCHA() {
        self.log("Couldn't subvert CAPTCHA...", withPrompt: true)
        self.log("Solve it, then press Enter:")

        DispatchQueue.global(qos: .background).async {
            _ = readLine(strippingNewline: false)
            self.run(asynchronously: true)
        }
    }

}

private extension Array where Element == String? {

    /// Joins an non-optional string components.
    ///
    /// - Parameter separator: The string separator to insert between each string component.
    ///
    /// - Returns The resultant joined string.
    ///
    func compactJoined(separator: String) -> String {
        return self.compactMap { $0 }.joined(separator: separator)
    }

}

private extension Optional {

    /// Performs a function only if `self` is non-optional.
    ///
    /// - Parameter f: A throwing function that takes in a non-optional wrapped value and returns `Void`.
    ///
    func `do`(_ f: (Wrapped) throws -> Void) rethrows {
        guard let unwrapped = self else { return }
        try f(unwrapped)
    }

}

private extension URL {

    /// Static constants that represent PlayStation 4 product URLs.
    struct PS4 {

        /// The product URL for the PS4 Pro.
        static let pro: URL? = URL(
            string: "https://direct.playstation.com/en-us/consoles/console/" +
            "playstation-4-pro-1tb-console.3003346"
        )

    }

    /// Static constants that represent PlayStation 5 product URLs.
    struct PS5 {

        /// A collection of all PS5 product pages.
        private static let all: [URL?] = [PS5.disc, PS5.digital]

        /// The current product page index represented by `Self.all`.
        private static var nextIndex: Int = 0

        /// The product URL for the PS5 Disc Edition.
        static let disc: URL? = URL(
            string: "https://direct.playstation.com/en-us/consoles/console/" +
            "playstation5-console.3005816"
        )

        /// The product URL for the PS5 Digital Edition.
        static let digital: URL? = URL(
            string: "https://direct.playstation.com/en-us/consoles/console/" +
            "playstation5-digital-edition-console.3005817"
        )

        /// Returns the next product URL.
        ///
        /// - Returns The URL of the next product in `Self.all`, wrapping back around to the beginning if the
        /// next index would exceed the total number of URLs.
        ///
        static func next() -> URL? {
            Self.nextIndex = (Self.nextIndex + 1) % Self.all.count
            return Self.all[Self.nextIndex]
        }

    }

}
