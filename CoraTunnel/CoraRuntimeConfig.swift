import Foundation

enum CoraRuntimeConfig {
    static let tunGatewayIP = "198.18.0.1"
    static let tunSubnetMask = "255.255.0.0"
    static let dnsServerIP = "198.18.0.2"
    static func directModeYAML() -> String {
        """
        mode: direct
        dns:
          enable: true
          nameserver: [https://223.5.5.5/dns-query, https://1.1.1.1/dns-query]
        proxies: []
        proxy-groups: []
        rules: ["MATCH,DIRECT"]
        """
    }
}
