namespace :trusted_proxies do
  desc "Refresh config/cloudflare_ips.yml from Cloudflare's published lists (and stamp today's date)"
  task refresh: :environment do
    require "net/http"
    lists = { "ipv4" => "https://www.cloudflare.com/ips-v4", "ipv6" => "https://www.cloudflare.com/ips-v6" }
    ranges = lists.transform_values do |url|
      body = Net::HTTP.get_response(URI(url)).tap { |r| abort("#{url}: HTTP #{r.code}") unless r.is_a?(Net::HTTPSuccess) }.body
      body.lines.map(&:strip).reject(&:empty?).each { |r| IPAddr.new(r) } # raises on junk
    end
    # A short list is a truncated download, not a smaller Cloudflare.
    abort("ipv4 list too short (#{ranges['ipv4'].size})") if ranges["ipv4"].size < 10
    abort("ipv6 list too short (#{ranges['ipv6'].size})") if ranges["ipv6"].size < 4
    path = Rails.root.join("config/cloudflare_ips.yml")
    header = File.read(path).lines.take_while { |l| l.start_with?("#") }.join
    File.write(path, header + { "fetched_on" => Date.today.iso8601, "source" => lists.values,
                                 "ipv4" => ranges["ipv4"], "ipv6" => ranges["ipv6"] }.to_yaml.sub(/\A---\n/, ""))
    puts "pinned #{ranges['ipv4'].size} IPv4 + #{ranges['ipv6'].size} IPv6 ranges, fetched #{Date.today}"
  end
end
