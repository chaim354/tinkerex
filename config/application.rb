require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# THE SYNC ENGINE IS NOT A DEPENDENCY OF THIS APP (Arc D Part 2 -- see the Gemfile for what went
# with it): it is in no Gemfile group, nothing here loads it, and `Sync::` is undefined in this
# process. This line used to be the conditional require that decided. What survives is only
# LibraryBackend itself, required by hand because it sits in config.autoload_lib's `ignore:` list
# (that file argues why one constant must not be owned by Zeitwerk and a manual require at once).
require_relative "../lib/library_backend"

module Tinkerex
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks library_backend.rb])

    # ACTIVE STORAGE VARIANTS ARE OFF, and this is a security setting, not a tuning one.
    #
    # `load_defaults 8.1` sets variant_processor = :vips, which makes Active Storage load
    # ImageProcessing::Vips -> ruby-vips at boot. This app deliberately has no ruby-vips gem: every
    # thumbnail it generates shells out to the `vipsthumbnail` BINARY (see Maker::ImageThumb and
    # the Gemfile comment), precisely so there is no in-process libvips thread pool to deadlock the
    # fork-based parallel test runner. So the variant pipeline was never usable here — it was just
    # silently inert until activestorage 8.1.3.1 (the CVE-2026-66066 fix) added an eager
    # `require "image_processing/vips"` to the transformer. That require raises a LoadError whose
    # message ("ImageProcessing::Vips requires the ruby-vips gem") matches NEITHER arm of the
    # engine's own `rescue LoadError` (/libvips/ and /image_processing/ — note the underscore),
    # so it re-raises and takes the whole boot down instead of degrading to a warning.
    #
    # :disabled is the engine's own supported answer (-> NullTransformer; its warning text names
    # it). Do NOT "fix" this by adding ruby-vips: that reintroduces the parallel-test deadlock the
    # subprocess design exists to avoid. The only `representation` call in the tree is Action
    # Text's attachment partial (app/views/active_storage/blobs/_blob.html.erb), which is
    # unreachable — both rich-text models include Maker::TextOnlyRichText, so no
    # ActionText::Attachment ever persists. Turning it off therefore removes CVE-2026-66066's
    # code path STRUCTURALLY rather than leaving it merely unreachable by argument.
    config.active_storage.variant_processor = :disabled

    # NO CABLE ENDPOINT. This app defines no channel and nothing subscribes to one (see
    # test/cable_absent_test.rb); a device's sync nudge comes from the standalone sync server,
    # which has its own channel and its own cable config on the `sync` accessory.
    #
    # `mount_path = nil` IS THE KNOB, AND DELETING THE `mount` LINE FROM config/routes.rb IS NOT.
    # ActionCable's own engine prepends `mount ActionCable.server => config.action_cable.mount_path`
    # in an after_initialize whenever that path is non-nil, so /cable was drawn TWICE and the
    # hand-written mount in routes.rb was pure redundancy — removing it left `bin/rails routes`
    # byte-identical, which is exactly the shape of a fix that looks done and is not.
    config.action_cable.mount_path = nil

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
