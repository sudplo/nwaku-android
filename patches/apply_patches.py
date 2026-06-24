import os
import sys

def patch_file(filepath, target, replacement):
    if not os.path.exists(filepath):
        print(f"Error: File {filepath} does not exist", file=sys.stderr)
        return False
    with open(filepath, 'r', encoding='utf-8', newline='') as f:
        content = f.read()
    
    # Normalize CRLF to LF in content and target for comparison
    content_lf = content.replace('\r\n', '\n')
    target_lf = target.replace('\r\n', '\n')
    replacement_lf = replacement.replace('\r\n', '\n')
    
    if target_lf not in content_lf:
        print(f"Warning: Target string not found in {filepath}", file=sys.stderr)
        return False
    
    new_content_lf = content_lf.replace(target_lf, replacement_lf)
    
    # Match the original line endings of the file
    if '\r\n' in content:
        new_content = new_content_lf.replace('\n', '\r\n')
    else:
        new_content = new_content_lf
        
    with open(filepath, 'w', encoding='utf-8', newline='') as f:
        f.write(new_content)
    print(f"Successfully patched: {os.path.basename(filepath)}")
    return True

def apply_timeouts_patch(src_dir):
    print("Applying REST API timeouts patch...")
    rest_api_dir = os.path.join(src_dir, 'waku', 'rest_api')
    if not os.path.exists(rest_api_dir):
        print("Warning: REST API directory not found. Skipping timeouts patch.", file=sys.stderr)
        return False
    
    replacements = [
        ('const futTimeout* = 5.seconds', 'const futTimeout* = 20.seconds'),
        ('const futTimeout* = 15.seconds', 'const futTimeout* = 20.seconds'),
        ('const FutTimeoutForPushRequestProcessing* = 5.seconds', 'const FutTimeoutForPushRequestProcessing* = 20.seconds'),
        ('const futTimeoutForSubscriptionProcessing* = 5.seconds', 'const futTimeoutForSubscriptionProcessing* = 20.seconds')
    ]
    
    modified = 0
    for root, _, files in os.walk(rest_api_dir):
        for file in files:
            if file == 'handlers.nim':
                filepath = os.path.join(root, file)
                with open(filepath, 'r', encoding='utf-8', newline='') as f:
                    content = f.read()
                
                new_content = content
                for target, rep in replacements:
                    new_content = new_content.replace(target, rep)
                
                if new_content != content:
                    with open(filepath, 'w', encoding='utf-8', newline='') as f:
                        f.write(new_content)
                    print(f"Patched timeouts in: {os.path.relpath(filepath, src_dir)}")
                    modified += 1
    return modified > 0

def apply_onion_patch(src_dir):
    print("Applying Onion protocols support patch...")
    filepath = os.path.join(src_dir, 'waku', 'net', 'net_config.nim')
    target = '          it.hasProtocol("wss")'
    replacement = '          it.hasProtocol("wss") or it.hasProtocol("onion") or it.hasProtocol("onion3")'
    return patch_file(filepath, target, replacement)

def apply_lsquic_patch(src_dir):
    print("Applying lsquic Android x86_64 type mismatch patch...")
    nimbledeps_dir = os.path.join(src_dir, 'nimbledeps', 'pkgs2')
    if not os.path.exists(nimbledeps_dir):
        print("Warning: nimbledeps/pkgs2 directory not found. Skipping lsquic patch (normal if dependencies are not installed yet).")
        return True
    
    found = False
    for root, _, files in os.walk(nimbledeps_dir):
        for file in files:
            if file == 'io.nim' and os.path.basename(root) == 'context' and 'lsquic' in root:
                filepath = os.path.join(root, file)
                target = 'when defined(linux) and defined(x86_64):'
                replacement = 'when defined(linux) and defined(x86_64) and not defined(android):'
                if patch_file(filepath, target, replacement):
                    found = True
    return found

