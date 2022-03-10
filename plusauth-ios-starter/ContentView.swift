import SwiftUI
import AppAuth

// Custom Button Style
struct CustomButtonStyle: ButtonStyle {
    var color: Color
    init(color: Color) {
        self.color = color
    }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding([.trailing, .leading], 48)
            .padding([.top, .bottom], 12).background(color)
            .foregroundColor(.white).clipShape(Capsule())
    }
}

// PlusAuth.plist properties objects
struct PlusAuth : Decodable {
    let clientId, issuer : String
}

struct Root : Decodable {
    let credentials : PlusAuth
}

private var plusAuthCredentials = PlusAuth(clientId: "", issuer: "")
private let redirectUrl: String = "\(Bundle.main.bundleIdentifier ?? ""):/oauth2redirect/ios-provider";

private var config: OIDServiceConfiguration?
private var authState: OIDAuthState?
// State variables to store user auth state
private let plusAuthStateKey: String = "authState";
private let storageSuitName = "com.plusauth.iosexample"

class ViewModel: ObservableObject {
    @Published var isLoggedIn: Bool = false
    @Published var username = "-"
    @Published var profileInfo = "-"
}

struct ContentView: View {
   
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject var viewModel = ViewModel()

    init() {
        readCredentials()
        initNavigationBarAppearance()
        loadState()
        discoverConfiguration()
    }
    
    // Read clientId and issuer from PlusAuth.plist file
    func readCredentials(){
        let url = Bundle.main.url(forResource: "PlusAuth", withExtension:"plist")!
        do {
            let data = try Data(contentsOf: url)
            let result = try PropertyListDecoder().decode(Root.self, from: data)
            plusAuthCredentials = result.credentials
        } catch {
            print(error)
        }
    }
    
    // Navigationbar style
    func initNavigationBarAppearance(){
        let coloredAppearance = UINavigationBarAppearance()
        coloredAppearance.configureWithOpaqueBackground()
        coloredAppearance.backgroundColor = UIColor.darkGray
        UINavigationBar.appearance().standardAppearance = coloredAppearance
        UINavigationBar.appearance().compactAppearance = coloredAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = coloredAppearance
    }
    
    var body: some View {
        NavigationView {
            VStack {
                Text("Welcome to PlusAuth iOS Starter").padding([.top, .bottom], 24)
                Text("Username: " + viewModel.username).padding(.bottom, 24)
                if(viewModel.isLoggedIn) {
                    Button("Logout") {
                        logout()
                    }
                    .buttonStyle(CustomButtonStyle(color: .red))
                } else {
                    Button("Login") {
                        login()
                    }
                    .buttonStyle(CustomButtonStyle(color: .blue))
                }
                Text("Profile Info").padding([.top, .bottom], 24)
                Text(viewModel.profileInfo)
                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar{
                 ToolbarItem(placement: .principal) {
                     Text("PlusAuth iOS Starter").foregroundColor(.white)
                 }
            }
        }.accentColor(.white)
    }
    
    // MARK: PlusAuth Methods
    func discoverConfiguration() {
        guard let issuerUrl = URL(string: plusAuthCredentials.issuer) else {
           print("Error creating URL for : \(plusAuthCredentials.issuer)")
           return
        }
        // Get PlusAuth auth endpoints
        OIDAuthorizationService.discoverConfiguration(forIssuer: issuerUrl) { configuration, error in
            if(error != nil) {
                print("Error: \(error?.localizedDescription ?? "DEFAULT_ERROR")")
            } else {
                config = configuration
            }
        }
    }
    
    
    func login() {
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let presentingView = windowScene?.windows.first?.rootViewController

        // Create redirectURI from redirectURL string
        guard let redirectURI = URL(string: redirectUrl) else {
            print("Error creating URL for : \(redirectUrl)")
            return
        }
        
        // Create login request
        let request = OIDAuthorizationRequest(configuration: config!, clientId: plusAuthCredentials.clientId, clientSecret: nil, scopes: ["openid", "profile", "offline_access"],
                                        redirectURL: redirectURI, responseType: OIDResponseTypeCode, additionalParameters: nil)
        // performs authentication request
        appDelegate.currentAuthorizationFlow = OIDAuthState.authState(byPresenting: request, presenting: presentingView!) { (authState, error) in
            if let authState = authState {
                setAuthState(state: authState)
                saveState()
                fetchUserInfo()
            } else {
                print("Authorization error: \(error?.localizedDescription ?? "DEFAULT_ERROR")")
            }
        }

    }
    
    func logout() {
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let presentingView = windowScene?.windows.first?.rootViewController

        // Create redirectURI from redirectURL string
        guard let redirectURI = URL(string: redirectUrl) else {
            print("Error creating URL for : \(redirectUrl)")
            return
        }
        
        guard let idToken = authState?.lastTokenResponse?.idToken else { return }
        
        // Create logout request
        let request = OIDEndSessionRequest(configuration: config!, idTokenHint: idToken, postLogoutRedirectURL: redirectURI, additionalParameters: nil)

        guard let userAgent = OIDExternalUserAgentIOS(presenting: presentingView!) else { return }

        // performs logout request
        appDelegate.currentAuthorizationFlow = OIDAuthorizationService.present(request, externalUserAgent: userAgent, callback: { (_, error) in
            setAuthState(state: nil)
            saveState()
            viewModel.username = "-"
            viewModel.profileInfo = "-"
        })
    }
    
    // MARK: Helper Methods
    // Load local state info if exists
    func loadState() {
        guard let data = UserDefaults(suiteName: storageSuitName)?.object(forKey: plusAuthStateKey) as? Data else {
            return
        }
        do {
            let authState = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? OIDAuthState
            self.setAuthState(state: authState)
            // Fetch user info if user authenticated
            fetchUserInfo()
       } catch {
           print(error)
       }
   }
    
    // Save user state to local
    func saveState() {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: authState as Any, requiringSecureCoding: true) else {
            return
        }
        
        if let userDefaults = UserDefaults(suiteName: storageSuitName) {
            userDefaults.set(data, forKey: plusAuthStateKey)
            userDefaults.synchronize()
        }
    }
    
