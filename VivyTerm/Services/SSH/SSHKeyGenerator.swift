import Foundation
import CryptoKit
import Security

// MARK: - SSH Key Type

enum SSHKeyType: String, CaseIterable, Identifiable, Codable {
    case ed25519
    case rsa4096

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .rsa4096: return "RSA 4096"
        }
    }

    var description: String {
        switch self {
        case .ed25519: return "Modern, fast, and secure. Recommended for most uses."
        case .rsa4096: return "Wide compatibility with older systems."
        }
    }

    var algorithmName: String {
        switch self {
        case .ed25519: return "ssh-ed25519"
        case .rsa4096: return "ssh-rsa"
        }
    }
}

// MARK: - Generated Key Result

struct GeneratedSSHKey {
    let privateKey: Data
    let publicKey: String
    let keyType: SSHKeyType
    let fingerprint: String
}

// MARK: - SSH Key Generator

enum SSHKeyGeneratorError: LocalizedError {
    case keyGenerationFailed
    case encodingFailed
    case rsaExportFailed
    case invalidKeyData

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed: return "Failed to generate SSH key"
        case .encodingFailed: return "Failed to encode key data"
        case .rsaExportFailed: return "Failed to export RSA key"
        case .invalidKeyData: return "Invalid key data"
        }
    }
}

enum SSHKeyGenerator {

    /// Generate a new SSH key pair
    static func generate(type: SSHKeyType, comment: String = "") throws -> GeneratedSSHKey {
        switch type {
        case .ed25519:
            return try generateEd25519(comment: comment)
        case .rsa4096:
            return try generateRSA(bits: 4096, comment: comment)
        }
    }

    // MARK: - Ed25519 Generation

    private static func generateEd25519(comment: String) throws -> GeneratedSSHKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        // Format private key in OpenSSH format
        let privateKeyPEM = formatEd25519PrivateKey(privateKey, comment: comment)
        guard let privateKeyData = privateKeyPEM.data(using: .utf8) else {
            throw SSHKeyGeneratorError.encodingFailed
        }

        // Format public key in OpenSSH format
        let publicKeyString = formatEd25519PublicKey(publicKey, comment: comment)

        // Calculate fingerprint
        let fingerprint = calculateFingerprint(publicKeyData: publicKey.rawRepresentation, type: .ed25519)

