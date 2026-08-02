require "net/http"
require "json"

module Tools
  # Typed client for the OpenSCAD sidecar. Real HTTP; the sidecar is a separate GPL-2.0 image we never
  # link (CLAUDE.md §9). `configured?` gates the addon's availability — no OPENSCAD_SIDECAR_URL and the
  # tool greys out, the same graceful degradation Boxes and the preview renderers use. Tests inject
  # FakeOpenscad via `Tools::OpenscadClient.stub` (test/support/fake_openscad.rb).
  class OpenscadClient
    # param_groups: Array<Hash{"title","advanced",bool,"params"=>Array<Hash>}> — the .scad's own
    # Customizer groups, normalized by the sidecar into the SAME shape Tools::BoxesClient::Generator uses so
    # the two addons' field partials stay aligned rather than drifting apart.
    Generator = Data.define(:key, :title, :description, :license, :attribution, :source_url,
                            :params, :param_groups)
    class Error < StandardError; end

    # Renders can legitimately take up to the sidecar's 60 s cap, so this read timeout must sit ABOVE
    # it — otherwise Rails gives up on a render that is about to succeed and the user sees a generic
    # failure instead of the sidecar's specific 422.
    RENDER_READ_TIMEOUT = 90
    READ_TIMEOUT = 30
    OPEN_TIMEOUT = 3

    class << self
      attr_writer :stub

      # `.present?` and not `.nil?`: deploy.ovh.yml un-inherits Kamal's deep-merged env.clear by
      # setting the URL to "", so a BLANK url means "no sidecar here" just as much as a missing one.
      def configured? = ENV["OPENSCAD_SIDECAR_URL"].present?
      def base_url = ENV.fetch("OPENSCAD_SIDECAR_URL")
      def current = @stub || new(base_url)
      def stubbed? = !@stub.nil?
      def reset! = @stub = nil
    end

    def initialize(base_url) = @base = base_url

    def generators
      get("/generators").map do |g|
        Generator.new(**g.symbolize_keys.slice(:key, :title, :description, :license, :attribution,
                                               :source_url, :params, :param_groups))
      end
    end

    # The raw .scad for a bundled generator. Rails fetches this and posts it to #render exactly as it
    # posts a bring-your-own file's bytes — that is what keeps ONE render path (spec §3.1).
    #
    # The re-tag is load-bearing, not tidiness. Net::HTTP hands EVERY body back as ASCII-8BIT, and this
    # text goes straight back out as JSON in #render's body: `to_json` on a BINARY string holding a
    # degree sign or an accented author's name warns today ("UTF-8 string passed as BINARY") and RAISES
    # under json 3.0 — on the catalog render path, which is the addon's main flow. Lossless, because
    # the sidecar declares text/plain; charset=utf-8 and reads its catalog with encoding="utf-8".
    def source(key)
      http(Net::HTTP::Get.new(URI.join(@base, "/source/#{key}"))).body.force_encoding(Encoding::UTF_8)
    end

    # Customizer schema for ARBITRARY source -> { "params" => [...], "param_groups" => [...] }.
    def params_for(scad)
      JSON.parse(post("/params", { scad: }))
    end

    # 3MF bytes (String). Raises Error on 4xx/5xx.
    def render(scad:, params:, format: "3mf")
      post("/render", { scad:, params:, format: }, accept: "model/3mf", read_timeout: RENDER_READ_TIMEOUT)
    end

    private

    def get(path)
      JSON.parse(http(Net::HTTP::Get.new(URI.join(@base, path))).body)
    end

    def post(path, body, accept: "application/json", read_timeout: READ_TIMEOUT)
      req = Net::HTTP::Post.new(URI.join(@base, path))
      req["Content-Type"] = "application/json"
      req["Accept"] = accept
      req.body = body.to_json
      http(req, read_timeout:).body
    end

    def http(req, read_timeout: READ_TIMEOUT)
      uri = req.uri
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: OPEN_TIMEOUT, read_timeout:) { |h| h.request(req) }
      unless res.is_a?(Net::HTTPSuccess)
        # Surface the sidecar's own {"error": …} when it sent one — it names the actual OpenSCAD
        # complaint ("Parser error: syntax error…"), which is the only thing the user can act on.
        raise Error, error_detail(res) || "openscad sidecar #{res.code}"
      end

      res
    end

    def error_detail(res)
      body = res.body.to_s
      detail = begin
        JSON.parse(body)["error"]
      rescue StandardError
        nil
      end
      (detail || body[0, 200]).presence
    end
  end
end
