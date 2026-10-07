import Foundation
import SwiftData

@Model
final class NASConfig {
    var id: UUID
    var name: String              // display name
    var host: String              // IP or hostname
    var port: Int                 // default 445
    var username: String
    var shareName: String         // SMB share name e.g. "media"
    var isActive: Bool
    var connectionType: String = "smb"   // "smb", "quickConnect", or "fnConnect"
    var quickConnectID: String?          // Only for QuickConnect type
    var fnConnectID: String?             // Only for FnConnect type

    /// Old remote-protocol records remain editable until the user supplies SMB coordinates.
    var requiresSMBSetup: Bool { connectionType != "smb" || host.isEmpty || shareName.isEmpty }

    /// SMB connection
    init(
        name: String,
        host: String,
        port: Int = 445,
        username: String,
        shareName: String
    ) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.shareName = shareName
        self.isActive = false
        self.connectionType = "smb"
    }

}