def apply_socks5_proxy_patch(src_dir):
    print("Applying Tor SOCKS5 proxy support patch...")
    
    # 1. tools/confutils/cli_args.nim
    f1 = os.path.join(src_dir, 'tools', 'confutils', 'cli_args.nim')
    t1_1 = '''    extMultiAddrsOnly* {.
      desc: "Only announce external multiaddresses setup with --ext-multiaddr",
      defaultValue: false,
      name: "ext-multiaddr-only"
    .}: bool'''
    r1_1 = '''    extMultiAddrsOnly* {.
      desc: "Only announce external multiaddresses setup with --ext-multiaddr",
      defaultValue: false,
      name: "ext-multiaddr-only"
    .}: bool

    socks5Proxy* {.
      desc: "Tor SOCKS5 proxy address (e.g., 127.0.0.1:9050) to route outgoing p2p traffic through Tor.",
      defaultValue: "",
      name: "socks5-proxy"
    .}: string'''
    
    t1_2 = '  b.withPeerPersistence(n.peerPersistence)'
    r1_2 = '''  b.withPeerPersistence(n.peerPersistence)
  if n.socks5Proxy != "":
    b.withSocks5Proxy(n.socks5Proxy)'''
    
    # 2. waku/factory/waku_conf.nim
    f2 = os.path.join(src_dir, 'waku', 'factory', 'waku_conf.nim')
    t2_1 = '''  mixConf*: Option[MixConf]
  kademliaDiscoveryConf*: Option[KademliaDiscoveryConf]'''
    r2_1 = '''  mixConf*: Option[MixConf]
  socks5Proxy*: Option[string]
  kademliaDiscoveryConf*: Option[KademliaDiscoveryConf]'''
    
    # 3. waku/factory/conf_builder/waku_conf_builder.nim
    f3 = os.path.join(src_dir, 'waku', 'factory', 'conf_builder', 'waku_conf_builder.nim')
    t3_1 = '  localStoragePath: Option[string]'
    r3_1 = '''  localStoragePath: Option[string]
  socks5Proxy: Option[string]'''
    
    t3_2 = '''proc withLocalStoragePath*(b: var WakuConfBuilder, localStoragePath: string) =
  b.localStoragePath = some(localStoragePath)'''
    r3_2 = '''proc withLocalStoragePath*(b: var WakuConfBuilder, localStoragePath: string) =
  b.localStoragePath = some(localStoragePath)

proc withSocks5Proxy*(b: var WakuConfBuilder, socks5Proxy: string) =
  if socks5Proxy != "":
    b.socks5Proxy = some(socks5Proxy)'''
    
    t3_3 = '''    mixConf: mixConf,
    kademliaDiscoveryConf: kademliaDiscoveryConf,'''
    r3_3 = '''    mixConf: mixConf,
    socks5Proxy: builder.socks5Proxy,
    kademliaDiscoveryConf: kademliaDiscoveryConf,'''
    
    # 4. waku/factory/builder.nim
    f4 = os.path.join(src_dir, 'waku', 'factory', 'builder.nim')
    t4_1 = '''    # Rate limit configs for non-relay req-resp protocols
    rateLimitSettings: Option[ProtocolRateLimitSettings]'''
    r4_1 = '''    # Rate limit configs for non-relay req-resp protocols
    rateLimitSettings: Option[ProtocolRateLimitSettings]
    socks5Proxy: Option[string]'''
    
    t4_2 = '''  if not nameResolver.isNil():
    builder.switchNameResolver = some(nameResolver)'''
    r4_2 = '''  if not nameResolver.isNil():
    builder.switchNameResolver = some(nameResolver)

proc withSocks5Proxy*(builder: var WakuNodeBuilder, socks5Proxy: Option[string]) =
  builder.socks5Proxy = socks5Proxy'''
    
    t4_3 = '''      circuitRelay = circuitRelay,
    )'''
    r4_3 = '''      circuitRelay = circuitRelay,
      socks5Proxy = builder.socks5Proxy,
    )'''
    
    # 5. waku/factory/node_factory.nim
    f5 = os.path.join(src_dir, 'waku', 'factory', 'node_factory.nim')
    t5_1 = '  builder.withColocationLimit(conf.colocationLimit)'
    r5_1 = '''  builder.withColocationLimit(conf.colocationLimit)
  builder.withSocks5Proxy(conf.socks5Proxy)'''
    
    # 6. waku/node/waku_switch.nim
    f6 = os.path.join(src_dir, 'waku', 'node', 'waku_switch.nim')
    t6_1 = '  libp2p/transports/[transport, tcptransport, wstransport]'
    r6_1 = '  libp2p/transports/[transport, tcptransport, wstransport, tortransport]'
    
    t6_2 = '''    circuitRelay: Relay,
): Switch {.raises: [Defect, IOError, LPError].} ='''
    r6_2 = '''    circuitRelay: Relay,
    socks5Proxy: Option[string] = none(string),
): Switch {.raises: [Defect, IOError, LPError].} ='''
    
    t6_3 = '''    .withNoise()
    .withTcpTransport(transportFlags)
    .withNameResolver(nameResolver)'''
    r6_3 = '''    .withNoise()
    .withNameResolver(nameResolver)'''

    t6_4 = '''    .withCircuitRelay(circuitRelay)
    .withAutonat()

  if peerStoreCapacity.isSome():'''
    r6_4 = '''    .withCircuitRelay(circuitRelay)
    .withAutonat()

  if socks5Proxy.isSome() and socks5Proxy.get() != "":
    let proxyAddress = try:
      initTAddress(socks5Proxy.get())
    except CatchableError as e:
      raise newException(LPError, "Invalid SOCKS5 proxy address: " & e.msg)
    b = b.withTransport(
      proc(config: TransportConfig): Transport =
        TorTransport.new(proxyAddress, transportFlags, config.upgr)
    )
  else:
    b = b.withTcpTransport(transportFlags)

  if peerStoreCapacity.isSome():'''
    
    success = True
    success &= patch_file(f1, t1_1, r1_1)
    success &= patch_file(f1, t1_2, r1_2)
    success &= patch_file(f2, t2_1, r2_1)
    success &= patch_file(f3, t3_1, r3_1)
    success &= patch_file(f3, t3_2, r3_2)
    success &= patch_file(f3, t3_3, r3_3)
    success &= patch_file(f4, t4_1, r4_1)
    success &= patch_file(f4, t4_2, r4_2)
    success &= patch_file(f4, t4_3, r4_3)
    success &= patch_file(f5, t5_1, r5_1)
    success &= patch_file(f6, t6_1, r6_1)
    success &= patch_file(f6, t6_2, r6_2)
    success &= patch_file(f6, t6_3, r6_3)
    success &= patch_file(f6, t6_4, r6_4)
    return success

def main():
    if len(sys.argv) < 2:
        print("Usage: python apply_patches.py <nwaku-src-dir>")
        sys.exit(1)
        
    src_dir = sys.argv[1]
    print(f"Using nwaku source directory: {src_dir}")
    
    success = True
    success &= apply_timeouts_patch(src_dir)
    success &= apply_onion_patch(src_dir)
    success &= apply_socks5_proxy_patch(src_dir)
    success &= apply_lsquic_patch(src_dir) # Must be run after nimbledeps are resolved
    
    if success:
        print("\nAll patches applied successfully! OK")
    else:
        print("\nSome patches failed to apply. Please check warnings/errors above.", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
