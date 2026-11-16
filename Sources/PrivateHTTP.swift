import Foundation

/// Short private-network requests must not reuse an idle connection across VPN changes.
/// The voice WebSocket remains persistent for the duration of its conversation.
enum PrivateHTTP {
    static func data(for request:URLRequest) async throws -> (Data,URLResponse) {
        let configuration=URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity=false
        configuration.timeoutIntervalForRequest=8
        configuration.timeoutIntervalForResource=15
        configuration.urlCache=nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies=false
        let session=URLSession(configuration:configuration)
        defer { session.finishTasksAndInvalidate() }
        do { return try await session.data(for:request) }
        catch let error as URLError {
            let diagnosis="Connection failed (\(error.code.rawValue)). Safari working with the same URL means this may be an app networking or permission issue. Check iPhone Settings → Apps → Hermes → Local Network if that option is present, then reopen Hermes. The request could not be confirmed."
            if [.timedOut,.cannotFindHost,.cannotConnectToHost,.networkConnectionLost,.notConnectedToInternet,.dnsLookupFailed].contains(error.code) {
                throw NSError(domain:"HermesConnection",code:error.code.rawValue,userInfo:[NSLocalizedDescriptionKey:diagnosis])
            }
            throw error
        }
    }
}
