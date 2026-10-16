#!/usr/bin/env ruby
# The landing's four feature crops (docs/superpowers/specs/2026-10-16-landing-format-wall-design.md
# section 3): the app, photographed. Drives headless Chrome at device pixel ratio 2 against a running
# Tinkerex whose demo is seeded from db/seeds/demo, signs in with Try the demo, and writes one
# 1120x700 JPEG per crop into app/assets/images/landing. The demo banner is removed before each
# capture -- it is the public demo's chrome, not the app's -- and NOTHING ELSE on the page is touched.
#
#   bundle exec ruby script/landing/capture_crops.rb http://localhost:8080
#
# Needs `vips` on PATH (Homebrew's) for the JPEG encode. Retake the crops whenever the pages they
# show move; never edit the images by hand.
require "base64"
require "open3"
require "selenium-webdriver"
require "tmpdir"
require "uri"

BASE = ARGV.fetch(0) { abort "usage: capture_crops.rb BASE_URL" }.chomp("/")
OUT = File.expand_path("../../app/assets/images/landing", __dir__)
WIDTH = 1120 # the <img> width/height in app/views/landings/show.html.erb
HEIGHT = 700
ASPECT = WIDTH.fdiv(HEIGHT)

# Each crop: the page (a file found by name, or a path); the viewport it is laid out in, in CSS
# pixels; the button that opens it, if any; when it is ready to photograph; and the frame -- the
# element, how to frame it, and how many CSS pixels of page to keep around it:
#   expand -- the whole element, widened or heightened around its centre to 16:10
#   top    -- the element's full width, 16:10 from its top edge
# THE VIEWPORT IS PER CROP because the frame is the element's own box, and the file page's two
# viewers are shaped by it: the 3D stage is 60vh tall at the column's width, and Measure's stage is
# square, so at 1280x800 a 16:10 frame widened around either one reaches the rail and the file's
# side panel and cuts their words in half. 1280x600 makes the viewer itself 16:10; 1600x900 makes
# Measure and its laser settings, side by side, 16:10.
# The 3D viewer and Measure are LAZY -- each fetches nothing until its button is clicked
# (app/views/files/viewers/_model3d.html.erb, _measure.html.erb) -- and the box generator opens on
# a gallery, so each is opened before the wait.
CROPS = {
  "viewer" => { page: [ :file, "robber.3mf" ], viewport: [ 1280, 600 ],
                open: "[data-action='modelviewer#load']",
                ready: "(document.querySelector('.model-viewer-dims')?.textContent || '').trim().length > 0",
                frame: [ ".model-viewer", "expand", 4 ] },
  "measure" => { page: [ :file, "hex tiles.lbrn2" ], viewport: [ 1600, 900 ],
                 open: "[data-action='measure#load']",
                 ready: "(document.querySelector('.measure-stage')?.childElementCount || 0) > 0",
                 frame: [ ".preview-row", "expand", 16 ] },
  "project" => { page: [ :path, "/projects/catan" ], viewport: [ 1280, 800 ],
                 ready: "!!document.querySelector('.page-head')",
                 frame: [ "main#main", "top", 0 ] },
  "boxes" => { page: [ :path, "/tools/boxes" ], viewport: [ 1280, 800 ],
               open: "a.addon-card[data-terms~='abox']",
               ready: "!!document.querySelector('main img[src^=\"data:image/svg\"]')",
               frame: [ "main :has(> .box-editor)", "top", 16 ] }
}.freeze

FRAME_JS = <<~JS.freeze
  const [selector, frame, margin, aspect] = arguments;
  const r = document.querySelector(selector).getBoundingClientRect();
  let x = r.left + scrollX - margin, y = r.top + scrollY - margin, w = r.width + 2 * margin, h = r.height + 2 * margin;
  if (frame === "expand" && w / h < aspect) { const nw = h * aspect; x -= (nw - w) / 2; w = nw; }
  else if (frame === "expand") { const nh = w / aspect; y -= (nh - h) / 2; h = nh; }
  return { x: Math.max(0, x), y: Math.max(0, y), width: w, height: w / aspect, scale: 1 };
JS

options = Selenium::WebDriver::Chrome::Options.new(args: %w[--headless=new --window-size=1600,900 --hide-scrollbars])
driver = Selenium::WebDriver.for(:chrome, options:)
viewport = ->((width, height)) do
  driver.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height:, deviceScaleFactor: 2, mobile: false)
end
viewport.([ 1280, 800 ])
wait = Selenium::WebDriver::Wait.new(timeout: 90)

begin
  driver.navigate.to "#{BASE}/"
  wait.until { driver.find_elements(xpath: "//button[normalize-space()='Try the demo']").first }.click
  wait.until { driver.find_elements(css: "aside.rail").any? }

  CROPS.each do |name, crop|
    viewport.(crop.fetch(:viewport)) # before the page loads: both viewers size their stage once, on open
    kind, target = crop.fetch(:page)
    if kind == :file
      driver.navigate.to "#{BASE}/files?q=#{URI.encode_www_form_component(target)}"
      link = wait.until do
        driver.find_elements(xpath: "//main//a[contains(@href,'/files/')][contains(normalize-space(.), \"#{target}\")]").first
      end
      driver.navigate.to link.attribute("href")
    else
      driver.navigate.to "#{BASE}#{target}"
    end
    wait.until { driver.find_elements(css: crop[:open]).find(&:displayed?) }.click if crop[:open]
    wait.until { driver.execute_script("return #{crop.fetch(:ready)}") }
    sleep 3 # a WebGL frame, the Measure stage and an addon bundle all finish drawing after "ready"
    driver.execute_script("document.querySelector('.demo-banner')?.remove(); window.scrollTo(0, 0)")
    clip = driver.execute_script(FRAME_JS, *crop.fetch(:frame), ASPECT)
    data = driver.execute_cdp("Page.captureScreenshot", format: "png", clip:, captureBeyondViewport: true)["data"]

    Dir.mktmpdir do |dir|
      png = File.join(dir, "#{name}.png")
      File.binwrite(png, Base64.decode64(data))
      out = File.join(OUT, "#{name}.jpg")
      _, err, status = Open3.capture3("vips", "thumbnail", png, "#{out}[Q=82,strip]", WIDTH.to_s,
                                      "--height", HEIGHT.to_s, "--size", "force")
      abort "vips failed for #{name}: #{err}" unless status.success?
      puts "wrote #{out}"
    end
  end
ensure
  driver.quit
end
