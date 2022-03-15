//
//  SwiftuiViewController.swift
//  springdise
//
//  Created by Jeff E Mandel on 2/27/22.
//
//  Demonstrates displaying the Okta login in Swiftui and using the access token. Deals with the problem of presenting the signInWithBrowser, which wants a ViewController.
//  To embed this in your Swiftui project, do something like:
//  .sheet(isPresented: $showInfoModalView) { signin(showInfoModalView: $showInfoModalView)}
//
//  Note that this requires iOS > 14

import Foundation
import OktaOidc
import UIKit
import SwiftUI
import os

struct oktaView : View {
    /// This is a SwiftUI View that is embedded in the UIKit View (which is embedded in the main SwiftUI View)
    ///  We have 3 Bindings:
    ///     oktaStatus is a string that tells us what happened during authentication
    ///     isLoading is used to hide the ProgressView when we get done
    ///     showInfoModalView is passed back up to the SwiftUI View we're embedded in to let the main routine hide the sheet when the user hits the "OK" button
    
    @Binding var oktaStatus: String
    @Binding var isLoading: Bool
    @Binding var showInfoModalView: Bool

    var body: some View {
        VStack {
            ProgressView("Authenticating")
                .progressViewStyle(CircularProgressViewStyle())
                .opacity(isLoading ? 1.0 : 0.0)
                .padding()
            Text(oktaStatus)
                .padding()
            Button("OK") {
                self.showInfoModalView = false
            }
        }
    }
}

struct signin : UIViewControllerRepresentable {
    /// This View creates the UIKit View. Note that oktaStatus and isLoading belong to this struct, so are States
    typealias UIViewControllerType = SignInViewController
    @State var oktaStatus: String = ""
    @State var isLoading : Bool = true
    @Binding var showInfoModalView: Bool

    
    // instatiate the ViewController, passing the Bindings to the init() function
    func makeUIViewController(context: Context) -> SignInViewController {
        return SignInViewController(oktaStatus: $oktaStatus, isLoading: $isLoading, showInfoModalView: $showInfoModalView)
    }
    
    func updateUIViewController(_ uiViewController: SignInViewController, context: Context) {
    }
}


