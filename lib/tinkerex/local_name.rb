# frozen_string_literal: true

require "socket"
require "ipaddr"
require "resolv"
require "io/wait"

module Tinkerex
  # ANNOUNCES THE SERVER AS <name>.local ON THE NETWORK IT IS ON (multicast DNS, RFC 6762), so a
  # computer or phone in the same house opens http://tinkerex.local with nobody typing an address.
  # docker-compose.yml's `local-name` service runs it through bin/local-name, on the HOST'S network
  # (`network_mode: host`): a question for a .local name is multicast on the local link, and a
  # container behind Docker's bridge never hears it.
  #
  # THE STANDARD LIBRARY ONLY, NEVER RAILS: it starts in a moment and loads nothing the app does.
  # Avahi does this job and is LGPL, which CLAUDE.md section 9 keeps out of what we ship.
  #
  # WHAT IT ANSWERS. One A record, <name>.local -> this machine's IPv4 address ON THE NETWORK THE
  # QUESTION CAME FROM (the interface whose subnet holds the asker), so a machine on two networks
  # gives each the address it can reach. A question for any other type of the name -- AAAA above all
  # -- gets an NSEC saying A is all there is, which RFC 6762 section 6.1 requires and which spares a
  # resolver that asks for both from waiting out the AAAA. No service records: the name is the point.
  #
  # IT CHECKS BEFORE IT CLAIMS. Three probes (section 8.1) ask whether anyone already answers to the
  # name; one that does with an address that is not ours is another device, and this one then says so
  # in its log and stays quiet rather than fight it for the name. The machine's own mDNS answering
  # for the name with OUR address (Linux named `tinkerex`, running Avahi) is not a conflict.
  #
  # DOCKER DESKTOP CANNOT DO THIS, AND IT WAITS RATHER THAN EXITS. Its containers run in a VM whose
  # network is not the house's, so a multicast question never reaches them, host networking or not.
  # There it logs why once and sleeps: `restart: unless-stopped` restarts an exit forever, and a
  # container restarting in a loop reads as broken in Docker Desktop's window. The computer's own
  # name is the .local address there (docs/INSTALL.md section 2). The same holds for a bad name and
  # a conflict: say so, then wait.
  class LocalName
    GROUP = "224.0.0.251"
    PORT = 5353
    TTL = 120
    LEGACY_TTL = 10 # section 6.7: a reply to a one-shot (non-5353) asker carries at most ten seconds
    RESCAN = 30     # seconds between looks at the interfaces, for a cable plugged in or a new address

    A = 1
    NSEC = 47
    ANY = 255
    IN = 1
    CACHE_FLUSH = 0x8000 # top bit of a record's class: "this is the whole set, drop older ones"
    QUERY = 0x0000
    AUTHORITATIVE_RESPONSE = 0x8400

    LABEL = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
    # Docker's own links and other container or VM bridges: nobody on the house's network asks there.
    CONTAINER_LINK = /\A(?:docker|br-|veth|cni|flannel|virbr|lxcbr|podman)/
    # The kernels of the VMs Docker Desktop (Mac: linuxkit; Windows: WSL2) and OrbStack run in.
    DESKTOP_VM_KERNEL = /linuxkit|microsoft|wsl|orbstack/i

    Interface = Struct.new(:name, :ip, :network) do
      def include?(ip) = network.include?(ip)
    end

    # "Tinkerex", "tinkerex.local" and "tinkerex.local." all mean tinkerex.local; anything that is
    # not one DNS label (letters, digits, inner dashes) is refused, never repaired.
    def self.normalize(raw)
      label = raw.to_s.strip.downcase.delete_suffix(".").delete_suffix(".local")
      raise ArgumentError, "#{raw.inspect} is not one word of letters, digits and dashes" unless LABEL.match?(label)

      "#{label}.local"
    end

    def self.desktop_vm?(osrelease = read_osrelease) = DESKTOP_VM_KERNEL.match?(osrelease.to_s)

    def self.read_osrelease
      File.read("/proc/sys/kernel/osrelease")
    rescue SystemCallError
      nil
    end

    # The house's networks: up, multicast, not loopback, not a point-to-point tunnel (a VPN has no
    # neighbours to ask), not a container bridge.
    def self.interfaces
      Socket.getifaddrs.filter_map do |i|
        next unless i.addr&.ipv4? && i.netmask && !i.addr.ipv4_loopback?
        next unless i.flags.anybits?(Socket::IFF_UP) && i.flags.anybits?(Socket::IFF_MULTICAST)
        next if i.flags.anybits?(Socket::IFF_POINTOPOINT) || CONTAINER_LINK.match?(i.name)

        ip = i.addr.ip_address
        Interface.new(i.name, ip, IPAddr.new(ip).mask(netmask(i.netmask.to_sockaddr).to_s))
      end
    end

    # The mask's four bytes, read from the raw sockaddr rather than through Addrinfo#ip_address: BSD
    # (macOS) TRUNCATES a netmask's sockaddr after its last non-zero byte (`255.255.255.0` arrives as
    # seven bytes), and Addrinfo then reads past the end and answers a mask IPAddr refuses. The
    # address sits at offset 4 in both layouts (BSD: length, family, port; Linux: family, port).
    def self.netmask(sockaddr) = IPAddr.new_ntoh(sockaddr.b.byteslice(4, 4).to_s.ljust(4, "\x00"))

    # ---- the wire, by hand: Resolv can read mDNS but cannot write a cache-flush class ----

    def self.encode_name(name)
      name.split(".").map { |label| [ label.bytesize ].pack("C") + label.b }.join.b + "\x00".b
    end

    def self.record(name, type, ttl:, flush:, rdata:)
      encode_name(name) + [ type, IN | (flush ? CACHE_FLUSH : 0), ttl, rdata.bytesize ].pack("nnNn") + rdata
    end

    def self.a_record(name, ip, ttl:, flush: true) = record(name, A, ttl:, flush:, rdata: IPAddr.new(ip).hton)

    # The restricted NSEC of section 6.1: the next name is the name itself, then window 0 with one
    # bitmap byte whose bit 1 (0x40) is type A -- "A, and nothing else, exists for this name".
    def self.nsec_record(name, ttl:, flush: true)
      record(name, NSEC, ttl:, flush:, rdata: encode_name(name) + [ 0, 1, 0x40 ].pack("C3"))
    end

    def self.message(flags: AUTHORITATIVE_RESPONSE, id: 0, question: nil, answers: [], authority: [], additional: [])
      header = [ id, flags, question ? 1 : 0, answers.size, authority.size, additional.size ].pack("n6")
      asked = question ? encode_name(question.fetch(0)) + [ question.fetch(1), IN ].pack("nn") : "".b
      header + asked + answers.join + authority.join + additional.join
    end

    def self.decode(bytes)
      Resolv::DNS::Message.decode(bytes)
    rescue StandardError
      nil # anything on 5353 that does not parse is someone else's business
    end

    # The address another responder gives for `name` in a response, when it is not one of `ours`.
    def self.foreign_answer(bytes, name, ours)
      msg = decode(bytes)
      return unless msg && msg.qr == 1

      (msg.answer + msg.additional).each do |owner, _ttl, data|
        next unless owner.to_s.downcase == name && data.class::TypeValue == A

        ip = data.respond_to?(:address) ? data.address.to_s : IPAddr.new_ntoh(data.data).to_s
        return ip unless ours.include?(ip)
      end
      nil
    rescue StandardError
      nil
    end

    attr_reader :name

    def initialize(name, interfaces: nil, port: PORT, out: $stdout, osrelease: nil)
      begin
        @name = self.class.normalize(name)
      rescue ArgumentError => e
        @refused = e.message
      end
      @fixed_interfaces = interfaces
      @port = port
      @out = out
      @osrelease = osrelease
      @wake, @waker = IO.pipe
    end

    # What one received packet earns: a list of [bytes, ip, port, via] to send, where `via` is the
    # interface a multicast reply leaves by (nil for a unicast reply). Pure, which is what the tests
    # drive; #run does the sending.
    def replies(bytes, from_ip, from_port)
      msg = self.class.decode(bytes)
      return [] unless msg && msg.qr.zero? && msg.opcode.zero?

      via = interfaces.find { |i| i.include?(from_ip) }
      return [] unless via

      asked = msg.question.select { |owner, _| owner.to_s.downcase == name }
      return [] if asked.empty?

      types = asked.map { |_, typeclass| typeclass::TypeValue }
      legacy = from_port != PORT
      ttl = legacy ? LEGACY_TTL : TTL
      a = [ A, ANY ].intersect?(types)
      answers = a ? [ self.class.a_record(name, via.ip, ttl:, flush: !legacy) ] : [ self.class.nsec_record(name, ttl:, flush: !legacy) ]
      additional = a ? [ self.class.nsec_record(name, ttl:, flush: !legacy) ] : []

      if legacy
        # A one-shot asker (dig, a plain resolver) sent from its own port and reads only a reply to
        # it there, echoing its id and its question (section 6.7).
        question = [ name, types.first ]
        [ [ self.class.message(id: msg.id, question:, answers:, additional:), from_ip, from_port, nil ] ]
      else
        [ [ self.class.message(answers:, additional:), GROUP, PORT, via ] ]
      end
    end

    def interfaces = @interfaces ||= (@fixed_interfaces || self.class.interfaces)

    # `signals: false` leaves TERM and INT alone, for a caller (a test) whose process owns them; #stop
    # ends the run either way.
    def run(check: true, signals: true)
      @signals = signals
      return idle("TINKEREX_LOCAL_NAME #{@refused}, so no .local name is announced.") if @refused
      return idle("This computer runs Docker Desktop, whose containers sit apart from your network, so " \
                  "#{name} cannot be announced from here. Use the computer's own .local name instead " \
                  "(docs/INSTALL.md section 2, \"Open it from your other computers\"). Nothing is wrong; this waits.") if desktop?

      trap_signals
      open_socket
      if check && (taken = probe_for_conflict)
        return idle("Another device on this network already answers to #{name} (#{taken}), so this one " \
                    "does not. Pick another name with TINKEREX_LOCAL_NAME (docs/INSTALL.md section 3).")
      end

      say(interfaces.empty? ? "No network to announce #{name} on yet; looking again every #{RESCAN} seconds." : announcing)
      announce
      serve
      announce(ttl: 0) # goodbye (section 10.1): caches drop the name now rather than in two minutes
    end

    def stop = @waker.write_nonblock(".", exception: false)

    private

    def desktop? = self.class.desktop_vm?(@osrelease || self.class.read_osrelease)

    def announcing = "Announcing #{name} at #{interfaces.map { |i| "#{i.ip} (#{i.name})" }.join(', ')}."

    def say(text) = @out.puts(text)

    def idle(text)
      say(text)
      trap_signals
      @wake.wait_readable
      nil
    end

    # PID 1 in a container ignores a signal it has no handler for, so without this `docker stop`
    # waits its ten seconds and kills.
    def trap_signals
      return if @trapped || !@signals

      %w[TERM INT].each { |sig| Signal.trap(sig) { stop } }
      @trapped = true
    end

    def open_socket
      @socket = Socket.new(:INET, :DGRAM)
      # Avahi, or the host's own responder, holds 5353 too; sharing the port is how mDNS stacks coexist.
      @socket.setsockopt(:SOCKET, :REUSEADDR, true)
      @socket.setsockopt(:SOCKET, :REUSEPORT, true) if defined?(Socket::SO_REUSEPORT)
      @socket.bind(Addrinfo.udp("0.0.0.0", @port))
      @socket.setsockopt(:IP, :MULTICAST_TTL, 255) # section 11: 255 on every mDNS packet
      @socket.setsockopt(:IP, :TTL, 255)
      join(interfaces)
    end

    def join(list)
      list.each do |i|
        @socket.setsockopt(:IP, :ADD_MEMBERSHIP, IPAddr.new(GROUP).hton + IPAddr.new(i.ip).hton)
      rescue Errno::EADDRINUSE
        nil # already a member on that interface (its address changed under us)
      rescue SystemCallError => e
        say("Cannot listen on #{i.name} (#{e.message}); #{name} is not announced there.")
      end
    end

    def send_packet(bytes, ip, port, via)
      @socket.setsockopt(:IP, :MULTICAST_IF, IPAddr.new(via.ip).hton) if via
      @socket.send(bytes, 0, Addrinfo.udp(ip, port))
    rescue SystemCallError => e
      say("Could not send on #{via&.name || ip} (#{e.message}).")
    end

    def announce(ttl: TTL, list: interfaces)
      list.each do |i|
        bytes = self.class.message(answers: [ self.class.a_record(name, i.ip, ttl:) ], additional: [ self.class.nsec_record(name, ttl:) ])
        2.times do |n|
          sleep 1 if n.positive? && ttl.positive? # section 8.3: twice, a second apart
          send_packet(bytes, GROUP, PORT, i)
        end
      end
    end

    # Probes 250 ms apart (section 8.1), each asking for the name with our own claim in the authority
    # section; an answer from anyone else with an address that is not ours is the conflict.
    #
    # THE FOURTH PROBE, A SECOND LATER, IS THE ONE THAT USUALLY CATCHES IT. A responder will not
    # multicast a record again within a second of last doing so (section 6), so an owner that
    # announced or answered just before our three probes lets all three pass unanswered: measured
    # against macOS's mDNSResponder holding the name, three probes in 750 ms saw nothing and the name
    # was claimed twice; a probe after the second is up was answered every time.
    PROBE_AT = [ 0, 0.25, 0.5, 1.25 ].freeze
    PROBE_FOR = 2.0

    def probe_for_conflict
      ours = interfaces.map(&:ip)
      start = monotonic
      due = PROBE_AT.dup
      while (left = start + PROBE_FOR - monotonic).positive?
        if due.any? && monotonic - start >= due.first
          due.shift
          interfaces.each { |i| send_packet(probe(i), GROUP, PORT, i) }
          next
        end
        wait = due.any? ? [ start + due.first - monotonic, left ].min : left
        next unless @socket.wait_readable([ wait, 0 ].max)

        bytes, = @socket.recvfrom(9000)
        taken = self.class.foreign_answer(bytes, name, ours)
        return taken if taken
      end
      nil
    end

    def probe(interface)
      self.class.message(flags: QUERY, question: [ name, ANY ],
                         authority: [ self.class.a_record(name, interface.ip, ttl: TTL, flush: false) ])
    end

    def serve
      next_scan = monotonic + RESCAN
      loop do
        ready, = IO.select([ @socket, @wake ], nil, nil, [ next_scan - monotonic, 0 ].max)
        break if ready&.include?(@wake)

        if ready
          bytes, from = @socket.recvfrom(9000)
          replies(bytes, from.ip_address, from.ip_port).each { |packet| send_packet(*packet) }
        end
        if monotonic >= next_scan
          rescan
          next_scan = monotonic + RESCAN
        end
      end
    end

    def rescan
      return if @fixed_interfaces

      before = interfaces.map(&:ip)
      @interfaces = self.class.interfaces
      fresh = interfaces.reject { |i| before.include?(i.ip) }
      return if fresh.empty?

      join(fresh)
      say(announcing)
      announce(list: fresh)
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
