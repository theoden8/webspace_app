# IPtProxy as go/iptproxy/build.sh builds it from source: obfs4, meek_lite,
# webtunnel, snowflake and dnstt for Tor bridges (TOR-016), with no GPL code
# (LICENSE-001). The framework and LICENSES.txt are the script's
# output, not committed; both Podfiles run it before they install this pod.
here = File.dirname(__FILE__)
version = File.read(File.join(here, 'build.sh'))[/^IPTPROXY_TAG=(\S+)$/, 1]
licences = File.readlines(File.join(here, 'licences.tsv'))
  .reject { |line| line.start_with?('#') || line.strip.empty? }
  .flat_map { |line| line.split("\t", 2)[1].strip.split(' AND ') }
  .uniq
  .sort

Pod::Spec.new do |s|
  s.name             = 'IPtProxy'
  s.version          = version
  s.summary          = 'Tor pluggable transports: obfs4, meek_lite, webtunnel, snowflake and dnstt'
  s.description      = <<~DESC
    IPtProxy's Go wrapper over lyrebird's obfs4, meek_lite and webtunnel,
    snowflake and dnstt, bound with gomobile by go/iptproxy/build.sh from
    pinned sources. lyrebird's GPL parts are left out: obfs4's Elligator 2 key
    hiding comes from go/hiddenkey, and meek_lite's uTLS round tripper from
    go/meekutls.
  DESC
  s.homepage         = 'https://github.com/tladesignz/IPtProxy'
  s.license          = { :type => licences.join(' AND '), :file => 'LICENSES.txt' }
  s.author           = { 'theoden8' => 'theoden8@tutamail.com' }
  s.source           = { :path => '.' }

  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '11.0'

  s.vendored_frameworks = 'IPtProxy.xcframework'
  # The Go runtime's resolver links res_9_ninit and friends.
  s.libraries = 'resolv'
end
