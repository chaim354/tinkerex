# frozen_string_literal: true

namespace :lbrn do
  # A MANUAL PROBE, DELIBERATELY NOT A CI GATE.
  #
  # The 58 real LightBurn exports this feature was sized against are the only real-format
  # validation set there is — the repo's own fixtures are hand-authored, and the parser that
  # matched an invented dialect drew 1.0% of real shapes. But that corpus cannot live in the repo
  # (it is a user's own designs, and one file is 24 MB), so a CI gate over it would either be
  # skipped everywhere or fail on a fresh clone. This is the honest shape instead: point it at a
  # directory when you want the numbers, and read them yourself.
  #
  # What it is FOR: catching a payload regression that no fixture can show. The decimation
  # thresholds and the "excluded bitmaps" rule were both chosen from measurements over that corpus
  # (median 5 KB gzipped, worst 281 KB), and a change that quietly re-inflates the payload — most
  # obviously, letting bitmap base64 back in — is invisible in a suite whose largest fixture is
  # 2.4 KB. Compare against docs/superpowers/specs/2026-08-06-lightburn-shape-dimensions-design.md §3.
  desc "Geometry payload report over a directory of real .lbrn2 files (manual probe, NOT a gate)"
  task :geometry_report, [ :dir ] => :environment do |_t, args|
    dir = args[:dir] or abort "usage: rake 'lbrn:geometry_report[/path/to/lbrn2/files]'"
    files = Dir.glob(File.join(File.expand_path(dir), "**", "*.lbrn2"))
    abort "no .lbrn2 files under #{dir}" if files.empty?

    require "zlib"

    rows = files.filter_map do |path|
      bytes = File.binread(path)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      json = Maker::Previews::LbrnGeometry.render(bytes)[:bytes]
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
      payload = JSON.parse(json)

      { name: File.basename(path), contours: payload["shapes"].length, ms:,
        kb: (json.bytesize / 1024.0).round(1),
        gz: (Zlib::Deflate.deflate(json, 6).bytesize / 1024.0).round(1) }
    rescue StandardError => e
      # A SKIP IS A FINDING, NOT NOISE — it means a real file no longer parses. Printed to stderr
      # per file rather than aborting, so one bad file cannot hide the other 57's numbers.
      warn "SKIP #{File.basename(path)}: #{e.class}: #{e.message}"
      nil
    end
    abort "every file failed to parse — check the path and the parser" if rows.empty?

    rows.sort_by! { |r| -r[:gz] }
    printf("%-38s %8s %8s %9s %10s\n", "file", "contours", "ms", "json KB", "gzipped KB")
    rows.each do |r|
      printf("%-38s %8d %8s %9s %10s\n", r[:name][0, 38], r[:contours], r[:ms], r[:kb], r[:gz])
    end

    median = ->(key) { v = rows.map { |r| r[key] }.sort; v[v.length / 2] }
    skipped = files.length - rows.length
    puts
    puts "#{rows.length} files · median #{median.call(:gz)} KB gzipped, #{median.call(:ms)} ms · " \
         "worst #{rows.first[:gz]} KB (#{rows.first[:name]})"
    puts "#{skipped} file(s) SKIPPED — see stderr above" if skipped.positive?
  end
end
