require "test_helper"
require "stringio"

# THE .local ANNOUNCER (lib/tinkerex/local_name.rb), which docker-compose.yml's `local-name` service
# runs on a Linux host. What these pin is the protocol a phone or laptop's resolver holds it to:
# which address answers (the asker's own network's), the cache-flush bit on a multicast answer and
# not on a one-shot one, the one-shot reply echoing id and question, the NSEC that ends a resolver's
# wait for an AAAA, and the refusals (a bad name, Docker Desktop) that wait instead of exiting.
#
# The real-network half was measured, not asserted here (CI has no multicast to a second machine):
# macOS's `dns-sd -G v4v6` against it resolved the name with TTL 120 and read the AAAA as "No Such
# Record" in the same millisecond; curl opened the app at the name; a stop's goodbye dropped the name
# at once; and inside Docker Desktop's Linux VM a second host-network container got both answers.
#
# MUTATION-CHECKED (section 15), each red and restored: answering with the FIRST interface's address
# instead of the asker's subnet's; the cache-flush bit set on a one-shot answer; the legacy reply
# sent to the group instead of the asker; and the NSEC dropped from an AAAA answer.
class LocalNameTest < ActiveSupport::TestCase
  L = Tinkerex::LocalName

  HOME = L::Interface.new("eth0", "192.168.1.20", IPAddr.new("192.168.1.0/24"))
  WORKSHOP = L::Interface.new("eth1", "10.0.5.7", IPAddr.new("10.0.0.0/16"))

  def responder(name = "tinkerex", interfaces: [ HOME, WORKSHOP ]) = L.new(name, interfaces:, out: StringIO.new)

  def query(name, type, id: 0) = L.message(flags: L::QUERY, id:, question: [ name, type ])

  def decode(bytes) = Resolv::DNS::Message.decode(bytes)

  # [owner, ttl, type, class, rdata] for every record in a section, read without Resolv's class
  # lookup, which turns any class with the cache-flush bit into an anonymous Generic.
  def records(section)
    section.map { |owner, ttl, data| [ owner.to_s, ttl, data.class::TypeValue, data.class::ClassValue, raw(data) ] }
  end

  def raw(data) = data.respond_to?(:address) ? IPAddr.new(data.address.to_s).hton : data.data

  test "a name is one DNS label, with or without .local, and anything else is refused" do
    assert_equal "tinkerex.local", L.normalize("Tinkerex")
    assert_equal "workshop.local", L.normalize("workshop.local")
    assert_equal "shop-2.local", L.normalize(" shop-2.local. ")
    [ "", "two words", "-x", "x-", "a.b", "under_score", "x" * 64, "café" ].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { L.normalize(bad) }
    end
  end

  test "the kernels of Docker Desktop and OrbStack VMs are recognised, a real Linux one is not" do
    assert L.desktop_vm?("7.0.12-linuxkit")
    assert L.desktop_vm?("5.15.167.4-microsoft-standard-WSL2")
    assert L.desktop_vm?("6.11.0-orbstack-00280-g8a5e7c4")
    assert_not L.desktop_vm?("6.1.0-28-amd64")
    assert_not L.desktop_vm?("6.8.0-49-generic")
    assert_not L.desktop_vm?(nil)
  end

  # macOS hands getifaddrs netmasks back truncated after their last non-zero byte (measured: seven
  # bytes for a /24), and Addrinfo#ip_address then answers a mask IPAddr refuses.
  test "a netmask reads from a BSD-truncated sockaddr as well as a full one" do
    assert_equal "255.255.255.0", L.netmask("\x07\x02\x00\x00\xFF\xFF\xFF".b).to_s
    assert_equal "255.255.0.0", L.netmask("\x06\x02\x00\x00\xFF\xFF".b).to_s
    linux = Socket.sockaddr_in(0, "255.255.255.0")
    assert_equal "255.255.255.0", L.netmask(linux).to_s
  end

  test "a multicast question is answered on the group, with the address on the asker's own network" do
    packets = responder.replies(query("tinkerex.local", L::A), "192.168.1.33", L::PORT)
    assert_equal 1, packets.size
    bytes, ip, port, via = packets.first
    assert_equal [ L::GROUP, L::PORT, HOME ], [ ip, port, via ]

    msg = decode(bytes)
    assert_equal [ 1, 1, 0 ], [ msg.qr, msg.aa, msg.id ]
    assert_empty msg.question, "a multicast answer carries no question (section 6)"
    assert_equal [ [ "tinkerex.local", 120, L::A, 0x8001, IPAddr.new("192.168.1.20").hton ] ], records(msg.answer)
    assert_equal [ [ "tinkerex.local", 120, L::NSEC, 0x8001 ] ], records(msg.additional).map { |r| r.first(4) }

    other = responder.replies(query("tinkerex.local", L::A), "10.0.9.9", L::PORT).first
    assert_equal WORKSHOP, other[3]
    assert_equal IPAddr.new("10.0.5.7").hton, records(decode(other[0]).answer).first.last,
                 "a machine on two networks gives each the address it can reach"
  end

  test "an ANY question is answered too, and the name matches whatever its case" do
    assert_equal 1, responder.replies(query("TinkerEx.LOCAL", L::ANY), "192.168.1.33", L::PORT).size
  end

  test "an AAAA question gets the NSEC that says A is all there is, and no address" do
    bytes, = responder.replies(query("tinkerex.local", 28), "192.168.1.33", L::PORT).first
    msg = decode(bytes)
    assert_equal [ [ "tinkerex.local", 120, L::NSEC, 0x8001 ] ], records(msg.answer).map { |r| r.first(4) }
    assert_equal L.encode_name("tinkerex.local") + "\x00\x01\x40".b, records(msg.answer).first.last,
                 "next name is the name itself; window 0, one byte, bit 1 = type A"
    assert_empty msg.additional
  end

  test "a one-shot asker is answered at its own port, with its id and question, a short TTL and no cache flush" do
    packets = responder.replies(query("tinkerex.local", L::A, id: 4242), "192.168.1.33", 51_000)
    assert_equal 1, packets.size
    bytes, ip, port, via = packets.first
    assert_equal [ "192.168.1.33", 51_000, nil ], [ ip, port, via ]
    msg = decode(bytes)
    assert_equal 4242, msg.id
    assert_equal [ "tinkerex.local" ], msg.question.map { |name, _| name.to_s }
    assert_equal [ [ "tinkerex.local", 10, L::A, 1, IPAddr.new("192.168.1.20").hton ] ], records(msg.answer)
  end

  test "nothing answers another name, a response, garbage, or an asker on no network of ours" do
    r = responder
    assert_empty r.replies(query("printer.local", L::A), "192.168.1.33", L::PORT)
    assert_empty r.replies(L.message(answers: [ L.a_record("tinkerex.local", "192.168.1.99", ttl: 120) ]), "192.168.1.33", L::PORT)
    assert_empty r.replies("\x00\x01garbage".b, "192.168.1.33", L::PORT)
    assert_empty r.replies(query("tinkerex.local", L::A), "172.16.0.4", L::PORT)
  end

  test "another device's answer for the name is a conflict, unless the address is ours" do
    theirs = L.message(answers: [ L.a_record("tinkerex.local", "192.168.1.99", ttl: 120) ])
    assert_equal "192.168.1.99", L.foreign_answer(theirs, "tinkerex.local", [ "192.168.1.20" ])
    assert_nil L.foreign_answer(theirs, "tinkerex.local", [ "192.168.1.99" ]),
               "the host's own Avahi answering with our address (Linux named tinkerex) is not a rival"
    assert_nil L.foreign_answer(theirs, "printer.local", [ "192.168.1.20" ])
    assert_nil L.foreign_answer(query("tinkerex.local", L::A), "tinkerex.local", [ "192.168.1.20" ]), "a question claims nothing"
    assert_nil L.foreign_answer("junk".b, "tinkerex.local", [])
    unflushed = L.message(answers: [ L.a_record("tinkerex.local", "192.168.1.99", ttl: 120, flush: false) ])
    assert_equal "192.168.1.99", L.foreign_answer(unflushed, "tinkerex.local", [ "192.168.1.20" ])
  end

  # A refusal must WAIT, not exit: `restart: unless-stopped` restarts an exit forever.
  test "a bad name and Docker Desktop each say why once and wait until stopped" do
    { [ "two words", "6.1.0-28-amd64" ] => /TINKEREX_LOCAL_NAME .*not one word/,
      [ "tinkerex", "7.0.12-linuxkit" ] => /Docker Desktop.*tinkerex\.local cannot be announced/ }.each do |(name, kernel), said|
      out = StringIO.new
      r = L.new(name, interfaces: [ HOME ], out:, osrelease: kernel)
      thread = Thread.new { r.run(signals: false) }
      sleep 0.2
      assert thread.alive?, "#{name} on #{kernel} exited instead of waiting"
      r.stop
      assert thread.join(2), "stop did not end the wait"
      assert_match said, out.string
      assert_equal 1, out.string.lines.size
    end
  end

  # THE SOCKET LOOP, over loopback: a one-shot question sent to the responder's port comes back as a
  # unicast answer, and #stop ends the loop. Multicast itself needs a network; this needs only lo.
  test "the running loop answers a question on its socket and stops when told" do
    port = Addrinfo.udp("127.0.0.1", 0).bind { |s| s.local_address.ip_port }
    lo = L::Interface.new("lo", "127.0.0.1", IPAddr.new("127.0.0.0/8"))
    r = L.new("tinkerex", interfaces: [ lo ], port:, out: StringIO.new, osrelease: "6.1.0-28-amd64")
    thread = Thread.new { r.run(check: false, signals: false) }

    client = Socket.new(:INET, :DGRAM)
    client.bind(Addrinfo.udp("127.0.0.1", 0))
    answer = nil
    10.times do
      client.send(query("tinkerex.local", L::A, id: 7), 0, Addrinfo.udp("127.0.0.1", port))
      break if client.wait_readable(0.5) && (answer = decode(client.recvfrom(9000).first))
    end
    assert answer, "no answer on the responder's port"
    assert_equal 7, answer.id
    assert_equal IPAddr.new("127.0.0.1").hton, records(answer.answer).first.last

    r.stop
    assert thread.join(3), "stop did not end the loop"
  ensure
    client&.close
    r&.stop
  end
end