    // Set user auth state
    func setAuthState(state: OIDAuthState?) {
        if (authState == state) {
            return;
        }
        authState = state;
        viewModel.isLoggedIn = state?.isAuthorized == true
    }
    
    // Get authenticaed user info from PlusAuth
    func fetchUserInfo() {
        guard let userinfoEndpoint = authState?.lastAuthorizationResponse.request.configuration.discoveryDocument?.userinfoEndpoint else {
            print("Userinfo endpoint not declared in discovery document")
            return
        }

       print("Performing userinfo request")

        let currentAccessToken: String? = authState?.lastTokenResponse?.accessToken

        authState?.performAction() { (accessToken, idToken, error) in

            if error != nil  {
                print("Error fetching fresh tokens: \(error?.localizedDescription ?? "ERROR")")
                return
            }
            guard let accessToken = accessToken else {
                print("Error getting accessToken")
                return
            }
            if currentAccessToken != accessToken {
                print("Access token was refreshed automatically (\(currentAccessToken ?? "CURRENT_ACCESS_TOKEN") to \(accessToken))")
            } else {
                print("Access token was fresh and not updated \(accessToken)")
            }

            var urlRequest = URLRequest(url: userinfoEndpoint)
            urlRequest.allHTTPHeaderFields = ["Authorization":"Bearer \(accessToken)"]

            let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in

                DispatchQueue.main.async {
                    guard error == nil else {
                        print("HTTP request failed \(error?.localizedDescription ?? "ERROR")")
                        return
                    }
                    guard let response = response as? HTTPURLResponse else {
                        print("Non-HTTP response")
                        return
                    }
                    guard let data = data else {
                        print("HTTP response data is empty")
                        return
                    }

                    var json: [AnyHashable: Any]?

                    do {
                        json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                    } catch {
                        print("JSON Serialization Error")
                    }

                    if response.statusCode != 200 {
                        let responseText: String? = String(data: data, encoding: String.Encoding.utf8)

                        if response.statusCode == 401 {
                            let oauthError = OIDErrorUtilities.resourceServerAuthorizationError(withCode: 0, errorResponse: json, underlyingError: error)
                            authState?.update(withAuthorizationError: oauthError)
                            print("Authorization Error (\(oauthError)). Response: \(responseText ?? "RESPONSE_TEXT")")
                        } else {
                            print("HTTP: \(response.statusCode), Response: \(responseText ?? "RESPONSE_TEXT")")
                        }
                        return
                    }
                    // Create profile info string
                    if let json = json {
                        viewModel.username = json["username"] as! String
                        viewModel.profileInfo = ""
                        for (key, value) in json {
                            viewModel.profileInfo += "\(key): \(value is NSNull ? "-" : value), "
                        }
                    }
                }
            }
            task.resume()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView().previewInterfaceOrientation(.portrait)
    }
}
