import Foundation

/// Why a turn stopped without reaching the end.
///
/// The set is **closed**: an unexpected value falls back to `unknown` instead of
/// propagating as a free-form string all the way to the row. An empty or
/// unexpected label in a 240 px wide column is worse than a generic one.
public enum StopFailureReason: String, Sendable, Equatable, CaseIterable, Codable {
    case rateLimit = "rate_limit"
    case overloaded = "overloaded"
    case authenticationFailed = "authentication_failed"
    case oauthOrgNotAllowed = "oauth_org_not_allowed"
    case billingError = "billing_error"
    case invalidRequest = "invalid_request"
    case modelNotFound = "model_not_found"
    case serverError = "server_error"
    case maxOutputTokens = "max_output_tokens"
    case unknown = "unknown"
    /// A command under `lampboard watch` exited with a code other than 0.
    case commandFailed = "command_failed"

    /// Lenient construction: any unrecognized value becomes `unknown`.
    public static func from(rawValue: String?) -> StopFailureReason {
        guard let rawValue, !rawValue.isEmpty else { return .unknown }
        return StopFailureReason(rawValue: rawValue) ?? .unknown
    }

    /// Label for the row's right-hand slot, in place of the timestamp.
    /// It has to fit in a few characters: the workspace name sits next to it.
    public var shortLabel: String {
        switch self {
        case .rateLimit: return "rate limit"
        case .overloaded: return "overloaded"
        case .authenticationFailed: return "auth"
        case .oauthOrgNotAllowed: return "org"
        case .billingError: return "billing"
        case .invalidRequest: return "request"
        case .modelNotFound: return "model"
        case .serverError: return "server"
        case .maxOutputTokens: return "truncated"
        case .unknown: return "API error"
        case .commandFailed: return "exit"
        }
    }

    /// Extended description for the tooltip.
    public var detailedLabel: String {
        switch self {
        case .rateLimit: return "request limit reached"
        case .overloaded: return "service overloaded"
        case .authenticationFailed: return "authentication failed"
        case .oauthOrgNotAllowed: return "organization not allowed"
        case .billingError: return "billing problem"
        case .invalidRequest: return "invalid request"
        case .modelNotFound: return "model not found"
        case .serverError: return "server error"
        case .maxOutputTokens: return "answer truncated at maximum length"
        case .unknown: return "turn interrupted by an API error"
        case .commandFailed: return "the command exited with an error"
        }
    }

    /// `true` when, despite the interruption, there is text worth reading.
    ///
    /// True only for truncation at maximum length: there Claude did produce an
    /// answer, it simply didn't finish it. Treating that as a dead turn would
    /// hide real content.
    public var hasUsableOutput: Bool {
        self == .maxOutputTokens
    }
}
