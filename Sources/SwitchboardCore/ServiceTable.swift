/// Names a service from its port. A port is a hint, not proof, so every label from here
/// carries the `port` basis (docs/SPEC.md §6.5).
public enum ServiceTable {
    private static let both: [UInt16: String] = [
        53: "DNS", 88: "Kerberos", 123: "NTP", 137: "NetBIOS", 138: "NetBIOS", 389: "LDAP",
        500: "IKE", 514: "Syslog", 1194: "OpenVPN", 3478: "STUN", 4500: "IPsec NAT-T",
        5060: "SIP", 5353: "mDNS", 5355: "LLMNR", 51820: "WireGuard",
    ]

    private static let tcp: [UInt16: String] = [
        20: "FTP", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 80: "HTTP", 110: "POP3",
        139: "NetBIOS", 143: "IMAP", 179: "BGP", 443: "HTTPS", 445: "SMB", 465: "SMTPS", 548: "AFP",
        587: "SMTP", 631: "IPP", 636: "LDAPS", 853: "DNS-over-TLS", 993: "IMAPS", 995: "POP3S",
        1433: "SQL Server", 1521: "Oracle", 1883: "MQTT", 2049: "NFS", 2375: "Docker", 2376: "Docker",
        3000: "HTTP-dev", 3283: "Remote Desktop", 3306: "MySQL", 3389: "RDP", 5000: "HTTP-dev",
        5222: "XMPP", 5223: "APNs", 5228: "FCM", 5432: "PostgreSQL", 5900: "VNC", 6379: "Redis",
        6443: "Kubernetes", 7000: "AirPlay", 8000: "HTTP-alt", 8080: "HTTP-alt", 8443: "HTTPS-alt",
        8883: "MQTT-TLS", 9092: "Kafka", 9200: "Elasticsearch", 11211: "Memcached", 27017: "MongoDB",
    ]

    private static let udp: [UInt16: String] = [
        67: "DHCP", 68: "DHCP", 69: "TFTP", 161: "SNMP", 162: "SNMP", 443: "QUIC", 546: "DHCPv6",
        547: "DHCPv6", 1900: "SSDP", 3702: "WS-Discovery", 5351: "NAT-PMP", 41641: "Tailscale",
    ]

    public static func service(proto: TransportProtocol, port: UInt16) -> String? {
        let specific = proto == .tcp ? tcp[port] : udp[port]
        return specific ?? both[port]
    }

    /// Labels a flow by whichever end has a well-known port, preferring the remote end.
    public static func service(for key: FlowKey) -> String? {
        service(proto: key.proto, port: key.remote.port) ?? service(proto: key.proto, port: key.local.port)
    }
}