        return GeneratedSSHKey(
            privateKey: privateKeyData,
            publicKey: publicKeyString,
            keyType: .ed25519,
            fingerprint: fingerprint
        )
    }

    private static func formatEd25519PrivateKey(_ key: Curve25519.Signing.PrivateKey, comment: String) -> String {
        // OpenSSH private key format for Ed25519
        // The format is: openssh-key-v1 + padding + cipher + kdf + kdf options + number of keys + public key + private key section

        let publicKeyBytes = key.publicKey.rawRepresentation
        let privateKeyBytes = key.rawRepresentation

        // Build the public key blob: "ssh-ed25519" + public key
        var publicBlob = Data()
        publicBlob.append(sshString("ssh-ed25519"))
        publicBlob.append(sshString(publicKeyBytes))

        // Build the private section
        // checkint (random, repeated) + keytype + pubkey + privkey + pubkey + comment + padding
        let checkInt = UInt32.random(in: 0..<UInt32.max)
        var privateSection = Data()
        privateSection.append(uint32BE(checkInt))
        privateSection.append(uint32BE(checkInt))
        privateSection.append(sshString("ssh-ed25519"))
        privateSection.append(sshString(publicKeyBytes))
        // Ed25519 private key in OpenSSH is 64 bytes: private (32) + public (32)
        var fullPrivateKey = Data(privateKeyBytes)
        fullPrivateKey.append(publicKeyBytes)
        privateSection.append(sshString(fullPrivateKey))
        privateSection.append(sshString(comment))

        // Add padding to align to block size (8 bytes for no encryption)
        let blockSize = 8
        let paddingNeeded = (blockSize - (privateSection.count % blockSize)) % blockSize
        for i in 1...max(paddingNeeded, 1) {
            if paddingNeeded > 0 && i <= paddingNeeded {
                privateSection.append(UInt8(i))
            }
        }
        if paddingNeeded == 0 {
            // Still need to align, but already aligned
        } else {
            // Padding already added
        }
        // Actually let's redo padding properly
        var paddedPrivateSection = privateSection
        let currentMod = paddedPrivateSection.count % blockSize
        if currentMod != 0 {
            let needed = blockSize - currentMod
            for i in 1...needed {
                paddedPrivateSection.append(UInt8(i))
            }
        }

        // Build the full key blob
        var keyBlob = Data()
        keyBlob.append("openssh-key-v1".data(using: .utf8)!)
        keyBlob.append(0) // null terminator
        keyBlob.append(sshString("none")) // cipher
        keyBlob.append(sshString("none")) // kdf
        keyBlob.append(sshString(Data())) // kdf options (empty)
        keyBlob.append(uint32BE(1)) // number of keys
        keyBlob.append(sshString(publicBlob)) // public key
        keyBlob.append(sshString(paddedPrivateSection)) // private section

        // Base64 encode and format as PEM
        let base64 = keyBlob.base64EncodedString()
        let wrapped = wrapBase64(base64, lineLength: 70)

        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(wrapped)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    private static func formatEd25519PublicKey(_ key: Curve25519.Signing.PublicKey, comment: String) -> String {
        var blob = Data()
        blob.append(sshString("ssh-ed25519"))
        blob.append(sshString(key.rawRepresentation))

        let base64 = blob.base64EncodedString()
        if comment.isEmpty {
            return "ssh-ed25519 \(base64)"
        } else {
            return "ssh-ed25519 \(base64) \(comment)"
        }
    }

    // MARK: - RSA Generation

    private static func generateRSA(bits: Int, comment: String) throws -> GeneratedSSHKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
        ]

        var error: Unmanaged<CFError>?
        guard let privateSecKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SSHKeyGeneratorError.keyGenerationFailed
        }

        guard let publicSecKey = SecKeyCopyPublicKey(privateSecKey) else {
            throw SSHKeyGeneratorError.keyGenerationFailed
        }

        // Export private key in PKCS#1 PEM format
        let privateKeyPEM = try exportRSAPrivateKey(privateSecKey, comment: comment)
        guard let privateKeyData = privateKeyPEM.data(using: .utf8) else {
            throw SSHKeyGeneratorError.encodingFailed
        }

        // Format public key in OpenSSH format
        let publicKeyString = try formatRSAPublicKey(publicSecKey, comment: comment)

        // Calculate fingerprint
        let fingerprint = calculateRSAFingerprint(publicSecKey)

        return GeneratedSSHKey(
            privateKey: privateKeyData,
            publicKey: publicKeyString,
            keyType: .rsa4096,
            fingerprint: fingerprint
        )
    }

    private static func exportRSAPrivateKey(_ key: SecKey, comment: String) throws -> String {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw SSHKeyGeneratorError.rsaExportFailed
        }

        let base64 = data.base64EncodedString()
        let wrapped = wrapBase64(base64, lineLength: 64)

        return "-----BEGIN RSA PRIVATE KEY-----\n\(wrapped)\n-----END RSA PRIVATE KEY-----\n"
    }

    private static func formatRSAPublicKey(_ key: SecKey, comment: String) throws -> String {
        guard let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw SSHKeyGeneratorError.rsaExportFailed
        }

        // Parse the RSA public key data (PKCS#1 format: sequence of n and e)
        let (n, e) = try parseRSAPublicKey(data)

        // Build SSH public key blob
        var blob = Data()
        blob.append(sshString("ssh-rsa"))
        blob.append(sshMPInt(e))
        blob.append(sshMPInt(n))

        let base64 = blob.base64EncodedString()
        if comment.isEmpty {
            return "ssh-rsa \(base64)"
        } else {
            return "ssh-rsa \(base64) \(comment)"
        }
    }

    private static func parseRSAPublicKey(_ data: Data) throws -> (n: Data, e: Data) {
        // PKCS#1 RSA public key format:
        // SEQUENCE {
        //   INTEGER n
        //   INTEGER e
        // }
        var offset = 0

        // SEQUENCE tag
        guard data.count > 2, data[offset] == 0x30 else {
            throw SSHKeyGeneratorError.invalidKeyData
        }
        offset += 1

        // Length
        let (_, seqLenBytes) = parseASN1Length(data, offset: offset)
        offset += seqLenBytes

        // First INTEGER (n)
        guard data[offset] == 0x02 else {
            throw SSHKeyGeneratorError.invalidKeyData
        }
        offset += 1
        let (nLen, nLenBytes) = parseASN1Length(data, offset: offset)
        offset += nLenBytes
        let n = data.subdata(in: offset..<(offset + nLen))
        offset += nLen

        // Second INTEGER (e)
        guard data[offset] == 0x02 else {
            throw SSHKeyGeneratorError.invalidKeyData
        }
        offset += 1
        let (eLen, eLenBytes) = parseASN1Length(data, offset: offset)
        offset += eLenBytes
        let e = data.subdata(in: offset..<(offset + eLen))

        return (n, e)
    }

    private static func parseASN1Length(_ data: Data, offset: Int) -> (length: Int, bytesConsumed: Int) {
        let firstByte = data[offset]
        if firstByte < 0x80 {
            return (Int(firstByte), 1)
        } else {
            let numBytes = Int(firstByte & 0x7F)
            var length = 0
            for i in 0..<numBytes {
                length = (length << 8) | Int(data[offset + 1 + i])
            }
            return (length, 1 + numBytes)
        }
    }

    // MARK: - Fingerprint Calculation

    private static func calculateFingerprint(publicKeyData: Data, type: SSHKeyType) -> String {
        var blob = Data()
        blob.append(sshString(type.algorithmName))
        blob.append(sshString(publicKeyData))

        let hash = SHA256.hash(data: blob)
        let base64 = Data(hash).base64EncodedString()
        return "SHA256:\(base64.replacingOccurrences(of: "=", with: ""))"
    }

    private static func calculateRSAFingerprint(_ key: SecKey) -> String {
        guard let data = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let (n, e) = try? parseRSAPublicKey(data) else {
            return "Unknown"
        }

        var blob = Data()
        blob.append(sshString("ssh-rsa"))
        blob.append(sshMPInt(e))
        blob.append(sshMPInt(n))

        let hash = SHA256.hash(data: blob)
        let base64 = Data(hash).base64EncodedString()
        return "SHA256:\(base64.replacingOccurrences(of: "=", with: ""))"
    }

    // MARK: - SSH Format Helpers

    private static func sshString(_ string: String) -> Data {
        let bytes = string.data(using: .utf8)!
        return sshString(bytes)
    }

    private static func sshString(_ data: Data) -> Data {
        var result = Data()
        result.append(uint32BE(UInt32(data.count)))
        result.append(data)
        return result
    }

    private static func sshMPInt(_ data: Data) -> Data {
        var trimmed = data
        // Remove leading zeros but keep one if the high bit is set
        while trimmed.count > 1 && trimmed[0] == 0 {
            trimmed = trimmed.dropFirst()
        }
        // Add leading zero if high bit is set (to indicate positive number)
        if !trimmed.isEmpty && (trimmed[0] & 0x80) != 0 {
            var padded = Data([0])
            padded.append(trimmed)
            trimmed = padded
        }
        return sshString(trimmed)
    }

    private static func uint32BE(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: 4)
    }

    private static func wrapBase64(_ string: String, lineLength: Int) -> String {
        var result = ""
        var index = string.startIndex
        while index < string.endIndex {
            let endIndex = string.index(index, offsetBy: lineLength, limitedBy: string.endIndex) ?? string.endIndex
            if !result.isEmpty {
                result += "\n"
            }
            result += String(string[index..<endIndex])
            index = endIndex
        }
        return result
    }
}
