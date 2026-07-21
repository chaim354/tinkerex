require "net/http"
require "json"

# Typed client for the boxes sidecar (the forked boxes.py). Real HTTP; the sidecar itself is Plan B.
# `configured?` gates the addon's availability (no BOXES_SIDECAR_URL -> the Box Generator shows as
# unavailable, the same graceful degradation the preview renderers use). Tests inject FakeBoxes via
# `BoxesClient.stub` (test/support/fake_boxes.rb).
class BoxesClient
  # param_groups: Array<Hash{"title","advanced",bool,"params"=>Array<Hash>}> — the generator's
  # settings grouped as boxes.py groups them (own settings, Default Settings, then advanced
  # "Settings for <edge/part>" groups).
  Generator = Data.define(:key, :title, :group, :param_groups)
  class Error < StandardError; end

  class << self
    attr_writer :stub

    def configured? = ENV["BOXES_SIDECAR_URL"].present?
    def base_url = ENV.fetch("BOXES_SIDECAR_URL")
    def current = @stub || new(base_url)
    def stubbed? = !@stub.nil?
    def reset! = @stub = nil
  end

  def initialize(base_url) = @base = base_url

  def generators
    get("/generators").map { |g| Generator.new(**g.symbolize_keys.slice(:key, :title, :group, :param_groups)) }
  end

  # Returns SVG bytes (String). Raises Error on a 4xx/5xx.
  def generate(generator:, params:)
    post("/generate", { generator:, params: }, accept: "image/svg+xml")
  end

  private

  def get(path)
    JSON.parse(http(Net::HTTP::Get.new(URI.join(@base, path))).body)
  end

  def post(path, body, accept: "application/json")
    req = Net::HTTP::Post.new(URI.join(@base, path))
    req["Content-Type"] = "application/json"
    req["Accept"] = accept
    req.body = body.to_json
    http(req).body
  end

  def http(req)
    uri = req.uri
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 30) { |h| h.request(req) }
    raise Error, "boxes sidecar #{res.code}: #{res.body.to_s[0, 200]}" unless res.is_a?(Net::HTTPSuccess)

    res
  end
end
