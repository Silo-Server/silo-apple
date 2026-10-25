import CommonCrypto
import CryptoKit
import Foundation

/// Level `sealed` of the Roku receiver's transport (silo-roku
/// `docs/silocontrol.md` section 9.2). Roku sockets have no TLS, so a Roku
/// that requires pairing shares a 16-byte key with the phone through its
/// pairing QR code, and every frame after an opening exchange is encrypted
/// (AES-128-CBC) and authenticated (HMAC-SHA256, encrypt-then-MAC) and
/// numbered per direction, so none can be read, forged, replayed or
/// reordered.
///
/// Each side opens with one plain `sealed_hello` carrying the key's ID and a
/// 16-byte nonce; the phone sends first. The session keys are HKDF-SHA256 of
/// the pairing key with salt phoneNonce || tvNonce, one output block each. A
/// frame body is seq (8 bytes, big-endian, from 0 per direction) || iv (16)
/// || ciphertext || tag (32), the tag over the label, the direction byte,
/// seq, iv and ciphertext.
enum SiloControlSealed {
    static let label = "silo-cast-sealed-1"
    static let fromPhone: UInt8 = 1
    static let fromTV: UInt8 = 2
    static let keyBytes = 16
    static let nonceBytes = 16
    private static let ivBytes = 16
    private static let tagBytes = 32

    struct SessionKeys: Equatable, Sendable {
        let encryption: Data
        let authentication: Data
        /// Derived for the Roku's deterministic IVs; the phone sends random
        /// ones and never uses it.
        let iv: Data
    }

    /// The key's ID, as TXT `kid` and `sealed_hello` carry it: the first 8
    /// hex digits of SHA-256 of the key.
    static func keyId(_ key: Data) -> String {
        SHA256.hash(data: key).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func sessionKeys(key: Data, phoneNonce: Data, tvNonce: Data) -> SessionKeys {
        func expand(_ purpose: String, _ count: Int) -> Data {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: key),
                salt: phoneNonce + tvNonce,
                info: Data("\(label) \(purpose)".utf8),
                outputByteCount: count
            ).withUnsafeBytes { Data($0) }
        }
        return SessionKeys(encryption: expand("enc", 16), authentication: expand("mac", 32), iv: expand("iv", 16))
    }

    /// The sealed body of `plaintext` as frame `seq` sent in `direction`.
    static func seal(_ plaintext: Data, keys: SessionKeys, direction: UInt8, seq: UInt64, iv: Data) throws -> Data {
        guard iv.count == ivBytes else { throw SiloControlSealedError.badFrame }
        let signed = seqBytes(seq) + iv + (try aes128CBC(encrypt: true, key: keys.encryption, iv: iv, input: plaintext))
        return signed + tag(signed, keys: keys, direction: direction)
    }

    /// The plaintext of `body`, which must be frame `seq` from `direction`.
    /// The tag is checked before anything is decrypted.
    static func open(_ body: Data, keys: SessionKeys, direction: UInt8, seq: UInt64) throws -> Data {
        let body = Data(body)
        let overhead = 8 + ivBytes + tagBytes
        guard body.count >= overhead + 16, (body.count - overhead) % 16 == 0 else {
            throw SiloControlSealedError.badFrame
        }
        let signed = body.prefix(body.count - tagBytes)
        let message = Data(label.utf8) + [direction] + signed
        guard HMAC<SHA256>.isValidAuthenticationCode(
            body.suffix(tagBytes), authenticating: message,
            using: SymmetricKey(data: keys.authentication)
        ), signed.prefix(8) == seqBytes(seq) else {
            throw SiloControlSealedError.badFrame
        }
        let iv = signed.dropFirst(8).prefix(ivBytes)
        return try aes128CBC(encrypt: false, key: keys.encryption, iv: Data(iv), input: Data(signed.dropFirst(8 + ivBytes)))
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// RFC 4648 base32 without padding, as the pairing link carries the key.
    /// Nil for any character outside the alphabet.
    static func base32Decode(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = Data()
        var buffer = 0
        var bits = 0
        for character in text.uppercased() where character != "=" {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = ((buffer << 5) | value) & 0xFFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return out
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64url(_ text: String) -> Data? {
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }

    private static func tag(_ signed: Data, keys: SessionKeys, direction: UInt8) -> Data {
        let message = Data(label.utf8) + [direction] + signed
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: keys.authentication)))
    }

    private static func seqBytes(_ seq: UInt64) -> Data {
        withUnsafeBytes(of: seq.bigEndian) { Data($0) }
    }

    /// AES-128-CBC with PKCS#7 padding. CryptoKit has no CBC.
    private static func aes128CBC(encrypt: Bool, key: Data, iv: Data, input: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress, input.count,
                            out.baseAddress, capacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard Int(status) == kCCSuccess else { throw SiloControlSealedError.badFrame }
        output.count = moved
        return output
    }
}

