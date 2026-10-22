require "yaml"
require "uri"

module Tinkerex
  # THE COMPOSE GENERATOR'S TEMPLATE IS docker-compose.yml ITSELF, READ AT RENDER TIME (2026-10-21;
  # docs/superpowers/plans/2026-10-21-compose-generator.md). The page at /install/compose builds a
  # visitor's compose file in the browser from what this hands it, so there is NO SECOND COPY of the
  # file to drift: a new environment line, setting or comment reaches the generated file on the next
  # render with no edit anywhere else. `.dockerignore` re-includes the file for this reason
  # (deploy_hygiene_test.rb); the image excluded every compose file until this page existed.
  #
  # WHAT IT HANDS THE BROWSER (`to_h`):
  #   tree      the parsed YAML, `${VAR:-default}` left in for the browser to resolve
  #   leading   comment lines that precede a key or sequence item, by "/"-joined path
  #   trailing  comment lines that close a block: indented past the key after them, or at the end
  #   flow      the paths the file writes as `[a, b]`
  #   tools     the services the app's environment names by URL, those env keys, the volumes only
  #             they mount: what the Tools switch removes
  #   share     the network-share switch: which web volume is the library bind, the volume's name,
  #             the prose that explains it and the commented example parsed back into YAML
  #
  # WHAT THE GENERATOR KNOWS BY HAND is only this: the app service is `web`, the library is the bind
  # whose target is `/library`, and the commented block that closes `volumes:` is the share example.
  # A file whose shape stops matching any of it RAISES, naming the line, rather than guessing -- and
  # test/lib/compose_template_test.rb reads the real file, so that raise is a red build, never a
  # visitor's wrong file.
  #
  # THE TOOLS ARE READ OFF THE FILE, NEVER Tinkerex::Sidecars: /sidecar/ is dockerignored, so
  # `Sidecars#names` is [] in the image. The test cross-checks the two in a checkout.
  class ComposeTemplate
    Error = Class.new(StandardError)

    SOURCE = Rails.root.join("docker-compose.yml")
    APP = "web".freeze
    LIBRARY_TARGET = "/library".freeze
    # `bin/rails generate sidecar` inserts at these; they instruct a repo tool, not an installer.
    MARKERS = Tinkerex::Sidecars::MARKERS.values.filter_map { |file, text| text if file == :compose }.freeze

    KEY = /\A(?<indent> *)(?<key>[A-Za-z0-9_.-]+):(?=\s|\z)/
    ITEM = /\A(?<indent> *)- (?<rest>.*)\z/
    COMMENT = /\A(?<indent> *)#/

    attr_reader :tree, :header, :leading, :trailing, :flow, :markers, :tools, :share

    # True when `path` names a node of `tree` (a nil VALUE still counts, which `dig` cannot tell apart).
    def self.dig?(tree, path)
      path.reduce(tree) do |node, seg|
        case node
        when Hash then node.key?(seg) ? node[seg] : (return false)
        when Array then seg.is_a?(Integer) && seg < node.size ? node[seg] : (return false)
        else return false
        end
      end
      true
    end

    def initialize(text = SOURCE.read)
      @tree = YAML.safe_load(text)
      raise Error, "docker-compose.yml has no services: mapping" unless tree.is_a?(Hash) && tree["services"].is_a?(Hash)

      @header = []
      @leading = {}
      @trailing = {}
      @flow = []
      @markers = []
      walk(text.lines(chomp: true))
      (leading.keys + trailing.keys + flow).each do |key|
        raise Error, "the comment walk placed #{key}, which names no node of the parsed file" unless self.class.dig?(tree, path_of(key))
      end
      @tools = derive_tools
      @share = derive_share
    end

    def to_h = { tree:, leading:, trailing:, flow:, tools:, share: }

    private

    def key_for(path)
      raise Error, "#{path.inspect}: a key holding a slash cannot be addressed" if path.any? { |seg| seg.to_s.include?("/") }

      path.join("/")
    end

    def path_of(key) = key.split("/").map { |seg| seg.match?(/\A\d+\z/) ? seg.to_i : seg }

    # ONE PASS OVER THE LINES, keeping a stack of [indent, path] for every open key and sequence item.
    # A comment block is held until the next key, item or the end decides whose it is: the next key's
    # when it sits at that key's indent, the deepest open block's when it is indented past it.
    def walk(lines)
      stack = []
      items = Hash.new(0)
      pending = []
      lines.each_with_index do |line, i|
        if line.strip.empty?
          next if pending.empty?
          unless stack.empty? && header.empty?
            raise Error, "docker-compose.yml line #{pending.first[0] + 1}: a comment block followed by a blank line belongs to no key"
          end

          @header = pending.map(&:last)
          pending = []
        elsif (m = COMMENT.match(line))
          pending << [ i, m[:indent].size, line.strip ]
        elsif (m = ITEM.match(line))
          indent = m[:indent].size
          comments = settle(pending, indent, stack)
          pending = []
          stack.pop while stack.any? && stack.last[0] >= indent
          raise Error, "docker-compose.yml line #{i + 1}: a sequence item outside any key" if stack.empty?

          parent = stack.last[1]
          path = parent + [ items[parent] ]
          items[parent] += 1
          lead!(path, comments)
          stack << [ indent, path ]
          # `- path: .env` opens a mapping whose first key sits two columns in.
          if (k = KEY.match((" " * (indent + 2)) + m[:rest]))
            stack << [ indent + 2, path + [ k[:key] ] ]
          end
        elsif (m = KEY.match(line))
          indent = m[:indent].size
          comments = settle(pending, indent, stack)
          pending = []
          stack.pop while stack.any? && stack.last[0] >= indent
          path = (stack.last ? stack.last[1] : []) + [ m[:key] ]
          lead!(path, comments)
          stack << [ indent, path ]
          @flow << key_for(path) if line.match?(/:\s*\[/)
        else
          raise Error, "docker-compose.yml line #{i + 1}: not a key, a sequence item or a comment (#{line.strip[0, 40]})"
        end
      end
      settle(pending, nil, stack)
    end

    # Returns the comments that LEAD the next node, or files them as the closing comments of an open
    # block. `indent` is the next node's, nil at the end of the file.
    def settle(pending, indent, stack)
      return [] if pending.empty?

      indents = pending.map { |_, ind, _| ind }.uniq
      raise Error, "docker-compose.yml line #{pending.first[0] + 1}: one comment block at two indentations" if indents.size > 1

      at = indents.first
      markers, lines = pending.map(&:last).partition { |text| MARKERS.include?(text) }
      @markers.concat(markers)
      return lines if indent == at

      if indent && at < indent
        raise Error, "docker-compose.yml line #{pending.first[0] + 1}: a comment shallower than the key after it"
      end

      owner = stack.reverse.find { |ind, _| ind < at }
      raise Error, "docker-compose.yml line #{pending.first[0] + 1}: a closing comment with no block to close" unless owner

      (@trailing[key_for(owner[1])] ||= []).concat(lines) unless lines.empty?
      []
    end

    def lead!(path, comments)
      @leading[key_for(path)] = comments unless comments.empty?
    end

    def derive_tools
      services = tree.fetch("services")
      app = services[APP]
      raise Error, "docker-compose.yml has no #{APP} service" unless app.is_a?(Hash)

      env = app["environment"] || {}
      raise Error, "the #{APP} service's environment must be a mapping" unless env.is_a?(Hash)

      reached = env.filter_map do |key, value|
        host = url_host(value)
        [ key, host ] if host && host != APP && services.key?(host)
      end
      tools = reached.map(&:last).uniq
      unknown = services.keys - [ APP ] - tools
      if unknown.any?
        raise Error, "docker-compose.yml runs #{unknown.join(', ')}, which the app does not reach by URL, so the " \
                     "generator cannot tell whether switching the Tools gallery off should remove it"
      end

      { services: tools, env: reached.map(&:first), volumes: named_volumes(tools) - named_volumes(services.keys - tools) }
    end

    def url_host(value)
      URI.parse(value.to_s).host
    rescue URI::Error
      nil
    end

    def named_volumes(names)
      declared = (tree["volumes"] || {}).keys
      names.flat_map { |name| Array(tree.dig("services", name, "volumes")) }.filter_map { |entry|
        source = entry.is_a?(Hash) ? entry["source"] : entry.to_s.split(":").first
        source if declared.include?(source)
      }.uniq
    end

    def derive_share
      volumes = tree.dig("services", APP, "volumes")
      raise Error, "the #{APP} service mounts no volumes" unless volumes.is_a?(Array)

      binds = volumes.each_index.select { |i| volumes[i].is_a?(String) && volumes[i].end_with?(":#{LIBRARY_TARGET}") }
      raise Error, "the #{APP} service must bind exactly one folder to #{LIBRARY_TARGET}; it binds #{binds.size}" unless binds.size == 1

      closing = trailing["volumes"] || []
      start = closing.index { |l| l.match?(/\A# ?[A-Za-z0-9_-]+:\z/) }
      raise Error, "no commented network-share volume closes the volumes: block" unless start

      example = YAML.safe_load(closing[start..].map { |l| l.sub(/\A# ?/, "") }.join("\n"))
      raise Error, "the commented network-share example is not one volume" unless example.is_a?(Hash) && example.size == 1

      name, volume = example.first
      opts = volume.is_a?(Hash) ? volume["driver_opts"] : nil
      unless opts.is_a?(Hash) && %w[type device o].all? { |k| opts[k].is_a?(String) }
        raise Error, "the commented #{name} volume needs driver_opts type, device and o"
      end
      unless (trailing[key_for([ "services", APP, "volumes" ])] || []).include?("# - #{name}:#{LIBRARY_TARGET}")
        raise Error, "the #{APP} service's volumes do not offer `# - #{name}:#{LIBRARY_TARGET}` as the share's mount"
      end

      { service: APP, bind: binds.first, target: LIBRARY_TARGET, volume: name, note: closing[0...start], example: volume }
    end
  end
end
