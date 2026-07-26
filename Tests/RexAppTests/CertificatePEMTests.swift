import Foundation
import Testing
@testable import RexApp

@Test("PEM encoder terminates the Base64 body before the footer")
func pemEncoderProducesDelimitedRoundTrippableBody() throws {
    let certificateData = Data((0..<257).map { UInt8($0 % 251) })
    let pem = CertificatePEMEncoder.encode(certificateData)

    #expect(pem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
    #expect(pem.hasSuffix("\n-----END CERTIFICATE-----\n"))

    let body = pem
        .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----\n", with: "")
        .replacingOccurrences(of: "\n-----END CERTIFICATE-----\n", with: "")
        .replacingOccurrences(of: "\n", with: "")
    let decoded = try #require(Data(base64Encoded: body))
    #expect(decoded == certificateData)
}
