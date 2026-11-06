import Foundation

/// Print-Job ended without a clear yes or no, so the job may still come out of the printer.
struct UncertainDelivery: Error {
    var underlying: Error
}

extension IPPError {
    /// True when the printer clearly turned the request down, so nothing will print.
    var isRefusal: Bool {
        if status != nil { return true }
        if let httpStatus { return !(200...299).contains(httpStatus) }
        return false
    }

    /// True when the printer named the size and nothing else inside `media-col`. Printing on other media
    /// isn't an option, so there is no retry. A full echo of the collection doesn't say which member it
    /// disliked, and that one does get a retry.
    var refusesMediaSize: Bool {
        guard let members = unsupportedMembers["media-col"], !members.isEmpty else { return false }
        return Set(members) == ["media-size"]
    }
}

extension URLError {
    /// True when the failure happened before any bytes could reach the printer.
    var neverReachedPrinter: Bool {
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .appTransportSecurityRequiresSecureConnection, .unsupportedURL, .badURL:
            return true
        default:
            return false
        }
    }
}

/// What the person at the iPad reads. The raw code stays at the end so a report can be diagnosed.
enum PrintErrorText {
    static func message(for error: Error) -> String {
        switch error {
        case let uncertain as UncertainDelivery:
            return "The job may or may not have reached the printer: there was no clear answer. "
                + "Check the printer before printing again, or you could get two copies. (\(raw(uncertain.underlying)))"
        case is CancellationError:
            return "Printing was canceled."
        case let ipp as IPPError:
            return message(for: ipp)
        case let url as URLError:
            return message(for: url)
        case is IPPDecodeError:
            return "The device at that address answered, but not the way a printer does. (\(raw(error)))"
        default:
            return error.localizedDescription
        }
    }

    private static func message(for error: IPPError) -> String {
        let code = raw(error)
        if let status = error.status {
            switch status {
            case IPPStatus.serverErrorNotAcceptingJobs.rawValue:
                return "The printer is not accepting jobs right now. Check its screen for a paused queue or an error. (\(code))"
            case IPPStatus.serverErrorBusy.rawValue:
                return "The printer stayed busy. Wait for it to finish, then print again. (\(code))"
            case IPPStatus.clientErrorDocumentFormatNotSupported.rawValue:
                return "The printer refused the format the app sent. Try another \"Send as\" format in the Printer pane. (\(code))"
            case IPPStatus.clientErrorAttributesOrValuesNotSupported.rawValue:
                let names = error.unsupportedAttributes.joined(separator: ", ")
                var what = names.isEmpty ? "some of the job settings" : "these job settings: \(names)"
            if error.refusesMediaSize { what = "this paper size" }
                return "The printer refused \(what). Nothing was printed. (\(code))"
            case 0x0401...0x0403:
                return "The printer wants a sign-in, which this app does not support. Check its security settings in Web Config. (\(code))"
            case 0x0500...0x05FF:
                return "The printer reported an internal problem. Restart it if this keeps happening. (\(code))"
            default:
                return "The printer refused the request. Nothing was printed. (\(code))"
            }
        }
        switch error.httpStatus {
        case 401, 403:
            return "The printer wants a sign-in, which this app does not support. Check its security settings in Web Config. (\(code))"
        case 426:
            return "The printer only accepts secure connections, which this app does not support yet. Turn on plain IPP in Web Config. (\(code))"
        case .some(200...299):
            return "The device at that address answered, but not the way a printer does. (\(code))"
        default:
            return code
        }
    }

    private static func message(for error: URLError) -> String {
        let code = raw(error)
        if error.code == .appTransportSecurityRequiresSecureConnection {
            return "iPadOS blocked this address as insecure. Use the printer's .local name or pick it from the list. (\(code))"
        }
        if error.neverReachedPrinter {
            return "Can't reach the printer. Check that it is on and on the same Wi-Fi as this iPad, and that Local Network "
                + "is on for T2170 Print in Settings > Privacy & Security. (\(code))"
        }
        return "The printer stopped answering. Check that it is on and on the same Wi-Fi as this iPad, then try again. (\(code))"
    }

    private static func raw(_ error: Error) -> String {
        if let url = error as? URLError { return "\(url.localizedDescription) [\(url.code.rawValue)]" }
        return error.localizedDescription
    }
}
