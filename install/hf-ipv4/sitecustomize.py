# Auto-imported by any Python started with this dir on PYTHONPATH.
# TWO independent network workarounds for Hugging Face downloads on this machine.
# Dir name is historical ("hf-ipv4") — kept stable because memories, plans, and dl.sh
# reference this exact path. Scoped in via PYTHONPATH, never installed globally.
#
# (1) IPv4 forcing — filters getaddrinfo results to AF_INET (falls back to the full
#     result set if no IPv4 address exists). The HuggingFace CDN (CloudFront) IPv6
#     endpoints black-hole on some networks here; hf/requests otherwise try IPv6
#     first and hang in SYN_SENT. See memory hf-download-ipv6-blackhole.
#
# (2) OS trust store injection — on CORPORATE wifi (P7S1-Corp: *.fhm.de, DNS
#     172.21.4.50) a TLS-intercepting proxy makes every Python HTTPS request fail with
#     `[SSL: CERTIFICATE_VERIFY_FAILED] self-signed certificate in certificate chain`,
#     because certifi's bundle has no corporate CA while the macOS Keychain does.
#     truststore.inject_into_ssl() makes Python's ssl module use the Keychain, which
#     fixes `hf download` (and pip/uv) without disabling verification and without
#     admin rights. PROVEN 2026-08-06 on corporate wifi. See memory
#     corporate-wifi-python-ssl-mitm.
import socket as _socket

try:
    import truststore as _truststore

    _truststore.inject_into_ssl()
except Exception:  # truststore absent or injection unsupported — leave ssl untouched
    pass

_orig_getaddrinfo = _socket.getaddrinfo


def _ipv4_first(host, port, family=0, type=0, proto=0, flags=0):
    results = _orig_getaddrinfo(host, port, family, type, proto, flags)
    if family == 0:
        v4 = [r for r in results if r[0] == _socket.AF_INET]
        if v4:
            return v4
    return results


_socket.getaddrinfo = _ipv4_first
