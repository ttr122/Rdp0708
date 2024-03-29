# -*- coding: binary -*-

module Msf

###
#
# This module exposes methods for interacting with a remote RDP service
#
###
module Exploit::Remote::RDP
  require 'rc4'
  include Msf::Exploit::Remote::Tcp

  #
  # Creates an instance of a RDP exploit module.
  #
  def initialize(info = {})
    super
    register_options(
      [
        OptString.new('RDP_USER', [ false, 'The username to report during connect, UNSET = random']),
        OptString.new('RDP_CLIENT_NAME', [ false, 'The client computer name to report during connect, UNSET = random', 'rdesktop']),
        OptString.new('RDP_DOMAIN', [ false, 'The client domain name to report during connect']),
        OptAddress.new('RDP_CLIENT_IP', [ true, 'The client IPv4 address to report during connect', '192.168.0.100']),
        Opt::RPORT(3389)
      ], Msf::Exploit::Remote::RDP)
  end


  # used to abruptly abort scanner for a given host
  class RdpCommunicationError < StandardError
  end

  #
  # Constants
  #
  class RDPConstants
    SSL_REQUIRED_BY_SERVER = 1
    SSL_NOT_ALLOWED_BY_SERVER = 2
    SSL_CERT_NOT_ON_SERVER = 3
    INCONSISTENT_FLAGS = 4
    HYBRID_REQUIRED_BY_SERVER = 5
    SSL_WITH_USER_AUTH_REQUIRED_BY_SERVER = 6

    PROTOCOL_RDP = 0
    PROTOCOL_SSL = 1
    PROTOCOL_HYBRID = 2
    PROTOCOL_RDSTLS = 4
    PROTOCOL_HYBRID_EX = 8

    RDP_NEG_PROTOCOL = {
      0 => "PROTOCOL_RDP",
      1 => "PROTOCOL_SSL",
      2 => "PROTOCOL_HYBRID",
      4 => "PROTOCOL_RDSTLS",
      8 => "PROTOCOL_HYBRID_EX"
    }

    RDP_NEG_FAILURE = {
      1 => "SSL_REQUIRED_BY_SERVER",
      2 => "SSL_NOT_ALLOWED_BY_SERVER",
      3 => "SSL_CERT_NOT_ON_SERVER",
      4 => "INCONSISTENT_FLAGS",
      5 => "HYBRID_REQUIRED_BY_SERVER",
      6 => "SSL_WITH_USER_AUTH_REQUIRED_BY_SERVER"
    }

    REDIRECTION_SUPPORTED = 0x1
    REDIRECTION_VERSION3  = 0x2 << 2
    REDIRECTION_VERSION4  = 0x3 << 2
    REDIRECTION_VERSION5  = 0x4 << 2

    ENCRYPTION_40BIT  = 0x01
    ENCRYPTION_128BIT = 0x02
    ENCRYPTION_56BIT  = 0x08
    ENCRYPTION_FIPS   = 0x10

    CHAN_INITIALIZED               = 0x80000000
    CHAN_ENCRYPT_RDP               = 0x40000000
    CHAN_ENCRYPT_SC                = 0x20000000
    CHAN_ENCRYPT_CS                = 0x10000000
    CHAN_PRI_HIGH                  = 0x08000000
    CHAN_PRI_MED                   = 0x04000000
    CHAN_PRI_LOW                   = 0x02000000
    CHAN_COMPRESS_RDP              = 0x00800000
    CHAN_COMPRESS                  = 0x00400000
    CHAN_SHOW_PROTOCOL             = 0x00200000
    CHAN_REMOTE_CONTROL_PERSISTENT = 0x00100000

    CHAN_FLAG_FIRST         = 0x01
    CHAN_FLAG_LAST          = 0x02
    CHAN_FLAG_SHOW_PROTOCOL = 0x10

    RDPDR_CTYP_CORE = 0x4472

    PAKID_CORE_SERVER_ANNOUNCE     = 0x496e
    PAKID_CORE_SERVER_CAPABILITY   = 0x5350
    PAKID_CORE_CLIENTID_CONFIRM    = 0x4343
    PAKID_CORE_CLIENT_NAME         = 0x434e
    PAKID_CORE_DEVICELIST_ANNOUNCE = 0x4441
  end

  def rdp_connect
    self.rdp_sock = connect(false)
    self.rdp_sock.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_NODELAY, 1)
  end


  def rdp_disconnect
    disconnect(self.rdp_sock)
    self.rdp_sock = nil
  end

  def rdp_send(data)
    self.rdp_sock.put(data)
  end

  def rdp_recv(length = -1, timeout = 5)
    res = self.rdp_sock.get_once(length, timeout)
    raise RdpCommunicationError unless res # nil due to a timeout

    res
  rescue EOFError
    raise RdpCommunicationError
  end

  def rdp_send_recv(data)
    rdp_send(data)
    rdp_recv
  end

  # Connect and perform fingerprinting of the RDP service
  #
  # Note: NLA is required to detect the product_version
  #
  # @return [Boolean] Is service RDP
  # @return [Hash] Version information
  def rdp_fingerprint
    peer_info = {}
    # warning: if rdp_check_protocol starts handling NLA, this will need to be updated
    is_rdp, server_selected_proto = rdp_check_protocol(RDPConstants::PROTOCOL_SSL | RDPConstants::PROTOCOL_HYBRID | RDPConstants::PROTOCOL_HYBRID_EX)
    return false, nil unless is_rdp
    return true, peer_info unless [RDPConstants::PROTOCOL_HYBRID, RDPConstants::PROTOCOL_HYBRID_EX].include? server_selected_proto

    swap_sock_plain_to_ssl
    ntlm_negotiate_blob = ''  # see: https://fadedlab.wordpress.com/2019/06/13/using-nmap-to-extract-windows-info-from-rdp/
    ntlm_negotiate_blob << "\x30\x37\xa0\x03\x02\x01\x60\xa1\x30\x30\x2e\x30\x2c\xa0\x2a\x04\x28"
    ntlm_negotiate_blob << "\x4e\x54\x4c\x4d\x53\x53\x50\x00"  #  Identifier - NTLMSSP
    ntlm_negotiate_blob << "\x01\x00\x00\x00"                  #  Type: NTLMSSP Negotiate - 01
    ntlm_negotiate_blob << "\xb7\x82\x08\xe2"                  #  Flags (NEGOTIATE_SIGN_ALWAYS | NEGOTIATE_NTLM | NEGOTIATE_SIGN | REQUEST_TARGET | NEGOTIATE_UNICODE)
    ntlm_negotiate_blob << "\x00\x00"                          #  DomainNameLen
    ntlm_negotiate_blob << "\x00\x00"                          #  DomainNameMaxLen
    ntlm_negotiate_blob << "\x00\x00\x00\x00"                  #  DomainNameBufferOffset
    ntlm_negotiate_blob << "\x00\x00"                          #  WorkstationLen
    ntlm_negotiate_blob << "\x00\x00"                          #  WorkstationMaxLen
    ntlm_negotiate_blob << "\x00\x00\x00\x00"                  #  WorkstationBufferOffset
    ntlm_negotiate_blob << "\x0a"                              #  ProductMajorVersion = 10
    ntlm_negotiate_blob << "\x00"                              #  ProductMinorVersion = 0
    ntlm_negotiate_blob << "\x63\x45"                          #  ProductBuild = 0x4563 = 17763
    ntlm_negotiate_blob << "\x00\x00\x00"                      #  Reserved
    ntlm_negotiate_blob << "\x0f"                              #  NTLMRevision = 5 = NTLMSSP_REVISION_W2K3
    resp = rdp_send_recv(ntlm_negotiate_blob)

    ntlmssp_start = resp.index('NTLMSSP')
    if ntlmssp_start
      ntlmssp = NTLM_MESSAGE::parse(resp[ntlmssp_start..-1])
      version = ntlmssp.padding.bytes
      peer_info[:product_version] = "#{version[0]}.#{version[1]}.#{version[2] | (version[3] << 8)}"
    end

    return is_rdp, peer_info
  end

  def rdp_dispatch_loop
    while rdp_sock do
      rdp_handle_packet(rdp_recv)
    end
  end

  def rdp_create_channel_msg(chan_user_id, chan_id, data, flags = 3, data_length = nil)
    data_length ||= data.length

    pdu = [
      [25 << 2].pack('C'), # MCS send data request structure, choice 25
      [self.rdp_user_id, chan_id].pack('S>S>'), # MCS send data request structure, choice 25
      "\x70", # Wut (security header)
      per_data(
        [data_length].pack('<L'),
        [flags].pack('<L'),
        data
      )
    ].join('')

    build_data_tpdu(pdu)
  end

  def rdp_send_channel(chan_user_id, chan_id, data, flags = 3, data_length = nil)
    tpkt = rdp_create_channel_msg(chan_user_id, chan_id, data, flags, data_length)
    rdp_send(tpkt)
  end

  def rdp_terminate
    body = "\x21\x80" # user requested disconnect provider ultimatum

    rdp_send(build_data_tpdu(body))
  end

  # Connect and detect security protocol
  #
  # Note: NLA is detected but not supported yet
  #
  # @return [Boolean] Is service RDP
  # @return [RDPConstants] Protocol supported
  def rdp_check_protocol(req_proto = RDPConstants::PROTOCOL_SSL)
    if datastore['RDP_USER']
      @user_name = datastore['RDP_USER']
    else
      @user_name = Rex::Text.rand_text_alpha(7)
    end

    if datastore['RDP_DOMAIN']
      @domain = datastore['RDP_DOMAIN']
    else
      @domain = Rex::Text.rand_text_alpha(7)
    end

    if datastore['RDP_CLIENT_NAME']
      @computer_name = datastore['RDP_CLIENT_NAME']
    else
      @computer_name = Rex::Text.rand_text_alpha(15)
    end

    @ip_address = datastore['RDP_CLIENT_IP']

    # code to check if RDP is open or not
    vprint_status("Verifying RDP protocol...")

    vprint_status("Attempting to connect using TLS security")
    res = rdp_send_recv(pdu_negotiation_request(@user_name, req_proto))

    # return true if the response is a X.224 Connect Confirm
    # We can't use a check for RDP Negotiation Response because WinXP excludes it
    if res
      result, err_msg = rdp_parse_negotiation_response(res)
      return true, result if result

      # No current support for NLA, nothing to do here
      return true, RDPConstants::PROTOCOL_HYBRID if err_msg == 'HYBRID_REQUIRED_BY_SERVER'

      if err_msg == "Negotiation Response packet too short."
        vprint_status("Attempt to connect with TLS failed but looks like the target is Windows XP")
      else
        vprint_status("Attempt to connect with TLS failed with error: #{err_msg}")
      end

      if ["SSL_NOT_ALLOWED_BY_SERVER", "Negotiation Response packet too short."].include? err_msg
        # This happens if the server is configured to ONLY permit RDP Security
        vprint_status("Attempting to connect using Standard RDP security")
        rdp_disconnect
        rdp_connect
        res = rdp_send_recv(pdu_negotiation_request(@user_name, RDPConstants::PROTOCOL_RDP))

        if res
          result, err_msg = rdp_parse_negotiation_response(res)
          return true, result if result

          # Windows XP doesn't return the standard Negotiation Response packet
          # but we at least know this was RDP since the packet contained a
          # Connect-Confirm response (0xd0).
          if err_msg == "Negotiation Response packet too short."
            return true, RDPConstants::PROTOCOL_RDP
          end

          vprint_status("Attempt to connect with Standard RDP failed with error #{err_msg}")
        end
      end
    end

    return false, 0
  end

  # Negotiate security protocol and begin session building
  #
  # @return [Boolean] success
  def rdp_negotiate_security(channels, req_proto = RDPConstants::PROTOCOL_SSL)
    if req_proto == RDPConstants::PROTOCOL_SSL
      swap_sock_plain_to_ssl
      res = rdp_send_recv(pdu_connect_initial(channels, req_proto, @computer_name))
    elsif req_proto == RDPConstants::PROTOCOL_RDP
      res = rdp_send_recv(pdu_connect_initial(channels, req_proto, @computer_name))
      rsmod, rsexp, _rsran, server_rand, bitlen = rdp_parse_connect_response(res)
    elsif [RDPConstants::PROTOCOL_HYBRID, RDPConstants::PROTOCOL_HYBRID_EX].include?(req_proto)
      vprint_status("NLA Security protocol unsupported at this time.")
      return false
    else
      vprint_error("Unknown protocol requested (#{req_proto}).")
      return false
    end

    # erect domain and attach user
    vprint_status("Sending erect domain request")
    rdp_send(pdu_erect_domain_request)
    res = rdp_send_recv(pdu_attach_user_request)

    self.rdp_user_id = res[9, 2].unpack("n").first

    # send channel requests
    [1009, 1003, 1004, 1005, 1006, 1007, 1008].each do |chan|
      rdp_send_recv(pdu_channel_join_request(self.rdp_user_id, chan))
    end

    if req_proto == RDPConstants::PROTOCOL_RDP
      @rdp_sec = true

      # 5.3.4 Client Random Value
      client_rand = ''
      32.times { client_rand << rand(0..255) }
      rcran = bytes_to_bignum(client_rand)

      vprint_status("Sending security exchange PDU")
      rdp_send(pdu_security_exchange(rcran, rsexp, rsmod, bitlen))

      # We aren't decrypting anything at this point. Leave the variables here
      # to make it easier to understand in the future.
      rc4encstart, _rc4decstart, @hmackey, _sessblob = rdp_calculate_rc4_keys(client_rand, server_rand)

      @rc4enckey = RC4.new(rc4encstart)
    end

    return true
  end

  # Finish building session after all security is negotiated
  def rdp_establish_session
    vprint_status("Sending client info PDU")
    res = rdp_send_recv(rdp_build_pkt(pdu_client_info(@user_name, @domain, @ip_address), "\x03\xeb", true))
    vprint_status("Received License packet")

    # Windows XP sometimes sends a very large license packet. This is likely
    # some form of license error. When it does this it doesn't send a Server
    # Demand packet. If we wait on one we will time out here and error. We
    # can still successfully check for vulnerability anyway.
    if res.length <= 34
      vprint_status("Waiting for Server Demand packet")
      _res = rdp_recv
      vprint_status("Received Server Demand packet")
    end

    vprint_status("Sending client confirm active PDU")
    rdp_send(rdp_build_pkt(pdu_client_confirm_active))

    vprint_status("Sending client synchronize PDU")
    vprint_status("Sending client control cooperate PDU")
    # Unsure why we're using 1009 here but it works.
    synch = rdp_build_pkt(pdu_client_synchronize(1009))
    coop = rdp_build_pkt(pdu_client_control_cooperate)
    rdp_send(synch + coop)

    vprint_status("Sending client control request control PDU")
    rdp_send(rdp_build_pkt(pdu_client_control_request))

    vprint_status("Sending client input sychronize PDU")
    rdp_send(rdp_build_pkt(pdu_client_input_event_sychronize))

    vprint_status("Sending client font list PDU")
    rdp_send(rdp_build_pkt(pdu_client_font_list))
  end

  #
  # Protocol parsers
  #

  # Parse RDP Negotiation Data - 2.2.1.2
  # Reference: https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/13757f8f-66db-4273-9d2c-385c33b1e483
  # @return [String, nil] String representation of the Selected Protocol or nil on failure
  # @return [String] Error message
  def rdp_parse_negotiation_response(data)
    return false, "Response is not an RDP Negotiation Response packet." unless data.match("\x03\x00\x00..\xd0")
    return false, "Negotiation Response packet too short." if data.length < 19

    response_code = data[11].unpack("C")[0]

    if response_code == 2  # TYPE_RDP_NEG_RSP
      # RDP Negotiation Response - 2.2.1.2.1
      server_selected_proto = data[15..18].unpack("L<")[0]

      proto_label = RDPConstants::RDP_NEG_PROTOCOL[server_selected_proto]
      return server_selected_proto, nil if proto_label

      return nil, "Unknown protocol in Negotiation Response: #{server_selected_proto}"

    elsif response_code == 3  # TYPE_RDP_NEG_FAILURE
      # RDP Negotiation Failure - 2.2.1.2.2
      failure_code = data[15..18].unpack("L<")[0]
      return nil, RDPConstants::RDP_NEG_FAILURE[failure_code]
    else
      return nil, "Unknown Negotiation Response code: #{response_code}"
    end
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/927de44c-7fe8-4206-a14f-e5517dc24b1c
  # Parse Server MCS Connect Response PUD - 2.2.1.4
  def rdp_parse_connect_response(pkt)
    ptr = 0
    rdp_pkt = pkt[0x49..pkt.length]

    while ptr < rdp_pkt.length
      header_type = rdp_pkt[ptr..ptr + 1]
      header_length = rdp_pkt[ptr + 2..ptr + 3].unpack("S<")[0]

      if header_type == "\x02\x0c"

        server_random = rdp_pkt[ptr + 20..ptr + 51]
        public_exponent = rdp_pkt[ptr + 84..ptr + 87]

        rsa_magic = rdp_pkt[ptr + 68..ptr + 71]
        if rsa_magic != "RSA1"
          print_error("Server cert isn't RSA, this scenario isn't supported (yet).")
          raise RdpCommunicationError
        end

        bitlen = rdp_pkt[ptr + 72..ptr + 75].unpack("L<")[0] - 8
        modulus = rdp_pkt[ptr + 88..ptr + 87 + bitlen]
      end

      ptr += header_length
    end

    # vprint_status("SERVER_MODULUS: #{bin_to_hex(modulus)}")
    # vprint_status("SERVER_EXPONENT: #{bin_to_hex(public_exponent)}")
    # vprint_status("SERVER_RANDOM: #{bin_to_hex(server_random)}")

    rsmod = bytes_to_bignum(modulus)
    rsexp = bytes_to_bignum(public_exponent)
    rsran = bytes_to_bignum(server_random)

    # vprint_status("MODULUS  = #{bin_to_hex(modulus)} - #{rsmod.to_s}")
    # vprint_status("EXPONENT = #{bin_to_hex(public_exponent)} - #{rsexp.to_s}")
    # vprint_status("SVRANDOM = #{bin_to_hex(server_random)} - #{rsran.to_s}")

    return rsmod, rsexp, rsran, server_random, bitlen
  end

  #
  # Encryption: Standard RDP Security
  #

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/7c61b54e-f6cd-4819-a59a-daf200f6bf94
  # mac_salt_key = "W\x13\xc58\x7f\xeb\xa9\x10*\x1e\xddV\x96\x8b[d"
  # data_content = "\x12\x00\x17\x00\xef\x03\xea\x03\x02\x00\x00\x01\x04\x00$\x00\x00\x00"
  # hmac = rdp_hmac(mac_salt_key, data_content) # == hexlified: "22d5aeb486994a0c785dc929a2855923"
  def rdp_hmac(mac_salt_key, data_content)
    sha1 = Digest::SHA1.new
    md5 = Digest::MD5.new

    pad1 = "\x36" * 40
    pad2 = "\x5c" * 48

    sha1 << mac_salt_key
    sha1 << pad1
    sha1 << [data_content.length].pack('<L')
    sha1 << data_content

    md5 << mac_salt_key
    md5 << pad2
    md5 << [sha1.hexdigest].pack("H*")

    [md5.hexdigest].pack("H*")
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/705f9542-b0e3-48be-b9a5-cf2ee582607f
  #  SaltedHash(S, I) = MD5(S + SHA(I + S + ClientRandom + ServerRandom))
  def rdp_salted_hash(s_bytes, i_bytes, client_random_bytes, server_random_bytes)
    sha1 = Digest::SHA1.new
    md5 = Digest::MD5.new

    sha1 << i_bytes
    sha1 << s_bytes
    sha1 << client_random_bytes
    sha1 << server_random_bytes

    md5 << s_bytes
    md5 << [sha1.hexdigest].pack("H*")

    [md5.hexdigest].pack("H*")
  end

  #  FinalHash(K) = MD5(K + ClientRandom + ServerRandom)
  def rdp_final_hash(k, client_random_bytes, server_random_bytes)
    md5 = Digest::MD5.new

    md5 << k
    md5 << client_random_bytes
    md5 << server_random_bytes

    [md5.hexdigest].pack("H*")
  end

  def rdp_calculate_rc4_keys(client_random, server_random)
    # preMasterSecret = First192Bits(ClientRandom) + First192Bits(ServerRandom)
    preMasterSecret = client_random[0..23] + server_random[0..23]

    # PreMasterHash(I) = SaltedHash(preMasterSecret, I)
    # MasterSecret = PreMasterHash(0x41) + PreMasterHash(0x4242) + PreMasterHash(0x434343)
    masterSecret = rdp_salted_hash(preMasterSecret, "A", client_random,server_random) +  rdp_salted_hash(preMasterSecret, "BB", client_random, server_random) + rdp_salted_hash(preMasterSecret, "CCC", client_random, server_random)

    # MasterHash(I) = SaltedHash(MasterSecret, I)
    # SessionKeyBlob = MasterHash(0x58) + MasterHash(0x5959) + MasterHash(0x5A5A5A)
    sessionKeyBlob = rdp_salted_hash(masterSecret, "X", client_random, server_random) +  rdp_salted_hash(masterSecret, "YY", client_random, server_random) + rdp_salted_hash(masterSecret, "ZZZ", client_random, server_random)

    # InitialClientDecryptKey128 = FinalHash(Second128Bits(SessionKeyBlob))
    initialClientDecryptKey128 = rdp_final_hash(sessionKeyBlob[16..31], client_random, server_random)

    # InitialClientEncryptKey128 = FinalHash(Third128Bits(SessionKeyBlob))
    initialClientEncryptKey128 = rdp_final_hash(sessionKeyBlob[32..47], client_random, server_random)

    mac_key = sessionKeyBlob[0..15]

    return initialClientEncryptKey128, initialClientDecryptKey128, mac_key, sessionKeyBlob
  end

  def rsa_encrypt(bignum, rsexp, rsmod)
    (bignum ** rsexp) % rsmod
  end

  def rdp_rc4_crypt(rc4obj, data)
    rc4obj.encrypt(data)
  end

  def bytes_to_bignum(bytes_val, order = "little")
    bytes = bin_to_hex(bytes_val)
    if order == "little"
      bytes = bytes.scan(/../).reverse.join('')
    end
    s = "0x" + bytes
    s.to_i(16)
  end

  # https://www.ruby-forum.com/t/integer-to-byte-string-speed-improvements/67110
  def int_to_bytestring( int_val, num_chars = nil )
    unless num_chars
      bits_needed = Math.log(int_val) / Math.log(2)
      num_chars = ( bits_needed / 8.0 ).ceil
    end
    if pack_code = { 1 => 'C', 2 => 'S', 4 => 'L' }[num_chars]
      [int_val].pack(pack_code)
    else
      a = (0..(num_chars)).map{ |i|
        (( int_val >> i*8 ) & 0xFF ).chr
      }.join
      a[0..-2] # seems legit lol
    end
  end

  def bin_to_hex(str_val)
    str_val.each_byte.map { |b| b.to_s(16).rjust(2, '0') }.join
  end


  #
  # Protocol Data Unit definitions and helpers
  #

  # Build the X.224 packet, encrypt with Standard RDP Security as needed
  # default channel_id = 0x03eb = 1003
  def rdp_build_pkt(data, channel_id = "\x03\xeb", client_info = false)
    flags = 0
    flags |= 0b1000 if @rdp_sec       # Set SEC_ENCRYPT
    flags |= 0b1000000 if client_info # Set SEC_INFO_PKT

    pdu = ""

    # TS_SECURITY_HEADER - 2.2.8.1.1.2.1
    # Send when the packet is encrypted w/ Standard RDP Security and in all Client Info PDUs
    if client_info || @rdp_sec
      pdu << [flags].pack("S<")  # flags  "\x48\x00" = SEC_INFO_PKT | SEC_ENCRYPT
      pdu << "\x00\x00"          # flagsHi
    end

    if @rdp_sec
      # Encrypt the payload with RDP Standard Encryption
      pdu << rdp_hmac(@hmackey, data)[0..7]
      pdu << rdp_rc4_crypt(@rc4enckey, data)
    else
      pdu << data
    end

    user_data_len = pdu.length
    udl_with_flag = 0x8000 | user_data_len

    pkt =  "\x64"      # sendDataRequest
    pkt << "\x00\x08"  # intiator userId .. TODO: for a functional client this isn't static
    pkt << channel_id  # channelId
    pkt << "\x70"      # dataPriority
    pkt << [udl_with_flag].pack("S>")
    pkt << pdu

    build_data_tpdu(pkt)
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/6c074267-1b32-4ceb-9496-2eb941a23e6b
  # Virtual Channel PDU 2.2.6.1
  def build_virtual_channel_pdu(flags, data)
    data_len = data.length

    [data_len].pack("L<") + # length
      [flags].pack("L<") +  # flags
      data
  end

  # Builds x.224 Data (DT) TPDU - Section 13.7
  def build_data_tpdu(data)
    tpkt_length = data.length + 7

    "\x03\x00" +                 # TPKT Header version 03, reserved 0
      [tpkt_length].pack("S>") + # TPKT length
      "\x02\xf0\x80" +           # X.224 Data TPDU (2 bytes: 0xf0 = Data TPDU, 0x80 = EOT, end of transmission)
      data
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/18a27ef9-6f9a-4501-b000-94b1fe3c2c10
  # Client X.224 Connect Request PDU - 2.2.1.1
  def pdu_negotiation_request(user_name = "", requested_protocols = 0)
    # Blank username is ok, nil = random
    user_name = Rex::Text.rand_text_alpha(12) if user_name.nil?
    tpkt_len = user_name.length + 38
    x224_len = user_name.length + 33

    "\x03\x00" +              # TPKT Header version 03, reserved 0
      [tpkt_len].pack("S>") + # TPKT length: 43
      [x224_len].pack("C") +  # X.224 LengthIndicator
      "\xe0" +        # X.224 Type: Connect Request
      "\x00\x00" +    # dst reference
      "\x00\x00" +    # src reference
      "\x00" +        # class and options
      # cookie - literal 'Cookie: mstshash='
      "\x43\x6f\x6f\x6b\x69\x65\x3a\x20\x6d\x73\x74\x73\x68\x61\x73\x68\x3d" +
      user_name +     # Identifier "username"
      "\x0d\x0a" +    # cookie terminator
      "\x01\x00" +    # Type: RDP Negotiation Request ( 0x01 )
      "\x08\x00" +    # Length
      [requested_protocols].pack('L<') # requestedProtocols
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/db6713ee-1c0e-4064-a3b3-0fac30b4037b
  def pdu_connect_initial(channels, selected_proto = 0, host_name = "rdesktop")
    # After negotiating TLS or NLA the connectInitial packet needs to include the
    # protocol selection that the server indicated in its Negotiation Response

    pdu = [
      "\x7f\x65",        # T.125 Connect-Initial (BER: Application 101)
      ber_data(
        "\x04\x01\x01",    # CallingDomainSelector: 1 (BER: OctetString)
        "\x04\x01\x01",    # CalledDomainSelector: 1 (BER: OctetString)
        "\x01\x01\xff",    # UpwaredFlag: True (BER: boolean)

        # TargetParamenters
        encode_domain_selector(
          max_chan_ids: 0x22,
          max_user_ids: 0x2
        ),
        # MinimumParameters
        encode_domain_selector(
          max_chan_ids: 0x1,
          max_user_ids: 0x1,
          max_token_ids: 0x1,
          max_mcspdu_size: 0x0420
        ),
        # MaximumParameters
        encode_domain_selector(
          max_chan_ids: 0xffff,
          max_user_ids: 0xfc17,
          max_token_ids: 0xffff
        ),
        # UserData
        ber_octet_string(
          # T.124 GCC Connection Data (ConnectData)- PER Encoding used
          per_object(oid(0, 0, 20, 124, 0, 1)),
          per_data(
            conf_create_req(),
            per_data(
              cs_core_data(client_name: host_name, selected_proto: selected_proto),
              cs_cluster_data(),
              cs_security_data(),
              cs_network_data(channels)
            )
          )
        )
      )
    ].join('')

    build_data_tpdu(pdu)
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/04c60697-0d9a-4afd-a0cd-2cc133151a9c
  # Client MCS Erect Domain Request PDU - 2.2.1.5
  def pdu_erect_domain_request
    pdu =
      "\x04" +       # T.125 ErectDomainRequest
      "\x01\x00" +   # subHeight - length 1, value 0
      "\x01\x00"     # subInterval - length 1, value 0

    build_data_tpdu(pdu)
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/f5d6a541-9b36-4100-b78f-18710f39f247\
  # Client MCS Attach User Request PDU - 2.2.1.6
  def pdu_attach_user_request
    pdu = "\x28"  # T.125 AttachUserRequest

    build_data_tpdu(pdu)
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/64564639-3b2d-4d2c-ae77-1105b4cc011b
  # Client MCS Channel Join Request PDU -2.2.1.8
  def pdu_channel_join_request(user1, channel_id)
    pdu =
      "\x38" + # T.125 ChannelJoinRequest
      [user1, channel_id].pack("nn")

    build_data_tpdu(pdu)
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/9cde84cd-5055-475a-ac8b-704db419b66f
  # Client Security Exchange PDU - 2.2.1.10
  def pdu_security_exchange(rcran, rsexp, rsmod, bitlen)
    encrypted_rcran_bignum = rsa_encrypt(rcran, rsexp, rsmod)
    encrypted_rcran = int_to_bytestring(encrypted_rcran_bignum)

    bitlen += 8 # Pad with size of TS_SECURITY_PACKET header

    userdata_length = 8 + bitlen
    userdata_length_low = userdata_length & 0xFF
    userdata_length_high = userdata_length / 256
    flags = 0x80 | userdata_length_high

    pdu =
      "\x64" +            # T.125 sendDataRequest
      "\x00\x08" +        # intiator userId
      "\x03\xeb" +        # channelId = 1003
      "\x70" +            # dataPriority = high, segmentation = begin | end
      [flags].pack("C") +
      [userdata_length_low].pack("C") + # UserData length
      # TS_SECURITY_PACKET - 2.2.1.10.1
      "\x01\x00" +           # securityHeader flags
      "\x00\x00" +           # securityHeader flagsHi
      [bitlen].pack("L<") +  # TS_ length
      encrypted_rcran +      # encryptedClientRandom - 64 bytes
      "\x00\x00\x00\x00\x00\x00\x00\x00" # 8 bytes rear padding (always present)

    build_data_tpdu(pdu)
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/772d618e-b7d6-4cd0-b735-fa08af558f9d
  # TS_INFO_PACKET - 2.2.1.11.1.1
  def pdu_client_info(user_name, domain_name = "", ip_address = "")
    # Max len for 4.0/6.0 servers is 44 bytes including terminator
    # Max len for all other versions is 512 including terminator
    # We're going to limit to 44 (21 chars + null -> unicode) here.
    # Blank username is ok, nil = random
    user_name = Rex::Text.rand_text_alpha(10) if user_name.nil?
    user_unicode = Rex::Text.to_unicode(user_name[0..20], 'utf-16le')
    uname_len = user_unicode.length

    # Domain can can be, and for rdesktop typically is, empty.
    # Max len for 4.0/5.0 servers is 52 including terminator
    # Max len for all other versions is 512 including terminator
    # We're going to limit to 52 (25 chars + null -> unicode) here.
    domain_unicode = Rex::Text.to_unicode(domain_name[0..24], 'utf-16le')
    domain_len = domain_unicode.length

    # This address value is primarily used to reduce the fields by which this
    # module can be fingerprinted. It doesn't show up in Windows logs.
    # clientAddress + null terminator
    ip_unicode = Rex::Text.to_unicode(ip_address, 'utf-16le') + "\x00\x00"
    ip_len = ip_unicode.length

    "\x00\x00\x00\x00" +    # CodePage
      "\x33\x01\x00\x00" +  # flags - INFO_MOUSE, INFO_DISABLECTRLALTDEL, INFO_UNICODE, INFO_MAXIMIZESHELL, INFO_ENABLEWINDOWSKEY
      [domain_len].pack("S<") + # cbDomain (length value) - EXCLUDES null terminator
      [uname_len].pack("S<") +  # cbUserName (length value) - EXCLUDES null terminator
      "\x00\x00" +  # cbPassword (length value)
      "\x00\x00" +  # cbAlternateShell (length value)
      "\x00\x00" +  # cbWorkingDir (length value)
      [domain_unicode].pack("a*") + # Domain
      "\x00\x00" +                  # Domain null terminator, EXCLUDED from value of cbDomain
      [user_unicode].pack("a*") +   # UserName
      "\x00\x00" +  # UserName null terminator, EXCLUDED FROM value of cbUserName
      "\x00\x00" +  # Password - empty
      "\x00\x00" +  # AlternateShell - empty
      "\x00\x00" +  # WorkingDir - empty
      # TS_EXTENDED_INFO_PACKET - 2.2.1.11.1.1.1
      "\x02\x00" +              # clientAddressFamily - AF_INET - FIXFIX - detect and set dynamically
      [ip_len].pack("S<") +     # cbClientAddress (length value) - INCLUDES terminator ... for reasons.
      [ip_unicode].pack("a*") + # clientAddress (unicode + null terminator (unicode)
      "\x3c\x00" +              # cbClientDir (length value): 60
      # clientDir - 'C:\WINNT\System32\mstscax.dll' + null terminator
      "\x3c\x00\x43\x00\x3a\x00\x5c\x00\x57\x00\x49\x00\x4e\x00\x4e\x00" + #
      "\x54\x00\x5c\x00\x53\x00\x79\x00\x73\x00\x74\x00\x65\x00\x6d\x00" + #
      "\x33\x00\x32\x00\x5c\x00\x6d\x00\x73\x00\x74\x00\x73\x00\x63\x00" + #
      "\x61\x00\x78\x00\x2e\x00\x64\x00\x6c\x00\x6c\x00\x00\x00" + #
      # clientTimeZone - TS_TIME_ZONE struct - 172 bytes
      # These are the default values for rdesktop
      "\xa4\x01\x00\x00" + # Bias
      # StandardName - 'GTB,normaltid'
      "\x47\x00\x54\x00\x42\x00\x2c\x00\x20\x00\x6e\x00\x6f\x00\x72\x00" + #
      "\x6d\x00\x61\x00\x6c\x00\x74\x00\x69\x00\x64\x00\x00\x00\x00\x00" + #
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" + #
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" + #
      "\x00\x00\x0a\x00\x00\x00\x05\x00\x03\x00\x00\x00\x00\x00\x00\x00" + # StandardDate - Oct 5
      "\x00\x00\x00\x00" + # StandardBias
      # DaylightName - 'GTB,sommartid'
      "\x47\x00\x54\x00\x42\x00\x2c\x00\x20\x00\x73\x00\x6f\x00\x6d\x00" + #
      "\x6d\x00\x61\x00\x72\x00\x74\x00\x69\x00\x64\x00\x00\x00\x00\x00" + #
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" + #
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" + #
      "\x00\x00\x03\x00\x00\x00\x05\x00\x02\x00\x00\x00\x00\x00\x00\x00" + # DaylightDate - Mar 3
      "\xc4\xff\xff\xff" + # DaylightBias
      "\x00\x00\x00\x00" + # clientSessionId
      "\x27\x00\x00\x00" + # performanceFlags
      "\x00\x00"           # cbAutoReconnectCookie
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/73d01865-2eae-407f-9b2c-87e31daac471
  # Share Control Header - TS_SHARECONTROLHEADER - 2.2.8.1.1.1.1
  def build_share_control_header(type, data)
    total_len = data.length + 6

    [total_len].pack("S<") + # totalLength - includes all headers
      [type].pack("S<") +    # pduType - flags 16 bit, unsigned
      "\xf1\x03" +           # PDUSource: 0x03f1 = 1009
      data
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/4b5d4c0d-a657-41e9-9c69-d58632f46d31
  # Share Data Header - TS_SHAREDATAHEADER - 2.2.8.1.1.1.2
  def build_share_data_header(type, data)
    uncompressed_len = data.length + 4

    "\xea\x03\x01\x00" + # shareId: 66538
      "\x00" +     # pad1
      "\x01" +     # streamID: 1
      [uncompressed_len].pack("S<") + # uncompressedLength - 16 bit, unsigned int
      [type].pack("C") + # pduType2 - 8 bit, unsigned int - 2.2.8.1.1.2
      "\x00" +     # compressedType: 0
      "\x00\x00" + # compressedLength: 0
      data
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/9d1e1e21-d8b4-4bfd-9caf-4b72ee91a7135
  # Control Cooperate - TC_CONTROL_PDU 2.2.1.15
  def pdu_client_control_cooperate
    pdu =
      "\x04\x00" +       # action: 4 - CTRLACTION_COOPERATE
      "\x00\x00" +       # grantId: 0
      "\x00\x00\x00\x00" # controlId: 0

    # pduType2 = 0x14 = 20 - PDUTYPE2_CONTROL
    data_header = build_share_data_header(0x14, pdu)

    # type = 0x17 = TS_PROTOCOL_VERSION | PDUTYPE_DATAPDU
    build_share_control_header(0x17, data_header)
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/4f94e123-970b-4242-8cf6-39820d8e3d35
  # Control Request - TC_CONTROL_PDU 2.2.1.16
  def pdu_client_control_request
    pdu =
      "\x01\x00" +       # action: 1 - CTRLACTION_REQUEST_CONTROL
      "\x00\x00" +       # grantId: 0
      "\x00\x00\x00\x00" # controlId: 0

    # pduType2 = 0x14 = 20 - PDUTYPE2_CONTROL
    data_header = build_share_data_header(0x14, pdu)

    # type = 0x17 = TS_PROTOCOL_VERSION | PDUTYPE_DATAPDU
    build_share_control_header(0x17, data_header)
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/7067da0d-e318-4464-88e8-b11509cf0bd9
  # Client Font List - TS_FONT_LIST_PDU - 2.2.1.18
  def pdu_client_font_list
    pdu =
      "\x00\x00" + # numberFonts: 0
      "\x00\x00" + # totalNumberFonts: 0
      "\x03\x00" + # listFlags: 3 (FONTLIST_FIRST | FONTLIST_LAST)
      "\x32\x00"   # entrySize: 50

    # pduType2 = 0x27 = 29 -  PDUTYPE2_FONTLIST
    data_header = build_share_data_header(0x27, pdu)

    # type = 0x17 = TS_PROTOCOL_VERSION | PDUTYPE_DATAPDU
    build_share_control_header(0x17, data_header)
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/5186005a-36f5-4f5d-8c06-968f28e2d992
  # Client Synchronize - TS_SYNCHRONIZE_PDU - 2.2.1.19 /  2.2.14.1
  def pdu_client_synchronize(target_user = 0)
    pdu =
      "\x01\x00" +              # messageType: 1 SYNCMSGTYPE_SYNC
      [target_user].pack("S<")  # targetUser, 16 bit, unsigned.

    # pduType2 = 0x1f = 31 - PDUTYPE2_SCYNCHRONIZE
    data_header = build_share_data_header(0x1f, pdu)

    # type = 0x17 = TS_PROTOCOL_VERSION | PDUTYPE_DATAPDU
    build_share_control_header(0x17, data_header)
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/4e9722c3-ad83-43f5-af5a-529f73d88b48
  # Confirm Active PDU Data - TS_CONFIRM_ACTIVE_PDU - 2.2.1.13.2.1
  def pdu_client_confirm_active
    pdu =
      "\xea\x03\x01\x00" + # shareId: 66538
      "\xea\x03" + # originatorId
      "\x06\x00" + # lengthSourceDescriptor: 6
      "\x8e\x01" + # lengthCombinedCapabilities: 398
      "\x4d\x53\x54\x53\x43\x00" + # SourceDescriptor: 'MSTSC'
      "\x0e\x00" + # numberCapabilities: 14
      "\x00\x00" + # pad2Octets
      "\x01\x00" + # capabilitySetType: 1 - TS_GENERAL_CAPABILITYSET
      "\x18\x00" + # lengthCapability: 24
      "\x01\x00\x03\x00\x00\x02\x00\x00\x00\x00\x0d\x04\x00\x00\x00\x00" + #
      "\x00\x00\x00\x00" + #
      "\x02\x00" + # capabilitySetType: 2 - TS_BITMAP_CAPABILITYSET
      "\x1c\x00" + # lengthCapability: 28
      "\x10\x00\x01\x00\x01\x00\x01\x00\x20\x03\x58\x02\x00\x00\x01\x00" + #
      "\x01\x00\x00\x00\x01\x00\x00\x00" + #
      "\x03\x00" + # capabilitySetType: 3 - TS_ORDER_CAPABILITYSET
      "\x58\x00" + # lengthCapability: 88
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" + #
      "\x00\x00\x00\x00\x01\x00\x14\x00\x00\x00\x01\x00\x47\x01\x2a\x00" + #
      "\x01\x01\x01\x01\x00\x00\x00\x00\x01\x01\x01\x01\x00\x01\x01\x00" + #
      "\x00\x00\x00\x00\x01\x01\x01\x00\x00\x01\x01\x01\x00\x00\x00\x00" + #
      "\xa1\x06\x00\x00\x00\x00\x00\x00\x00\x84\x03\x00\x00\x00\x00\x00" + #
      "\xe4\x04\x00\x00\x13\x00\x28\x00\x00\x00\x00\x03\x78\x00\x00\x00" + #
      "\x78\x00\x00\x00\x50\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" + #
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" + #
      "\x08\x00" + # capabilitySetType: 8 - TS_POINTER_CAPABILITYSET
      "\x0a\x00" + # lengthCapability: 10
      "\x01\x00\x14\x00\x14\x00" + #
      "\x0a\x00" + # capabilitySetType: 10 - TS_COLORTABLE_CAPABILITYSET
      "\x08\x00" + # lengthCapability: 8
      "\x06\x00\x00\x00" + #
      "\x07\x00" + # capabilitySetType: 7 - TSWINDOWACTIVATION_CAPABILITYSET
      "\x0c\x00" + # lengthCapability: 12
      "\x00\x00\x00\x00\x00\x00\x00\x00" + #
      "\x05\x00" + # capabilitySetType: 5 - TS_CONTROL_CAPABILITYSET
      "\x0c\x00" + # lengthCapability: 12
      "\x00\x00\x00\x00\x02\x00\x02\x00" + #
      "\x09\x00" + # capabilitySetType: 9 - TS_SHARE_CAPABILITYSET
      "\x08\x00" + # lengthCapability: 8
      "\x00\x00\x00\x00" + #
      "\x0f\x00" + # capabilitySetType: 15 - TS_BRUSH_CAPABILITYSET
      "\x08\x00" + # lengthCapability: 8
      "\x01\x00\x00\x00" + #
      "\x0d\x00" + # capabilitySetType: 13 - TS_INPUT_CAPABILITYSET
      "\x58\x00" + # lengthCapability: 88
      "\x01\x00\x00\x00\x09\x04\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00" + #
      "\x0c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" + #
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" + #
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" + #
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" + #
      "\x00\x00\x00\x00" + #
      "\x0c\x00" + # capabilitySetType: 12 - TS_SOUND_CAPABILITYSET
      "\x08\x00" + # lengthCapability: 8
      "\x01\x00\x00\x00" + #
      "\x0e\x00" + # capabilitySetType: 14 - TS_FONT_CAPABILITYSET
      "\x08\x00" + # lengthCapability: 8
      "\x01\x00\x00\x00" + #
      "\x10\x00" + # capabilitySetType: 16 - TS_GLYPHCAChE_CAPABILITYSET
      "\x34\x00" + # lengthCapability: 52
      "\xfe\x00\x04\x00\xfe\x00\x04\x00\xfe\x00\x08\x00\xfe\x00\x08\x00" + #
      "\xfe\x00\x10\x00\xfe\x00\x20\x00\xfe\x00\x40\x00\xfe\x00\x80\x00" + #
      "\xfe\x00\x00\x01\x40\x00\x00\x08\x00\x01\x00\x01\x02\x00\x00\x00"

    # type = 0x13 = TS_PROTOCOL_VERSION | PDUTYPE_CONFIRMACTIVEPDU
    build_share_control_header(0x13, pdu)
  end

  # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/ff7f06f8-0dcf-4c8d-be1f-596ae60c4396
  # Client Input Event Data - TS_INPUT_PDU_DATA - 2.2.8.1.1.3.1
  def pdu_client_input_event_sychronize
    pdu =
      "\x01\x00" +         # numEvents: 1
      "\x00\x00" +         # pad2Octets
      "\x00\x00\x00\x00" + # eventTime
      "\x00\x00" +         # messageType: 0 - INPUT_EVENT_SYNC
      # TS_SYNC_EVENT 202.8.1.1.3.1.1.5
      "\x00\x00" +         # pad2Octets
      "\x00\x00\x00\x00"   # toggleFlags

    # pduType2 = 0x1c = 28 - PDUTYPE2_INPUT
    data_header = build_share_data_header(0x1c, pdu)

    # type = 0x17 = TS_PROTOCOL_VERSION | PDUTYPE_DATAPDU
    build_share_control_header(0x17, data_header)
  end

  #
  # Non-RDP protocol helper methods
  #

  # Create a new SSL session on the existing socket.
  # Stolen from exploit/smtp_deliver.rb
  def swap_sock_plain_to_ssl
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.min_version = OpenSSL::SSL::TLS1_VERSION
    ssl = OpenSSL::SSL::SSLSocket.new(self.rdp_sock, ctx)

    ssl.connect

    self.rdp_sock.extend(Rex::Socket::SslTcp)
    self.rdp_sock.sslsock = ssl
    self.rdp_sock.sslctx  = ctx
  end

