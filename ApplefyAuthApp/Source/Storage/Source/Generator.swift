//
//  Generator.swift
//  ApplefyAuthApp
//
//  Created by Denys on 25.05.2023.
//

import CryptoKit
import Foundation

/// A `Generator` contains all of the parameters needed to generate a one-time password.
public struct Generator: Equatable {
    /// The moving factor, either timer- or counter-based.
    public let factor: Factor

    /// The secret shared between the client and server.
    public let secret: Data

    /// The cryptographic hash function used to generate the password.
    public let algorithm: Algorithm

    /// The number of digits in the password.
    public let digits: Int

    /// Initializes a new password generator with the given parameters.
    ///
    /// - parameter factor:    The moving factor.
    /// - parameter secret:    The shared secret.
    /// - parameter algorithm: The cryptographic hash function.
    /// - parameter digits:    The number of digits in the password.
    ///
    /// - throws: A `Generator.Error` if the given parameters are invalid.
    /// - returns: A new password generator with the given parameters.
    public init(factor: Factor, secret: Data, algorithm: Algorithm, digits: Int) throws {
        try Self.validateFactor(factor)
        try Self.validateDigits(digits)

        self.factor = factor
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
    }

    // MARK: Password Generation

    /// Generates the password for the given point in time.
    ///
    /// - parameter time: The target time, represented as a `Date`.
    ///                   The time must not be before the Unix epoch.
    ///
    /// - throws: A `Generator.Error` if a valid password cannot be generated for the given time.
    /// - returns: The generated password, or throws an error if a password could not be generated.
    public func password(at time: Date) throws -> String {
        try Self.validateDigits(digits)

        let counter = try factor.counterValue(at: time)
        // Ensure the counter value is big-endian
        var bigCounter = counter.bigEndian

        // Generate an HMAC value from the key and counter
        let counterData = Data(bytes: &bigCounter, count: MemoryLayout<UInt64>.size)
        let hash = Self.generateHMAC(for: counterData, using: secret, with: algorithm)

        var truncatedHash = hash.withUnsafeBytes { ptr -> UInt32 in
            // Use the last 4 bits of the hash as an offset (0 <= offset <= 15)
            let offset = ptr[hash.count - 1] & 0x0f

            // Take 4 bytes from the hash, starting at the given byte offset
            let truncatedHashPtr = ptr.baseAddress! + Int(offset)
            return truncatedHashPtr.bindMemory(to: UInt32.self, capacity: 1).pointee
        }

        // Ensure the four bytes taken from the hash match the current endian format
        truncatedHash = UInt32(bigEndian: truncatedHash)
        // Discard the most significant bit
        truncatedHash &= 0x7fffffff
        // Constrain to the right number of digits
        truncatedHash = truncatedHash % UInt32(pow(10, Float(digits)))

        // Pad the string representation with zeros, if necessary
        return String(truncatedHash).padded(with: "0", toLength: digits)
    }

    private static func generateHMAC(for data: Data, using keyData: Data, with algorithm: Generator.Algorithm) -> Data {
        func authenticationCode<H: HashFunction>(with _: H.Type) -> Data {
            let key = SymmetricKey(data: keyData)
            let authenticationCode = HMAC<H>.authenticationCode(for: data, using: key)
            return Data(authenticationCode)
        }

        switch algorithm {
        case .sha1:
            return authenticationCode(with: Insecure.SHA1.self)
        case .sha256:
            return authenticationCode(with: SHA256.self)
        case .sha512:
            return authenticationCode(with: SHA512.self)
        }
    }

    // MARK: Update

    /// Returns a `Generator` configured to generate the *next* password, which follows the password
    /// generated by `self`.
    ///
    /// - requires: The next generator is valid.
    public func successor() -> Generator {
        switch factor {
        case .counter(let counterValue):
            // Update a counter-based generator by incrementing the counter.
            // Force-trying should be safe here, since any valid generator should have a valid successor.
            // swiftlint:disable:next force_try
            return try! Generator(
                factor: .counter(counterValue + 1),
                secret: secret,
                algorithm: algorithm,
                digits: digits
            )
        case .timer:
            // A timer-based generator does not need to be updated.
            return self
        }
    }