enum SiloControlSealedError: LocalizedError, Equatable {
    /// The TV's opening frame wasn't a `sealed_hello` for this key: a TV
    /// that refuses the key answers with a plain `close` instead.
    case pairingRefused
    /// A frame failed its tag, sequence, or padding check.
    case badFrame

    var errorDescription: String? {
        switch self {
        case .pairingRefused:
            return "The TV didn't accept this iPhone's pairing. On the TV, open Connect a Phone in Silo and scan its code again."
        case .badFrame:
            return "Lost the secure connection to the TV."
        }
    }
}

/// One phone-side connection's `sealed` state: the opening exchange, the
/// session keys it yields, and each direction's frame counter.
struct SiloControlSealedChannel: SiloFrameSealing {
    private struct Hello: Codable {
        var type = "sealed_hello"
        var v = 1
        let keyId: String
        let nonce: String
    }

    private let key: Data
    private let nonce: Data
    private var keys: SiloControlSealed.SessionKeys?
    private var sendSeq: UInt64 = 0
    private var receiveSeq: UInt64 = 0

    init(key: Data, nonce: Data = SiloControlSealed.randomBytes(SiloControlSealed.nonceBytes)) {
        self.key = key
        self.nonce = nonce
    }

    var openingFrame: Data {
        let hello = Hello(keyId: SiloControlSealed.keyId(key), nonce: SiloControlSealed.base64url(nonce))
        return (try? JSONEncoder().encode(hello)) ?? Data()
    }

    var isKeyed: Bool { keys != nil }

    /// Keys the session from the TV's `sealed_hello`. Anything else, such as
    /// the plain `close` a TV sends for an unknown key, ends the connection.
    mutating func receiveOpening(_ body: Data) throws {
        guard let hello = try? JSONDecoder().decode(Hello.self, from: body),
              hello.type == "sealed_hello",
              hello.keyId.lowercased() == SiloControlSealed.keyId(key),
              let tvNonce = SiloControlSealed.fromBase64url(hello.nonce),
              tvNonce.count == SiloControlSealed.nonceBytes else {
            throw SiloControlSealedError.pairingRefused
        }
        keys = SiloControlSealed.sessionKeys(key: key, phoneNonce: nonce, tvNonce: tvNonce)
    }

    mutating func seal(_ payload: Data) throws -> Data {
        guard let keys else { throw SiloControlSealedError.badFrame }
        let body = try SiloControlSealed.seal(
            payload, keys: keys, direction: SiloControlSealed.fromPhone, seq: sendSeq,
            iv: SiloControlSealed.randomBytes(16)
        )
        sendSeq += 1
        return body
    }

    mutating func open(_ body: Data) throws -> Data {
        guard let keys else { throw SiloControlSealedError.badFrame }
        let payload = try SiloControlSealed.open(body, keys: keys, direction: SiloControlSealed.fromTV, seq: receiveSeq)
        receiveSeq += 1
        return payload
    }
}
