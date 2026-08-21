# frozen_string_literal: true

require "net/http"
require "json"

module FileLayer
  class ChunkRemote
    # THE WIRE FOR `chunk_remote` — the maker app talking to a standalone sync server as an ordinary
    # DEVICE, over the same v1 API a desktop client uses. Stage 4; design doc §6.
    #
    # ZERO NEW SERVER ENDPOINTS, which is the design's central claim and the reason this class is
    # thin: every port verb already has one (mkdir POST /v1/nodes, move POST /v1/nodes/:id/move,
    # delete DELETE /v1/nodes/:id, undelete POST /v1/trash/:id/restore, upload POST /v1/commits +
    # finalize, hydrate POST /v1/chunks/download, catalog GET /v1/changes). If a verb here ever
    # needs a new endpoint, that is a signal the port grew a shape the sync protocol does not have —
    # stop and reconsider rather than adding one.
    #
    # Net::HTTP from stdlib, matching Maker::Addons::ServiceProxy rather than introducing a client
    # gem: §9 keeps dependencies permissive and few, and this needs nothing Faraday would add.
    class Transport
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 30

      # THE ERROR MAPPING IS THE WHOLE DESIGN OF THIS CLASS, and it is a direct application of an
      # invariant §14a already paid for on share: "an unmounted share must never read as 'your file
      # is permanently gone'". A remote sync server is an unmounted share with a longer wire.
      #
      #   timeout / refused / 5xx  -> FetchError          RETRYABLE. Renders 503. The file is fine;
      #                                                   the network or the server is not.
      #   404                      -> NotFound            TERMINAL. Renders 404. The node is gone.
      #   409 / 422                -> UnsupportedOperation Renders 422. A clobber, a cycle, a name
      #                                                   the server refuses -- never succeeds on
      #                                                   retry, which is exactly what separates it
      #                                                   from FetchError.
      #   401 / 403                -> FetchError          DELIBERATELY RETRYABLE, not terminal. A
      #                                                   rejected device token is an operator
      #                                                   condition (expired, rotated, revoked), not
      #                                                   a statement about the file. Answering 404
      #                                                   would tell a user their library vanished
      #                                                   because a credential lapsed.
      #   501                      -> UnsupportedOperation The server gated the verb. Terminal for
      #                                                   this deployment, same as any other backend
      #                                                   refusing a capability it lacks.
      def initialize(base_url:, token:, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
        @base_url = base_url.to_s.chomp("/")
        @token = token
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def get(path, params = {}) = request(Net::HTTP::Get, path, params:)
      def post(path, body = {}) = request(Net::HTTP::Post, path, body:)
      def delete(path) = request(Net::HTTP::Delete, path)

      private

      def request(klass, path, params: nil, body: nil)
        uri = URI.parse("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(params) if params.present?

        req = klass.new(uri)
        req["Authorization"] = "Bearer #{@token}"
        req["Accept"] = "application/json"
        if body
          req["Content-Type"] = "application/json"
          req.body = body.to_json
        end

        response = perform(uri, req)
        interpret(response, path)
      end

      # EVERY TRANSPORT-LEVEL FAILURE BECOMES FetchError HERE, including the ones Net::HTTP raises
      # rather than returns. Letting a raw Errno or Timeout escape would reach FilesController's
      # rescue table as an unmapped StandardError and 500 -- a network blip presented to the user as
      # a broken application.
      def perform(uri, req)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
          http.request(req)
        end
      rescue Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET,
             SocketError, OpenSSL::SSL::SSLError, IOError => e
        raise FileLayer::FetchError, "sync server unreachable (#{e.class}): #{e.message}"
      end

      def interpret(response, path)
        code = response.code.to_i
        return parse(response) if code.between?(200, 299)

        body = parse(response)

        # `chunks_missing` IS A PORT CONDITION WITH ITS OWN CLASS, AND IT CARRIES DATA. The server
        # answers it as a 422, which the generic arm below would flatten into UnsupportedOperation --
        # discarding the `missing` hashes, which are the entire point of the error: the caller is
        # meant to upload those chunks and finalize again. Mapping it here rather than in the
        # adapter keeps this class's job intact (wire condition -> port vocabulary) instead of
        # making the adapter re-parse a message the transport already read.
        raise FileLayer::ChunksMissing, Array(body["missing"]) if body["error"] == "chunks_missing"

        message = error_message(response) || "HTTP #{code}"
        case code
        when 404          then raise FileLayer::NotFound, "#{path}: #{message}"
        when 409, 422     then raise FileLayer::UnsupportedOperation, "#{path}: #{message}"
        when 501          then raise FileLayer::UnsupportedOperation, "#{path}: #{message}"
        when 401, 403     then raise FileLayer::FetchError, "sync server rejected this device (#{code}): #{message}"
        else                   raise FileLayer::FetchError, "sync server error #{code} on #{path}: #{message}"
        end
      end

      # A BODY THAT IS NOT JSON IS NOT AN ERROR BY ITSELF -- a proxy's own 502 page, a load
      # balancer's plain-text 503. The status has already been read; the body is only here to make
      # the message useful, so a parse failure must not replace a clear 503 with a JSON::ParserError.
      def parse(response)
        return {} if response.body.blank?

        JSON.parse(response.body)
      rescue JSON::ParserError
        {}
      end

      def error_message(response)
        body = parse(response)
        body["error"].presence || body["errors"]&.first.presence
      end
    end
  end
end