    // MARK: Nested Types

    /// A moving factor with which a generator produces different one-time passwords over time.
    /// The possible values are `Counter` and `Timer`, with associated values for each.
    public enum Factor: Equatable {
        /// Indicates a HOTP, with an associated 8-byte counter value for the moving factor. After
        /// each use of the password generator, the counter should be incremented to stay in sync
        /// with the server.
        case counter(UInt64)
        /// Indicates a TOTP, with an associated time interval for calculating the time-based moving
        /// factor. This period value remains constant, and is used as a divisor for the number of
        /// seconds since the Unix epoch.
        case timer(period: TimeInterval)

        /// Calculates the counter value for the moving factor at the target time. For a counter-
        /// based factor, this will be the associated counter value, but for a timer-based factor,
        /// it will be the number of time steps since the Unix epoch, based on the associated
        /// period value.
        ///
        /// - parameter time: The target time, represented as a `Date`.
        ///                   The time must not be before the Unix epoch.
        ///
        /// - throws: A `Generator.Error` if a valid counter cannot be calculated.
        /// - returns: The counter value needed to generate the password for the target time.
        fileprivate func counterValue(at time: Date) throws -> UInt64 {
            switch self {
            case .counter(let counter):
                return counter
            case .timer(let period):
                let timeSinceEpoch = time.timeIntervalSince1970
                try Generator.validateTime(timeSinceEpoch)
                try Generator.validatePeriod(period)
                return UInt64(timeSinceEpoch / period)
            }
        }
    }

    /// A cryptographic hash function used to calculate the HMAC from which a password is derived.
    /// The supported algorithms are SHA-1, SHA-256, and SHA-512.
    public enum Algorithm: Equatable {
        /// The SHA-1 hash function.
        case sha1
        /// The SHA-256 hash function.
        case sha256
        /// The SHA-512 hash function.
        case sha512
    }

    /// An error type enum representing the various errors a `Generator` can throw when computing a
    /// password.
    public enum Error: Swift.Error {
        /// The requested time is before the epoch date.
        case invalidTime
        /// The timer period is not a positive number of seconds.
        case invalidPeriod
        /// The number of digits is either too short to be secure, or too long to compute.
        case invalidDigits
    }
}

// MARK: - Private

private extension Generator {
    // MARK: Validation

    static func validateDigits(_ digits: Int) throws {
        // https://tools.ietf.org/html/rfc4226#section-5.3 states "Implementations MUST extract a
        // 6-digit code at a minimum and possibly 7 and 8-digit codes."
        let acceptableDigits = 6...8
        guard acceptableDigits.contains(digits) else {
            throw Error.invalidDigits
        }
    }

    static func validateFactor(_ factor: Factor) throws {
        switch factor {
        case .counter:
            return
        case .timer(let period):
            try validatePeriod(period)
        }
    }

    static func validatePeriod(_ period: TimeInterval) throws {
        // The period must be positive and non-zero to produce a valid counter value.
        guard period > 0 else {
            throw Error.invalidPeriod
        }
    }

    static func validateTime(_ timeSinceEpoch: TimeInterval) throws {
        // The time must be positive to produce a valid counter value.
        guard timeSinceEpoch >= 0 else {
            throw Error.invalidTime
        }
    }
}

private extension String {
    /// Prepends the given character to the beginning of `self` until it matches the given length.
    ///
    /// - parameter character: The padding character.
    /// - parameter length:    The desired length of the padded string.
    ///
    /// - returns: A new string padded to the given length.
    func padded(with character: Character, toLength length: Int) -> String {
        let paddingCount = length - count
        guard paddingCount > 0 else {
            return self
        }

        let padding = String(repeating: String(character), count: paddingCount)
        return padding + self
    }
}