class SignInViewController: UIViewController, OktaNetworkRequestCustomizationDelegate,OKTTokenValidator {
    /// Configure unified logger for viewing the OktaNetworkRequestCustomizationDelegate messages
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "network")

    @Binding var oktaStatus : String
    @Binding var isLoading : Bool
    @Binding var showInfoModalView: Bool

    private var oktaAppAuth: OktaOidc?
    /// The stateManager is the object that provides our tokens. If it changes, we write it to secure storage
    private var authStateManager: OktaOidcStateManager? {
        didSet {
            authStateManager?.writeToSecureStorage()
        }
    }

    /// When we create the ViewController, save the bindings to self variables
    public init(oktaStatus: Binding<String> , isLoading: Binding<Bool> , showInfoModalView: Binding<Bool> ) {
        self._oktaStatus = oktaStatus
        self._isLoading = isLoading
        self._showInfoModalView = showInfoModalView
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// OktaNetworkRequestCustomizationDelegate required functions; we log at debug level
    func customizableURLRequest(_ request: URLRequest?) -> URLRequest? {
        if let request = request {
            logger.debug("request = \(request)")
        }
        return request
    }
    
    func didReceive(_ response: URLResponse?) {
        if let response = response {
            logger.debug("response = \(response)")
        }
    }
    
    /// OKTTokenValidator required functions
    func isIssued(atDateValid issuedAt: Date?, token tokenType: OKTTokenType) -> Bool {
        guard let issuedAt = issuedAt else {
            return false
        }
        
        let now = Date()
        
        return fabs(now.timeIntervalSince(issuedAt)) <= 200
    }
    
    func isDateExpired(_ expiry: Date?, token tokenType: OKTTokenType) -> Bool {
        guard let expiry = expiry else {
            return false
        }
        
        let now = Date()
        
        return now >= expiry
    }
    
    private var isUITest: Bool {
        return ProcessInfo.processInfo.environment["UITEST"] == "1"
    }
    
    private var testConfig: OktaOidcConfig? {
        return try? OktaOidcConfig(with: [
            "issuer": ProcessInfo.processInfo.environment["ISSUER"]!,
            "clientId": ProcessInfo.processInfo.environment["CLIENT_ID"]!,
            "redirectUri": ProcessInfo.processInfo.environment["REDIRECT_URI"]!,
            "logoutRedirectUri": ProcessInfo.processInfo.environment["LOGOUT_REDIRECT_URI"]!,
            "scopes": "openid profile offline_access"
        ])
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    /// Set up our SwiftUI view and pass the bindings
    func showSwiftView() {
        let contentView = UIHostingController(rootView: oktaView(oktaStatus: self.$oktaStatus, isLoading: $isLoading, showInfoModalView: $showInfoModalView))
        addChild(contentView)
        view.addSubview(contentView.view)
        contentView.view.translatesAutoresizingMaskIntoConstraints=false
        contentView.view.topAnchor.constraint(equalTo:view.topAnchor).isActive=true
        contentView.view.bottomAnchor.constraint(equalTo:view.bottomAnchor).isActive=true
        contentView.view.leftAnchor.constraint(equalTo:view.leftAnchor).isActive=true
        contentView.view.rightAnchor.constraint(equalTo:view.rightAnchor).isActive = true
    }
    
    /// Do the work
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        showSwiftView()
        
        /// get the default configuration from the Okta.plist and set the delegates
        let configuration = try? OktaOidcConfig.default()
        configuration?.requestCustomizationDelegate = self
        configuration?.tokenValidator = self
        
        /// Initialize the Okta  with our configuration
        oktaAppAuth = try? OktaOidc(configuration: isUITest ? testConfig : configuration)
        guard let config = oktaAppAuth?.configuration else {
            self.oktaStatus = "Bad configuration provided!"
            self.isLoading = false
            return
        }
        

        /// We have an acceptable configuration. See if we've already stored a stateManager for this configuration
        self.authStateManager = OktaOidcStateManager.readFromSecureStorage(for: config)
        self.authStateManager?.requestCustomizationDelegate = self
//        self.authStateManager = nil
        if self.authStateManager == nil {
            /// We don't have a stored stateManager, so call signInWithBrowser to get one
            oktaAppAuth?.signInWithBrowser(from: self) { authStateManager, error in
                /// We end up here when the user has finished interacting with the browser
                if let error = error {
                    self.authStateManager = nil
                    self.oktaStatus = "Error: \(error.localizedDescription)";
                    self.isLoading = false
                    return
                } else {
                    self.authStateManager = authStateManager
                    let accessToken = authStateManager?.accessToken
                    self.useAccessToken(accessToken: accessToken ?? "")
                }
            }
       } else {
            /// We have a stored stateManager, so introspect the access token and renew if needed
            var accessToken = authStateManager?.accessToken
            if accessToken == nil {
                authStateManager?.renew { newAuthStateManager, error in
                    if let error = error {
                        // Error
                        self.isLoading = false
                        self.oktaStatus = "Error trying to Refresh AccessToken: \(error)"
                        return
                    }
                    self.authStateManager = newAuthStateManager
                    accessToken = newAuthStateManager?.accessToken
                    
                    self.authStateManager?.introspect(token: accessToken, callback: { payload, error in
                        guard let isValid = payload?["active"] as? Bool else {
                            self.isLoading = false
                            self.oktaStatus = "Error: \(error?.localizedDescription ?? "Unknown")"
                            return
                        }
                        if isValid {
                            self.useAccessToken(accessToken: accessToken ?? "")
                        } else {
                            self.isLoading = false
                            self.oktaStatus = "Invalid AccessToken"
                            return
                        }
                    })
                }
            } else {
                authStateManager?.introspect(token: accessToken, callback: { payload, error in
                    guard let isValid = payload?["active"] as? Bool else {
                        self.oktaStatus = "Error: \(error?.localizedDescription ?? "Unknown")"
                        self.isLoading = false
                        return
                    }
                    
                    if isValid {
                        self.useAccessToken(accessToken: accessToken ?? "")
                    } else {
                        self.isLoading = false
                        self.oktaStatus = "Invalid AccessToken"
                        return
                    }
                })
            }
        }
        
    }
    func useAccessToken(accessToken: String) {
        /// We have an access token, so use it to call a protected endpoint
        self.oktaStatus = "Valid AccessToken"
        var components = URLComponents()
        components.scheme = "https"
        /// Load these from environment varibles to avoid storing them in a plist
        components.host = ProcessInfo.processInfo.environment["host"]
        components.path = ProcessInfo.processInfo.environment["path"] ?? ""
        components.queryItems = [ URLQueryItem(name: "themessage", value: "Hello World") ]
        
        let url = components.url!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            
            // Check if Error took place
            if let error = error {
                self.oktaStatus = "Error with call to server \(error)"
                self.isLoading = false
                return
            }
            
            // Read HTTP Response Status code
            if let response = response as? HTTPURLResponse {
                switch response.statusCode {
                case 200:
                    // Convert HTTP Response Data to a simple String
                    if let data = data, let dataString = String(data: data, encoding: .utf8) {
                        self.logger.debug("Response data string: \(dataString)")
                        if dataString == "OK" {
                            self.oktaStatus = "Query successful"
                        } else {
                            self.oktaStatus = "Server said: \(dataString)"
                        }
                    }
                case 503:
                    self.oktaStatus = "Service unavailable"
                default:
                    self.logger.debug("Response: \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))")
                    self.oktaStatus = "Server response: \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))"
                }
                self.isLoading = false
            }
            
            
        }
        task.resume()
   }
}



extension OktaOidcError {
    var displayMessage: String {
        switch self {
        case let .api(message, _):
            switch (self as NSError).code {
            case NSURLErrorNotConnectedToInternet,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotLoadFromNetwork,
            NSURLErrorCancelled:
                return "No Internet Connection"
            case NSURLErrorTimedOut:
                return "Connection timed out"
            default:
                break
            }
            
            return "API Error occurred: \(message)"
        case let .authorization(error, _):
            return "Authorization error: \(error)"
        case let .unexpectedAuthCodeResponse(statusCode):
            return "Authorization failed due to incorrect status code: \(statusCode)"
        default:
            return localizedDescription
        }
    }
}