protected

  def encode_domain_selector(
    max_chan_ids: 0,
    max_user_ids: 0,
    max_token_ids: 0,
    num_priorities: 1,
    min_throughput: 0,
    max_height: 1,
    max_mcspdu_size: 65535,
    protocol_ver: 2
  )

    body = [
      ber_int(max_chan_ids),
      ber_int(max_user_ids),
      ber_int(max_token_ids),
      ber_int(num_priorities),
      ber_int(min_throughput),
      ber_int(max_height),
      ber_int(max_mcspdu_size),
      ber_int(protocol_ver)
    ].join('')

    result = [
      "\x30",
      [body.length].pack('C'),
      body
    ].join('')

    result
  end

  def per_object(*ds)
    body = ds.join('')

    result = [
      "\x00",
      [body.length].pack('C'),
      body
    ].join('')

    result
  end

  def per_data(*ds)
    data = ds.join('')
    result = ''
    if data.length < 0x4000
      result = [data.length | 0x8000].pack('S>') + data
    else
      result = "\xA2" + [data.length].pack('S>') + data
    end

    result
  end

  def cs_cluster_data(
    flags: RDPConstants::REDIRECTION_SUPPORTED | RDPConstants::REDIRECTION_VERSION3,
    session_id: 0
  )
    body = [flags, session_id].pack('<L<L')

    result = [
      [0xc004, body.length + 4].pack('<S<S'),
      body
    ].join('')

    result
  end

  def cs_security_data(
    encryption_methods: RDPConstants::ENCRYPTION_40BIT | RDPConstants::ENCRYPTION_128BIT,
    ext_encryption_methods: 0
  )
    body = [encryption_methods, ext_encryption_methods].pack('<L<L')

    result = [
      [0xc002, body.length + 4].pack('<S<S'),
      body
    ].join('')

    result
  end

  def cs_network_data(channels)
    chan_data = channels.map{ |c|
      [c[0].encode('ASCII')].pack('a8*') + [c[1]].pack('L')
    }.join('')

    body = [
      [channels.length].pack('L'),
      chan_data
    ].join('')

    result = [
      [0xc003, body.length + 4].pack('<S<S'),
      body
    ].join('')

    result
  end


  def cs_core_data(
    version: 0x80004,
    width: 800,
    height: 600,
    keyboard: 1033, # English
    client_build: 2600,
    client_name: "rdesktop",
    keyboard_type: 4, # IBMEhanced 101/102
    keyboard_subtype: 0,
    keyboard_func_key: 12,
    serial_num: 0,
    client_product_id: 1,
    client_dig_product_id: "",
    selected_proto: 0
  )

    client_name = Rex::Text.to_unicode(client_name[0..16], 'utf-16le')
    client_dig_product_id = Rex::Text.to_unicode(client_dig_product_id[0..32], 'utf-16le')

    body = [
      [version, width, height].pack('<L<S<S'),
      "\x01\xca", # colour depth (8BPP)
      "\x03\xaa", # SASSequence
      [keyboard, client_build, client_name, keyboard_type].pack('<L<La32*'),
      [keyboard_type, keyboard_subtype, keyboard_func_key].pack('<L<L<L'),
      "\x00" * 64, # imeFileName
      "\x01\xca", # postBeta2ColorDepth (8BPP)
      [client_product_id, serial_num].pack('<S<L'),
      "\x18\x00", # highColorDepth: 24 bpp
      "\x07\x00", # supportedColorDepths: flag (24 bpp | 16 bpp | 15 bpp )
      "\x01\x00", # earlyCapabilityFlags: 1 (RNS_UD_CS_SUPPORT_ERRINFO_PDU)
      [client_dig_product_id].pack('a64*'),
      "\x00", # connectionType: 0
      "\x00", # pad1octet
      # serverSelectedProtocol - After negotiating TLS or CredSSP this value must
      # match the selectedProtocol value from the server's Negotiate Connection
      # confirm PDU that was sent before encryption was started.
      [selected_proto].pack('L<')
    ].join('')

    result = [
      [0xc001, body.length + 4].pack('<S<S'),
      body
    ].join('')

    result
  end

  def conf_create_req(user_data_sets: 1, h221_key: "Duca")
    b2 = 0
    b2 |= 0x08 if user_data_sets > 0

    b5 = 0x40
    b5 |= 0x80 if user_data_sets > 0

    # TODO: add more flags here
    [
      "\x00",
      [b2].pack('C'),
      "\x00\x10\x00",
      [user_data_sets].pack('C'),
      [b5].pack('C'),
      "\x00",
      [h221_key.encode('ASCII')].pack('a*')
    ].join('')
  end

  def oid(itut, rec, t, t124, ver, desc)
    [(itut << 8) | rec, t, t124, ver, desc].pack('C*')
  end

  def ber_octet_string(*ds)
    result = [
      "\x04",
      ber_data(ds)
    ].join('')

    result
  end

  def ber_data(*ds)
    data = ds.join('')

    result = [
      "\x82",
      [data.length].pack('S>'),
      data
    ].join('')

    result
  end

  def ber_int(i)
    d = ''
    if i < (2 ** 8)
      d = [i].pack('C')
    elsif i < (2 ** 16)
      d = [i].pack('S>')
    else
      d = [i].pack('L>')
    end

    "\x02" + [d.length].pack('C') + d
  end

  def rdp_handle_packet(pkt)
    if pkt && pkt[0] == "\x03"
      if pkt[4..6] == "\x02\xf0\x80"
        if pkt[7] == "\x68"
          chan_user_id = pkt[8..9].unpack('S>')[0]
          chan_id = pkt[10..11].unpack('S>')[0]
          flags = pkt[18..21].unpack('<L')[0]
          data = pkt[22..pkt.length]
          rdp_on_channel_receive(pkt, chan_user_id, chan_id, flags, data)
        end
      end
    end
  end

  def rdp_on_channel_receive(pkt, chan_user_id, chan_id, flags, data)
    ctype = data[0..1].unpack('S')[0]

    if ctype == RDPConstants::RDPDR_CTYP_CORE
      opcode = data[2..3].unpack('S')[0]
      if opcode == RDPConstants::PAKID_CORE_SERVER_ANNOUNCE
        rdp_on_core_server_announce(pkt, chan_user_id, chan_id, flags, data)
      elsif opcode == RDPConstants::PAKID_CORE_SERVER_CAPABILITY
        rdp_on_core_server_capability(pkt, chan_user_id, chan_id, flags, data)
      elsif opcode == RDPConstants::PAKID_CORE_CLIENTID_CONFIRM
        rdp_on_core_client_id_confirm(pkt, chan_user_id, chan_id, flags, data)
      end
    end
  end

  def rdp_on_core_server_announce(pkt, chan_user_id, chan_id, flags, data)
    vprint_status("Handling SERVER ANNOUNCE ...")
    rdpdr_client_announce_reply(pkt, chan_user_id, chan_id, flags, data)
    rdpdr_client_name_request(pkt, chan_user_id, chan_id, flags, data)
  end

  def rdp_on_core_server_capability(pkt, chan_user_id, chan_id, flags, data)
    vprint_status("Handling SERVER CAPABILITY ...")
    # change opcode 1 byte to match server capabilities
    reply = [data[0..2], "\x43", data[4..data.length]].join('')

    rdp_send_channel(chan_user_id, chan_id, reply)
  end

  def rdp_on_core_client_id_confirm(pkt, chan_user_id, chan_id, flags, data)
    vprint_status("Handling CLIENT ID CONFIRM ...")
    rdpdr_client_device_list_announce_request(pkt, chan_user_id, chan_id, flags, data)
  end

  def rdpdr_client_device_list_announce_request(pkt, chan_user_id, chan_id, flags, data)
    reply = [
      RDPConstants::RDPDR_CTYP_CORE,
      RDPConstants::PAKID_CORE_DEVICELIST_ANNOUNCE,
      0x0, # Device count
    ].pack('SSL')

    rdp_send_channel(chan_user_id, chan_id, reply)
  end

  def rdpdr_client_announce_reply(pkt, chan_user_id, chan_id, flags, data)
    reply = [
      RDPConstants::RDPDR_CTYP_CORE,
      RDPConstants::PAKID_CORE_CLIENTID_CONFIRM,
      0x1, # Version Major
      0xc, # Version Minor
      0x2, # client ID (TODO: configure this? read it from the packet?
    ].pack('SSSSL')

    rdp_send_channel(chan_user_id, chan_id, reply)
  end

  def rdpdr_client_name_request(pkt, chan_user_id, chan_id, flags, data)
    computer_name = Rex::Text.to_unicode("ethdev\x00", 'utf-16le')
    reply = [
      RDPConstants::RDPDR_CTYP_CORE,
      RDPConstants::PAKID_CORE_CLIENT_NAME,
      0x1, # Unicode flag
      0x0, # Code Page
      computer_name.length,
      computer_name,
    ].pack('SSLLLa*')

    rdp_send_channel(chan_user_id, chan_id, reply)
  end

  attr_accessor :rdp_sock

  attr_accessor :rdp_user_id

=begin
  # debug stuff
  def rdp_to_file(b, del = false)
    p = "/tmp/ruby-full.bin"
    ::File.delete(p) if del && ::File.exist?(p)
    f = ::File.new(p, "ab")
    f.write(b)
    f.close
  end
=end

end
end