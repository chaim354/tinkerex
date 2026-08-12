require "net/http"
require "json"

# Typed client for the OpenSCAD sidecar. Real HTTP; the sidecar is a separate GPL-2.0 image we never
# link (CLAUDE.md §9). `configured?` gates the addon's availability — no OPENSCAD_SIDECAR_URL and the
# tool greys out, the same graceful degradation Boxes and the preview renderers use. Tests inject
# FakeOpenscad via `OpenscadClient.stub` (test/support/fake_openscad.rb).
class OpenscadClient
  # param_groups: Array<Hash{"title","advanced",bool,"params"=>Array<Hash>}> — the .scad's own
  # Customizer groups, normalized by the sidecar into the SAME shape BoxesClient::Generator uses so
  # the two addons' field partials stay aligned rather than drifting apart.
  Generator = Data.define(:key, :title, :description, :license, :attribution, :source_url,
                          :params, :param_groups)
  class Error < StandardError; end
  # A submitted PARAMETER VALUE the sidecar refused to coerce (sidecar/openscad/coerce.py). A
  # SUBCLASS rather than a flag or a second top-level class, so every existing `rescue
  # OpenscadClient::Error` keeps catching it and only the one caller that must branch on WHY says so
  # — §14a's rule for exactly this shape.
  class InvalidParams < Error; end

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
    raise refusal(res) unless res.is_a?(Net::HTTPSuccess)

    res
  end

  # THE STATUS ALONE CANNOT TELL THE TWO 422s APART, AND THE CALLER MUST. The sidecar answers 422
  # both for a .scad it cannot parse and for a submitted VALUE it refuses to coerce, and
  # Tools::OpenscadController reacts differently to each: a rejected value is something the user can
  # fix, so the editor comes back with their own form still in it; a broken source is not, so it
  # bounces to the index. The sidecar tags the one it means with `code: "invalid_params"`, and this
  # matches on that CODE and never on the prose — the prose is a human sentence, free to be reworded
  # in a sidecar release that never rebuilds Rails.
  def refusal(res)
    body = parsed_body(res)
    # Surface the sidecar's own {"error": …} when it sent one — it names the actual OpenSCAD
    # complaint ("Parser error: syntax error…"), which is the only thing the user can act on.
    detail = (body["error"].presence || res.body.to_s[0, 200]).presence
    klass = body["code"] == "invalid_params" ? InvalidParams : Error
    klass.new(detail || "openscad sidecar #{res.code}")
  end

  # -> Hash, ALWAYS. `is_a?(Hash)` and not merely a rescue: a body of `null` or `[]` parses fine and
  # then answers `[]` to `body["error"]` (a TypeError) or nil to `body["code"]`, so "it parsed" is
  # not the same question as "it is the object shape we are about to index".
  def parsed_body(res)
    parsed = JSON.parse(res.body.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue StandardError
    {}
  end
end
